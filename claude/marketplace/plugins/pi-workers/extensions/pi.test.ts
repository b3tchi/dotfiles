// Pi bridge cases (sp028 T4).
//
//   bun test claude/marketplace/plugins/infinifu/extensions/pi.test.ts
//
// These cover the decisions the bridge makes, not Pi's own behavior: when a
// message may be delivered and how, what the user payload is allowed to
// contain, what a result envelope must carry, and which messages a resumed
// session still owes. Those are the parts that can be wrong in a way no
// operator would notice — a steer sent during compaction, or a task body
// quietly copied into a work payload.
//
// What is NOT covered here: pi.sendUserMessage()'s real timing against a live
// streaming session. That needs a running Pi and is verified in the T7
// operator run.

import { expect, test, describe } from "bun:test";
import { join } from "node:path";

// Stage shape is read from the consumer's registry now, so the suite supplies
// one. Same fixture the nu suite uses, so both halves agree on the vocabulary.
process.env.PI_WORKER_STAGES = join(
  import.meta.dir,
  "../../../../..",
  "tests/pi-worker/stages.test.json",
);
import {
  createInboxWatcher,
  decideDelivery,
  userPayloadFor,
  systemContextFor,
  workerPromptGuidelines,
  resultEnvelopeFrom,
  settledWithoutResult,
  unreadAfter,
  createAgentStateTracker,
  createResultTool,
  createInitiatorTool,
  rosterFrame,
  collapsedStateLine,
  EMPTY_GRACE_MS,
  AGE_WORTH_SHOWING_MS,
  activityLine,
  ACTIVITY_TTL_MS,
  formatElapsed,
  stateTone,
  themePaint,
  startRosterFrame,
  transcriptLines,
  resultComponent,
  callComponent,
  wrapToWidth,
  MAX_SUMMARY_BYTES,
} from "./pi.ts";

const workEnvelope = {
  protocol: 1 as const,
  sequence: 3,
  run: "run-1",
  uid: "impl-a",
  kind: "inbox" as const,
  created: "2026-09-05T10:00:00Z",
  payload: { stage: "wk-build" as const, task: "dotfiles-963w.4" },
};

const akmEnvelope = {
  ...workEnvelope,
  payload: {
    stage: "doc-plan",
    instructions: "Refine the spec into tasks.",
    artifacts: ["sp028", "ft014"],
  },
};

const identity = {
  role: "impl",
  cwd: "/repo/.worktrees/bd-dotfiles-963w.4.0",
  branch: "bd-dotfiles-963w.4.0",
  session: "sid-1",
  skill: "wk-build",
  window: "impl-dotfiles-963w.4@dotfiles",
};

describe("delivery decisions", () => {
  test("an idle agent gets a plain follow-up", () => {
    const d = decideDelivery("idle", workEnvelope);
    expect(d.mode).toBe("followUp");
  });

  test("a streaming agent is steered rather than interrupted blindly", () => {
    const d = decideDelivery("streaming", workEnvelope);
    expect(d.mode).toBe("steer");
  });

  test("compaction defers instead of delivering", () => {
    // Injecting a turn mid-compaction races the very history being rewritten.
    // Deferring costs a redelivery; the bus redelivers until ack anyway.
    const d = decideDelivery("compacting", workEnvelope);
    expect(d.mode).toBe("defer");
    expect(d.reason).toMatch(/compact/i);
  });

  test("shutdown refuses delivery and says so", () => {
    const d = decideDelivery("shutting_down", workEnvelope);
    expect(d.mode).toBe("defer");
    expect(d.reason).toMatch(/shut/i);
  });

  test("an unknown agent state defers rather than guessing", () => {
    // Fail closed: a state this build does not recognise might be any of the
    // unsafe ones.
    const d = decideDelivery("some_future_state", workEnvelope);
    expect(d.mode).toBe("defer");
    expect(d.reason).toMatch(/unknown/i);
  });

  test("delivery is never 'drop' — the bus owns redelivery", () => {
    for (const state of ["idle", "streaming", "compacting", "shutting_down", "???"]) {
      expect(["followUp", "steer", "defer"]).toContain(decideDelivery(state, workEnvelope).mode);
    }
  });
});

describe("user payload shaping", () => {
  test("a work stage sends exactly the bd task id", () => {
    expect(userPayloadFor(workEnvelope)).toBe("dotfiles-963w.4");
  });

  test("a work payload carries no prose, framing, or skill name", () => {
    const text = userPayloadFor(workEnvelope);
    expect(text).not.toMatch(/wk-build/);
    expect(text).not.toMatch(/please|implement|you are/i);
    expect(text.split(/\s+/)).toHaveLength(1);
  });

  test("an AKM stage sends its instructions and artifact ids", () => {
    const text = userPayloadFor(akmEnvelope);
    expect(text).toContain("Refine the spec into tasks.");
    expect(text).toContain("sp028");
    expect(text).toContain("ft014");
  });

  test("a work envelope carrying extra fields is rejected, not trimmed", () => {
    // Trimming would hide the caller's mistake and ship a payload the
    // protocol says cannot exist.
    const bad = { ...workEnvelope, payload: { ...workEnvelope.payload, design: "copied prose" } };
    expect(() => userPayloadFor(bad as never)).toThrow(/work/i);
  });

  test("an unknown stage with neither task nor instructions is rejected", () => {
    const bad = { ...workEnvelope, payload: { stage: "mystery" } };
    // An undeclared stage is now refused up front, by the registry, rather than
    // by the shape of what it happened to carry.
    expect(() => userPayloadFor(bad as never)).toThrow(/not declared in the stage registry/i);
  });
});

describe("trusted configuration stays out of the user message", () => {
  test("role and skill are carried in system context", () => {
    const ctx = systemContextFor(identity);
    expect(ctx).toContain("impl");
    expect(ctx).toContain("wk-build");
    expect(ctx).toContain(identity.cwd);
  });

  test("system context is never mixed into the user payload", () => {
    const ctx = systemContextFor(identity);
    const text = userPayloadFor(workEnvelope);
    for (const secret of [identity.session, identity.branch, identity.cwd, "wk-build"]) {
      expect(text).not.toContain(secret);
    }
    expect(ctx).toContain(identity.session);
  });
});

describe("typed result envelope", () => {
  const good = {
    status: "complete",
    summary: "landed",
    validation: "PASS",
  };

  test("builds a complete result from the tool input", () => {
    const env = resultEnvelopeFrom(good, identity);
    expect(env.status).toBe("complete");
    expect(env.window).toBe(identity.window);
    expect(env.session).toBe(identity.session);
    expect(env.resume).toBe(`pi --session ${identity.session}`);
  });

  test("accepts the non-complete outcomes a worker can report", () => {
    for (const status of ["waiting_human", "blocked", "failed"]) {
      expect(resultEnvelopeFrom({ status, summary: "s" }, identity).status).toBe(status);
    }
  });

  test("refuses a completion with no validation verdict", () => {
    expect(() => resultEnvelopeFrom({ status: "complete", summary: "s" }, identity)).toThrow(
      /validation/i,
    );
  });

  test("refuses statuses a worker cannot grant itself", () => {
    for (const status of ["accepted", "stopped", "running", "unknown"]) {
      expect(() => resultEnvelopeFrom({ status, summary: "s" }, identity)).toThrow();
    }
  });

  test("refuses an oversized summary rather than truncating it", () => {
    // Truncating would ship a summary that reads as complete but is not.
    const summary = "x".repeat(MAX_SUMMARY_BYTES + 1);
    expect(() => resultEnvelopeFrom({ status: "blocked", summary }, identity)).toThrow(/4 KiB/);
  });

  test("a summary exactly at the cap is accepted", () => {
    const summary = "x".repeat(MAX_SUMMARY_BYTES);
    expect(resultEnvelopeFrom({ status: "blocked", summary }, identity).summary).toHaveLength(
      MAX_SUMMARY_BYTES,
    );
  });

  test("measures the cap in bytes, not UTF-16 code units", () => {
    // A summary of multi-byte characters is well under the cap by .length and
    // over it by bytes; the file on disk is what the cap protects.
    const summary = "é".repeat(MAX_SUMMARY_BYTES - 10);
    expect(() => resultEnvelopeFrom({ status: "blocked", summary }, identity)).toThrow(/4 KiB/);
  });
});

describe("settling without the result tool", () => {
  test("produces a protocol error, never a completion", () => {
    const env = settledWithoutResult(identity);
    expect(env.code).toBe("protocol_error");
    expect(env.detail).toMatch(/result tool/i);
    expect(JSON.stringify(env)).not.toContain("complete");
  });
});

describe("resume without duplicate turns", () => {
  const inbox = [1, 2, 3, 4].map((sequence) => ({ ...workEnvelope, sequence }));

  test("a fresh session owes every message", () => {
    expect(unreadAfter(0, inbox).map((e) => e.sequence)).toEqual([1, 2, 3, 4]);
  });

  test("a resumed session owes only what it had not delivered", () => {
    expect(unreadAfter(2, inbox).map((e) => e.sequence)).toEqual([3, 4]);
  });

  test("a fully caught-up session owes nothing", () => {
    expect(unreadAfter(4, inbox)).toEqual([]);
  });

  test("a high-water mark past the end does not replay", () => {
    // The extension reloaded after delivering, before the mark was persisted
    // anywhere the inbox can see. Replaying would double the turn.
    expect(unreadAfter(9, inbox)).toEqual([]);
  });

  test("out-of-order files are still owed in sequence order", () => {
    const shuffled = [3, 1, 4, 2].map((sequence) => ({ ...workEnvelope, sequence }));
    expect(unreadAfter(1, shuffled).map((e) => e.sequence)).toEqual([2, 3, 4]);
  });
});

