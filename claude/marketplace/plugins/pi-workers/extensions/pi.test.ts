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
  resultEnvelopeFrom,
  settledWithoutResult,
  unreadAfter,
  createAgentStateTracker,
  createResultTool,
  createInitiatorTool,
  rosterFrame,
  transcriptLines,
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

  test("the detail verbs keep every line they produced", () => {
    const detail = "{\n  \"run\": \"x1\"\n}";
    expect(transcriptLines("inspect", true, detail)).toEqual(detail.split("\n"));
    expect(transcriptLines("status", true, detail)).toEqual(detail.split("\n"));
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
