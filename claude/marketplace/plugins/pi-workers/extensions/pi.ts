import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Worker bus protocol (ft014 / sp028 T1) — contract only.
//
// These definitions are the extension's half of the contract implemented in
// scripts/pi-worker.nu. The inbox watcher and the typed result tool land
// in sp028 T4; what lives here is the shape both sides must agree on, so the
// two halves cannot drift silently.
//
// TRANSPORT BOUNDARY: tmux hosts and displays workers. It is not the bus.
// Nothing in this extension may use tmux send-keys, wait-for, pane options, or
// display-message to carry a message, a completion signal, or any coordination
// state. Envelopes travel through the runtime directory and nowhere else.

/** Bumped only for an incompatible envelope change; unknown versions fail closed. */
export const PROTOCOL_VERSION = 1;

/** A bus message addresses work — it never carries it. */
export const MAX_ENVELOPE_BYTES = 65536;

/** What the initiator reads inline; detail stays in the window and the JSONL. */
export const MAX_SUMMARY_BYTES = 4096;

export type EnvelopeKind = "inbox" | "result" | "error";

/**
 * Persisted worker states. `unknown` is deliberately absent: it is an
 * observational verdict ("the evidence does not say") and per adr0017 it never
 * licenses stopping, accepting, or deleting a worker.
 */
export type WorkerState =
  | "created"
  | "running"
  | "waiting_human"
  | "blocked"
  | "failed"
  | "complete"
  | "protocol_error"
  | "accepted"
  | "stopped";

/**
 * Statuses a worker may report about itself. `accepted` is the initiator's
 * verdict and `stopped` is an external act, so neither is claimable here.
 */
export const RESULT_STATUSES = ["complete", "waiting_human", "blocked", "failed"] as const;

export type ResultStatus = (typeof RESULT_STATUSES)[number];

/** Stages whose entire work content is a bd ticket id (ft013). */
/** Stages the bus authors itself; they need no consumer declaration. */
export const RESERVED_STAGES = ["rejection"] as const;

export interface Envelope<P = unknown> {
  protocol: typeof PROTOCOL_VERSION;
  sequence: number;
  run: string;
  uid: string;
  kind: EnvelopeKind;
  created: string;
  payload: P;
}

/**
 * A work stage receives its bd task id and nothing else; it resolves the
 * work itself from that id. Copying the body into the payload would
 * create a second source of truth that drifts from bd on the next update.
 */
export interface WorkPayload {
  stage: string;
  task: string;
}

/** An instruction stage gets prose plus artifact ids. */
export interface InstructionPayload {
  stage: string;
  instructions: string;
  artifacts: string[];
}

export interface ResultPayload {
  status: ResultStatus;
  summary: string;
  /** Required when status is "complete": completion is gated on validation. */
  validation: string | null;
  window: string;
  session: string;
  /** The exact `pi --session <id>` command that resumes this worker. */
  resume: string;
  task?: string;
  artifact?: string;
  commit?: string;
}

/**
 * The reason the typed result tool exists.
 *
 * An agent that finishes its turn without calling it has not completed
 * anything — there is no verdict, no summary, no resume evidence, only an idle
 * prompt. Completion must never be inferred from an idle prompt, an exited
 * pane, or assistant prose claiming success, so the absence of a result
 * envelope is itself reported, as this error.
 */
export const SETTLED_WITHOUT_RESULT = {
  code: "protocol_error",
  detail:
    "agent settled without calling the typed result tool; completion is never inferred from an idle prompt, an exited pane, or assistant prose",
} as const;

// ---------------------------------------------------------------------------
// Bridge decisions (sp028 T4).
//
// Everything below is pure so it can be tested without a running Pi. The parts
// that touch the live agent — the inbox watcher and the actual
// pi.sendUserMessage() call — are thin wrappers over these decisions, because
// the decisions are where a mistake hides: a steer sent during compaction, or
// a task body quietly copied into a work payload, both look fine at a glance.

export type AgentState = "idle" | "streaming" | "compacting" | "shutting_down" | string;

export interface DeliveryDecision {
  mode: "followUp" | "steer" | "defer";
  reason: string;
}

/**
 * How — or whether — to deliver a message given what the agent is doing.
 *
 * `defer` is never a drop. The bus redelivers until the message is
 * acknowledged, so declining now costs one more poll; delivering at the wrong
 * moment costs a corrupted turn. Anything not positively known to be safe
 * therefore defers, including states this build has never heard of.
 */
export function decideDelivery(state: AgentState, _envelope: Envelope): DeliveryDecision {
  switch (state) {
    case "idle":
      return { mode: "followUp", reason: "agent is idle; deliver as a normal user turn" };
    case "streaming":
      return { mode: "steer", reason: "agent is mid-turn; steer rather than interrupt blindly" };
    case "compacting":
      return {
        mode: "defer",
        reason: "agent is compacting; injecting a turn races the history being rewritten",
      };
    case "shutting_down":
      return { mode: "defer", reason: "agent is shutting down; the message would be lost" };
    default:
      return {
        mode: "defer",
        reason: `unknown agent state '${state}'; deferring rather than guessing it is safe`,
      };
  }
}

// ---------------------------------------------------------------------------
// Agent state, derived from events (dotfiles-zxzj).
//
// Pi's ExtensionAPI exposes NO state getter. An earlier build of this bridge
// called `host.agentState()` — an API that looks like it ought to exist and
// does not — so every poll fell through to the literal string "unknown",
// `decideDelivery` correctly refused to guess, and a live worker deferred the
// same message once a second forever without ever receiving it.
//
// The state machine was right; the source it read from was imaginary. So the
// vocabulary below is unchanged and only its origin moves: subscribe to the
// lifecycle events Pi really publishes and keep the last one seen.
//
// Every event name here appears on `ExtensionAPI.on()` in
// @earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts (0.84.4),
// checked against the installed package rather than assumed.

/** The subset of ExtensionAPI the tracker needs: just event subscription. */
export interface StateEventSource {
  on(event: string, handler: (event: unknown) => unknown): void;
}

export interface AgentStateTracker {
  current(): AgentState;
}

/**
 * Track what the agent is doing by watching its lifecycle events.
 *
 * Starting state is `idle`, not `unknown`: a freshly spawned worker sits at a
 * prompt with nothing running, and that is precisely when the orchestrator
 * sends its first message. Starting at `unknown` is what turned a missing API
 * into a permanent stall rather than a transient one.
 *
 * `agent_settled` — not `agent_end` — is what returns us to `idle`. Pi
 * documents settled as "after an agent run has fully settled and no automatic
 * retry, compaction, or queued continuation will run"; `agent_end` merely ends
 * the loop and may be followed by any of those three. Treating `agent_end` as
 * idle would deliver a user turn into a run that is about to resume.
 *
 * Compaction clears on either outcome. Leaving a failed compaction latched
 * would make the worker defer everything for the rest of its life, and the
 * hazard `decideDelivery` guards — a turn racing the history rewrite — is over
 * once compaction stops either way. If a continuation does follow,
 * `agent_start` says so and delivery becomes a steer.
 *
 * `shutting_down` is terminal: a late event must not make a dying session look
 * deliverable again.
 */
export function createAgentStateTracker(source: StateEventSource): AgentStateTracker {
  let state: AgentState = "idle";

  const set = (next: AgentState) => () => {
    if (state === "shutting_down") return;
    state = next;
  };

  const transitions: Array<[string, () => void]> = [
    ["agent_start", set("streaming")],
    ["agent_settled", set("idle")],
    ["session_before_compact", set("compacting")],
    ["session_compact", set("idle")],
    ["session_compact_failed", set("idle")],
    [
      "session_shutdown",
      () => {
        state = "shutting_down";
      },
    ],
  ];

  for (const [event, handler] of transitions) {
    // Subscribe defensively. A Pi that renamed or dropped one of these events
    // costs precision in one signal; an exception thrown while the host is
    // loading extensions would take the entire worker down, which is strictly
    // worse than a worker that occasionally defers a message it could have
    // delivered.
    try {
      source.on(event, handler);
    } catch {
      // Nothing to recover: the signal simply will not arrive.
    }
  }

  return { current: () => state };
}

/**
 * Whether a stage's message is an ADDRESS (a ticket id) or prose.
 *
 * Read from the consumer's stage registry, so the bus never has to know what
 * any particular stage means. A stage the bus authors itself is prose by
 * construction.
 */
function isTicketStage(stage: string): boolean {
  if ((RESERVED_STAGES as readonly string[]).includes(stage)) return false;
  for (const entry of loadStages()) {
    if (entry.name === stage) return entry.payload === "ticket";
  }
  throw new Error(`unknown stage '${stage}': not declared in the stage registry`);
}

export interface StageEntry {
  name: string;
  isolation: string;
  payload: string;
}

/**
 * The declared stages, for the tool description.
 *
 * Live: an agent tried `default`, then `work-do`, then `build`, and never
 * tried `probe` — the one it wanted. Every guess cost a turn and a refusal,
 * and the refusals were the third place it learned the names rather than the
 * first. A stage is a required argument with a closed set of values; nothing
 * is served by making the model discover that set by being told no.
 *
 * The payload kind is carried too, because knowing the name is not enough:
 * after landing on `build` the agent was refused again for having no ticket
 * id. Name plus payload is the whole decision.
 *
 * One line, because this goes in a tool description. An empty registry says so
 * explicitly — a tool that lists nothing reads as a tool that accepts
 * anything.
 */
export function stageCatalogue(stages: StageEntry[]): string {
  if (stages.length === 0) {
    return "no stages are declared, so nothing can be spawned until the registry has one";
  }
  return stages.map((s) => `${s.name} (${s.payload})`).join(", ");
}

/**
 * The stage catalogue, or a note that it could not be read.
 *
 * Used to build a tool description, which is evaluated during registration —
 * so this must not throw. A missing or malformed registry is a real condition
 * (the consumer has not installed one yet) and saying so in the description is
 * more use to the caller than taking the extension down.
 */
function describeStages(): string {
  try {
    return stageCatalogue(loadStages());
  } catch {
    return "the stage registry could not be read; run `pi-worker doctor`";
  }
}

/** The consumer's stage registry, located the same way the CLI locates it. */
function loadStages(): StageEntry[] {
  const explicit = process.env.PI_WORKER_STAGES;
  const base =
    process.env.XDG_CONFIG_HOME ?? join(process.env.HOME ?? "", ".config");
  const path = explicit && explicit.length > 0 ? explicit : join(base, "pi-workers", "stages.json");
  const parsed = JSON.parse(readFileSync(path, "utf8")) as { stages?: StageEntry[] };
  if (!Array.isArray(parsed.stages)) {
    throw new Error(`stage registry ${path} must be an object with a 'stages' list`);
  }
  return parsed.stages;
}