// ---------------------------------------------------------------------------
// Agent state derivation (dotfiles-zxzj).
//
// Pi's ExtensionAPI has NO state getter. The original bridge called a
// host.agentState() that does not exist, so every poll read the literal string
// "unknown" and deferred forever — a live worker logged
// "deferring seq 1 — unknown agent state 'unknown'" once a second and never
// received its message. State has to be DERIVED by subscribing to events.
//
// These cases pin the derivation against the event names in
// @earendil-works/pi-coding-agent/dist/core/extensions/types.d.ts (v0.84.4).

describe("agent state tracker", () => {
  function fakeSource() {
    const handlers = new Map<string, (e: unknown) => unknown>();
    return {
      fire: (event: string, payload: unknown = {}) => {
        const h = handlers.get(event);
        if (!h) throw new Error(`nothing subscribed to '${event}'`);
        h(payload);
      },
      subscribed: () => [...handlers.keys()],
      source: {
        on: (event: string, handler: (e: unknown) => unknown) => {
          handlers.set(event, handler);
        },
      },
    };
  }

  test("a fresh session is idle before any event fires", () => {
    // A worker is spawned and sits at its prompt. Nothing has run yet, so
    // there is no event to learn from — and this is exactly the moment the
    // orchestrator sends the first message. Starting at "unknown" is what made
    // the bug permanent rather than transient.
    const { source } = fakeSource();
    expect(createAgentStateTracker(source).current()).toBe("idle");
  });

  test("agent_start begins a turn and agent_settled ends it", () => {
    const { source, fire } = fakeSource();
    const t = createAgentStateTracker(source);

    fire("agent_start");
    expect(t.current()).toBe("streaming");
    fire("agent_settled");
    expect(t.current()).toBe("idle");
  });

  test("agent_end alone does NOT mean idle", () => {
    // agent_end fires when the loop ends; a retry, a compaction or a queued
    // continuation may still follow. Only agent_settled promises none will
    // ("fired after an agent run has fully settled"). Treating agent_end as
    // idle would deliver into a turn that is about to resume.
    const { source, fire } = fakeSource();
    const t = createAgentStateTracker(source);

    fire("agent_start");
    expect(() => fire("agent_end", { messages: [] })).toThrow();
    expect(t.current()).toBe("streaming");
  });

  test("compaction is observed and cleared", () => {
    // Delivering mid-compaction races the history being rewritten.
    const { source, fire } = fakeSource();
    const t = createAgentStateTracker(source);

    fire("session_before_compact");
    expect(t.current()).toBe("compacting");
    fire("session_compact");
    expect(t.current()).toBe("idle");
  });

  test("a failed compaction still clears, so a worker cannot wedge", () => {
    // If a failure left the tracker compacting forever the worker would defer
    // every message for the rest of its life. The history rewrite is over
    // either way; if a continuation follows, agent_start says so.
    const { source, fire } = fakeSource();
    const t = createAgentStateTracker(source);

    fire("session_before_compact");
    fire("session_compact_failed");
    expect(t.current()).toBe("idle");
  });

  test("shutdown is terminal", () => {
    const { source, fire } = fakeSource();
    const t = createAgentStateTracker(source);

    fire("session_shutdown", { reason: "quit" });
    expect(t.current()).toBe("shutting_down");
    // Nothing reopens a shutting-down session: a late agent_settled must not
    // make it look deliverable again.
    fire("agent_settled");
    expect(t.current()).toBe("shutting_down");
  });

  test("it subscribes only to events Pi actually publishes", () => {
    // The whole bug was a plausible-looking API that did not exist. Pin the
    // names: every one below appears on ExtensionAPI.on() in the shipped
    // types for 0.84.4.
    const { source, subscribed } = fakeSource();
    createAgentStateTracker(source);

    expect(subscribed().sort()).toEqual([
      "agent_settled",
      "agent_start",
      "session_before_compact",
      "session_compact",
      "session_compact_failed",
      "session_shutdown",
    ]);
  });

  test("a source that rejects an unknown event does not break startup", () => {
    // An older or newer Pi may not publish one of these. Losing one signal
    // costs precision; throwing during extension load would take the whole
    // worker down.
    const source = {
      on: (event: string) => {
        if (event === "session_compact_failed") throw new Error("no such event");
      },
    };
    expect(() => createAgentStateTracker(source).current()).not.toThrow();
  });
});

// ---------------------------------------------------------------------------
// The typed result tool (dotfiles-87bt).
//
// wk-build/SKILL.md tells every worker "You finish by calling the typed result
// tool, not by ending your turn." No such tool was ever registered, so a
// compliant worker could not comply: it did the work, settled, and the
// initiator saw `results: 0` with state stuck at `running` forever.
//
// The tool is deliberately a thin shell over `pi-worker result`. The
// envelope shape, the stage gate and the adr0017 status rules then have ONE
// implementation in the nu CLI rather than a second, drifting copy in TS.
// These cases assert the command it issues, not the bus's behaviour — that is
// already covered against the real CLI in tests/pi-worker.

describe("the worker is told to report", () => {
  // systemContextFor built exactly the right briefing and NOTHING called it:
  // grep returned only its own definition. It had two passing tests, both
  // asserting what it returns and neither asserting that anything delivers it
  // — so a worker was never told to report, did the work, settled, and was
  // recorded as a protocol_error. A green test over a path production never
  // reaches is worse than no test: it is a claim nobody re-checks.
  //
  // These assert DELIVERY.
  test("the result tool carries the finish contract as a prompt guideline", () => {
    // A tool description is read when the model is already considering that
    // tool: it answers "what does this do", not "must I call something before
    // finishing". promptGuidelines lands in the system prompt unconditionally.
    const guidance = workerPromptGuidelines({
      role: "impl",
      cwd: "/repo",
      branch: "main",
      session: "sid",
      skill: "probe",
      window: "impl-1@dotfiles",
    });
    const text = guidance.join("\n");
    expect(guidance.length).toBeGreaterThan(0);
    expect(text).toContain("protocol error");
    expect(text.toLowerCase()).toContain("result tool");
  });

  test("the guidance carries the worker's own identity, not a generic blurb", () => {
    const text = workerPromptGuidelines({
      role: "rev",
      cwd: "/repo/wk-t.0",
      branch: "wk-t.0",
      session: "sid-r",
      skill: "wk-review",
      window: "rev-a@dotfiles",
    }).join("\n");
    expect(text).toContain("rev");
    expect(text).toContain("wk-review");
    expect(text).toContain("wk-t.0");
  });

  test("it is built from systemContextFor, so the two cannot drift", () => {
    // The briefing existed and was correct; only its delivery was missing.
    // Rewriting the words here would leave two sources for one contract.
    const identity = {
      role: "impl",
      cwd: "/repo",
      branch: "main",
      session: "sid",
      skill: "probe",
      window: "impl-1@dotfiles",
    };
    expect(workerPromptGuidelines(identity).join("\n")).toBe(systemContextFor(identity));
  });
});

describe("typed result tool", () => {
  const identity = {
    role: "impl",
    cwd: "/tmp/wt",
    branch: "bd-t1.0",
    session: "sid-1",
    skill: "wk-build",
    window: "impl-a@dotfiles",
  };

  function fakeExec() {
    const calls: Array<{ command: string; args: string[] }> = [];
    return {
      calls,
      exec: async (command: string, args: string[]) => {
        calls.push({ command, args });
        return { stdout: "{}", stderr: "", code: 0, killed: false };
      },
    };
  }

  test("it reports through the CLI, passing the worker's own address", async () => {
    const { exec, calls } = fakeExec();
    const tool = createResultTool({ run: "r1", uid: "impl-a", identity, exec });

    const out = await tool.report({
      status: "complete",
      summary: "did the thing",
      validation: "TESTS PASS",
    });

    expect(calls).toHaveLength(1);
    expect(calls[0].command).toBe("pi-worker");
    expect(calls[0].args).toEqual([
      "result",
      "impl-a",
      "--run",
      "r1",
      "--status",
      "complete",
      "--summary",
      "did the thing",
      "--validation",
      "TESTS PASS",
    ]);
    expect(out.ok).toBe(true);
  });

  test("an absent verdict is omitted, not sent as an empty string", () => {
    // The gate tests for emptiness. Passing --validation "" would present the
    // shape of a verdict without one, which is exactly what a worker looking
    // compliant without having validated anything would send.
    const { exec, calls } = fakeExec();
    const tool = createResultTool({ run: "r1", uid: "impl-a", identity, exec });

    tool.report({ status: "blocked", summary: "stuck on a missing fixture" });

    expect(calls[0].args).not.toContain("--validation");
    expect(calls[0].args).not.toContain("");
  });

  test("a refusal from the CLI is returned to the agent, not swallowed", async () => {
    // The worker must SEE the gate's reason so it can report correctly on its
    // next attempt. A silent failure here is how a worker ends up believing it
    // reported when it did not.
    const calls: Array<{ command: string; args: string[] }> = [];
    const tool = createResultTool({
      run: "r1",
      uid: "impl-a",
      identity,
      exec: async (command: string, args: string[]) => {
        calls.push({ command, args });
        return {
          stdout: "",
          stderr: "a 'complete' result must carry its validation verdict",
          code: 1,
          killed: false,
        };
      },
    });

    const out = await tool.report({ status: "complete", summary: "trust me" });

    expect(out.ok).toBe(false);
    expect(out.detail).toContain("validation verdict");
  });

  test("the settle reporter is a separate verb on the same path", async () => {
    const { exec, calls } = fakeExec();
    const tool = createResultTool({ run: "r1", uid: "impl-a", identity, exec });

    await tool.reportSettled();

    expect(calls[0].args).toEqual(["settled", "impl-a", "--run", "r1"]);
  });

  test("a missing CLI is reported rather than thrown at the host", async () => {
    // An extension that throws inside a tool call or an event handler damages
    // the session it is trying to serve.
    const tool = createResultTool({
      run: "r1",
      uid: "impl-a",
      identity,
      exec: async () => {
        throw new Error("spawn pi-worker ENOENT");
      },
    });

    const out = await tool.report({ status: "failed", summary: "gave up" });
    expect(out.ok).toBe(false);
    expect(out.detail).toContain("ENOENT");
  });
});

