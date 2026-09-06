import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pluginRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const bootstrapPath = join(pluginRoot, "skills", "meta-bootstrap", "SKILL.md");

function stripFrontmatter(content: string): string {
  return content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");
}

const bootstrap = stripFrontmatter(readFileSync(bootstrapPath, "utf8"));

const piMapping = `
**Tool mapping for Pi:**
- Infinifu references such as \`infinifu:domain-tdd\` mean Pi skill \`domain-tdd\`.
- Load a skill by reading its listed \`SKILL.md\`, or let the user invoke \`/skill:<name>\`.
- \`TodoWrite\`, \`TaskCreate\`, and \`TaskUpdate\` → use the \`bd\` CLI. Never create markdown TODO lists.
- \`Read\`, \`Write\`, \`Edit\`, \`Bash\`, \`Glob\`, and \`Grep\` → use Pi's native read, write, edit, bash, find, and grep tools.
- Runtime-specific lifecycle behavior follows \`infinifu:meta-patterns/runtime-adapter.md\`: \`AI_AGENT=pi\` selects Pi, Claude's native Agent/Task surface selects Claude behavior, and unknown runtimes fail closed.
- Worker orchestration under Pi uses the \`infinifu-worker\` CLI bus. tmux hosts and displays workers; it never carries messages, completion signals, or status. Report completion only through the typed result tool — settling without it is a protocol error, not a success.
- Claude \`Agent\`/\`Task\` subagents are not built into Pi. Use independent Pi processes in tmux only when a Pi runtime adapter provides a direct messaging contract; otherwise execute sequentially. Never pretend a subagent was dispatched.

**bd task tracking:**
Use \`bd\` for multi-step work. Start with \`bd prime\` for current commands and workflow. Track status and discovered work in bd; follow the repository's AGENTS.md completion protocol.
`;

// ---------------------------------------------------------------------------
// Worker bus protocol (ft014 / sp028 T1) — contract only.
//
// These definitions are the extension's half of the contract implemented in
// scripts/infinifu-worker.nu. The inbox watcher and the typed result tool land
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
export const WORK_STAGES = ["work-do", "work-audit", "work-merge"] as const;

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
 * contract with `bd show <id>`. Copying the task body into the payload would
 * create a second source of truth that drifts from bd on the next update.
 */
export interface WorkPayload {
  stage: (typeof WORK_STAGES)[number];
  task: string;
}