/**
 * The user-visible message text for an inbox envelope.
 *
 * For a work stage this is the bare bd task id and nothing else — no framing,
 * no skill name, no instructions. The worker resolves its contract with
 * that id, and any prose here becomes a second description of the work
 * that drifts from bd the moment the ticket is edited.
 *
 * A payload that violates the shape is REJECTED rather than trimmed to fit:
 * trimming would hide the caller's mistake and deliver a message the protocol
 * says cannot exist.
 */
export function userPayloadFor(envelope: Envelope): string {
  const payload = envelope.payload as Record<string, unknown>;
  const stage = String(payload.stage ?? "");

  if (isTicketStage(stage)) {
    const extra = Object.keys(payload).filter((k) => k !== "stage" && k !== "task");
    if (extra.length > 0) {
      throw new Error(
        `work-stage payload for '${stage}' may carry only stage and task; found ${extra.join(", ")}`,
      );
    }
    if (!payload.task) {
      throw new Error(`work-stage payload for '${stage}' must carry its bd task id`);
    }
    return String(payload.task);
  }

  if (!payload.instructions) {
    throw new Error(`payload for '${stage}' must carry direct instructions`);
  }
  const artifacts = Array.isArray(payload.artifacts) ? payload.artifacts : [];
  return artifacts.length > 0
    ? `${payload.instructions}\n\nArtifacts: ${artifacts.join(", ")}`
    : String(payload.instructions);
}

/**
 * Trusted configuration for the worker, delivered as system context.
 *
 * Role, skill, worktree and session are transport configuration the
 * orchestrator sets — not something the worker should read as if a user had
 * typed it. Keeping them out of the user message is what makes the work
 * payload's "just the ticket id" rule meaningful.
 */
export function systemContextFor(identity: WorkerIdentity, isolation?: string): string {
  return [
    `You are a pi-worker.`,
    `role: ${identity.role}`,
    `skill: ${identity.skill}`,
    `worktree: ${identity.cwd}`,
    `branch: ${identity.branch}`,
    `session: ${identity.session}`,
    `window: ${identity.window}`,
    // An isolated worker's tree is thrown away when its work is accepted, and
    // the branch is what gets merged — so uncommitted work is not "nearly
    // done", it is lost. The bus refuses a `complete` from a dirty worktree
    // for that reason; being told here means not learning it from a refusal.
    ...(isolation === "worktree"
      ? [
          `Your work lives on branch ${identity.branch} and nowhere else. COMMIT it`,
          `before you report complete: this worktree is deleted when the work is`,
          `accepted, and an uncommitted branch merges as a no-op, so an uncommitted`,
          `complete loses everything you did. A complete from a dirty tree is refused.`,
        ]
      : []),
    // The mirror image, and the more surprising one. A main-isolation worker
    // is standing in the operator's own checkout on their branch, where the
    // ordinary instinct of a coding agent — finish, commit — is the wrong
    // move. Six such commits reached this repo's main in one evening. git
    // refuses them now; saying so here means not spending a turn finding out.
    ...(isolation === "main"
      ? [
          `You are in the operator's OWN working tree, on their branch`,
          `(${identity.branch}). Do not commit and do not push: both are refused by`,
          `a hook, because a commit here lands on their branch rather than one of`,
          `your own. Leave your changes in the tree and report what you did. If the`,
          `work genuinely needs its own commit, it needs a stage declared with`,
          `isolation: worktree — say so by reporting blocked.`,
        ]
      : []),
    `Report your outcome by calling the result tool. Finishing your turn without`,
    `calling it is recorded as a protocol error, not a success.`,
  ].join("\n");
}

/**
 * The worker's briefing, as prompt-guideline bullets.
 *
 * `systemContextFor` above produced exactly the right words and nothing ever
 * called it — grep returned one line, its own definition. So no worker was
 * ever told to report, every worker settled, and every settle was recorded as
 * a protocol error. It had two passing tests; both asserted what it returned
 * and neither asserted that anything delivered it.
 *
 * `promptGuidelines` on a ToolDefinition is the delivery route, and its
 * scoping is the reason to prefer it: `pi_worker_result` is registered ONLY in
 * worker mode, so these bullets reach a worker's system prompt and can never
 * leak into an ordinary session. A tool DESCRIPTION would not do — that is
 * read once the model is already considering the tool, and answers "what does
 * this do" rather than "must I call something before finishing".
 *
 * One line per bullet, and the text comes from systemContextFor rather than
 * being restated, so there is one source for the contract.
 */
export function workerPromptGuidelines(identity: WorkerIdentity, isolation?: string): string[] {
  return systemContextFor(identity, isolation).split("\n");
}

export interface WorkerIdentity {
  role: string;
  cwd: string;
  branch: string;
  session: string;
  skill: string;
  window: string;
}

function utf8Bytes(value: string): number {
  return new TextEncoder().encode(value).length;
}

/**
 * Validate and complete the worker's typed result.
 *
 * The worker supplies the outcome; the window, session and resume command come
 * from the identity the orchestrator recorded, so a worker cannot misreport
 * where it lives or how to reach it.
 */
export function resultEnvelopeFrom(
  input: { status: string; summary: string; validation?: string | null; [k: string]: unknown },
  identity: WorkerIdentity,
): ResultPayload {
  const status = input.status;
  if (!(RESULT_STATUSES as readonly string[]).includes(status)) {
    throw new Error(
      `'${status}' is not a status a worker may report; expected one of ${RESULT_STATUSES.join(", ")}`,
    );
  }
  // Byte length, not .length: the cap protects the file written to the bus,
  // and a summary of multi-byte characters is far larger on disk than in
  // UTF-16 code units.
  if (utf8Bytes(input.summary ?? "") > MAX_SUMMARY_BYTES) {
    throw new Error(
      "result summary exceeds the 4 KiB summary cap; detail belongs in the worker window and the Pi transcript",
    );
  }
  const validation = input.validation ?? null;
  if (status === "complete" && !validation) {
    throw new Error(
      "a 'complete' result must carry its validation verdict: completion cannot be reported before the stage's required validation passes",
    );
  }
  return {
    status: status as ResultStatus,
    summary: input.summary,
    validation,
    window: identity.window,
    session: identity.session,
    resume: `pi --session ${identity.session}`,
  };
}

/** The error envelope payload for an agent that settled without reporting. */
export function settledWithoutResult(_identity: WorkerIdentity) {
  return { ...SETTLED_WITHOUT_RESULT };
}

/**
 * Inbox messages a session still owes, in sequence order.
 *
 * `delivered` is a high-water mark rather than a per-message flag so that a
 * resumed session cannot replay a turn it already took: sequences are
 * monotonic, so everything at or below the mark has been seen. A mark past the
 * end of the inbox (the extension reloaded between delivering and persisting)
 * yields nothing rather than replaying.
 */
export function unreadAfter(delivered: number, inbox: Envelope[]): Envelope[] {
  return inbox
    .filter((envelope) => envelope.sequence > delivered)
    .sort((a, b) => a.sequence - b.sequence);
}

// ---------------------------------------------------------------------------
// Inbox watcher.
//
// Deliberately written against an injected IO surface rather than importing
// node:fs directly, so the whole loop — scanning, ordering, the high-water
// mark, and the delivery call — is exercised by a fake in pi.test.ts. The real
// wiring at the bottom of this file supplies the filesystem.
//
// UNVERIFIED AGAINST A LIVE PI: the agent-state strings and the exact shape of
// pi.sendUserMessage() are assumptions — the Pi package is not installed here,
// so there is nothing to type-check them against. Both are reconciled in the
// sp028 T7 operator run. Every call is therefore feature-detected: a missing
// or renamed API degrades to a logged no-op rather than throwing inside the
// host, and an unrecognised agent state defers (see decideDelivery), so a
// wrong guess costs a redelivery instead of a corrupted turn.

export interface WatcherIO {
  /** Envelope filenames in the worker's inbox directory. */
  list(dir: string): string[];
  /** Raw contents of one envelope. */
  read(path: string): string;
  join(...parts: string[]): string;
  /** Structured log line; never throws. */
  log(line: string): void;
}

export interface WatcherHost {
  /** Current agent state, if the host exposes one. */
  agentState?: () => AgentState;
  /**
   * Pi's real signature (0.84.4):
   *   sendUserMessage(content, { deliverAs?: "steer" | "followUp",
   *                              expandPromptTemplates?: boolean })
   *
   * The option key is `deliverAs`. An earlier build passed `{ mode }`; Pi
   * ignores an unrecognised key, so the call succeeded and quietly used
   * default delivery — a steer intended to land mid-turn queued as an
   * ordinary follow-up instead. Silent, and invisible to a fake that mirrored
   * the same wrong key.
   */
  sendUserMessage?: (
    text: string,
    options?: { deliverAs?: "steer" | "followUp"; expandPromptTemplates?: boolean },
  ) => unknown;
}

export interface InboxWatcher {
  /** Deliver everything owed. Returns the sequences actually delivered. */
  poll(): number[];
  delivered(): number;
}

export function createInboxWatcher(
  host: WatcherHost,
  identity: WorkerIdentity,
  inboxDir: string,
  io: WatcherIO,
): InboxWatcher {
  // The high-water mark lives in the closure and is re-derived on resume from
  // what the host has already been told; see unreadAfter for why a mark rather
  // than per-message flags.
  let mark = 0;

  function load(): Envelope[] {
    const envelopes: Envelope[] = [];
    for (const name of io.list(inboxDir)) {
      if (!name.endsWith(".json")) continue; // scratch files are not envelopes
      let parsed: unknown;
      try {
        parsed = JSON.parse(io.read(io.join(inboxDir, name)));
      } catch {
        // Fail loudly but keep going: one corrupt file must not stop the
        // messages behind it from ever being delivered. The bus-side reader
        // refuses it too, so it cannot be silently acted on.
        io.log(`pi-worker: unreadable inbox envelope ${name}; skipped`);
        continue;
      }
      if (parsed && typeof parsed === "object") envelopes.push(parsed as Envelope);
    }
    return envelopes;
  }

  return {
    delivered: () => mark,
    poll(): number[] {
      if (typeof host.sendUserMessage !== "function") {
        io.log("pi-worker: host exposes no sendUserMessage; inbox delivery is inert");
        return [];
      }
      const state: AgentState = host.agentState ? host.agentState() : "unknown";
      const sent: number[] = [];

      for (const envelope of unreadAfter(mark, load())) {
        const decision = decideDelivery(state, envelope);
        if (decision.mode === "defer") {
          // Stop at the first deferral rather than skipping ahead: delivering
          // message 4 before 3 would reorder the conversation.
          io.log(`pi-worker: deferring seq ${envelope.sequence} — ${decision.reason}`);
          break;
        }
        let text: string;
        try {
          text = userPayloadFor(envelope);
        } catch (err) {
          io.log(`pi-worker: refusing malformed inbox envelope ${envelope.sequence}: ${err}`);
          mark = envelope.sequence; // never retried; the bus reader reports it
          continue;
        }
        // `decision.mode` is this bridge's vocabulary; `deliverAs` is Pi's
        // parameter name. Only followUp and steer reach here — defer breaks
        // out of the loop above — so the cast is exhaustive by construction.
        host.sendUserMessage(text, {
          deliverAs: decision.mode as "steer" | "followUp",
        });
        mark = envelope.sequence;
        sent.push(envelope.sequence);
      }
      return sent;
    },
  };
}