// ---------------------------------------------------------------------------
// The initiator tool.
//
// A Pi session that ORCHESTRATES workers had no tools at all: the extension
// only woke up in worker mode, so driving the bus meant shelling out by hand.
// This is the other half — one dispatch tool mirroring the CLI verbs.
//
// One tool rather than eleven on purpose. Every session pays for the tool list
// in its prompt, and eleven near-identical entries crowd out the tools the
// agent is actually there to use. The verb is an enum, so the model still gets
// a closed set rather than free text.
//
// Like the result tool, it is a thin shell over `pi-worker`. The bus has one
// implementation; this contributes a typed surface and nothing else, which is
// why these cases assert the command issued rather than the bus's behaviour.

describe("initiator tool", () => {
  function fakeExec(result?: { stdout?: string; stderr?: string; code?: number }) {
    const calls: Array<{ command: string; args: string[] }> = [];
    return {
      calls,
      exec: async (command: string, args: string[]) => {
        calls.push({ command, args });
        return {
          stdout: result?.stdout ?? "{}",
          stderr: result?.stderr ?? "",
          code: result?.code ?? 0,
          killed: false,
        };
      },
    };
  }

  test("spawn passes every flag the CLI needs, and omits the ones not given", async () => {
    const { exec, calls } = fakeExec();
    const tool = createInitiatorTool({ exec });

    await tool.invoke({
      verb: "spawn",
      run: "t1",
      uid: "w1",
      role: "rev",
      subject: "demo",
      project: "dotfiles",
      repo: "/repo",
      session: "sid-1",
      skill: "probe",
    });

    expect(calls[0].command).toBe("pi-worker");
    expect(calls[0].args).toEqual([
      "spawn", "--run", "t1", "--uid", "w1", "--role", "rev",
      "--subject", "demo", "--project", "dotfiles", "--repo", "/repo",
      "--session", "sid-1", "--skill", "probe",
    ]);
    // `--task` was not supplied, so it must not appear as an empty flag: the
    // CLI distinguishes absent from empty, and an empty one reads as a stage
    // that has a ticket id when it does not.
    expect(calls[0].args).not.toContain("--task");
  });

  test("a positional verb puts the uid where the CLI expects it", async () => {
    // `send`, `status`, `resume` and friends take the uid positionally, not as
    // a flag. Getting that wrong fails at the CLI, but only at runtime.
    const { exec, calls } = fakeExec();
    const tool = createInitiatorTool({ exec });

    await tool.invoke({ verb: "send", run: "t1", uid: "w1", stage: "probe", instructions: "go" });

    expect(calls[0].args).toEqual([
      "send", "w1", "--run", "t1", "--stage", "probe", "--instructions", "go",
    ]);
  });

  test("wait takes only a run and returns what the bus said", async () => {
    const { exec, calls } = fakeExec({
      stdout: '{"kind":"result","sequence":1,"run":"t1","uid":"w1","payload":{"status":"complete","summary":"done"}}',
    });
    const tool = createInitiatorTool({ exec });

    const out = await tool.invoke({ verb: "wait", run: "t1" });

    expect(calls[0].args).toEqual(["wait", "--run", "t1"]);
    expect(out.ok).toBe(true);
    // Summarised, not passed through — see the summarisation cases below.
    expect(out.detail).toContain("complete");
  });

  test("wait scopes to a worker when one is named", async () => {
    // A run that still holds a finished worker with an unacked envelope would
    // otherwise hand its answer to whoever asked next — which is exactly what
    // happened live: a spawn of r2/x1 was answered with r2/w1's stale result.
    const { exec, calls } = fakeExec();
    await createInitiatorTool({ exec }).invoke({ verb: "wait", run: "r2", uid: "x1" });
    expect(calls[0].args).toEqual(["wait", "--run", "r2", "--uid", "x1"]);
  });

  test("wait without a uid still drains the whole run", async () => {
    // The orchestrator's use: whatever finished first, whoever it was.
    const { exec, calls } = fakeExec();
    await createInitiatorTool({ exec }).invoke({ verb: "wait", run: "r2" });
    expect(calls[0].args).toEqual(["wait", "--run", "r2"]);
  });

  test("a switch is passed as a bare flag, not as `--block true`", async () => {
    // nu's `--block` takes no value. Rendering the boolean with String() would
    // emit `--block true` and nu would read `true` as an extra positional.
    const calls: string[][] = [];
    const tool = createInitiatorTool({
      exec: async (_cmd, argv) => {
        calls.push(argv);
        return { code: 0, stdout: "", stderr: "" };
      },
    });
    await tool.invoke({ verb: "wait", run: "r1", uid: "w1", block: true, timeout: 30 });
    expect(calls[0]).toEqual(["wait", "--run", "r1", "--uid", "w1", "--block", "--timeout", "30"]);
  });

  test("a switch left false is omitted entirely", async () => {
    // `--block false` is not how nu spells "do not block"; absence is.
    const calls: string[][] = [];
    const tool = createInitiatorTool({
      exec: async (_cmd, argv) => {
        calls.push(argv);
        return { code: 0, stdout: "", stderr: "" };
      },
    });
    await tool.invoke({ verb: "wait", run: "r1", block: false });
    expect(calls[0]).toEqual(["wait", "--run", "r1"]);
  });

  test("spawn omits the ids it is not given, so the CLI can mint them", async () => {
    // The tool used to ask the model for a fresh uuid, which is why a bare
    // `uuidgen` kept appearing in the operator's transcript.
    const calls: string[][] = [];
    const tool = createInitiatorTool({
      exec: async (_cmd, argv) => {
        calls.push(argv);
        return { code: 0, stdout: "{}", stderr: "" };
      },
    });
    await tool.invoke({
      verb: "spawn",
      role: "impl",
      subject: "timestamp",
      project: "dotfiles",
      repo: "/home/jan/.dotfiles",
      skill: "probe",
    });
    const argv = calls[0].join(" ");
    expect(argv).not.toContain("--uid");
    expect(argv).not.toContain("--run");
    expect(argv).not.toContain("--session");
    expect(argv).toContain("--role impl");
  });

  test("rm releases one address", async () => {
    const { exec, calls } = fakeExec();
    await createInitiatorTool({ exec }).invoke({ verb: "rm", run: "r2", uid: "x1" });
    expect(calls[0].args).toEqual(["rm", "--run", "r2", "--uid", "x1"]);
  });

  test("an empty wait is success with nothing, not a failure", async () => {
    // `wait` prints nothing when there is no mail. Reporting that as an error
    // would make an idle run look broken.
    const { exec } = fakeExec({ stdout: "" });
    const tool = createInitiatorTool({ exec });

    const out = await tool.invoke({ verb: "wait", run: "t1" });
    expect(out.ok).toBe(true);
    expect(out.detail).toContain("no unacknowledged");
  });

  test("results come back as one line, not a JSON dump", async () => {
    // The tool result is rendered in the transcript, so whatever it returns is
    // what the operator reads. Handing back the CLI's full envelope buried the
    // one fact they wanted — is it alive, what did it say — in fifteen lines of
    // addressing they already know.
    const spawn = fakeExec({
      stdout: JSON.stringify({
        run: "x1", uid: "w1", window: "rev-demo@dotfiles", window_id: "@185",
        cwd: "/repo", branch: "main", session: "sid-1", skill: "probe",
        resume: "pi --session sid-1", live: true, liveness: "live",
      }),
    });
    const out = await createInitiatorTool({ exec: spawn.exec }).invoke({
      verb: "spawn", run: "x1", uid: "w1",
    });

    expect(out.detail.split("\n")).toHaveLength(1);
    expect(out.detail).toContain("x1/w1");
    expect(out.detail).toContain("rev-demo@dotfiles");
    expect(out.detail).toContain("@185");
  });

  test("a result envelope is summarised down to its verdict", async () => {
    const { exec } = fakeExec({
      stdout: JSON.stringify({
        protocol: 1, sequence: 3, run: "x1", uid: "w1", kind: "result",
        created: "2026-09-06T18:58:00Z",
        payload: { status: "blocked", summary: "could not reach the fixture", window: "w", session: "s", resume: "r" },
      }),
    });
    const out = await createInitiatorTool({ exec }).invoke({ verb: "wait", run: "x1" });

    expect(out.detail.split("\n")).toHaveLength(1);
    expect(out.detail).toContain("blocked");
    expect(out.detail).toContain("could not reach the fixture");
    expect(out.detail).toContain("seq 3");
  });

  test("a protocol error is summarised as one, not as a result", async () => {
    // Different kind, different meaning: the worker said nothing at all.
    const { exec } = fakeExec({
      stdout: JSON.stringify({
        protocol: 1, sequence: 1, run: "x1", uid: "w1", kind: "error",
        created: "t", payload: { code: "protocol_error", detail: "settled without reporting" },
      }),
    });
    const out = await createInitiatorTool({ exec }).invoke({ verb: "wait", run: "x1" });
    expect(out.detail).toContain("protocol_error");
  });

  test("inspect and status keep their full output", async () => {
    // These are the verbs you reach for WHEN you want the detail; summarising
    // them would leave no way to get it.
    const full = JSON.stringify({ run: "x1", uid: "w1", state: "blocked", identity: { a: 1 } }, null, 2);
    const { exec } = fakeExec({ stdout: full });
    const out = await createInitiatorTool({ exec }).invoke({ verb: "inspect", run: "x1", uid: "w1" });
    expect(out.detail).toBe(full);
  });

  test("a verb outside the closed set never reaches the shell", async () => {
    const { exec, calls } = fakeExec();
    const tool = createInitiatorTool({ exec });

    const out = await tool.invoke({ verb: "rm -rf /" as never, run: "t1" });
    expect(out.ok).toBe(false);
    expect(calls).toHaveLength(0);
  });

  test("a nushell error is reduced to its message, not its stack frame", async () => {
    // The CLI is a nu script, so `error make` renders the message together with
    // a source frame: the file, the line, the surrounding code and a caret run
    // wide enough to wrap several times. All of it lands in the transcript, and
    // none of it tells the operator anything they can act on — the message
    // already named the address and what to do about it.
    const { exec } = fakeExec({
      code: 1,
      stderr: [
        "Error: nu::shell::error",
        "",
        "  x x1/w1 already exists: that address has been used, and spawning onto it",
        "  | would inherit its mail and markers. Use a different uid, or remove",
        "  | /run/user/1000/pi-worker/x1/w1 if you are sure it is finished with",
        "      ,-[/home/jan/.local/bin/pi-worker:1141:20]",
        " 1140 |     if ($existing | path exists) {",
        " 1141 |         error make {msg: $\"($run)/($uid) already exists...\"}",
        "      :                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^",
        " 1142 |     }",
        "      `----",
      ].join("\n"),
    });

    const out = await createInitiatorTool({ exec }).invoke({ verb: "spawn", run: "x1", uid: "w1" });

    expect(out.ok).toBe(false);
    expect(out.detail).toBe(
      "x1/w1 already exists: that address has been used, and spawning onto it would inherit its mail and markers. Use a different uid, or remove /run/user/1000/pi-worker/x1/w1 if you are sure it is finished with",
    );
    expect(out.detail).not.toContain("pi-worker:1141");
    expect(out.detail).not.toContain("^^^");
  });

  test("an error that is not nushell-shaped is passed through untouched", async () => {
    // Only nu's framing is stripped. A plain message from anywhere else must
    // survive, or a real failure could be reduced to nothing.
    const { exec } = fakeExec({ code: 1, stderr: "tmux: no server running on /tmp/tmux-1000/default" });
    const out = await createInitiatorTool({ exec }).invoke({ verb: "wait", run: "x1" });
    expect(out.detail).toBe("tmux: no server running on /tmp/tmux-1000/default");
  });

  test("a refusal from the bus is returned verbatim, not swallowed", async () => {
    // The CLI's errors name what is wrong — an unknown stage lists the ones
    // that exist. Losing that leaves the agent guessing.
    const { exec } = fakeExec({ code: 1, stderr: "unknown stage 'nope': not one of probe, build" });
    const tool = createInitiatorTool({ exec });

    const out = await tool.invoke({ verb: "spawn", run: "t1", uid: "w1", skill: "nope" });
    expect(out.ok).toBe(false);
    expect(out.detail).toContain("not one of probe, build");
  });

  test("a missing CLI is reported rather than thrown at the host", async () => {
    const tool = createInitiatorTool({
      exec: async () => {
        throw new Error("spawn pi-worker ENOENT");
      },
    });
    const out = await tool.invoke({ verb: "wait", run: "t1" });
    expect(out.ok).toBe(false);
    expect(out.detail).toContain("ENOENT");
  });
});