/** AKM stages get direct instructions plus artifact ids, resolved via `akm`. */
export interface AkmPayload {
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

function isWorkStage(stage: string): stage is (typeof WORK_STAGES)[number] {
  return (WORK_STAGES as readonly string[]).includes(stage);
}

/**
 * The user-visible message text for an inbox envelope.
 *
 * For a work stage this is the bare bd task id and nothing else — no framing,
 * no skill name, no instructions. The worker resolves its contract with
 * `bd show <id>`, and any prose here becomes a second description of the task
 * that drifts from bd the moment the ticket is edited.
 *
 * A payload that violates the shape is REJECTED rather than trimmed to fit:
 * trimming would hide the caller's mistake and deliver a message the protocol
 * says cannot exist.
 */
export function userPayloadFor(envelope: Envelope): string {
  const payload = envelope.payload as Record<string, unknown>;
  const stage = String(payload.stage ?? "");

  if (isWorkStage(stage)) {
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
    throw new Error(`AKM-stage payload for '${stage}' must carry direct instructions`);
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
    `You are an infinifu worker.`,
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
        io.log(`infinifu: unreadable inbox envelope ${name}; skipped`);
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
        io.log("infinifu: host exposes no sendUserMessage; inbox delivery is inert");
        return [];
      }
      const state: AgentState = host.agentState ? host.agentState() : "unknown";
      const sent: number[] = [];

      for (const envelope of unreadAfter(mark, load())) {
        const decision = decideDelivery(state, envelope);
        if (decision.mode === "defer") {
          // Stop at the first deferral rather than skipping ahead: delivering
          // message 4 before 3 would reorder the conversation.
          io.log(`infinifu: deferring seq ${envelope.sequence} — ${decision.reason}`);
          break;
        }
        let text: string;
        try {
          text = userPayloadFor(envelope);
        } catch (err) {
          io.log(`infinifu: refusing malformed inbox envelope ${envelope.sequence}: ${err}`);
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
// This is deliberately a THIN shell over `infinifu-worker result`. The
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
      const out = await opts.exec("infinifu-worker", args, { cwd: opts.identity.cwd });
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
  const run = env.INFINIFU_RUN;
  const uid = env.INFINIFU_UID;
  if (!runtime || !run || !uid) return null;
  return join(runtime, "infinifu-worker", run, uid, "inbox");
}

export default function infinifu(pi: ExtensionAPI): void {
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n<EXTREMELY_IMPORTANT>\nYou have Infinifu lifecycle skills and bd task tracking. The meta-bootstrap skill is already loaded below; do not load it again.\n\n${bootstrap}\n\n${piMapping}\n</EXTREMELY_IMPORTANT>`,
  }));

  // Worker mode. Only active when the orchestrator set INFINIFU_RUN/UID, so an
  // ordinary interactive session is completely unaffected.
  //
  // Every host call below is feature-detected. The event names, the
  // sendUserMessage signature and the tool/exec surfaces were reconciled
  // against the installed Pi 0.84.4 types in the sp028 T7 operator run
  // (dotfiles-ea0g), but feature detection stays: a mismatch must degrade to a
  // logged no-op, because an extension that throws during host startup takes
  // the whole worker down — strictly worse than one that says what it cannot
  // do.
  const inboxDir = workerInboxDir(process.env as Record<string, string | undefined>);
  if (!inboxDir) return;

  const io = nodeWatcherIO();
  const run = process.env.INFINIFU_RUN ?? "";
  const uid = process.env.INFINIFU_UID ?? "";
  const identity = {
    role: process.env.INFINIFU_ROLE ?? "worker",
    cwd: process.cwd(),
    branch: process.env.INFINIFU_BRANCH ?? "",
    session: process.env.INFINIFU_SESSION ?? "",
    skill: process.env.INFINIFU_SKILL ?? "",
    window: process.env.INFINIFU_WINDOW ?? "",
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
      "infinifu: this Pi build exposes no sendUserMessage; worker inbox delivery is inert. Reconcile against the live API (sp028 T7).",
    );
    return;
  }

  // The worker's way back to the initiator (dotfiles-87bt). Registered BEFORE
  // the inbox watcher starts: a message may arrive on the first poll, and a
  // worker asked to work before it can report is the exact silence this fixes.
  const exec = (pi as unknown as { exec?: ExecFn }).exec?.bind(pi);
  const reporter = exec
    ? createResultTool({ run, uid, identity, exec })
    : null;

  if (!reporter) {
    io.log(
      "infinifu: this Pi build exposes no exec; the worker cannot report an outcome. Reconcile against the live API.",
    );
  } else {
    const registerTool = (pi as unknown as { registerTool?: (t: unknown) => void })
      .registerTool?.bind(pi);
    if (typeof registerTool !== "function") {
      io.log("infinifu: this Pi build exposes no registerTool; the typed result tool is unavailable");
    } else {
      try {
        registerTool({
          name: "infinifu_result",
          label: "Report result",
          description:
            "Report this worker's outcome to the orchestrator. Call this to finish; ending your turn without it is recorded as a protocol error, never as success.",
          promptSnippet: "infinifu_result — report your outcome to the orchestrator",
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
        io.log(`infinifu: could not register the result tool: ${err}`);
      }
    }

    // A settle with nothing reported is itself the report. Without this the
    // initiator cannot tell "still working" from "finished and went quiet",
    // and waits forever on a worker that is done.
    try {
      pi.on("agent_settled", () => {
        void reporter.reportSettled().then((outcome) => {
          if (!outcome.ok) io.log(`infinifu: settle report failed: ${outcome.detail}`);
        });
      });
    } catch (err) {
      io.log(`infinifu: could not subscribe to agent_settled: ${err}`);
    }
  }

  const watcher = createInboxWatcher(host, identity, inboxDir, io);
  const timer = setInterval(() => {
    try {
      watcher.poll();
    } catch (err) {
      // A watcher fault must never propagate into the host's event loop.
      io.log(`infinifu: inbox poll failed: ${err}`);
    }
  }, 1000);
  if (typeof timer === "object" && timer && "unref" in timer) {
    (timer as { unref: () => void }).unref(); // never hold the process open
  }
}
