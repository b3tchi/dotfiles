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
  sendUserMessage?: (text: string, options?: { mode?: string }) => unknown;
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
        host.sendUserMessage(text, { mode: decision.mode });
        mark = envelope.sequence;
        sent.push(envelope.sequence);
      }
      return sent;
    },
  };
}

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
  // Every host call below is feature-detected. The Pi package is not installed
  // in this repo, so the event name and the sendUserMessage signature are
  // assumptions carried from ft014 rather than anything a compiler has checked;
  // sp028 T7's operator run is where they get reconciled against the real API.
  // Until then a mismatch must degrade to a logged no-op — an extension that
  // throws during host startup would take the whole worker down, which is
  // strictly worse than one that delivers nothing and says so.
  const inboxDir = workerInboxDir(process.env as Record<string, string | undefined>);
  if (!inboxDir) return;

  const io = nodeWatcherIO();
  const identity = {
    role: process.env.INFINIFU_ROLE ?? "worker",
    cwd: process.cwd(),
    branch: process.env.INFINIFU_BRANCH ?? "",
    session: process.env.INFINIFU_SESSION ?? "",
    skill: process.env.INFINIFU_SKILL ?? "",
    window: process.env.INFINIFU_WINDOW ?? "",
  };

  const host = pi as unknown as WatcherHost;
  if (typeof host.sendUserMessage !== "function") {
    io.log(
      "infinifu: this Pi build exposes no sendUserMessage; worker inbox delivery is inert. Reconcile against the live API (sp028 T7).",
    );
    return;
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