// ---------------------------------------------------------------------------
// The live frame.
//
// One keyed widget refreshed in place, instead of a tool-result block appended
// per call. Pi's setWidget takes a key, so writing the same key repeatedly
// updates the same lines rather than accumulating them.

describe("roster frame", () => {
  const rows = [
    { run: "x2", uid: "w1", role: "rev", state: "running", liveness: "live", window: "rev-demo@dotfiles" },
    { run: "x2", uid: "w2", role: "impl", state: "blocked", liveness: "exited", window: "impl-t4@dotfiles" },
  ];

  test("one line per worker, aligned so the columns can be read down", () => {
    const frame = rosterFrame(rows);
    expect(frame).toHaveLength(3); // a heading plus the two workers
    const [heading, first, second] = frame;
    expect(heading).toContain("2 workers");
    // The run/uid column is padded to a common width, so uid `w1` and `w2`
    // line up rather than drifting with the length of the run id.
    expect(first.indexOf("running")).toBe(second.indexOf("blocked"));
    expect(first).toContain("rev-demo@dotfiles");
  });

  test("a worker whose state and liveness disagree is what the frame is for", () => {
    // `blocked` with `exited` means it reported and its process is gone;
    // `running` with `exited` would mean it died without reporting. Showing
    // both side by side is the whole point of the frame.
    const frame = rosterFrame(rows);
    expect(frame[2]).toContain("blocked");
    expect(frame[2]).toContain("exited");
  });

  test("finished workers leave the frame, unfinished ones stay", () => {
    // The frame answers "what is running", so a stopped or accepted worker has
    // no business holding a row — and a run whose workers are all done should
    // give the terminal space back entirely. A `blocked` worker is NOT done:
    // it is waiting for someone, which is exactly what a status panel is for.
    const mixed = [
      { run: "a", uid: "1", role: "rev", state: "running", liveness: "live", window: "w1" },
      { run: "a", uid: "2", role: "rev", state: "blocked", liveness: "live", window: "w2" },
      { run: "old", uid: "1", role: "rev", state: "stopped", liveness: "unknown", window: "w3" },
      { run: "old", uid: "2", role: "rev", state: "accepted", liveness: "unknown", window: "w4" },
    ];
    const frame = rosterFrame(mixed);
    expect(frame).toHaveLength(3);
    expect(frame[0]).toContain("2 workers");
    expect(frame.join("\n")).not.toContain("w3");
    expect(frame.join("\n")).not.toContain("w4");
    expect(frame.join("\n")).toContain("blocked");
  });

  test("a roster of only finished workers shows no frame", () => {
    expect(
      rosterFrame([
        { run: "old", uid: "1", role: "rev", state: "stopped", liveness: "unknown", window: "w3" },
      ]),
    ).toBeUndefined();
  });

  test("no workers means no frame at all, not an empty box", () => {
    // A widget occupies terminal rows permanently. An idle session should get
    // them back rather than stare at a header with nothing under it.
    expect(rosterFrame([])).toBeUndefined();
  });

  test("one worker is singular", () => {
    expect(rosterFrame([rows[0]])[0]).toContain("1 worker");
    expect(rosterFrame([rows[0]])[0]).not.toContain("1 workers");
  });

  // ---------------------------------------------------------------- elapsed
  //
  // `running` is the same word after eight seconds and after forty minutes,
  // and only one of those is a worker worth interrupting.

  test("elapsed is rendered from the worker's start stamp", () => {
    const started = "2026-09-07T12:00:00.000000Z";
    const now = Date.parse(started) + 4 * 60_000 + 30_000;
    const frame = rosterFrame([{ ...rows[0], started }], { now });
    expect(frame[1]).toContain("4m");
  });

  test("a worker with no start stamp gets a blank cell, not a zero", () => {
    // "" is what the CLI reports for a worker whose identity envelope was
    // never written. `0s` would read as one that had only just started.
    //
    // The age has to clear AGE_WORTH_SHOWING_MS to appear at all now, so this
    // uses an age that does.
    const started = "2026-09-07T12:00:00.000000Z";
    const now = Date.parse(started) + AGE_WORTH_SHOWING_MS + 12_000;
    const frame = rosterFrame(
      [
        { ...rows[0], started },
        { ...rows[1], started: "" },
      ],
      { now },
    );
    expect(frame[1]).toContain("1m");
    expect(frame[2]).not.toContain("0s");
    // The blank is padded, so the column after it still lines up. Compared on
    // the window cell, which both rows have — the liveness column here holds
    // `live` on one row and `exited` on the other, and `live` is dropped.
    // Compared on where each window cell STARTS. `indexOf("@dotfiles")` would
    // drift with the length of the window name, not the column.
    expect(frame[1].indexOf("rev-demo@dotfiles")).toBe(frame[2].indexOf("impl-t4@dotfiles"));
  });

  test("a young age and a live worker carry no column at all", () => {
    // The row the operator actually asked for:
    //     r1/impl-1  warming-up  impl-tsfile0707@dotfiles
    // `8s` and `live` beside a working state are one fact and two
    // restatements of it.
    const started = "2026-09-07T12:00:00.000000Z";
    const frame = rosterFrame(
      [{ run: "r1", uid: "impl-1", role: "impl", state: "created", liveness: "live", window: "impl-tsfile0707@dotfiles", started }],
      { now: Date.parse(started) + 8_000 },
    );
    expect(frame[1].split(/\s+/).filter(Boolean)).toEqual([
      "r1/impl-1",
      "warming-up",
      "impl-tsfile0707@dotfiles",
    ]);
  });

  test("a liveness that complicates the state keeps its column", () => {
    // `gone` beside a working state is a worker that died without reporting —
    // the row that needs a human, and the reason the column exists.
    const frame = rosterFrame(
      [{ run: "r1", uid: "impl-1", role: "impl", state: "running", liveness: "gone", window: "impl-1@dotfiles" }],
      { now: Date.now() },
    );
    expect(frame[1]).toContain("gone");
  });

  test("a garbage stamp is a blank cell rather than NaN on screen", () => {
    const frame = rosterFrame([{ ...rows[0], started: "whenever" }], {
      now: Date.parse("2026-09-07T12:00:00Z"),
    });
    expect(frame[1]).not.toContain("NaN");
  });

  test("formatElapsed reads at a glance at every scale", () => {
    const t0 = Date.parse("2026-09-07T12:00:00Z");
    const at = (ms: number) => formatElapsed("2026-09-07T12:00:00Z", t0 + ms);
    expect(at(8_000)).toBe("8s");
    expect(at(59_000)).toBe("59s");
    expect(at(4 * 60_000)).toBe("4m");
    expect(at(72 * 60_000)).toBe("1h12m");
    // A clock that went backwards is not a negative age.
    expect(at(-5_000)).toBe("0s");
    expect(formatElapsed("", t0)).toBe("");
  });

  // ------------------------------------------------------------------ colour
  //
  // A failed worker should be visibly failed rather than a word in a column.
  // Colour is applied to the STATE cell only, and after the layout is
  // computed: wrapToWidth counts ANSI bytes as width, so painting first would
  // mis-wrap every row.

  test("the state cell is painted and nothing else is", () => {
    const paint = (tone: string, text: string) => `<${tone}>${text}</${tone}>`;
    const frame = rosterFrame(rows, { paint });
    expect(frame[1]).toContain("<accent>running</accent>");
    expect(frame[2]).toContain("<warning>blocked</warning>");
    // The window cell carries no markup. (Liveness is `live` on both rows
    // here, so it has no column to check — see the column-rule tests above.)
    expect(frame[1]).toContain("rev-demo@dotfiles");
    expect(frame[1]).not.toContain("<accent>rev-demo");
  });

  test("colour does not move the columns", () => {
    const paint = (tone: string, text: string) => `\u001b[31m${text}\u001b[39m`;
    const plain = rosterFrame(rows);
    const painted = rosterFrame(rows, { paint });
    const stripped = painted.map((line) =>
      line.replaceAll("\u001b[31m", "").replaceAll("\u001b[39m", ""),
    );
    expect(stripped).toEqual(plain);
  });

  test("a state tone is chosen by what the operator must do about it", () => {
    expect(stateTone("running")).toBe("accent");
    expect(stateTone("complete")).toBe("success");
    expect(stateTone("failed")).toBe("error");
    expect(stateTone("protocol_error")).toBe("error");
    expect(stateTone("blocked")).toBe("warning");
    expect(stateTone("waiting_human")).toBe("warning");
    expect(stateTone("created")).toBe("muted");
    // An unrecognised state is still shown — just uncoloured. Inventing a
    // tone for it would assert something the bus never said.
    expect(stateTone("something-new")).toBe("plain");
  });

  test("fg is called as a method, because Pi's reads `this`", () => {
    // Observed live: pulling `fg` off the theme and calling it detached exits
    // the whole Pi session with
    //     TypeError: Cannot read properties of undefined (reading 'fgColors')
    // An arrow-function stub cannot catch this — it has no `this` to lose — so
    // the stub here is shaped like Pi's own theme.
    class HostTheme {
      private fgColors: Record<string, string> = { error: "31" };
      fg(tone: string, text: string): string {
        return `<${this.fgColors[tone] ?? "0"}>${text}`;
      }
    }
    const theme = new HostTheme();
    expect(themePaint(theme)("error", "failed")).toBe("<31>failed");
  });

  test("a theme that throws costs the frame its colour, never the session", () => {
    // themePaint is called from inside a component's render(), which Pi drives
    // from a timer: a throw there is an uncaughtException that exits Pi.
    let calls = 0;
    const paint = themePaint({
      fg: () => {
        calls += 1;
        throw new TypeError("Cannot read properties of undefined (reading 'fgColors')");
      },
    });
    expect(paint("error", "failed")).toBe("failed");
    // And it stops trying, rather than throwing sixty times a second.
    expect(paint("error", "failed again")).toBe("failed again");
    expect(calls).toBe(1);
  });

  test("a theme that returns a non-string does not blank the cell", () => {
    const paint = themePaint({ fg: (() => undefined) as never });
    expect(paint("warning", "blocked")).toBe("blocked");
  });

  test("a theme without fg degrades to no colour rather than throwing", () => {
    expect(themePaint(undefined)("error", "failed")).toBe("failed");
    expect(themePaint({})("error", "failed")).toBe("failed");
    expect(
      themePaint({ fg: (tone: string, text: string) => `[${tone}]${text}` })("error", "failed"),
    ).toBe("[error]failed");
    // `plain` never reaches the theme: there is no such colour role.
    expect(themePaint({ fg: (t: string, s: string) => `[${t}]${s}` })("plain", "x")).toBe("x");
  });
});

