# Agent health monitoring

**Alert the user immediately** when any agent shows signs of struggling. Do not wait for the agent to finish or fail — early warning saves time and money, and a stuck agent burns tokens until killed.

## Signals to watch

| Signal | Detection | Action |
|--------|-----------|--------|
| **Long runtime** | Agent has been running significantly longer than peers on similar-sized tasks | Alert user with elapsed time and task ID |
| **Large report** | Implementer returns an unusually verbose report (sign of thrashing/rework) | Flag to user before dispatching reviewer |
| **Partial progress** | Agent reports it completed some but not all of the task | Alert user — may need task split or help |
| **Self-reported difficulty** | Agent mentions uncertainty, workarounds, or "best effort" in its report | Flag verbatim quotes to user immediately |
| **Blocked marker** | Agent sets task to `blocked` | Alert user instantly — do not batch this into a progress report |

## Alert format

Alerts go to the user **as soon as detected** — do not defer to the next batch report.

```
⚠️  AGENT ALERT: bd-XXXX "[task title]"
Status:     [long-running | struggling | partial | blocked]
Elapsed:    [time if relevant]
Detail:     [what was observed — agent quotes if available]
Suggestion: [kill and reassign | wait longer | split task | human intervention]
```

## Checking on live workers

`ListAgents` is the cheap read: every row leads with the worker's `name [ref]` and says whether it is busy or idle right now. Use it to build the health picture instead of guessing from elapsed time alone.

- **Never poll it in a loop, and never send "are you done?"** — completion notifications arrive on their own.
- To hear when a worker goes quiet, prefer the one-shot subscription over repeated checks.
- Killing a stuck worker: `TaskStop({task_id: "impl-<bd-id>"})` — the agent name is accepted directly as the task id. Kill only workers this session dispatched, and only after alerting the user.

## Comparing agents

When multiple agents are running in parallel, compare their progress. If one agent finishes while another on a comparable task is still running, that's a signal the slow agent may be struggling — alert the user. The comparison only matters when tasks are comparable in scope; do not flag a "long" agent if its task is genuinely larger than its peers.