// ---------------------------------------------------------------------------
// The typed result tool (dotfiles-87bt).
//
// `work-do/SKILL.md` tells every worker: "You finish by calling the typed
// result tool, not by ending your turn. Settling without it is recorded as
// protocol_error, not success." No such tool was ever registered, and the nu
// CLI had no `result` verb either, so the worker->initiator direction had no
// reachable implementation by ANY route. A worker did the work, settled, and
// the initiator saw `results: 0` with state stuck at `running` forever.
//
// This is deliberately a THIN shell over `pi-worker result`. The
// envelope shape, the stage gate (`validate-completion`) and the adr0017
// status rules stay in the nu CLI, with one implementation instead of a second
// copy in TS that drifts. The tool contributes the typed surface and nothing
// else — that is why it asserts on the command it issues rather than on the
// bus.

/** Just the exec shape the reporter needs, so it is testable without Pi. */
export type ExecFn = (
  command: string,
  args: string[],
  options?: { cwd?: string; timeout?: number },
) => Promise<{ stdout: string; stderr: string; code: number; killed: boolean }>;

export interface ReportOutcome {
  ok: boolean;
  detail: string;
}

export interface ResultTool {
  report(input: { status: string; summary: string; validation?: string }): Promise<ReportOutcome>;
  reportSettled(): Promise<ReportOutcome>;
}

export function createResultTool(opts: {
  run: string;
  uid: string;
  identity: WorkerIdentity;
  exec: ExecFn;
}): ResultTool {
  const run = async (args: string[]): Promise<ReportOutcome> => {
    try {
      const out = await opts.exec("pi-worker", args, { cwd: opts.identity.cwd });
      if (out.code === 0) return { ok: true, detail: out.stdout.trim() };
      // The refusal reason must reach the agent. The gate's message is how a
      // worker learns to report correctly on its next attempt; swallowing it
      // is how a worker ends up believing it reported when it did not.
      return { ok: false, detail: (out.stderr || out.stdout).trim() };
    } catch (err) {
      // A missing CLI, a spawn failure: reported, never thrown. An exception
      // raised inside a tool call or an event handler damages the very session
      // this extension exists to serve.
      return { ok: false, detail: String(err) };
    }
  };

  return {
    report: (input) => {
      const args = [
        "result",
        opts.uid,
        "--run",
        opts.run,
        "--status",
        input.status,
        "--summary",
        input.summary,
      ];
      // Omitted, not empty. The gate tests for emptiness, so `--validation ""`
      // would present the shape of a verdict without one — precisely what a
      // worker looking compliant without having validated anything would send.
      if (input.validation) args.push("--validation", input.validation);
      return run(args);
    },
    reportSettled: () => run(["settled", opts.uid, "--run", opts.run]),
  };
}

/**
 * TypeBox schemas are plain JSON Schema objects at runtime, and `typebox`
 * lives inside Pi's own node_modules rather than anywhere this extension can
 * import from. So the schema is written as a literal and cast: no dependency
 * to resolve, and the extension still loads if Pi moves the package.
 */
const RESULT_TOOL_PARAMETERS = {
  type: "object",
  properties: {
    status: {
      type: "string",
      enum: [...RESULT_STATUSES],
      description:
        "complete only with a passing validation verdict; otherwise blocked, waiting_human or failed",
    },
    summary: {
      type: "string",
      description:
        "at most 4 KiB. The initiator reads this inline; detail belongs in your window and transcript",
    },
    validation: {
      type: "string",
      description:
        "your stage's required verdict. Mandatory when status is complete; a summary mentioning it is not a verdict",
    },
  },
  required: ["status", "summary"],
  additionalProperties: false,
} as const;

// ---------------------------------------------------------------------------
// The initiator tool.
//
// The other half of the bridge. `createResultTool` is what a WORKER uses to
// report; this is what the session ORCHESTRATING workers uses to drive them.
// Without it an initiator running under Pi had no tools at all — the extension
// only woke up in worker mode — so driving the bus meant shelling out by hand.
//
// One dispatch tool rather than eleven separate ones. Every session pays for
// the tool list in its prompt, and eleven near-identical entries crowd out the
// tools the agent is actually there to use. The verb stays a closed enum, so
// the model still picks from a fixed set rather than composing a command line.
//
// Thin over `pi-worker`, for the same reason the result tool is: the bus has
// one implementation, in the CLI. This contributes a typed surface and nothing
// else.

/** The verbs an initiator drives. `result` and `settled` are a worker's, not an initiator's. */
export const INITIATOR_VERBS = [
  "ps",
  "spawn",
  "send",
  "wait",
  "rm",
  "ack",
  "status",
  "inspect",
  "timeline",
  "workers",
  "liveness",
  "resume",
  "accept",
  "stop",
  "respawn",
] as const;

export type InitiatorVerb = (typeof INITIATOR_VERBS)[number];

/** Verbs whose uid is positional rather than a flag, matching the CLI. */
const UID_IS_POSITIONAL: readonly string[] = [
  "send",
  "status",
  "inspect",
  "timeline",
  "liveness",
  "resume",
  "accept",
  "stop",
  "respawn",
];

export interface InitiatorArgs {
  verb: InitiatorVerb;
  run?: string;
  uid?: string;
  role?: string;
  subject?: string;
  project?: string;
  repo?: string;
  session?: string;
  skill?: string;
  task?: string;
  stage?: string;
  instructions?: string;
  artifacts?: string;
  feedback?: string;
  sequence?: number;
  block?: boolean;
  timeout?: number;
  socket?: string;
}

export interface InitiatorTool {
  invoke(args: InitiatorArgs): Promise<ReportOutcome>;
}

/** Flags each verb accepts, in the order the CLI documents them. */
const VERB_FLAGS: Record<string, readonly string[]> = {
  ps: ["run", "socket"],
  spawn: ["run", "uid", "role", "subject", "project", "repo", "session", "skill", "task", "socket"],
  send: ["run", "stage", "task", "instructions", "artifacts"],
  wait: ["run", "uid", "block", "timeout"],
  rm: ["run", "uid"],
  // `socket` because ack is also the RELEASE: it kills the worker's window and
  // the pi process in it, and a verb that touches tmux needs the display host.
  ack: ["run", "uid", "sequence", "socket"],
  status: ["run"],
  inspect: ["run"],
  // `--json` because the CLI answers a person with columns by default; the
  // extension needs the structure to summarise it.
  timeline: ["run", "json"],
  workers: ["run"],
  liveness: ["run", "socket"],
  resume: ["run", "feedback", "socket"],
  accept: ["run", "repo", "socket"],
  stop: ["run", "socket"],
  respawn: ["run", "repo", "socket"],
};

// ---------------------------------------------------------------------------
// The live frame.
//
// A tool-result block per call means the answer to "what is running right now?"
// is scattered across the transcript, oldest first, with the current truth
// somewhere at the bottom. This is the same information as one keyed widget:
// Pi's setWidget takes a key, so writing the same key repeatedly refreshes
// those lines in place instead of appending more.

export interface RosterRow {
  run: string;
  uid: string;
  role: string;
  state: string;
  liveness: string;
  window: string;
  /**
   * The tmux window id (`@7`), worn as a suffix on the address.
   *
   * The row used to carry the window NAME as its own cell, so a worker had two
   * names on screen — `r32/impl-1` and `impl-timestamp-md@dotfiles` — and the
   * redundant one was the widest cell on the row. The id is not a second
   * identifier: it is where this one is on screen, and it is what
   * `tmux select-window -t` takes. The name is still on `pi-worker ps`, which
   * is the lookup table.
   *
   * "" for an identity written before the id was recorded.
   */
  window_id?: string;
  /** When the worker was spawned, from its identity envelope. "" if unknown. */
  started?: string;
  /**
   * The worker's last tool call, while it has not reported yet.
   *
   * `state` is a fact about the BUS — `created` means "has never reported" —
   * so it sits unchanged for almost the whole of a worker's life, and an
   * operator watching `warming-up` for two minutes cannot tell work from a
   * wedge. This is read from the worker's own Pi transcript, and it is the
   * only column that moves while a worker is thinking.
   */
  doing?: string;
}

/**
 * Colour roles the frame asks for, named by what they mean rather than by a
 * colour: the theme decides what `error` looks like.
 *
 * `plain` is the honest answer for a state the frame does not recognise —
 * inventing a tone for it would assert something the bus never said.
 */
export type Tone = "accent" | "success" | "error" | "warning" | "muted" | "plain";

/** Applies a tone. The identity function when there is no theme to ask. */
export type PaintFn = (tone: Tone, text: string) => string;

const NO_PAINT: PaintFn = (_tone, text) => text;

/**
 * A tone per state, chosen by what the operator has to DO about it.
 *
 * `blocked` and `waiting_human` are warnings because something is waiting on a
 * person; `failed` and `protocol_error` are errors because the worker is not
 * coming back. `created` is muted: nothing has happened yet.
 */
/**
 * What a state is called in the frame.
 *
 * Only `created` is renamed. The bus's word is right for the bus — the worker
 * was created and has reported nothing — but an operator reading a row wants
 * to know what it means for them, and "created" does not say "it is alive and
 * working, it just has not answered yet". The frame already heads its
 * pre-first-worker view "warming up", so the row uses the same word for the
 * same idea.
 *
 * Every other state is shown verbatim. A display vocabulary that renames
 * things freely becomes a second set of names to learn.
 */
export function stateLabel(state: string): string {
  return state === "created" ? "warming-up" : state;
}

export function stateTone(state: string): Tone {
  switch (state) {
    case "running":
      return "accent";
    case "complete":
      return "success";
    case "failed":
    case "protocol_error":
      return "error";
    case "blocked":
    case "waiting_human":
      return "warning";
    case "created":
      // Alive and not yet anyone's problem.
      return "muted";
    default:
      return "plain";
  }
}

/**
 * A PaintFn backed by a Pi theme, or the identity function if there is none.
 *
 * Feature-detected rather than typed: the theme reaches the frame through
 * setWidget's component factory, and a host that hands over something without
 * `fg` must cost the frame its colour and nothing else.
 *
 * Two things here are load-bearing, and both were learned by taking Pi down.
 *
 * `fg` is called AS A METHOD. Pi's implementation reads `this.fgColors`, so a
 * detached reference — `const fg = theme.fg; fg(tone, text)` — throws:
 *
 *     TypeError: Cannot read properties of undefined (reading 'fgColors')
 *
 * A test stub written as an arrow function does not notice, because an arrow
 * has no `this` to lose.
 *
 * And the call is GUARDED. This runs inside a component's render(), which Pi
 * invokes from a timer: anything thrown there is an uncaughtException that
 * exits the whole session, so a theme that misbehaves must cost the frame its
 * colour, not the operator their Pi. The first failure disables painting for
 * the life of this PaintFn rather than throwing sixty times a second.
 */
