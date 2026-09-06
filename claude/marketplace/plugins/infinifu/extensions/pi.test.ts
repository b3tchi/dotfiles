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
import {
  createInboxWatcher,
  decideDelivery,
  userPayloadFor,
  systemContextFor,
  resultEnvelopeFrom,
  settledWithoutResult,
  unreadAfter,
  createAgentStateTracker,
  MAX_SUMMARY_BYTES,
} from "./pi.ts";

const workEnvelope = {
  protocol: 1 as const,
  sequence: 3,
  run: "run-1",
  uid: "impl-a",
  kind: "inbox" as const,
  created: "2026-09-05T10:00:00Z",
  payload: { stage: "work-do" as const, task: "dotfiles-963w.4" },
};

const akmEnvelope = {
  ...workEnvelope,
  payload: {
    stage: "spec-refinement",
    instructions: "Refine the spec into tasks.",
    artifacts: ["sp028", "ft014"],
  },
};

const identity = {
  role: "impl",
  cwd: "/repo/.worktrees/bd-dotfiles-963w.4.0",
  branch: "bd-dotfiles-963w.4.0",
  session: "sid-1",
  skill: "work-do",
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
    expect(text).not.toMatch(/work-do/);
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
    expect(() => userPayloadFor(bad as never)).toThrow(/instructions/i);
  });
});

describe("trusted configuration stays out of the user message", () => {
  test("role and skill are carried in system context", () => {
    const ctx = systemContextFor(identity);
    expect(ctx).toContain("impl");
    expect(ctx).toContain("work-do");
    expect(ctx).toContain(identity.cwd);
  });

  test("system context is never mixed into the user payload", () => {
    const ctx = systemContextFor(identity);
    const text = userPayloadFor(workEnvelope);
    for (const secret of [identity.session, identity.branch, identity.cwd, "work-do"]) {
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
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "work-do", task: "dotfiles-963w.4" }) });
    const { host, sent } = fakeHost("idle");
    const w = createInboxWatcher(host, identity, "/inbox", io);

    expect(w.poll()).toEqual([1]);
    expect(sent).toEqual([
      { text: "dotfiles-963w.4", deliverAs: "followUp", mode: undefined },
    ]);
  });

  test("delivers an AKM message as instructions plus artifacts", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "spec-retro", instructions: "Run the retro.", artifacts: ["sp028"] }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();

    expect(sent[0].text).toContain("Run the retro.");
    expect(sent[0].text).toContain("sp028");
  });

  test("steers rather than follows up while the agent is streaming", () => {
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "work-do", task: "t" }) });
    const { host, sent } = fakeHost("streaming");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent[0].deliverAs).toBe("steer");
    expect(sent[0].mode).toBeUndefined();
  });

  test("delivers nothing while compacting, and delivers it later", () => {
    const files = { "1.json": envelope(1, { stage: "work-do", task: "t" }) };
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
      "1.json": envelope(1, { stage: "work-do", task: "one" }),
      "2.json": envelope(2, { stage: "work-do", task: "two" }),
    });
    const host = {
      agentState: () => (calls++ === 0 ? "compacting" : "idle"),
      sendUserMessage: () => {},
    };
    expect(createInboxWatcher(host, identity, "/inbox", io).poll()).toEqual([]);
  });

  test("never redelivers what it already sent", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "work-do", task: "one" }),
      "2.json": envelope(2, { stage: "work-do", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    const w = createInboxWatcher(host, identity, "/inbox", io);
    expect(w.poll()).toEqual([1, 2]);
    expect(w.poll()).toEqual([]);
    expect(sent).toHaveLength(2);
  });

  test("skips a scratch file without treating it as a message", () => {
    const { io } = fakeIO({
      "1.json": envelope(1, { stage: "work-do", task: "one" }),
      ".tmp.abc123": "{partial",
    });
    const { host, sent } = fakeHost("idle");
    expect(createInboxWatcher(host, identity, "/inbox", io).poll()).toEqual([1]);
    expect(sent).toHaveLength(1);
  });

  test("a corrupt envelope does not block the messages behind it", () => {
    const { io, logs } = fakeIO({
      "1.json": "not json at all",
      "2.json": envelope(2, { stage: "work-do", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent.map((s) => s.text)).toEqual(["two"]);
    expect(logs.join(" ")).toMatch(/unreadable/i);
  });

  test("a protocol-violating payload is refused, logged, and not retried forever", () => {
    const { io, logs } = fakeIO({
      "1.json": envelope(1, { stage: "work-do", task: "one", design: "copied prose" }),
      "2.json": envelope(2, { stage: "work-do", task: "two" }),
    });
    const { host, sent } = fakeHost("idle");
    createInboxWatcher(host, identity, "/inbox", io).poll();
    expect(sent.map((s) => s.text)).toEqual(["two"]);
    expect(logs.join(" ")).toMatch(/refusing/i);
  });

  test("a host with no sendUserMessage is inert and says so, rather than throwing", () => {
    // The Pi package is not installed here, so the API shape is an assumption.
    // A mismatch must not take the host down with it.
    const { io, logs } = fakeIO({ "1.json": envelope(1, { stage: "work-do", task: "one" }) });
    expect(createInboxWatcher({}, identity, "/inbox", io).poll()).toEqual([]);
    expect(logs.join(" ")).toMatch(/inert/i);
  });

  test("a host that reports no agent state defers rather than guessing", () => {
    const { io } = fakeIO({ "1.json": envelope(1, { stage: "work-do", task: "one" }) });
    const { host, sent } = fakeHost();
    expect(createInboxWatcher({ sendUserMessage: host.sendUserMessage }, identity, "/inbox", io).poll()).toEqual([]);
    expect(sent).toHaveLength(0);
  });
});
