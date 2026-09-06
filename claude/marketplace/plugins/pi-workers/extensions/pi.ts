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

interface StageEntry {
  name: string;
  isolation: string;
  payload: string;
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
export function systemContextFor(identity: WorkerIdentity): string {
  return [
    `You are a pi-worker.`,
    `role: ${identity.role}`,
    `skill: ${identity.skill}`,
    `worktree: ${identity.cwd}`,
    `branch: ${identity.branch}`,
    `session: ${identity.session}`,
    `window: ${identity.window}`,
    `Report your outcome by calling the result tool. Finishing your turn without`,
    `calling it is recorded as a protocol error, not a success.`,
  ].join("\n");
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
  "ack",
  "status",
  "inspect",
  "workers",
  "liveness",
  "resume",
  "accept",
  "stop",
] as const;

export type InitiatorVerb = (typeof INITIATOR_VERBS)[number];

/** Verbs whose uid is positional rather than a flag, matching the CLI. */
const UID_IS_POSITIONAL: readonly string[] = [
  "send",
  "status",
  "inspect",
  "liveness",
  "resume",
  "accept",
  "stop",
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
  wait: ["run"],
  ack: ["run", "uid", "sequence"],
  status: ["run"],
  inspect: ["run"],
  workers: ["run"],
  liveness: ["run", "socket"],
  resume: ["run", "feedback", "socket"],
  accept: ["run", "repo", "socket"],
  stop: ["run", "socket"],
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
/** States meaning the worker is finished with; nothing is waiting on it. */
const FINISHED_STATES: readonly string[] = ["stopped", "accepted"];

export function rosterFrame(all: RosterRow[]): string[] | undefined {
  // The frame answers "what is running", so a finished worker has no business
  // holding a row. `blocked` and `waiting_human` are NOT finished — they are
  // waiting for someone, which is precisely what a status panel is for.
  const rows = all.filter((r) => !FINISHED_STATES.includes(r.state));
  if (rows.length === 0) return undefined;

  const addr = rows.map((r) => `${r.run}/${r.uid}`);
  // Padded to a common width so the columns read down the frame rather than
  // drifting with the length of each run id.
  const addrWidth = Math.max(...addr.map((a) => a.length));
  const stateWidth = Math.max(...rows.map((r) => r.state.length));
  const liveWidth = Math.max(...rows.map((r) => r.liveness.length));

  const heading = `pi-workers · ${rows.length} worker${rows.length === 1 ? "" : "s"}`;
  const lines = rows.map((r, i) =>
    [
      addr[i].padEnd(addrWidth),
      r.state.padEnd(stateWidth),
      r.liveness.padEnd(liveWidth),
      r.window,
    ].join("  "),
  );
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
export function startRosterFrame(opts: {
  exec: ExecFn;
  setWidget: (key: string, content: string[] | undefined) => void;
  intervalMs?: number;
}): { refresh: () => Promise<void>; stop: () => void } {
  const refresh = async () => {
    try {
      const out = await opts.exec("pi-worker", ["ps"], {});
      if (out.code !== 0) return;
      const rows = JSON.parse(out.stdout || "[]") as RosterRow[];
      opts.setWidget("pi-workers", rosterFrame(rows));
    } catch {
      // A frame that cannot be drawn is not worth breaking a session over.
    }
  };

  const timer = setInterval(() => void refresh(), opts.intervalMs ?? 5000);
  if (typeof timer === "object" && timer && "unref" in timer) {
    (timer as { unref: () => void }).unref(); // never hold the process open
  }
  void refresh();
  return { refresh, stop: () => clearInterval(timer) };
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
];

export function transcriptLines(verb: string, ok: boolean, detail: string): string[] {
  // A failure always prints, whatever the verb. Suppressing a spawn's success
  // must never suppress its refusal — an operator who cannot see the failure
  // has no idea why nothing happened.
  if (!ok) return [detail];

  // `inspect` and `status` are asked precisely for their detail.
  if (verb === "inspect" || verb === "status") return detail.split("\n");

  if (FRAME_COVERED_VERBS.includes(verb)) return [];

  // An empty mailbox was the noisiest line of a polling loop and says nothing
  // the frame does not.
  if (verb === "wait" && detail.startsWith("no unacknowledged")) return [];

  return detail.length > 0 ? [detail] : [];
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
 */
export function resultComponent(
  verb: string,
  ok: boolean,
  detail: string,
): { render: (width: number) => string[]; invalidate: () => void } {
  const lines = transcriptLines(verb, ok, detail);
  return {
    // Honours the width it is given; see wrapToWidth for why that is not
    // optional.
    render: (width: number) => wrapToWidth(lines, width),
    invalidate: () => {
      // Nothing is cached; the lines were computed once when the call returned.
    },
  };
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
    case "stop":
    case "accept":
      return o.changed
        ? `${o.state} ${o.run}/${o.uid}`
        : `${o.run}/${o.uid} was ${o.reason ?? "already in that state"}`;
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
    run: { type: "string", description: "the run id grouping these workers" },
    uid: { type: "string", description: "the worker's id within the run" },
    role: { type: "string", description: "spawn: shown in the window name, e.g. impl or rev" },
    subject: { type: "string", description: "spawn: what the worker is working on; shown in the window name. Avoid '.'" },
    project: { type: "string", description: "spawn: tmux session group or session name to host the window" },
    repo: { type: "string", description: "spawn/accept: the git repository" },
    session: { type: "string", description: "spawn: a fresh uuid for the worker's Pi session" },
    skill: { type: "string", description: "spawn: a stage name declared in the stage registry" },
    task: { type: "string", description: "spawn/send: ticket id, for stages whose payload is a ticket" },
    stage: { type: "string", description: "send: the stage this message belongs to" },
    instructions: { type: "string", description: "send: prose, for stages whose payload is instructions" },
    artifacts: { type: "string", description: "send: comma-separated artifact ids" },
    feedback: { type: "string", description: "resume: why the work is being sent back" },
    sequence: { type: "number", description: "ack: which result envelope is being acknowledged" },
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
        setWidget: (key, content) =>
          ctx.ui.setWidget(key, content, { placement: "aboveEditor" }),
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
          "Drive Pi workers: `ps` lists every worker, whether it is alive and which tmux window to look at. Also: spawn one as a visible tmux window, check its liveness, send it a message, wait for its typed result, resume it with feedback, then accept or stop it. Verbs: " +
          INITIATOR_VERBS.join(", ") +
          ". Stages must be declared in the stage registry.",
        promptSnippet: "pi_worker — spawn, watch and message Pi workers",
        parameters: INITIATOR_TOOL_PARAMETERS,
        // `self` so Pi draws no header box around an empty body: without it a
        // suppressed result still leaves a `pi_worker` label behind, which is
        // the noise this removes.
        renderShell: "self",
        renderCall: () => callComponent(),
        renderResult: (result: { details?: unknown }) => {
          const outcome = (result.details ?? {}) as { ok?: boolean; detail?: string };
          return resultComponent(lastVerb, outcome.ok !== false, outcome.detail ?? "");
        },
        execute: async (
          _id: string,
          params: InitiatorArgs,
          _signal: AbortSignal | undefined,
          _onUpdate: unknown,
          ctx: ExtensionContext,
        ) => {
          lastVerb = params.verb;
          const outcome = await initiator.invoke(params);
          // Redraw immediately rather than waiting out the interval: the verb
          // that just ran is usually the thing that changed the roster.
          armFrame(ctx);
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