// ---------------------------------------------------------------------------
// Mounting the frame.
//
// Pi's setWidget takes either an array of lines or a component FACTORY. The
// factory form is what carries a theme and a `requestRender`, so it is what
// the frame wants; the array form is the fallback for a host that will not
// take a function.

describe("roster widget", () => {
  const psRows = [
    {
      run: "x2",
      uid: "w1",
      role: "rev",
      state: "running",
      liveness: "live",
      window: "rev-demo@dotfiles",
      started: "2026-09-07T12:00:00.000000Z",
    },
  ];
  const psExec = (rows: unknown[]) => async () => ({
    code: 0,
    stdout: JSON.stringify(rows),
    stderr: "",
  });

  test("it mounts a component factory, which is what carries the theme", async () => {
    const set: { key: string; content: unknown }[] = [];
    const frame = startRosterFrame({
      exec: psExec(psRows) as never,
      setWidget: (key, content) => set.push({ key, content }),
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    frame.stop();

    const last = set.at(-1);
    expect(last?.key).toBe("pi-workers");
    expect(typeof last?.content).toBe("function");

    // The factory is handed a tui and a theme, and returns a real component:
    // render honours its width, and invalidate exists — a component without it
    // breaks /reload.
    const factory = last!.content as (tui: unknown, theme: unknown) => {
      render: (width: number) => string[];
      invalidate: () => void;
      dispose?: () => void;
    };
    const component = factory({ requestRender: () => {} }, {
      fg: (tone: string, text: string) => `[${tone}]${text}`,
    });
    expect(typeof component.invalidate).toBe("function");
    const lines = component.render(200);
    expect(lines.join("\n")).toContain("[accent]running");
    expect(Math.max(...lines.map((l) => l.length))).toBeLessThanOrEqual(200);
  });

  test("a refresh repaints through the tui instead of re-mounting", async () => {
    const set: unknown[] = [];
    let renders = 0;
    const frame = startRosterFrame({
      exec: psExec(psRows) as never,
      setWidget: (_key, content) => {
        set.push(content);
        if (typeof content === "function") {
          (content as (tui: unknown, theme: unknown) => unknown)(
            { requestRender: () => { renders += 1; } },
            {},
          );
        }
      },
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    await frame.refresh();
    frame.stop();

    // Mounted once; the second refresh asked the tui to repaint.
    expect(set.filter((c) => typeof c === "function")).toHaveLength(1);
    expect(renders).toBeGreaterThan(0);
  });

  test("invalidate does NOT re-register, or the bar blinks all turn", async () => {
    // This asserted the opposite until the bar was seen blinking through every
    // turn. It was written to fix a theme switch leaving the frame on the old
    // palette, and it read half of Pi's contract: invalidate is "called when
    // theme changes OR when component needs to re-render from scratch", and
    // that second clause fires constantly while output streams. A rare
    // cosmetic problem had been traded for a permanent one.
    const factories: unknown[] = [];
    const frame = startRosterFrame({
      exec: psExec(psRows) as never,
      setWidget: (_key, content) => {
        if (typeof content === "function") factories.push(content);
      },
      intervalMs: 1_000_000,
      allRuns: true,
    });
    await frame.refresh();
    expect(factories).toHaveLength(1);

    const component = (factories[0] as (t: unknown, th: unknown) => {
      render: (w: number) => string[];
      invalidate: () => void;
    })({ requestRender: () => {} }, {});

    component.invalidate();
    await frame.refresh();
    frame.stop();

    // Still one registration: the component was never dropped, so there was
    // nothing to hand over again.
    expect(factories).toHaveLength(1);
    // And it still draws — nothing is cached for invalidate to clear.
    expect(component.render(200).join("\n")).toContain("running");
  });

  test("a host that refuses a factory still gets a frame, in the array form", async () => {
    // An older Pi whose setWidget only accepts lines. A colourless frame is
    // strictly better than no frame, and strictly better than an exception
    // thrown into host startup.
    const set: unknown[] = [];
    const frame = startRosterFrame({
      exec: psExec(psRows) as never,
      setWidget: (_key, content) => {
        if (typeof content === "function") throw new TypeError("content must be an array");
        set.push(content);
      },
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    frame.stop();

    const last = set.at(-1) as string[];
    expect(Array.isArray(last)).toBe(true);
    expect(last.join("\n")).toContain("running");
    // No theme reached it, so no escape codes were invented.
    expect(last.join("\n")).not.toContain("\u001b[");
  });

  test("a render that would throw yields no lines, not an exception", async () => {
    // Pi calls render from a timer, so a throw is an uncaughtException that
    // exits the session — verified the hard way. Nothing a status panel does
    // is worth that.
    const set: unknown[] = [];
    const frame = startRosterFrame({
      exec: psExec(psRows) as never,
      setWidget: (_key, content) => set.push(content),
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    frame.stop();

    const factory = set.at(-1) as (tui: unknown, theme: unknown) => {
      render: (width: number) => string[];
    };
    // A width that makes wrapToWidth's arithmetic meaningless is the cheapest
    // way to reach the guard without stubbing internals.
    const component = factory({ requestRender: () => {} }, {
      get fg() {
        throw new TypeError("theme exploded during property access");
      },
    });
    expect(() => component.render(200)).not.toThrow();
  });

  test("an empty roster gives the terminal rows back", async () => {
    const set: unknown[] = [];
    const frame = startRosterFrame({
      exec: psExec([]) as never,
      setWidget: (_key, content) => set.push(content),
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    frame.stop();
    expect(set.at(-1)).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// What reaches the transcript.
//
// The frame above the editor now carries live state, so echoing it again per
// call is duplication that scrolls. What the frame CANNOT show is what a worker
// actually said, and anything that failed — those still belong in the
// transcript, because they are history rather than status.
//
// This only affects DISPLAY. The tool's content still goes to the model in
// full; hiding a line from the operator must never hide it from the agent.

describe("transcript lines", () => {
  test("a long line is wrapped to the viewport, never emitted over it", () => {
    // pi-tui throws an UNCAUGHT exception when a custom component returns a
    // line wider than the terminal, taking the whole editor down with it:
    //
    //   Error: Rendered line 67 exceeds terminal width (205 > 118).
    //
    // The occupied-address refusal is ~205 characters, and `messageOnly` joins
    // nu's already-wrapped message back into one line, so the first time a
    // spawn was refused in a narrow terminal it killed the session.
    const long =
      "x1/w1 already exists: that address has been used, and spawning onto it would inherit its mail and markers. " +
      "Use a different uid, or remove /run/user/1000/pi-worker/x1/w1 if you are sure it is finished with";
    const lines = wrapToWidth([long], 60);

    expect(lines.length).toBeGreaterThan(1);
    for (const l of lines) expect(l.length).toBeLessThanOrEqual(60);
    // Wrapped, not truncated: an error you cannot read is no better than one
    // you cannot see.
    expect(lines.join(" ")).toContain("if you are sure it is finished with");
  });

  test("wrapping breaks on spaces, and falls back to a hard cut for one long token", () => {
    expect(wrapToWidth(["alpha beta gamma"], 11)).toEqual(["alpha beta", "gamma"]);
    // A path with no spaces cannot be broken politely; it must still not exceed.
    const cut = wrapToWidth(["/a/very/long/path/with/no/spaces/at/all"], 10);
    for (const l of cut) expect(l.length).toBeLessThanOrEqual(10);
    expect(cut.join("")).toBe("/a/very/long/path/with/no/spaces/at/all");
  });

  test("a width of zero or less is ignored rather than looping forever", () => {
    // Defensive: a zero width would otherwise make the wrap loop never advance.
    expect(wrapToWidth(["abc"], 0)).toEqual(["abc"]);
  });

  test("the result component wraps at the width it is given", () => {
    const c = resultComponent("wait", false, "x".repeat(300));
    for (const l of c.render(80)) expect(l.length).toBeLessThanOrEqual(80);
  });

  test("the call itself renders nothing — the result line speaks for it", () => {
    // renderShell: "self" removed the box around the RESULT, but the tool's
    // name label is drawn by the call, so a suppressed result still left a bare
    // `pi_worker` with nothing under it — six of them in one run.
    const c = callComponent();
    expect(c.render(80)).toEqual([]);
    expect(typeof c.invalidate).toBe("function");
  });

  test("the rendered component satisfies pi-tui's Component contract", () => {
    // `invalidate()` is REQUIRED, not optional. Returning only `render` was
    // enough for a fresh draw and broke `/reload`: re-rendering history calls
    // invalidate on every component, and a session with pi_worker results in
    // its transcript died with "this.child.invalidate is not a function".
    const c = resultComponent("wait", true, "seq 1 from x/y: blocked — nope");
    expect(typeof c.render).toBe("function");
    expect(typeof c.invalidate).toBe("function");
    expect(() => c.invalidate()).not.toThrow();
    expect(c.render(80)).toEqual(["seq 1 from x/y: blocked — nope"]);
  });

  test("a suppressed result still renders as a real component, not nothing", () => {
    // The component is built even when it has no lines; returning undefined
    // would put the same hole in the render tree that the missing invalidate did.
    const c = resultComponent("spawn", true, "spawned x/y");
    expect(c.render(80)).toEqual([]);
    expect(typeof c.invalidate).toBe("function");
  });

  test("verbs whose state the frame already shows print nothing", () => {
    for (const verb of ["spawn", "liveness", "ps", "stop", "accept", "send", "resume", "workers"]) {
      expect(transcriptLines(verb, true, "anything")).toEqual([]);
    }
  });

  test("what a worker said always prints — the frame cannot show it", () => {
    const lines = transcriptLines("wait", true, "seq 1 from x3/w1: blocked — could not reach the fixture");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("could not reach the fixture");
  });

  test("an empty mailbox prints nothing rather than a line saying so", () => {
    // "no unacknowledged results" was the noisiest line of a polling loop and
    // told the operator nothing the frame does not.
    expect(transcriptLines("wait", true, "no unacknowledged results in this run")).toEqual([]);
  });

  test("a failure always prints, whatever the verb", () => {
    // Suppressing a spawn's success must never suppress its refusal: an
    // operator who cannot see the failure has no idea why nothing happened.
    const lines = transcriptLines("spawn", false, "x1/w1 already exists");
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("already exists");
  });

  test("the detail verbs keep every line they produced — once expanded", () => {
    // This used to assert the body printed unconditionally. It does not any
    // more: the agent chooses the verb and the operator pays the screen, so
    // the detail is reachable rather than unbidden. What must not change is
    // that expanding loses nothing.
    const detail = "{\n  \"run\": \"x1\"\n}";
    expect(transcriptLines("inspect", true, detail, { expanded: true })).toEqual(detail.split("\n"));
    expect(transcriptLines("status", true, detail, { expanded: true })).toEqual(detail.split("\n"));
    // And collapsed, each is a single line that still names the worker.
    expect(transcriptLines("inspect", true, detail, { expanded: false })).toHaveLength(1);
    expect(transcriptLines("inspect", true, detail, { expanded: false })[0]).toContain("x1");
  });
});

describe("inbox watcher against a fake Pi", () => {
  function fakeIO(files: Record<string, unknown>) {
    const logs: string[] = [];
    return {
      logs,
      io: {
        list: () => Object.keys(files),
        read: (path: string) => {
          const name = path.split("/").pop()!;
          const value = files[name];
          return typeof value === "string" ? value : JSON.stringify(value);
        },
        join: (...parts: string[]) => parts.join("/"),
        log: (line: string) => logs.push(line),
      },
    };
  }

  function fakeHost(state: AgentStateName = "idle") {
    // Records `deliverAs`, the option key on Pi's real signature:
    //   sendUserMessage(content, { deliverAs?: "steer" | "followUp", ... })
    // An earlier build passed `{ mode }`. Pi ignores an unrecognised key, so
    // the call succeeded and silently used default delivery — a steer meant to
    // land mid-turn would instead queue as an ordinary follow-up. A fake that
    // mirrored the wrong key made that invisible, which is why this records
    // BOTH and asserts the wrong one is never sent.
    const sent: Array<{ text: string; deliverAs?: string; mode?: string }> = [];
    return {
      sent,
      host: {
        agentState: () => state,
        sendUserMessage: (
          text: string,
          options?: { deliverAs?: string; mode?: string },
        ) => {
          sent.push({ text, deliverAs: options?.deliverAs, mode: options?.mode });
        },
      },
    };
  }

  type AgentStateName = string;
  const envelope = (sequence: number, payload: unknown) => ({
    protocol: 1,
    sequence,
    run: "run-1",
    uid: "impl-a",
    kind: "inbox",
    created: "2026-09-05T10:00:00Z",
    payload,
  });

  test("delivers a work message as the bare ticket id", () => {
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "wk-build", task: "dotfiles-963w.4" }) });
    const { host, sent } = fakeHost("idle");
    const w = createInboxWatcher(host, identity, "/inbox", io);

    expect(w.poll()).toEqual([1]);
    expect(sent).toEqual([
      { text: "dotfiles-963w.4", deliverAs: "followUp", mode: undefined },
    ]);
  });

  test("delivers an AKM message as instructions plus artifacts", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "doc-retro", instructions: "Run the retro.", artifacts: ["sp028"] }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();

    expect(sent[0].text).toContain("Run the retro.");
    expect(sent[0].text).toContain("sp028");
  });

  test("steers rather than follows up while the agent is streaming", () => {
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "wk-build", task: "t" }) });
    const { host, sent } = fakeHost("streaming");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent[0].deliverAs).toBe("steer");
    expect(sent[0].mode).toBeUndefined();
  });

  test("delivers nothing while compacting, and delivers it later", () => {
    const files = { "1.json": envelope(1, { stage: "wk-build", task: "t" }) };
    const { io } = fakeIO(files);
    const busy = createInboxWatcher({ agentState: () => "compacting", sendUserMessage: () => {} }, identity, "/inbox", io);
    expect(busy.poll()).toEqual([]);

    const { host, sent } = fakeHost("idle");
    expect(createInboxWatcher(host, identity, "/inbox", io).poll()).toEqual([1]);
    expect(sent).toHaveLength(1);
  });

  test("does not reorder: a deferral stops the batch rather than skipping ahead", () => {
    // Delivering 2 while 1 is undeliverable would reorder the conversation.
    let calls = 0;
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "wk-build", task: "one" }),
      "2.json": envelope(2, { stage: "wk-build", task: "two" }),
    });
    const host = {
      agentState: () => (calls++ === 0 ? "compacting" : "idle"),
      sendUserMessage: () => {},
    };
    expect(createInboxWatcher(host, identity, "/inbox", io).poll()).toEqual([]);
  });

  test("never redelivers what it already sent", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "wk-build", task: "one" }),
      "2.json": envelope(2, { stage: "wk-build", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    const w = createInboxWatcher(host, identity, "/inbox", io);
    expect(w.poll()).toEqual([1, 2]);
    expect(w.poll()).toEqual([]);
    expect(sent).toHaveLength(2);
  });

  test("skips a scratch file without treating it as a message", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "wk-build", task: "one" }),
      ".tmp.abc123": "{partial",
    });
    const { host, sent } = fakeHost("idle");
    expect(createInboxWatcher(host, identity, "/inbox", io).poll()).toEqual([1]);
    expect(sent).toHaveLength(1);
  });

  test("a corrupt envelope does not block the messages behind it", () => {
    const { io, logs } = fakeIO({
      "1.json": "not json at all",
      "2.json": envelope(2, { stage: "wk-build", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent.map((s) => s.text)).toEqual(["two"]);
    expect(logs.join(" ")).toMatch(/unreadable/i);
  });

  test("a protocol-violating payload is refused, logged, and not retried forever", () => {
    const { io, logs } = fakeIO({
      "1.json": envelope(1, { stage: "wk-build", task: "one", design: "copied prose" }),
      "2.json": envelope(2, { stage: "wk-build", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent.map((s) => s.text)).toEqual(["two"]);
    expect(logs.join(" ")).toMatch(/refusing/i);
  });

  test("a host with no sendUserMessage is inert and says so, rather than throwing", () => {
    // The Pi package is not installed here, so the API shape is an assumption.
    // A mismatch must not take the host down with it.
    const { io, logs } = fakeIO({ "1.json": envelope(1, { stage: "wk-build", task: "one" }) });
    expect(createInboxWatcher({}, identity, "/inbox", io).poll()).toEqual([]);
    expect(logs.join(" ")).toMatch(/inert/i);
  });

  test("a host that reports no agent state defers rather than guessing", () => {
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "wk-build", task: "one" }) });
    const { host, sent } = fakeHost();
    expect(createInboxWatcher({ sendUserMessage: host.sendUserMessage }, identity, "/inbox", io).poll()).toEqual([]);
    expect(sent).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Collapsing inspect and status.
//
// Those two verbs exist to carry detail, so they cannot be suppressed the way
// the frame-covered verbs are. But the AGENT picks the verb and the OPERATOR
// pays the screen: an agent probing a hang called `inspect` twice and printed
// two identical twenty-line JSON blobs nobody asked for. So the body collapses
// to one line and is available on demand.

const INSPECT_BODY = JSON.stringify(
  {
    run: "x3",
    uid: "w1",
    identity: {
      role: "impl",
      cwd: "/home/jan/.dotfiles",
      branch: "main",
      session: "2b9d7b5e-4c6d-4adf-b3ff-b459f6a3f2a",
      skill: "probe",
      window: "impl-timestamp-file@dotfiles",
      window_id: "@219",
    },
    state: "running",
    last_result: null,
    rejections: 0,
    resume: "pi --session 2b9d7b5e-4c6d-4adf-b3ff-b459f6a3f2a",
    transcript: "/home/jan/.pi/agent/sessions/x/y.jsonl",
  },
  null,
  2,
);

describe("collapsed state line", () => {
  test("it names the address, the state and the window", () => {
    const line = collapsedStateLine(INSPECT_BODY);
    expect(line).toContain("x3/w1");
    expect(line).toContain("running");
    expect(line).toContain("impl-timestamp-file@dotfiles");
    // One line, whatever the body.
    expect(line.split("\n")).toHaveLength(1);
  });

  test("it carries the last reported status when there is one", () => {
    const body = JSON.stringify({
      run: "x2",
      uid: "w1",
      identity: { window: "impl-a@dotfiles" },
      state: "complete",
      last_result: { status: "complete", summary: "Created timestamp.txt" },
    });
    const line = collapsedStateLine(body);
    expect(line).toContain("x2/w1");
    expect(line).toContain("complete");
  });

  test("output that will not parse still yields a line, never nothing", () => {
    // The CLI is a nu script; a future verb could print something that is not
    // JSON at all. Collapsing to an empty line would hide the fact that the
    // call returned anything.
    expect(collapsedStateLine("not json at all").length).toBeGreaterThan(0);
    expect(collapsedStateLine("not json at all")).toContain("not json at all");
    expect(collapsedStateLine("").length).toBeGreaterThan(0);
  });

  test("it says it can be expanded, or the affordance is invisible", () => {
    expect(collapsedStateLine(INSPECT_BODY).toLowerCase()).toContain("expand");
  });
});

describe("transcriptLines expansion", () => {
  test("a collapsed inspect is one line, not the whole body", () => {
    const lines = transcriptLines("inspect", true, INSPECT_BODY, { expanded: false });
    expect(lines).toHaveLength(1);
    expect(lines[0]).toContain("x3/w1");
    expect(lines[0]).not.toContain("transcript");
  });

  test("an expanded inspect is byte-identical to the old full body", () => {
    expect(transcriptLines("inspect", true, INSPECT_BODY, { expanded: true })).toEqual(
      INSPECT_BODY.split("\n"),
    );
  });

  test("status collapses the same way", () => {
    expect(transcriptLines("status", true, INSPECT_BODY, { expanded: false })).toHaveLength(1);
    expect(transcriptLines("status", true, INSPECT_BODY, { expanded: true }).length).toBeGreaterThan(1);
  });

  test("a failure is never collapsed, whatever the verb or the expand state", () => {
    // An operator who cannot read the refusal has no idea why nothing
    // happened, and hiding it behind a click makes that worse, not better.
    const err = "refusing to spawn x3/w1: address occupied";
    expect(transcriptLines("inspect", false, err, { expanded: false })).toEqual([err]);
    expect(transcriptLines("status", false, err, { expanded: false })).toEqual([err]);
  });

  test("the other verbs are unaffected by the expand state", () => {
    // Regression guard: collapsing must not leak into the verbs the frame
    // already covers, nor un-suppress them when expanded.
    for (const expanded of [false, true]) {
      expect(transcriptLines("spawn", true, "spawned x3/w1", expanded)).toEqual([]);
      expect(transcriptLines("wait", true, "no unacknowledged results", expanded)).toEqual([]);
      expect(transcriptLines("ack", true, "acked seq 1", expanded)).toEqual(["acked seq 1"]);
    }
  });

  test("omitting the expand state collapses, because that is the default view", () => {
    expect(transcriptLines("inspect", true, INSPECT_BODY)).toHaveLength(1);
  });
});

describe("click to expand", () => {
  // Pi hands renderResult an options object with its own `expanded` flag and a
  // context carrying per-row state plus invalidate(). Both are real inputs, so
  // the stubs here are objects, not arrow functions standing in for them.
  const mouseEvent = (over: { x: number; y: number }) => ({
    type: "press" as const,
    button: "left" as const,
    x: over.x,
    y: over.y,
    screenX: over.x,
    screenY: over.y,
    width: 80,
    height: 1,
    shift: false,
    alt: false,
    ctrl: false,
  });

  test("a click inside the component expands it and redraws just that row", () => {
    let invalidated = 0;
    const state: Record<string, unknown> = {};
    const component = resultComponent("inspect", true, INSPECT_BODY, {
      expanded: false,
      state,
      invalidate: () => { invalidated += 1; },
    });

    expect(component.render(200)).toHaveLength(1);

    const result = component.handleMouse!(mouseEvent({ x: 3, y: 0 }));
    expect(result?.handled).toBe(true);
    expect(invalidated).toBe(1);

    // The toggle lives in the row's shared state, so the component Pi builds
    // on the next render sees it.
    const redrawn = resultComponent("inspect", true, INSPECT_BODY, {
      expanded: false,
      state,
      invalidate: () => {},
    });
    expect(redrawn.render(200).length).toBeGreaterThan(1);
  });

  test("a second click collapses it again", () => {
    const state: Record<string, unknown> = {};
    const opts = { expanded: false, state, invalidate: () => {} };
    resultComponent("inspect", true, INSPECT_BODY, opts).handleMouse!(mouseEvent({ x: 1, y: 0 }));
    resultComponent("inspect", true, INSPECT_BODY, opts).handleMouse!(mouseEvent({ x: 1, y: 0 }));
    expect(resultComponent("inspect", true, INSPECT_BODY, opts).render(200)).toHaveLength(1);
  });

  test("a click outside the component's bounds is not ours to handle", () => {
    let invalidated = 0;
    const component = resultComponent("inspect", true, INSPECT_BODY, {
      expanded: false,
      state: {},
      invalidate: () => { invalidated += 1; },
    });
    expect(component.handleMouse!(mouseEvent({ x: 3, y: 40 }))).toBeUndefined();
    expect(invalidated).toBe(0);
  });

  test("Pi's own expand key wins even with no click", () => {
    const component = resultComponent("inspect", true, INSPECT_BODY, {
      expanded: true,
      state: {},
      invalidate: () => {},
    });
    expect(component.render(200).length).toBeGreaterThan(1);
  });

  test("a verb with nothing to show offers no click target", () => {
    // `spawn` renders no lines at all; a mouse handler over zero rows would
    // swallow clicks meant for whatever Pi draws next.
    const component = resultComponent("spawn", true, "spawned x3/w1", {
      expanded: false,
      state: {},
      invalidate: () => {},
    });
    expect(component.render(200)).toEqual([]);
    expect(component.handleMouse?.(mouseEvent({ x: 0, y: 0 }))).toBeUndefined();
  });

  test("the old two-argument call still works, for callers that have no context", () => {
    expect(resultComponent("inspect", true, INSPECT_BODY).render(200)).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// The frame carries the warming up.
//
// Getting one worker running used to cost a screenful of failed guesses and
// stage refusals. None of that is history worth keeping — it is the agent
// finding its footing, which is state, which is what the frame is for.

describe("frame activity", () => {
  const rows = [
    { run: "r1", uid: "impl-1", role: "impl", state: "running", liveness: "live", window: "impl-1@dotfiles" },
  ];

  test("a call in flight is a muted progress note, not news", () => {
    const line = activityLine({ verb: "spawn", at: 1000 }, 1000, (tone, text) => `<${tone}>${text}`);
    expect(line).toBe("<muted>spawn…");
  });

  test("a refusal is painted as one and carries its reason", () => {
    // "spawn failed" without the reason is the same dead end as printing
    // nothing: the stage refusal names the alternatives, and that is the whole
    // value of it.
    const line = activityLine(
      { verb: "spawn", ok: false, detail: "unknown stage 'default': not one of probe, build", at: 1000 },
      1000,
      (tone, text) => `<${tone}>${text}`,
    );
    expect(line).toContain("<error>");
    expect(line).toContain("not one of probe, build");
  });

  test("a success says nothing — the rows below are the success", () => {
    expect(activityLine({ verb: "spawn", ok: true, at: 1000 }, 1000)).toBeUndefined();
  });

  test("a refusal ages out rather than sitting there tomorrow", () => {
    const refusal = { verb: "spawn", ok: false, detail: "nope", at: 1000 };
    expect(activityLine(refusal, 1000 + ACTIVITY_TTL_MS - 1)).toBeDefined();
    expect(activityLine(refusal, 1000 + ACTIVITY_TTL_MS + 1)).toBeUndefined();
  });

  test("no activity is no line at all", () => {
    expect(activityLine(undefined, 1000)).toBeUndefined();
  });

  test("the activity line sits under the rows it concerns", () => {
    const frame = rosterFrame(rows, {
      now: 1000,
      activity: { verb: "send", ok: false, detail: "stage 'build' takes a ticket payload", at: 1000 },
    });
    expect(frame).toHaveLength(3); // heading, the worker, the refusal
    expect(frame[1]).toContain("impl-1");
    expect(frame[2]).toContain("takes a ticket payload");
  });

  test("with no workers yet the frame still draws, and says what it is", () => {
    // This is the interesting moment: before the first worker exists, while
    // the agent is still finding its footing. Claiming `0 workers` would be a
    // count nobody asked for.
    const frame = rosterFrame([], { now: 1000, activity: { verb: "spawn", at: 1000 } });
    expect(frame).toHaveLength(2);
    expect(frame[0]).toContain("warming up");
    expect(frame[0]).not.toContain("0 worker");
    expect(frame[1]).toContain("spawn");
  });

  test("neither rows nor activity gives the terminal rows back", () => {
    expect(rosterFrame([], { now: 1000 })).toBeUndefined();
    expect(rosterFrame([], { now: 1000, activity: { verb: "spawn", ok: true, at: 1000 } })).toBeUndefined();
  });

  test("note() draws immediately, and a success clears the line", async () => {
    // On the next poll would be five seconds of the operator reading a stale
    // frame while the transcript stays silent.
    // Mounted once, then repainted through the tui — so the component is held
    // and re-rendered, which is what Pi does with it. A note that only landed
    // on the next re-registration would leave the operator reading a stale
    // frame while the transcript stayed silent.
    let component: { render: (w: number) => string[] } | undefined;
    let repaints = 0;
    const frame = startRosterFrame({
      exec: (async () => ({ code: 0, stdout: JSON.stringify(rows), stderr: "" })) as never,
      setWidget: (_key, content) => {
        if (typeof content === "function") {
          component = (content as (t: unknown, th: unknown) => { render: (w: number) => string[] })(
            { requestRender: () => { repaints += 1; } },
            {},
          );
        }
      },
      intervalMs: 1_000_000,
      // These exercise mount and repaint mechanics, not scoping.
      allRuns: true,
    });
    await frame.refresh();
    expect(component).toBeDefined();

    frame.note({ verb: "spawn", ok: false, detail: "unknown stage 'default'", at: Date.now() });
    expect(repaints).toBeGreaterThan(0);
    expect(component!.render(200).join("\n")).toContain("unknown stage 'default'");

    frame.note({ verb: "spawn", ok: true, at: Date.now() });
    expect(component!.render(200).join("\n")).not.toContain("unknown stage");
    frame.stop();
  });
});

describe("refusals move to the frame, but only when there is one", () => {
  const refusal = "unknown stage 'default': not one of probe, build";

  test("with the frame live, a refusal prints nothing inline", () => {
    expect(transcriptLines("spawn", false, refusal, { frameLive: true })).toEqual([]);
  });

  test("with no frame, a refusal prints in full — as it always did", () => {
    // print, json and rpc mode, and any session without a UI. Suppressing here
    // would mean the operator cannot see the failure ANYWHERE, which is the
    // thing this file has always refused to do.
    expect(transcriptLines("spawn", false, refusal, { frameLive: false })).toEqual([refusal]);
    expect(transcriptLines("spawn", false, refusal, {})).toEqual([refusal]);
    expect(transcriptLines("spawn", false, refusal)).toEqual([refusal]);
  });

  test("expanding never resurrects a suppressed refusal, or it would double up", () => {
    expect(transcriptLines("inspect", false, refusal, { frameLive: true, expanded: true })).toEqual([]);
  });

  test("resultComponent honours frameLive too", () => {
    expect(resultComponent("spawn", false, refusal, { frameLive: true }).render(200)).toEqual([]);
    expect(resultComponent("spawn", false, refusal, {}).render(200)).toEqual([refusal]);
  });
});

describe("the frame shows this session's runs, not the whole box", () => {
  // The bus is per-user, not per-session, so `pi-worker ps` answers for
  // everything on the machine — right for a CLI, wrong for a widget. A
  // session's frame was showing other sessions' workers and leftovers from
  // previous ones, and `2 workers` gave the operator no way to tell which were
  // theirs.
  const mine = { run: "r9", uid: "impl-1", role: "impl", state: "running", liveness: "live", window: "impl-1@dotfiles" };
  const theirs = { run: "r5", uid: "x1", role: "rev", state: "running", liveness: "live", window: "rev-demo@dotfiles" };

  const frameOver = (rows: unknown[], opts: { allRuns?: boolean } = {}) => {
    let component: { render: (w: number) => string[] } | undefined;
    const frame = startRosterFrame({
      exec: (async () => ({ code: 0, stdout: JSON.stringify(rows), stderr: "" })) as never,
      setWidget: (_key, content) => {
        if (typeof content === "function") {
          component = (content as (t: unknown, th: unknown) => { render: (w: number) => string[] })(
            { requestRender: () => {} },
            {},
          );
        } else if (content === undefined) {
          component = undefined;
        }
      },
      intervalMs: 1_000_000,
      ...opts,
    });
    return { frame, drawn: () => component?.render(200) ?? [] };
  };

  test("a run this session never touched stays out of its frame", async () => {
    const { frame, drawn } = frameOver([mine, theirs]);
    frame.own("r9");
    await frame.refresh();
    frame.stop();
    const text = drawn().join("\n");
    expect(text).toContain("r9/impl-1");
    expect(text).not.toContain("r5/x1");
    expect(text).toContain("1 worker");
  });

  test("having touched no run shows nothing, rather than everything", async () => {
    // Showing everything is the bug. Showing nothing is honest, and the global
    // view is one `ps` call away.
    const { frame, drawn } = frameOver([theirs]);
    await frame.refresh();
    frame.stop();
    expect(drawn()).toEqual([]);
  });

  test("allRuns brings the whole bus back for anyone who wants it", async () => {
    const { frame, drawn } = frameOver([mine, theirs], { allRuns: true });
    await frame.refresh();
    frame.stop();
    expect(drawn().join("\n")).toContain("r5/x1");
  });
});

describe("the frame appears once and stays until the work is done", () => {
  // It used to strobe. `note` marks a call in flight and mounts; the call
  // returns and clears the activity; and for the moment before the next `ps`
  // lists the worker it just created, the roster is empty — so the widget was
  // torn down and rebuilt, once per verb, each rebuild a fresh component for
  // Pi to lay out. The operator saw the bar blink several times per spawn.

  const harness = (rows: unknown[]) => {
    let clock = 1_000_000;
    const events: string[] = [];
    const frame = startRosterFrame({
      exec: (async () => ({ code: 0, stdout: JSON.stringify(rows), stderr: "" })) as never,
      setWidget: (_key, content) => {
        events.push(content === undefined ? "unmount" : "mount");
        if (typeof content === "function") {
          (content as (t: unknown, th: unknown) => unknown)({ requestRender: () => {} }, {});
        }
      },
      intervalMs: 1_000_000,
      now: () => clock,
    });
    return { frame, events, advance: (ms: number) => { clock += ms; } };
  };

  test("a verb that clears its activity does not tear the frame down", async () => {
    const { frame, events, advance } = harness([]);
    await frame.refresh();

    frame.note({ verb: "spawn", at: 1_000_000 });
    expect(events).toEqual(["mount"]);

    // The call succeeds; its activity clears; `ps` has not caught up yet.
    advance(200);
    frame.note({ verb: "spawn", ok: true, at: 1_000_200 });
    await frame.refresh();

    // No unmount. This is the whole bug.
    expect(events).toEqual(["mount"]);
    frame.stop();
  });

  test("several verbs in a row mount exactly once", async () => {
    const { frame, events, advance } = harness([]);
    await frame.refresh();
    for (const verb of ["spawn", "send", "wait", "accept"]) {
      frame.note({ verb, at: 1_000_000 });
      advance(150);
      frame.note({ verb, ok: true, at: 1_000_000 });
      await frame.refresh();
      advance(150);
    }
    expect(events).toEqual(["mount"]);
    frame.stop();
  });

  test("a mounted frame never renders zero lines mid-run", async () => {
    // The symptom that survived the first two fixes. Staying mounted stopped
    // the widget being torn down, but with no workers on the bus yet, clearing
    // a verb's activity left rosterFrame with nothing to return — so the
    // component rendered zero lines, which on screen is indistinguishable from
    // having vanished. The next verb brought it back. That is the blink.
    let clock = 1_000_000;
    let component: { render: (w: number) => string[] } | undefined;
    const frame = startRosterFrame({
      exec: (async () => ({ code: 0, stdout: "[]", stderr: "" })) as never,
      setWidget: (_key, content) => {
        if (typeof content === "function") {
          component = (content as (t: unknown, th: unknown) => { render: (w: number) => string[] })(
            { requestRender: () => {} },
            {},
          );
        }
      },
      intervalMs: 1_000_000,
      now: () => clock,
    });
    await frame.refresh();

    frame.note({ verb: "spawn", at: clock });
    expect(component!.render(200).length).toBeGreaterThan(0);

    // The verb succeeds and its activity clears, while `ps` still lists
    // nothing. This is the exact moment the bar used to go dark.
    clock += 200;
    frame.note({ verb: "spawn", ok: true, at: clock });
    await frame.refresh();
    expect(component!.render(200).length).toBeGreaterThan(0);
    expect(component!.render(200)[0]).toContain("warming up");

    // Same for the gap between any two later verbs.
    clock += 200;
    frame.note({ verb: "wait", at: clock });
    clock += 200;
    frame.note({ verb: "wait", ok: true, at: clock });
    await frame.refresh();
    expect(component!.render(200).length).toBeGreaterThan(0);
    frame.stop();
  });

  test("but an idle frame does give its rows back eventually", async () => {
    // Holding forever would leave an idle session staring at a widget with
    // nothing to say.
    const { frame, events, advance } = harness([]);
    await frame.refresh();
    frame.note({ verb: "spawn", at: 1_000_000 });
    frame.note({ verb: "spawn", ok: true, at: 1_000_000 });

    advance(EMPTY_GRACE_MS - 1);
    await frame.refresh();
    expect(events).toEqual(["mount"]);

    advance(2);
    await frame.refresh();
    expect(events).toEqual(["mount", "unmount"]);
    frame.stop();
  });
});