export function themePaint(theme: unknown): PaintFn {
  const host = theme as { fg?: (tone: string, text: string) => string } | undefined;
  if (typeof host?.fg !== "function") return NO_PAINT;
  let usable = true;
  return (tone, text) => {
    if (!usable || tone === "plain") return text;
    try {
      const painted = host.fg!(tone, text);
      // A theme that returns nothing would blank the cell; treat that as
      // unusable rather than rendering an empty column.
      if (typeof painted !== "string") {
        usable = false;
        return text;
      }
      return painted;
    } catch {
      usable = false;
      return text;
    }
  };
}

/**
 * How long a worker has been around, from its start stamp.
 *
 * Coarse on purpose: the question is "has this been sitting there", and a
 * seconds-precise reading of a forty-minute worker answers it no better than
 * `40m`. An absent or unparseable stamp yields "" rather than a number —
 * `0s` would read as a worker that had only just started.
 */
export function formatElapsed(started: string | undefined, now: number): string {
  if (!started) return "";
  const at = Date.parse(started);
  if (!Number.isFinite(at)) return "";
  const seconds = Math.max(0, Math.round((now - at) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  return `${Math.floor(minutes / 60)}h${minutes % 60}m`;
}

/**
 * The frame's lines, or undefined when there is nothing to show.
 *
 * Undefined rather than an empty box: a widget holds terminal rows for as long
 * as it is set, and an idle session should get them back.
 *
 * State and liveness are shown side by side because their disagreement is the
 * interesting case — `blocked`/`exited` is a worker that reported and then
 * finished, while `running`/`exited` is one that died without reporting.
 */
/**
 * Liveness verdicts that add nothing to the state beside them.
 *
 * `live` next to `created` or `running` is the same fact twice. The verdict
 * earns its column when it COMPLICATES the state: `gone` or `exited` beside a
 * working state is a worker that died without reporting, and `unknown` means
 * the question could not be asked. Those are the rows worth a second look.
 */
const UNREMARKABLE_LIVENESS: readonly string[] = ["live"];

/**
 * Below this, an age is noise.
 *
 * A worker eight seconds old tells the operator nothing they did not just
 * watch happen. One that has been at it for minutes is the whole reason the
 * column exists.
 */
export const AGE_WORTH_SHOWING_MS = 60_000;

/** States meaning the worker is finished with; nothing is waiting on it. */
const FINISHED_STATES: readonly string[] = ["stopped", "accepted"];

/**
 * What the extension is doing right now, as opposed to what the bus knows.
 *
 * The bus cannot supply this. A refused spawn leaves nothing behind to list,
 * and a call still in flight has not written anything yet — so the setup
 * chatter that used to scroll past as transcript text has no representation
 * there. `createInitiatorTool` sees every call and its outcome, and this is
 * where it says so.
 */
export interface FrameActivity {
  verb: string;
  /** undefined while the call is in flight. */
  ok?: boolean;
  /** The refusal, when there was one. */
  detail?: string;
  /** When it happened, for ageing a refusal out. */
  at: number;
}

/**
 * How long a refusal keeps its line.
 *
 * A refusal that blinks past on the next poll is worse than one printed
 * inline, because the operator has no way to go back and read it. It stays
 * until a later call succeeds, or until this elapses — long enough to read and
 * short enough that yesterday's mistake is not still on screen.
 */
export const ACTIVITY_TTL_MS = 90_000;

/**
 * The activity line, or undefined when there is nothing to say.
 *
 * In flight is muted: it is a progress note, not news. A refusal is painted as
 * one and carries its own text, because "spawn failed" without the reason is
 * the same dead end as printing nothing. A success says nothing at all — the
 * rows below are the success.
 */
export function activityLine(
  activity: FrameActivity | undefined,
  now: number,
  paint: PaintFn = NO_PAINT,
): string | undefined {
  if (!activity) return undefined;
  if (activity.ok === undefined) {
    return paint("muted", `${activity.verb}…`);
  }
  if (activity.ok) return undefined;
  if (now - activity.at > ACTIVITY_TTL_MS) return undefined;
  const detail = (activity.detail ?? "").trim();
  const text = detail.length > 0 ? `${activity.verb} refused: ${detail}` : `${activity.verb} refused`;
  return paint("error", text);
}

export function rosterFrame(
  all: RosterRow[],
  opts: {
    now?: number;
    paint?: PaintFn;
    activity?: FrameActivity;
    /**
     * Draw the heading even with nothing else to say.
     *
     * Zero lines is indistinguishable from gone. Staying MOUNTED across the
     * gaps stopped the widget being torn down, but a mounted widget rendering
     * nothing still reads as one that vanished — so during a run, where the
     * roster is briefly empty between a verb succeeding and its worker
     * appearing on the bus, the bar was still seen blinking.
     *
     * The caller decides, because only it knows whether a run is under way.
     */
    holdEmpty?: boolean;
    /**
     * The viewport width, so a row can be made to FIT rather than wrap.
     *
     * Without it the activity cell pushed rows past the edge and wrapToWidth
     * split them, so one worker occupied two lines and the promise that every
     * line after the heading is exactly one agent quietly stopped holding.
     *
     * Optional: callers that only want the text (tests, the CLI) pass nothing
     * and get it untruncated.
     */
    width?: number;
  } = {},
): string[] | undefined {
  // The frame answers "what is running", so a finished worker has no business
  // holding a row. `blocked` and `waiting_human` are NOT finished — they are
  // waiting for someone, which is precisely what a status panel is for.
  const rows = all.filter((r) => !FINISHED_STATES.includes(r.state));

  const now = opts.now ?? Date.now();
  const paint = opts.paint ?? NO_PAINT;
  const activity = activityLine(opts.activity, now, paint);

  // No workers is not necessarily nothing to show: the interesting moment is
  // precisely the one before the first worker exists, when the agent is still
  // finding its footing. With neither rows nor activity the widget goes away
  // and gives its terminal rows back.
  if (rows.length === 0) {
    const heading = paint("muted", "pi-workers · warming-up");
    if (activity !== undefined) return [`${heading}  ${activity}`];
    return opts.holdEmpty === true ? [heading] : undefined;
  }

  const addr = rows.map((r) => `${r.run}/${r.uid}${r.window_id ?? ""}`);
  const label = rows.map((r) => stateLabel(r.state));
  // A column is carried only when it says something the state does not. A row
  // reading `created  8s  live` is one fact and two restatements of it, and
  // every column that never varies makes the row that matters harder to find.
  const age = rows.map((r) => {
    const started = r.started ? Date.parse(r.started) : NaN;
    if (!Number.isFinite(started)) return "";
    return now - started >= AGE_WORTH_SHOWING_MS ? formatElapsed(r.started, now) : "";
  });
  const live = rows.map((r) => (UNREMARKABLE_LIVENESS.includes(r.liveness) ? "" : r.liveness));
  const doing = rows.map((r) => r.doing ?? "");
  // Padded to a common width so the columns read down the frame rather than
  // drifting with the length of each run id.
  const addrWidth = Math.max(...addr.map((a) => a.length));
  // Measured on the LABEL, not the state: `warming-up` is wider than
  // `created`, and padding to the shorter one puts the next column inside it.
  const stateWidth = Math.max(...label.map((l) => l.length));
  const ageWidth = Math.max(...age.map((a) => a.length));
  const liveWidth = Math.max(...live.map((l) => l.length));

  // Line one is the frame's own state; every line after it is exactly one
  // worker. The activity used to be appended AFTER the rows, which put a
  // refusal below the workers it was not about and meant the operator could
  // not tell how many lines were agents without reading them. Carrying it on
  // the heading keeps the list a list.
  const count = `pi-workers · ${rows.length} worker${rows.length === 1 ? "" : "s"}`;
  const heading = activity === undefined ? count : `${count}  ${activity}`;
  // The activity cell is budgeted last and truncated to what is left, because
  // it is both the longest and the least structured thing on the row. Every
  // other cell is an identifier or a state and means nothing cut in half.
  const fixedWidth =
    addrWidth + 2 + stateWidth +
    (ageWidth > 0 ? ageWidth + 2 : 0) +
    (liveWidth > 0 ? liveWidth + 2 : 0);
  const doingBudget =
    opts.width === undefined || !Number.isFinite(opts.width)
      ? Number.POSITIVE_INFINITY
      : opts.width - fixedWidth - 2;
  const fitted = doing.map((d) => {
    if (d.length === 0 || d.length <= doingBudget) return d;
    // Under about a dozen columns there is no room to say anything useful, so
    // the cell is dropped rather than shown as an ellipsis.
    if (doingBudget < 12) return "";
    return `${d.slice(0, doingBudget - 1)}…`;
  });

  const lines = rows.map((r, i) => {
    const cells: { text: string; width: number; tone?: Tone }[] = [
      { text: addr[i], width: addrWidth },
      { text: label[i], width: stateWidth, tone: stateTone(r.state) },
      // An empty column would still cost two spaces, so a CLI too old to
      // report `started` keeps precisely the layout it had.
      ...(ageWidth > 0 ? [{ text: age[i], width: ageWidth }] : []),
      ...(liveWidth > 0 ? [{ text: live[i], width: liveWidth }] : []),
      ...(fitted[i].length > 0 ? [{ text: fitted[i], width: fitted[i].length, tone: "muted" as Tone }] : []),
    ];
    // A trailing cell is neither padded nor kept when it is empty: padding one
    // just puts spaces at the end of every line, and an empty one puts two
    // there. Every cell BEFORE the last is padded even when empty, because
    // that is what holds the column for the rows that filled it.
    while (cells.length > 0 && cells[cells.length - 1].text.length === 0) cells.pop();
    const last = cells.length - 1;
    return cells
      .map((c, j) => {
        // Padded BEFORE painting. A tone is escape codes, and every width here
        // — this padding and fitToWidth's — counts bytes, so a painted cell
        // measured as text would push the rest of the row out of column.
        const text = j === last ? c.text : c.text.padEnd(c.width);
        return c.tone === undefined ? text : paint(c.tone, text);
      })
      .join("  ");
  });
  return [heading, ...lines];
}

/**
 * Keep the frame current.
 *
 * Polls rather than subscribing: the bus is a directory of files written by
 * other processes, and liveness comes from tmux, so there is nothing to
 * subscribe to. The interval is slow on purpose — this is a status panel, not
 * an animation, and each refresh costs a `pi-worker ps`.
 */
export const ROSTER_WIDGET_KEY = "pi-workers";

/**
 * How long the frame holds an empty view before giving its rows back.
 *
 * The only gap this has to cover is between a verb clearing its activity line
 * and the next `ps` listing what it just created — one subprocess, well under
 * a second. It was ten seconds, which covered that and then left
 * `pi-workers · warming up` sitting on screen for ten seconds after the work
 * was done, which reads as a leftover rather than as status.
 *
 * Two seconds spans the gap with room to spare and disappears promptly when
 * there is genuinely nothing to report.
 */
export const EMPTY_GRACE_MS = 2_000;

/** What the frame needs from the host's tui handle, and nothing more. */
interface FrameTui {
  requestRender(): void;
}

export function startRosterFrame(opts: {
  exec: ExecFn;
  setWidget: (key: string, content: unknown) => void;
  intervalMs?: number;
  now?: () => number;
  /** Show every run on the bus, not just this session's. Off by default. */
  allRuns?: boolean;
}): {
  refresh: () => Promise<void>;
  note: (activity: FrameActivity | undefined) => void;
  own: (run: string) => void;
  stop: () => void;
} {
  const clock = opts.now ?? (() => Date.now());
  let rows: RosterRow[] = [];
  let activity: FrameActivity | undefined;
  let mounted = false;

  /**
   * The runs this session is driving.
   *
   * `pi-worker ps` answers for the whole bus, which is right for a CLI and
   * wrong for a widget: the bus is per-user, not per-session, so a session's
   * frame was showing workers that belonged to other sessions — and, worse,
   * leftovers from previous ones. An operator reading `2 workers` had no way
   * to tell which were theirs to care about.
   *
   * A session earns a run by ADDRESSING it through the tool: spawning into it,
   * or asking about it. That is a better signal than the spawn alone, since a
   * session handed an existing run to drive is legitimately driving it.
   *
   * Empty means show nothing rather than show everything: a session that has
   * touched no run has no business claiming other sessions' workers, and the
   * global view is a `ps` call away.
   */
  const ownRuns = new Set<string>();

  /** When the frame first had nothing to draw, or undefined while it has. */
  let emptySince: number | undefined;
  let tui: FrameTui | undefined;
  // Whether the host takes a component factory. Assumed until one is refused;
  // see mount() for why a refusal is not fatal.
  let factoryForm = true;

  /**
   * Hand the host a component factory.
   *
   * The factory form is the one that carries a theme and a `requestRender`, so
   * it is what the frame wants. A host that will not take a function is an
   * older Pi, not a broken one: it gets the array form instead, which costs
   * the frame its colour and nothing else. Throwing here would put the failure
   * in host startup, which takes the whole worker down — strictly worse than a
   * frame with no colour.
   */
  const mount = () => {
    if (factoryForm) {
      try {
        opts.setWidget(ROSTER_WIDGET_KEY, (hostTui: unknown, theme: unknown) => {
          tui = hostTui as FrameTui;
          // Resolved on first render, INSIDE the guard below, and remembered.
          // Reading the theme is itself something a host can make throw — an
          // accessor, a proxy — and doing it out here would put that throw in
          // the factory, where there is nothing to catch it.
          let paint: PaintFn | undefined;
          return {
            // Rendered on demand, so the lines are computed against the
            // clock at draw time rather than at poll time.
            //
            // Guarded as a whole for the same reason themePaint guards its
            // call: Pi renders from a timer, and a throw here is an
            // uncaughtException that exits the session. A status panel is
            // never worth that, so a frame that cannot be drawn draws nothing.
            render: (width: number) => {
              try {
                paint ??= themePaint(theme);
                // fitToWidth, not wrapToWidth: a wrapped row would put one
                // worker on two lines. The transcript still wraps, because
                // there a cut error message loses the instruction.
                return fitToWidth(
                  rosterFrame(rows, { now: clock(), paint, activity, holdEmpty: holdEmpty(), width }) ?? [],
                  width,
                );
              } catch {
                return [];
              }
            },
            invalidate: () => {
              // Deliberately does NOT unmount, and that reverses an earlier
              // decision here.
              //
              // The earlier reasoning: the theme is captured when this factory
              // runs, so a session that switches theme would keep painting the
              // old palette; Pi calls invalidate when a fresh capture is
              // available, so drop the registration and re-register.
              //
              // What that missed is the rest of Pi's own contract for
              // invalidate — "called when theme changes OR when component
              // needs to re-render from scratch". The second clause fires
              // constantly during a streaming turn, so dropping the
              // registration here made the bar blink through every turn. A
              // rare cosmetic problem was traded for a permanent one.
              //
              // Nothing here is cached: render reads `rows` and `activity`
              // live, so there is genuinely nothing to invalidate. The cost is
              // that a `/theme` switch leaves this one widget on the old
              // palette until it next remounts — which happens on reload, or
              // after it has been idle long enough to release its rows.
            },
            dispose: () => {
              // Only disown the handle we were given: a later mount may
              // already have replaced it.
              if (tui === (hostTui as FrameTui)) tui = undefined;
              mounted = false;
            },
          };
        });
        mounted = true;
        return;
      } catch {
        factoryForm = false;
      }
    }
    opts.setWidget(
      ROSTER_WIDGET_KEY,
      rosterFrame(rows, { now: clock(), activity, holdEmpty: holdEmpty() }),
    );
    mounted = true;
  };

  /**
   * Whether to keep drawing a heading with nothing under it.
   *
   * True once the frame has been shown and while it is inside its grace
   * window: that is exactly the span of a run, and a bar that renders zero
   * lines between two verbs reads as one that disappeared.
   */
  const holdEmpty = () => mounted;

  const draw = () => {
    // Emptiness is decided on the plain frame: an unpainted render is cheap at
    // roster size.
    // Deliberately WITHOUT holdEmpty: this decides whether there is anything
    // to say, and holdEmpty is about how an empty view is drawn. Mixing them
    // makes the frame immortal — it would never see itself as empty, so it
    // would never give its rows back.
    const empty = rosterFrame(rows, { now: clock(), activity }) === undefined;

    if (empty) {
      if (!mounted) return;
      // Do NOT unmount on the first empty draw. The frame used to, and it
      // flickered through every single verb: `note` marks a call in flight and
      // mounts, the call returns and clears the activity, and for the moment
      // before the next `ps` lists the new worker the roster is empty — so the
      // widget was torn down and rebuilt, once per verb, each rebuild a fresh
      // component for Pi to lay out again. What the operator saw was the bar
      // blinking several times per spawn.
      //
      // A mounted component with nothing to show renders zero lines, so it
      // holds no terminal rows while it waits. Staying mounted through the
      // gaps costs nothing and is the difference between a bar that appears
      // once and stays until the work is done, and one that strobes.
      const now = clock();
      emptySince ??= now;
      if (now - emptySince < EMPTY_GRACE_MS) {
        tui?.requestRender();
        return;
      }
      opts.setWidget(ROSTER_WIDGET_KEY, undefined);
      mounted = false;
      tui = undefined;
      emptySince = undefined;
      return;
    }

    emptySince = undefined;
    if (!mounted || !factoryForm) {
      mount();
      return;
    }
    // Already mounted as a component: ask for a repaint instead of handing
    // over a second factory, which would leave the first one's handle stale.
    tui?.requestRender();
  };

  const refresh = async () => {
    try {
      const out = await opts.exec("pi-worker", ["ps"], {});
      if (out.code === 0) {
        const all = JSON.parse(out.stdout || "[]") as RosterRow[];
        rows = opts.allRuns === true ? all : all.filter((r) => ownRuns.has(r.run));
      }
      // Drawn even when `ps` failed, and that is the point: draw() is what
      // ages an empty view out. Returning early on a bad exit left the frame
      // frozen in whatever it last showed, with no path back to unmounting —
      // one failed poll and `warming up` was on screen for good. The stale
      // rows are kept rather than blanked: a poll that could not answer has
      // not learned that the workers are gone.
      draw();
    } catch {
      // A frame that cannot be drawn is not worth breaking a session over.
    }
  };

  /**
   * Record what the extension is doing, and redraw at once.
   *
   * Immediate rather than on the next poll: the whole point is that a refusal
   * appears where the operator is already looking, and a five-second delay
   * would have them reading a stale frame while the transcript stays silent.
   *
   * A success clears the line instead of setting one, so the frame does not
   * accumulate a log — the rows below ARE the success.
   */
  const note = (next: FrameActivity | undefined) => {
    activity = next?.ok === true ? undefined : next;
    draw();
  };

  /** Claim a run for this session, so its workers reach the frame. */
  const own = (run: string) => {
    if (run.length > 0) ownRuns.add(run);
  };

  const timer = setInterval(() => void refresh(), opts.intervalMs ?? 5000);
  if (typeof timer === "object" && timer && "unref" in timer) {
    (timer as { unref: () => void }).unref(); // never hold the process open
  }
  void refresh();
  return { refresh, note, own, stop: () => clearInterval(timer) };
}

/**
 * What a verb puts in the TRANSCRIPT, as opposed to what it returns.
 *
 * The frame above the editor carries live state, so echoing it again per call
 * is duplication that scrolls away. What the frame cannot show is what a worker
 * actually SAID, and anything that failed — those are history rather than
 * status, so they stay.
 *
 * Display only. The tool's content still reaches the model in full: hiding a
 * line from the operator must never hide it from the agent.
 */
const FRAME_COVERED_VERBS: readonly string[] = [
  "spawn",
  "liveness",
  "ps",
  "workers",
  "stop",
  "accept",
  "send",
  "resume",
  "rm",
];

/** The two verbs whose whole purpose is detail, so they collapse rather than hide. */
const DETAIL_VERBS: readonly string[] = ["inspect", "status", "timeline"];

/**
 * One line standing in for a whole `inspect` or `status` body.
 *
 * What an operator wants at a glance is the same three facts the frame shows —
 * who, what state, where to look — so the collapsed line is those, parsed out
 * of the JSON rather than sliced off the top of it. The first line of that JSON
 * is `{`, which tells nobody anything.
 *
 * Never empty. A body that will not parse falls back to its own first line: the
 * CLI is a nu script and a future verb may print something that is not JSON,
 * and collapsing that to nothing would hide the fact that the call answered at
 * all.
 */
export function collapsedStateLine(detail: string): string {
  const raw = detail.trim();
  const hint = "click or expand-key for detail";

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    const first = raw.split("\n")[0] ?? "";
    return first.length > 0 ? `${first} · ${hint}` : `(no output) · ${hint}`;
  }
  if (parsed === null || typeof parsed !== "object") {
    const first = raw.split("\n")[0] ?? "";
    return first.length > 0 ? `${first} · ${hint}` : `(no output) · ${hint}`;
  }

  // A list, not a record: `timeline` answers with a series of events. Falling
  // through to the record branch below would find no `run` or `state` and
  // collapse the whole history to `[`.
  if (Array.isArray(parsed)) {
    if (parsed.length === 0) return `no events recorded · ${hint}`;
    // The SHAPE, not a count. "5 events over 32.7s" says a history exists;
    // `spawned → sent +5s → reported +33s` is the history, and it is the
    // question the verb was reached for — where did the time go.
    const steps = parsed
      .map((e) => {
        const row = e as Record<string, unknown>;
        const event = typeof row.event === "string" ? row.event : "?";
        const at = typeof row["+s"] === "number" ? (row["+s"] as number) : undefined;
        // The identity re-record is bookkeeping, not a step in the story.
        if (event === "identity") return undefined;
        const label = event.replace(/ seq \d+$/, "");
        return at === undefined || at === 0 ? label : `${label} +${Math.round(at)}s`;
      })
      .filter((x): x is string => x !== undefined);
    return `${steps.join(" → ")} · ${hint}`;
  }

  const o = parsed as Record<string, unknown>;
  const identity = (o.identity ?? {}) as Record<string, unknown>;
  const last = (o.last_result ?? null) as Record<string, unknown> | null;

  const parts: string[] = [];
  // Either half of the address is worth printing on its own: `status` answers
  // for a whole run and carries no uid, and requiring both dropped it to the
  // useless `{` fallback.
  const addr = [o.run, o.uid].filter((v) => typeof v === "string" && v.length > 0);
  if (addr.length > 0) parts.push(addr.join("/"));
  if (typeof o.state === "string") parts.push(o.state);
  // The last reported status only earns a place when it disagrees with the
  // state — otherwise it is the same word twice.
  if (last && typeof last.status === "string" && last.status !== o.state) {
    parts.push(`reported ${last.status}`);
  }
  if (typeof identity.window === "string" && identity.window.length > 0) {
    parts.push(identity.window);
  }
  if (parts.length === 0) parts.push(raw.split("\n")[0] ?? "(no output)");

  return `${parts.join("  ")} · ${hint}`;
}

/** How the transcript should be rendered for one result. */
export interface TranscriptView {
  /**
   * Collapsed is the DEFAULT view: the agent picks the verb and the operator
   * pays the screen, so detail has to be asked for rather than arrive.
   */
  expanded?: boolean;
  /**
   * Whether the roster frame is actually mounted and being drawn.
   *
   * This gates refusal suppression, and it has to be a real observation rather
   * than an assumption. The rule in this file has always been that an operator
   * who cannot see a failure has no idea why nothing happened — and that is
   * still true. What changed is that the frame is now a place to see it. In
   * print, json or rpc mode, or with no UI, there is no frame, so nothing is
   * suppressed.
   */
  frameLive?: boolean;
}

export function transcriptLines(
  verb: string,
  ok: boolean,
  detail: string,
  view: TranscriptView = {},
): string[] {
  const expanded = view.expanded === true;

  // A refusal must always be READABLE. Where it is readable depends on whether
  // there is a frame: with one live it is drawn there, painted and held for a
  // while, next to the rows it concerns — which is where the operator is
  // already looking, and keeps a run's warming-up chatter out of the history.
  // With no frame it prints here, as it always did.
  if (!ok) return view.frameLive === true ? [] : [detail];

  // `inspect` and `status` are asked precisely for their detail — so it is
  // reachable, not printed unbidden.
  if (DETAIL_VERBS.includes(verb)) {
    return expanded ? detail.split("\n") : [collapsedStateLine(detail)];
  }

  if (FRAME_COVERED_VERBS.includes(verb)) return [];

  // An empty mailbox was the noisiest line of a polling loop and says nothing
  // the frame does not.
  if (verb === "wait" && detail.startsWith("no unacknowledged")) return [];

  return detail.length > 0 ? [detail] : [];
}

/** SGR escape sequences, which occupy no columns. */
const SGR_PATTERN = /\u001b\[[0-9;]*m/g;

/** Columns a string actually occupies, ignoring colour. */
export function visibleWidth(text: string): number {
  return text.replace(SGR_PATTERN, "").length;
}

/**
 * Truncate lines to the viewport width, counting columns rather than bytes.
 *
 * The frame must never wrap: every line after its heading is exactly one
 * worker, and a wrapped row silently makes that untrue — one worker on two
 * lines, which is what the operator saw.
 *
 * Counting COLUMNS is the other half, and it is why the row wrapped in the
 * first place. wrapToWidth measures string length, so the escape codes in a
 * painted cell count toward the width: a row of about a hundred visible
 * columns with two coloured cells measures about a hundred and twenty and was
 * split at a hundred and eighteen. It fitted, and was wrapped anyway.
 *
 * A cut is followed by a reset, because the cut may land inside a styled
 * region and would otherwise leak that colour into the rest of the terminal.
 */
export function fitToWidth(lines: string[], width: number): string[] {
  if (!Number.isFinite(width) || width <= 0) return lines;
  return lines.map((line) => {
    if (visibleWidth(line) <= width) return line;
    let out = "";
    let seen = 0;
    // Walk the line, letting escapes through free and counting the rest.
    const parts = line.split(/(\u001b\[[0-9;]*m)/g);
    for (const part of parts) {
      if (part.length === 0) continue;
      if (SGR_PATTERN.test(part)) {
        SGR_PATTERN.lastIndex = 0;
        out += part;
        continue;
      }
      SGR_PATTERN.lastIndex = 0;
      const room = width - seen;
      if (room <= 0) break;
      if (part.length <= room) {
        out += part;
        seen += part.length;
      } else {
        out += part.slice(0, room);
        seen = width;
        break;
      }
    }
    return `${out}\u001b[0m`;
  });
}

/**
 * Wrap lines to the viewport width.
 *
 * pi-tui throws an UNCAUGHT exception when a custom component returns a line
 * wider than the terminal, which takes the whole editor down:
 *
 *     Error: Rendered line 67 exceeds terminal width (205 > 118)
 *
 * So `render(width)` must honour the width it is handed. Wrapped rather than
 * truncated because the lines that overflow are the ones that matter — an
 * error message is ~200 characters precisely because it is explaining what to
 * do, and cutting it at the viewport edge throws away the instruction.
 *
 * Breaks on spaces where it can; a single long token (a path, typically) is
 * cut, because exceeding the width is not an option.
 */
export function wrapToWidth(lines: string[], width: number): string[] {
  // A zero or negative width would make the loop below never advance.
  if (!Number.isFinite(width) || width <= 0) return lines;

  const out: string[] = [];
  for (const line of lines) {
    let rest = line;
    if (rest.length === 0) {
      out.push(rest);
      continue;
    }
    while (rest.length > width) {
      const window = rest.slice(0, width + 1);
      const brk = window.lastIndexOf(" ");
      // No space to break on: hard-cut rather than overflow.
      const cut = brk > 0 ? brk : width;
      out.push(rest.slice(0, cut));
      rest = rest.slice(brk > 0 ? cut + 1 : cut);
    }
    out.push(rest);
  }
  return out;
}

/**
 * The transcript component for the CALL.
 *
 * Renders nothing. `renderShell: "self"` suppresses the box around a result but
 * not the tool's name label, which the call draws — so a run whose results were
 * all suppressed still printed six bare `pi_worker` lines with nothing beneath
 * them. Every line that matters is carried by the result: a worker's answer
 * names its own run and uid, and a failure carries its own message.
 */
export function callComponent(): {
  render: (width: number) => string[];
  invalidate: () => void;
} {
  return { render: () => [], invalidate: () => {} };
}

/**
 * What Pi hands renderResult beyond the result itself.
 *
 * `expanded` is Pi's own view state, driven by the configured expand key.
 * `state` is the shared per-row object Pi keeps for a tool execution, which is
 * where the click toggle has to live: Pi rebuilds the component on every
 * redraw, so a flag held in the closure would be forgotten the moment the
 * click caused a redraw. `invalidate` repaints that one row.
 *
 * All three optional, so a caller with no Pi context still gets a component.
 */
export interface ResultViewOptions {
  expanded?: boolean;
  state?: Record<string, unknown>;
  invalidate?: () => void;
}

/** Where the click toggle is parked on the row's shared state. */
const CLICK_EXPANDED_KEY = "piWorkerClickExpanded";

/** A minimal shape of pi-tui's TuiMouseEvent — only what the hit test reads. */
interface MouseEventish {
  type: string;
  button: string;
  y: number;
  height: number;
}

/**
 * The transcript component for one tool result.
 *
 * pi-tui's `Component` requires `invalidate()` as well as `render()` — it is
 * called whenever the UI re-renders from scratch, which includes `/reload`.
 * Returning only `render` worked for a first draw and then killed reload in any
 * session that had a pi_worker result in its history:
 *
 *     Error: Reload failed: this.child.invalidate is not a function
 *
 * Always a real component, even with no lines: returning nothing would leave
 * the same hole in the render tree.
 *
 * `handleMouse` is offered only when there is something to expand. A handler
 * over zero rows would swallow clicks meant for whatever Pi draws next, and a
 * handler on a verb with no hidden detail would toggle nothing while claiming
 * the click.
 */
export function resultComponent(
  verb: string,
  ok: boolean,
  detail: string,
  opts: ResultViewOptions & TranscriptView = {},
): {
  render: (width: number) => string[];
  invalidate: () => void;
  handleMouse?: (event: MouseEventish) => { handled: boolean } | undefined;
} {
  const state = opts.state;
  const clicked = state?.[CLICK_EXPANDED_KEY] === true;
  // Either source expands it, so the expand key and the click cannot fight:
  // whichever the operator reached for, the detail appears.
  const expanded = opts.expanded === true || clicked;
  const lines = transcriptLines(verb, ok, detail, {
    expanded,
    ...(opts.frameLive === true ? { frameLive: true } : {}),
  });

  const collapsible = ok && DETAIL_VERBS.includes(verb) && lines.length > 0;

  const component: {
    render: (width: number) => string[];
    invalidate: () => void;
    handleMouse?: (event: MouseEventish) => { handled: boolean } | undefined;
  } = {
    // Honours the width it is given; see wrapToWidth for why that is not
    // optional.
    render: (width: number) => wrapToWidth(lines, width),
    invalidate: () => {
      // Nothing is cached; the lines were computed once when the call returned.
    },
  };

  if (collapsible && state) {
    component.handleMouse = (event) => {
      // Coordinates are local to this component, so a row inside it is
      // 0 <= y < height. Anything else belongs to a sibling — claiming it
      // would eat clicks this component never drew.
      if (event.y < 0 || event.y >= event.height) return undefined;
      if (event.button !== "left") return undefined;
      // Toggle on press only. Acting on press AND release would fire twice per
      // click and land back where it started.
      if (event.type !== "press") return undefined;
      state[CLICK_EXPANDED_KEY] = !clicked;
      opts.invalidate?.();
      return { handled: true };
    };
  }

  return component;
}

/**
 * Reduce a nushell error to the message it carries.
 *
 * The CLI is a nu script, so `error make` renders the message alongside a
 * source frame: file and line, the surrounding code, and a caret run wide
 * enough to wrap several times. All of it reaches the transcript and none of it
 * is actionable — the message already said what was wrong and what to do.
 *
 * Only nu's framing is stripped. Anything not shaped like it passes through
 * untouched, or a real failure from elsewhere could be reduced to nothing.
 */
function messageOnly(text: string): string {
  const lines = text.split("\n");
  const message: string[] = [];
  for (const line of lines) {
    const started = /^\s{2}x\s+(.*)$/.exec(line);
    if (started) {
      message.push(started[1].trim());
      continue;
    }
    // Continuation lines of the same message are `  | ...`; the frame that
    // follows starts with `,-[` or a line number, so it ends the capture.
    const cont = /^\s{2}\|\s?(.*)$/.exec(line);
    if (message.length > 0 && cont) {
      message.push(cont[1].trim());
      continue;
    }
    if (message.length > 0) break;
  }
  return message.length > 0 ? message.join(" ") : text.trim();
}

/**
 * Compress a verb's output to the one fact its caller wanted.
 *
 * The tool result is rendered in the transcript, so whatever this returns is
 * what the operator reads. Handing back the CLI's full JSON buried the answer —
 * is it alive, what did it say — under addressing they already knew.
 *
 * `inspect` and `status` are exempt: those are the verbs you reach for WHEN you
 * want the detail, and summarising them would leave no way to get it.
 */
function summarise(verb: string, stdout: string): string {
  const raw = stdout.trim();
  if (verb === "inspect" || verb === "status") return raw;
  if (raw.length === 0) return raw;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return raw; // not JSON; the caller sees whatever the CLI said
  }
  const o = parsed as Record<string, unknown>;

  switch (verb) {
    case "spawn":
      return `spawned ${o.run}/${o.uid} — ${o.window} (${o.window_id}), ${o.liveness}, cwd ${o.cwd}, session ${o.session}`;
    case "liveness":
      return `${o.verdict} — ${o.window} (${o.window_id}): ${o.reason}`;
    case "send": {
      const payload = (o.payload ?? {}) as Record<string, unknown>;
      return `sent seq ${o.sequence} to ${o.run}/${o.uid} (stage ${payload.stage})`;
    }
    case "wait": {
      const payload = (o.payload ?? {}) as Record<string, unknown>;
      // kind distinguishes "the worker answered" from "the worker said nothing
      // at all", which are not the same outcome and must not read the same.
      if (o.kind === "error") {
        return `seq ${o.sequence} from ${o.run}/${o.uid}: ${payload.code} — ${payload.detail}`;
      }
      return `seq ${o.sequence} from ${o.run}/${o.uid}: ${payload.status} — ${payload.summary}`;
    }
    case "rm":
      return o.removed ? `released ${o.run}/${o.uid}` : `${o.run}/${o.uid}: ${o.reason}`;
    // The receipt is the boring half. What the caller needs to know is whether
    // the worker's window and process are gone, because that is the part with
    // a consequence — and when they are not, why.
    case "ack":
      return o.released
        ? `acked seq ${o.sequence} from ${o.run}/${o.uid} — released ${o.window} (window and pi gone; worktree, branch and session id kept)`
        : `acked seq ${o.sequence} from ${o.run}/${o.uid} — not released: ${o.reason}`;
    case "stop":
    case "accept":
      return o.changed
        ? `${o.state} ${o.run}/${o.uid}`
        : `${o.run}/${o.uid} was ${o.reason ?? "already in that state"}`;
    // Both addresses, deliberately: the caller asked about the old one and
    // must talk to the new one from here on, and the session id is what says
    // the transcript is the same one.
    case "respawn":
      return (
        `${o.from} → ${o.run}/${o.uid} on session ${o.session} — ${o.window} (${o.window_id}), ` +
        `${o.reused_branch ? "back on" : "forked"} ${o.branch}, cwd ${o.cwd}`
      );
    case "ps":
    case "workers": {
      const rows = Array.isArray(parsed) ? (parsed as Record<string, unknown>[]) : [];
      if (rows.length === 0) return "no workers";
      return rows
        .map((r) => `${r.run}/${r.uid} ${r.state}/${r.liveness ?? "?"} ${r.window}`)
        .join("\n");
    }
    case "resume":
      return `resumed ${o.run}/${o.uid} (rejection ${o.rejections}${o.escalate ? ", escalated" : ""})`;
    default:
      return raw;
  }
}

export function createInitiatorTool(opts: { exec: ExecFn; cwd?: string }): InitiatorTool {
  return {
    invoke: async (args) => {
      // Checked before anything is spawned: the verb is the one field that
      // decides what runs, so an unrecognised one must never reach a shell.
      if (!(INITIATOR_VERBS as readonly string[]).includes(args.verb)) {
        return {
          ok: false,
          detail: `'${args.verb}' is not an initiator verb; expected one of ${INITIATOR_VERBS.join(", ")}`,
        };
      }

      const argv: string[] = [args.verb];
      if (UID_IS_POSITIONAL.includes(args.verb) && args.uid) argv.push(args.uid);

      for (const flag of VERB_FLAGS[args.verb] ?? []) {
        const value = (args as unknown as Record<string, unknown>)[flag];
        // Absent stays ABSENT. An empty flag is not the same as no flag: the
        // CLI reads an empty --task as "this stage has a ticket id" and then
        // fails on a shape the caller never asked for.
        if (value === undefined || value === null || value === "") continue;
        // A switch carries no value. `--block true` would hand nu `true` as an
        // extra positional, and `--block false` is not how nu spells "don't":
        // absence is.
        if (typeof value === "boolean") {
          if (value) argv.push(`--${flag}`);
          continue;
        }
        argv.push(`--${flag}`, String(value));
      }

      try {
        const out = await opts.exec("pi-worker", argv, { cwd: opts.cwd });
        if (out.code !== 0) {
          // The CLI's refusals name what is wrong and list what exists;
          // swallowing them would leave the agent guessing.
          return { ok: false, detail: messageOnly(out.stderr || out.stdout) };
        }
        const stdout = out.stdout.trim();
        if (args.verb === "wait" && stdout.length === 0) {
          // Silence from `wait` means an empty mailbox, not a fault. Reporting
          // it as failure would make an idle run look broken.
          return { ok: true, detail: "no unacknowledged results in this run" };
        }
        return { ok: true, detail: summarise(args.verb, stdout) };
      } catch (err) {
        return { ok: false, detail: String(err) };
      }
    },
  };
}

const INITIATOR_TOOL_PARAMETERS = {
  type: "object",
  properties: {
    verb: { type: "string", enum: [...INITIATOR_VERBS], description: "which bus operation to run" },
    run: { type: "string", description: "the run id grouping these workers. On spawn, omit it and one is minted; reuse what spawn reports for sibling workers" },
    uid: { type: "string", description: "the worker's id within the run. On spawn, omit it and one is minted from the role. On `wait`, scopes to that worker instead of the whole run" },
    role: { type: "string", description: "spawn: shown in the window name, e.g. impl or rev" },
    subject: { type: "string", description: "spawn: a short NAME for the work — it becomes the tmux window name and the git branch, e.g. 'timestamp-file'. Prose is slugified and capped rather than refused, so passing a whole instruction here gets you a window called 'impl-create-timestamp-named-text-file@…' and the instruction goes nowhere: what the worker should DO travels in `send --instructions`" },
    project: { type: "string", description: "spawn: omit this. The tmux session group is derived from the session you are in, which is where the operator is looking. Pass it only when running outside tmux" },
    repo: { type: "string", description: "spawn/accept: on spawn, omit it — the repository is derived from the current directory. Pass it only when that is not a repository, or for accept" },
    session: { type: "string", description: "spawn: omit this. The worker's Pi session id is minted for you — do not generate one" },
    skill: { type: "string", description: `spawn: which stage this worker runs. One of: ${describeStages()}. The payload kind in brackets says what else to pass — 'ticket' needs task, 'instructions' needs instructions` },
    task: { type: "string", description: "spawn/send: a ticket ID and nothing else, only for stages whose payload is a ticket. It names the worker's git branch, so it must be short and have no spaces. To give a worker prose, use `send` with instructions — never this" },
    stage: { type: "string", description: "send: the stage this message belongs to" },
    instructions: { type: "string", description: "send: the actual work, as prose. This is the ONLY field that takes a description of the task; spawn has none, so spawn the worker first and send this second" },
    artifacts: { type: "string", description: "send: comma-separated artifact ids" },
    feedback: { type: "string", description: "resume: why the work is being sent back" },
    sequence: { type: "number", description: "ack: which result envelope is being acknowledged" },
    block: { type: "boolean", description: "wait: block until a result arrives instead of peeking. This is how you learn a worker finished" },
    timeout: { type: "number", description: "wait: seconds to block before giving up, default 60. Giving up is not a failure — the worker may still be working" },
    socket: { type: "string", description: "an alternate tmux socket; omit for the default server" },
  },
  required: ["verb"],
  additionalProperties: false,
} as const;

/**
 * Filesystem-backed IO for the inbox watcher.
 *
 * Kept separate from createInboxWatcher so the watcher itself stays testable
 * without touching a disk; this is the only part that node:fs reaches.
 */
export function nodeWatcherIO(): WatcherIO {
  return {
    list: (dir) => {
      try {
        return readdirSync(dir);
      } catch {
        return []; // no inbox yet is not an error — the worker may predate it
      }
    },
    read: (path) => readFileSync(path, "utf8"),
    join: (...parts) => join(...parts),
    log: (line) => console.error(line),
  };
}

/**
 * Where this worker's inbox lives, or null when the process was not started as
 * a worker (an ordinary interactive Pi session, for instance).
 */
export function workerInboxDir(env: Record<string, string | undefined>): string | null {
  const runtime = env.XDG_RUNTIME_DIR;
  const run = env.PI_WORKER_RUN;
  const uid = env.PI_WORKER_UID;
  if (!runtime || !run || !uid) return null;
  return join(runtime, "pi-worker", run, uid, "inbox");
}

export default function piWorker(pi: ExtensionAPI): void {

  // Worker mode. Only active when the orchestrator set PI_WORKER_RUN/UID, so an
  // ordinary interactive session is completely unaffected.
  //
  // Every host call below is feature-detected. The event names, the
  // sendUserMessage signature and the tool/exec surfaces were reconciled
  // against the installed Pi 0.84.4 types in the sp028 T7 operator run
  // (dotfiles-ea0g), but feature detection stays: a mismatch must degrade to a
  // logged no-op, because an extension that throws during host startup takes
  // the whole worker down — strictly worse than one that says what it cannot
  // do.
  const exec = (pi as unknown as { exec?: ExecFn }).exec?.bind(pi);
  const registerTool = (pi as unknown as { registerTool?: (t: unknown) => void })
    .registerTool?.bind(pi);

  // The initiator half, registered in EVERY session. Orchestrating workers is
  // what most sessions using this package are for, and a session that had to
  // shell out to drive the bus was the gap this closes. A worker gets it too:
  // a worker that dispatches its own workers is the caller's business, not the
  // transport's.
  if (exec && typeof registerTool === "function") {
    const initiator = createInitiatorTool({ exec });
    // renderResult receives the result, not the arguments, so the verb that
    // produced it is remembered here. Calls render in order, so the latest is
    // the one being drawn.
    let lastVerb = "";

    // The live frame. Armed from the first event that carries a UI context,
    // because `ui` reaches an extension through ExtensionContext rather than
    // the API object. Guarded on tui mode: a widget is terminal rows, and
    // there are none to claim in print, json or rpc mode.
    let frame: { refresh: () => Promise<void>; stop: () => void } | null = null;
    const armFrame = (ctx: ExtensionContext) => {
      if (frame || ctx.mode !== "tui" || !ctx.hasUI) return;
      frame = startRosterFrame({
        exec,
        // `content` is either a line array or a component factory; which one
        // is startRosterFrame's decision, made once against what this host
        // will accept. Cast because the two overloads differ per Pi version
        // and the frame must compile against either.
        setWidget: (key, content) =>
          (ctx.ui.setWidget as (k: string, c: unknown, o?: unknown) => void)(
            key,
            content,
            { placement: "aboveEditor" },
          ),
      });
    };
    try {
      pi.on("session_start", (_event, ctx) => armFrame(ctx));
    } catch {
      // An older build without the event simply gets no frame.
    }

    try {
      registerTool({
        name: "pi_worker",
        label: "Worker bus",
        description:
          "Drive Pi workers: `ps` lists every worker, whether it is alive and which tmux window to look at. Also: spawn one as a visible tmux window, check its liveness, send it a message, `wait` for its typed result (pass uid to wait on that worker rather than the whole run), resume it with feedback, then accept or stop it. " +
"`timeline` shows what happened to one worker and when, with the gap between each step — reach for it when a worker took longer than expected and you want to know where the time went. " +
          "To learn that a worker finished, call `wait` with block true — it returns the moment a result lands. A worker's tmux window is there for a PERSON to look at: never read it, capture it, or treat anything in it as a completion signal, and never generate ids for spawn — omit run, uid and session and they are minted for you. " +
          "An address is claimed once: to reuse a run/uid after stopping or accepting it, call `rm` with that run and uid — that is the normal way to recycle one, and it refuses while the worker is still unfinished, so it is safe to try. " +
          "ACK EVERY RESULT you have handled: the ack is what releases the worker's tmux window and its pi process, so a run that never acks leaves one idle agent per worker sitting on the machine. Its worktree, branch and session id survive the release, so nothing is lost and `respawn` can bring the worker back on the same transcript. " +
          "Accept as soon as you judge the work correct: that reclaims the window, the worktree and the branch, and the session id it leaves on the bus is all a restore needs. If you want that worker again afterwards, call `respawn` with its uid — you get a NEW uid continuing the SAME Pi transcript, with its worktree rebuilt, so tearing down promptly costs you nothing. Verbs: " +
          INITIATOR_VERBS.join(", ") +
          `. Stages: ${describeStages()}.`,
        promptSnippet: "pi_worker — spawn, watch and message Pi workers",
        parameters: INITIATOR_TOOL_PARAMETERS,
        // `self` so Pi draws no header box around an empty body: without it a
        // suppressed result still leaves a `pi_worker` label behind, which is
        // the noise this removes.
        renderShell: "self",
        renderCall: () => callComponent(),
        // Pi passes its own view state and a per-row context here, and both
        // were being dropped on the floor — which is why `inspect` printed its
        // whole body every time regardless of the expand key. `options` and
        // `context` are typed loosely on purpose: their shapes differ across
        // Pi versions, and the frame must load against either.
        renderResult: (
          result: { details?: unknown },
          options?: { expanded?: boolean },
          _theme?: unknown,
          context?: { state?: Record<string, unknown>; invalidate?: () => void },
        ) => {
          const outcome = (result.details ?? {}) as { ok?: boolean; detail?: string };
          return resultComponent(lastVerb, outcome.ok !== false, outcome.detail ?? "", {
            expanded: options?.expanded === true,
            // Observed, not assumed: a refusal is only kept out of the
            // transcript when there is a frame drawing it instead.
            frameLive: frame !== null,
            // No context means no per-row state to remember a click in, so the
            // component simply offers no click target rather than pretending.
            ...(context?.state ? { state: context.state } : {}),
            ...(context?.invalidate ? { invalidate: context.invalidate } : {}),
          });
        },
        execute: async (
          _id: string,
          params: InitiatorArgs,
          _signal: AbortSignal | undefined,
          _onUpdate: unknown,
          ctx: ExtensionContext,
        ) => {
          lastVerb = params.verb;
          // Armed BEFORE the call, so the very first spawn of a session has a
          // frame to warm up in. Arming afterwards meant the one moment worth
          // watching — before any worker exists — had nowhere to show.
          armFrame(ctx);
          // Claimed BEFORE the call, so a spawn's own worker is in scope by
          // the time the first poll runs. For a minted run the id is not known
          // until spawn answers, which is why the outcome is read for it too.
          if (params.run) frame?.own(params.run);
          frame?.note({ verb: params.verb, at: Date.now() });

          const outcome = await initiator.invoke(params);

          // A spawn with no run given had one minted for it, and the only
          // record of which is the answer: "spawned r3/impl-1 — ...". Without
          // this the session's own first worker would be filtered out of its
          // own frame.
          if (outcome.ok !== false && outcome.detail) {
            const spawned = /\bspawned\s+([^/\s]+)\//.exec(outcome.detail);
            if (spawned) frame?.own(spawned[1]);
          }
          frame?.note({
            verb: params.verb,
            ok: outcome.ok !== false,
            ...(outcome.detail ? { detail: outcome.detail } : {}),
            at: Date.now(),
          });
          // Redraw immediately rather than waiting out the interval: the verb
          // that just ran is usually the thing that changed the roster.
          if (frame) await frame.refresh();
          return {
            content: [{ type: "text", text: outcome.detail || (outcome.ok ? "ok" : "failed") }],
            details: outcome,
          };
        },
      });
    } catch (err) {
      nodeWatcherIO().log(`pi-worker: could not register the initiator tool: ${err}`);
    }
  }

  // Worker mode below. Only active when an orchestrator set PI_WORKER_RUN/UID,
  // so an ordinary session is unaffected by any of it.
  const inboxDir = workerInboxDir(process.env as Record<string, string | undefined>);
  if (!inboxDir) return;

  const io = nodeWatcherIO();
  const run = process.env.PI_WORKER_RUN ?? "";
  const uid = process.env.PI_WORKER_UID ?? "";
  const identity = {
    role: process.env.PI_WORKER_ROLE ?? "worker",
    cwd: process.cwd(),
    branch: process.env.PI_WORKER_BRANCH ?? "",
    session: process.env.PI_WORKER_SESSION ?? "",
    skill: process.env.PI_WORKER_SKILL ?? "",
    window: process.env.PI_WORKER_WINDOW ?? "",
  };

  // Pi publishes lifecycle events but exposes no state getter, so the state
  // the watcher needs is derived here and handed in. This is the correction of
  // the ft014 assumption that a `host.agentState()` existed: the watcher's
  // contract is unchanged, its data source is now real.
  const tracker = createAgentStateTracker(pi as unknown as StateEventSource);
  const api = pi as unknown as WatcherHost;
  const host: WatcherHost = {
    sendUserMessage: api.sendUserMessage?.bind(pi),
    agentState: () => tracker.current(),
  };
  if (typeof host.sendUserMessage !== "function") {
    io.log(
      "pi-worker: this Pi build exposes no sendUserMessage; worker inbox delivery is inert. Reconcile against the live API (sp028 T7).",
    );
    return;
  }

  // The worker's way back to the initiator (dotfiles-87bt). Registered BEFORE
  // the inbox watcher starts: a message may arrive on the first poll, and a
  // worker asked to work before it can report is the exact silence this fixes.
  const reporter = exec
    ? createResultTool({ run, uid, identity, exec })
    : null;

  if (!reporter) {
    io.log(
      "pi-worker: this Pi build exposes no exec; the worker cannot report an outcome. Reconcile against the live API.",
    );
  } else {
    if (typeof registerTool !== "function") {
      io.log("pi-worker: this Pi build exposes no registerTool; the typed result tool is unavailable");
    } else {
      try {
        registerTool({
          name: "pi_worker_result",
          label: "Report result",
          description:
            "Report this worker's outcome to the orchestrator. Call this to finish; ending your turn without it is recorded as a protocol error, never as success.",
          promptSnippet: "pi_worker_result — report your outcome to the orchestrator",
          // The briefing that was built and never delivered. In the system
          // prompt rather than only in this description, because a worker has
          // to know it must report BEFORE it decides it has finished.
          // The stage's isolation decides whether this worker owns a throwaway
          // branch it has to commit to. Read defensively: a registry that
          // cannot be loaded must cost the worker one paragraph of guidance,
          // not its whole session.
          promptGuidelines: workerPromptGuidelines(identity, (() => {
            try {
              return loadStages().find((s) => s.name === identity.skill)?.isolation;
            } catch {
              return undefined;
            }
          })()),
          parameters: RESULT_TOOL_PARAMETERS,
          execute: async (
            _id: string,
            params: { status: string; summary: string; validation?: string },
          ) => {
            const outcome = await reporter.report(params);
            return {
              content: [
                {
                  type: "text",
                  text: outcome.ok
                    ? `reported: ${params.status}`
                    : `NOT reported — ${outcome.detail}`,
                },
              ],
              details: outcome,
              // Stop after a successful report: the worker is done and its
              // window stays open for inspection. A refusal does NOT terminate,
              // so the worker can read the reason and try again.
              terminate: outcome.ok,
            };
          },
        });
      } catch (err) {
        io.log(`pi-worker: could not register the result tool: ${err}`);
      }
    }

    // A settle with nothing reported is itself the report. Without this the
    // initiator cannot tell "still working" from "finished and went quiet",
    // and waits forever on a worker that is done.
    try {
      pi.on("agent_settled", () => {
        void reporter.reportSettled().then((outcome) => {
          if (!outcome.ok) io.log(`pi-worker: settle report failed: ${outcome.detail}`);
        });
      });
    } catch (err) {
      io.log(`pi-worker: could not subscribe to agent_settled: ${err}`);
    }
  }

  const watcher = createInboxWatcher(host, identity, inboxDir, io);
  const timer = setInterval(() => {
    try {
      watcher.poll();
    } catch (err) {
      // A watcher fault must never propagate into the host's event loop.
      io.log(`pi-worker: inbox poll failed: ${err}`);
    }
  }, 1000);
  if (typeof timer === "object" && timer && "unref" in timer) {
    (timer as { unref: () => void }).unref(); // never hold the process open
  }
}
