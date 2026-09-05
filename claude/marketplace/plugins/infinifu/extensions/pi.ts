import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
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
export type ResultStatus = "complete" | "waiting_human" | "blocked" | "failed";

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

export default function infinifu(pi: ExtensionAPI): void {
  pi.on("before_agent_start", (event) => ({
    systemPrompt: `${event.systemPrompt}\n\n<EXTREMELY_IMPORTANT>\nYou have Infinifu lifecycle skills and bd task tracking. The meta-bootstrap skill is already loaded below; do not load it again.\n\n${bootstrap}\n\n${piMapping}\n</EXTREMELY_IMPORTANT>`,
  }));
}
