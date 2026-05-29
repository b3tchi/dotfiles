---
name: idea-poc
description: "Use when an approach proposed during brainstorming has no clear proof it works yet — before committing it as a spec's chosen solution. Triggers on 'prove X works first', 'spike this', 'is this even possible', 'poc', 'I think the library can do Y', or the proof gate in `infinifu:idea-brainstorming` / `idea-feature` hitting an unproven approach. Builds the smallest THROWAWAY experiment in complete isolation (a discarded `poc/<slug>` worktree for code, a scratch dir for tooling), reads the verdict honestly, and records it as a `docs/notes/lab/poc###.md` lab-notebook zettel (hypothesis / method / result / recommendation) that feeds the spec's `## solution`. Pick this over `infinifu:idea-feature` (captures the capability, not its feasibility), `infinifu:domain-debug` (investigates broken code, not an unbuilt idea), and `infinifu:domain-tdd` / `work-do` (build the real, reviewed thing — a PoC never becomes the implementation)."
---

# Idea: PoC (de-risk an unproven approach)

<skill_overview>
A proof-of-concept de-risks an approach by building the smallest throwaway
thing that proves — or kills — it, in complete isolation, then records the
verdict as evidence that feeds the spec's chosen solution. The code is
disposable; the knowledge is the deliverable. A PoC that validates lets the
real lifecycle proceed with confidence; a PoC that invalidates kills a bad
approach in an hour instead of a sprint.
</skill_overview>

<rigidity_level>
MEDIUM-HIGH FREEDOM on *what* you build to test the idea; LOW FREEDOM on two
disciplines, because they are the entire reason a PoC is cheap and honest:

1. **Isolation.** The experiment runs where it can be thrown away whole — a
   `poc/<slug>` git worktree for code, a scratch dir for external tooling.
   A failed or abandoned PoC must leave *zero* residue on main except the
   `poc###` record. Isolation is what makes a wrong guess free.
2. **Throwaway.** PoC code never becomes the real implementation. The real
   thing is built fresh through the normal lifecycle (idea → spec → work)
   once the approach is proven. PoC code is hypothesis-shaped: no tests, no
   edge cases, no review. Promoting it smuggles untested code past the hard
   gate — the exact outage the lifecycle exists to prevent.

These two are why a PoC is a *sanctioned exception* to the brainstorming hard
gate (which forbids writing code before design approval): a PoC produces
knowledge, not product. The gate keeps undocumented behavior from shipping;
throwaway PoC code ships nothing. Discard the worktree, carry only the verdict
back into the design.
</rigidity_level>

<quick_reference>
| Step | Action | Deliverable |
|------|--------|-------------|
| 1 | State a **falsifiable** hypothesis | one sentence that can be proven false |
| 2 | `AKM_ROOT="$(akm-root)"` | poc### lands on main |
| 3 | Isolate — `poc/<slug>` worktree (code) or scratch dir (tooling) | a place born to be deleted |
| 4 | Build the smallest thing that answers the hypothesis | a running experiment, nothing more |
| 5 | Read the verdict honestly + capture evidence | validated / invalidated / inconclusive |
| 6 | `akm poc write <slug> --category … [--informs …] --stdin` | `docs/notes/lab/poc###.md` |
| 7 | **Discard** the worktree / scratch dir | clean main |
| 8 | Hand the recommendation back to brainstorming | spec `## solution` cites `[[poc###]]` |
</quick_reference>

<when_to_use>
**Use when:**

- An approach proposed during brainstorming hinges on an unproven assumption —
  the proof gate in `infinifu:idea-brainstorming` / `idea-feature` routes here.
- You catch yourself about to commit to a solution you have not seen work
  ("I *think* nushell can drive an fzf popup", "this library *probably*
  supports streaming").
- The user says "prove it works first", "spike this", "poc", "is this even
  possible".

**Don't use for:**

- Building the real, reviewed implementation → `infinifu:work-do` /
  `infinifu:domain-tdd`.
- Investigating why *existing* code misbehaves → `infinifu:domain-debug`.
- Capturing a reusable capability → `infinifu:idea-feature`.
- An approach already proven elsewhere — cite that evidence and skip the PoC.
</when_to_use>

<the_process>

## 1. Frame a falsifiable hypothesis

"Approach X works" is not testable. The smallest claim that, if true, removes
the risk *is*: "nushell can drive an fzf picker inside a tmux popup without TTY
breakage". If you cannot state it falsifiably, you do not yet know what you are
de-risking — go back to brainstorming and find the real unknown.

## 2. Resolve AKM root

```bash
AKM_ROOT="$(akm-root)"
```

The `poc###` record is shared knowledge — it lives on main. If `akm-root`
errors, surface its stderr and abort (see `infinifu:idea-brainstorming` for the
strict-main rule).

## 3. Isolate

**Pick the isolation by what the experiment touches** — a worktree is only for
code:

- **Touches repo source code** (a change to how the dotfiles themselves behave)
  → a throwaway worktree on `poc/<slug>` (use `infinifu:domain-git-worktrees`).
  Build there. This branch is born to be deleted — do not push it, do not open
  a PR.
- **Proves an external tool / binary / config** (does `nu` start fast enough,
  does library X stream, does this tool even do Y) → a scratch dir
  (`/tmp/poc-<slug>`, `~/.cache/...`), no worktree and no repo involvement at
  all. This is the common case — most feasibility questions are about a tool,
  not about repo code, so don't reach for a worktree by reflex.

The rule that makes a PoC free, either way: **nothing from the experiment lands
on main except the `poc###` record.**

## 4. Build the smallest experiment that answers the hypothesis

YAGNI hard. You are proving the risky bit, not building the feature. Stub
everything that is not the risk — hardcode inputs, skip error handling, ignore
the happy-path polish. The moment the experiment answers the hypothesis, stop.

## 5. Read the verdict honestly

`validated` / `invalidated` / `inconclusive`. Capture the *evidence*: the
command output, the measurement, the thing that broke. An honest `invalidated`
is the cheapest possible outcome — you killed a bad approach before it cost a
sprint. `inconclusive` means the experiment was wrong, not the idea — refine
the hypothesis and rerun.

## 6. Record the poc###

```bash
printf '## hypothesis\n%s\n\n## method\n%s\n\n## result\n%s\n\n## recommendation\n%s\n' \
  "$hypothesis" "$method" "$result" "$recommendation" \
  | akm poc write "$slug" --category cat003 --status validated --stdin
# --informs us014   when the story/spec being de-risked already exists
# --status open|validated|invalidated   (the verdict)
```

- `$slug` is kebab-case (becomes `aliases[0]`).
- `--category` is the `[[cat###]]` bucket(s) the approach lives in (required).
- `--informs` is optional and usually omitted — the experiment typically runs
  *before* the `sp###` exists, so the spec cites the `poc###` later rather than
  the reverse. Pass it only when the story/spec being de-risked already exists.
- `## method` should name the throwaway worktree or scratch dir so the record
  is reproducible.
- Success is the `Id: poc###` line printed on stdout — capture it. The CLI also
  stages the file; a `git add` warning (e.g. outside a git repo in a sandbox)
  is benign and does not mean the write failed.

## 7. Discard the experiment

Delete the `poc/<slug>` worktree/branch (or the scratch dir). The code's job is
done. Keeping it around is step 1 of the "just promote the branch" anti-pattern.

## 8. Feed the verdict back

Hand the `## recommendation` to whoever is brainstorming. When the design is
approved and the `sp###` graduates, its `## solution` cites `[[poc###]]` as the
evidence for the chosen approach. If invalidated, the rejected approach is
documented so nobody re-litigates it.

</the_process>

<discipline>

A PoC is cheap only if it stays a PoC. Under the pull of a working prototype,
the temptation is always to keep the code. Closing that loophole in advance:

**Violating the letter of these rules is violating the spirit of them.** A
"mostly isolated" experiment or a "lightly cleaned up" PoC branch is the
failure, not a near-miss.

| Excuse | Reality |
|--------|---------|
| "The PoC works — just clean it into the real impl" | PoC code is hypothesis-shaped: no tests, no edge cases, no review. The PoC proved it's *possible*, not *correct*. Build the real thing fresh through the lifecycle. |
| "No need to isolate, I'll just try it in the repo" | An abandoned experiment in the repo is residue the next person trips over. Isolation is the whole reason a failed PoC costs nothing. |
| "It's obviously going to work, skip the PoC" | Then state the hypothesis and prove it in 20 minutes. If it's obvious it's cheap; if it's not cheap it wasn't obvious. |
| "Invalidated, so the PoC was wasted" | Invalidated is the cheapest win — a bad approach killed before a sprint sank into it. Record it so it stays dead. |
| "The result's in my head, skip the poc### record" | The verdict is the deliverable. Unrecorded, the next person re-runs the experiment or, worse, picks the invalidated approach. |

**Red flags — stop, the PoC is bleeding into production:** "let me just promote
this branch", "close enough to production", "I'll write the tests after the
merge", "no time to spin a separate worktree", "I'll keep it as reference while
I build the real one".

</discipline>

<examples>

**Hypothesis framing — vague vs. falsifiable:**

Input: "I want to use nushell for the i3 status bar but I'm not sure it's fast enough"
Output (hypothesis): "a nushell script can produce the full i3blocks status line in under 50ms cold, so the bar refreshes without visible lag"

**Recommendation that feeds a solution — validated:**

Input: PoC proved a single `nu` invocation renders the bar in 31ms
Output (recommendation): "Adopt the single-shot nushell renderer. 31ms < 50ms budget measured in the poc/nu-i3status worktree. The im### should compose it as one script invoked per i3blocks interval; no daemon needed."

**Recommendation that closes a path — invalidated:**

Input: PoC showed the library drops connections over 1MB
Output (recommendation): "Reject the streaming-upload approach via lib X — it silently truncates payloads >1MB (reproduced in poc/stream-upload). Spec should use chunked multipart instead; do not revisit lib X streaming."

</examples>

<integration>

**Branched from (the proof gate):** `infinifu:idea-brainstorming` and its entry
skills — `infinifu:idea-feature`, `infinifu:idea-implement`,
`infinifu:idea-extend`, `infinifu:idea-hotfix` — when a proposed approach lacks
clear proof it works.

**Calls:**

- `infinifu:domain-git-worktrees` — the isolated, disposable `poc/<slug>`
  worktree for code experiments.
- `akm poc write` — mints `docs/notes/lab/poc###.md` (id allocation,
  frontmatter, `# PoC [[cat###]]... [[board]]` H1, optional `## informs`
  back-link, staging).

**Feeds:** `infinifu:spec-writing` — the verdict informs the design; the
graduating `sp###`'s `## solution` cites `[[poc###]]` as evidence for (or
against) the chosen approach.

</integration>

<process_flow>

```dot
digraph idea_poc {
    "Approach proposed in brainstorming" [shape=box];
    "Clear proof it works?" [shape=diamond];
    "Proceed — cite existing evidence" [shape=doublecircle];
    "State falsifiable hypothesis" [shape=box];
    "Isolate: poc/<slug> worktree or scratch dir" [shape=box];
    "Build smallest experiment" [shape=box];
    "Read verdict honestly" [shape=diamond];
    "Record poc### (validated)" [shape=box];
    "Record poc### (invalidated)" [shape=box];
    "Refine hypothesis" [shape=box];
    "Discard worktree / scratch" [shape=box];
    "Feed recommendation to spec ## solution" [shape=doublecircle];

    "Approach proposed in brainstorming" -> "Clear proof it works?";
    "Clear proof it works?" -> "Proceed — cite existing evidence" [label="yes"];
    "Clear proof it works?" -> "State falsifiable hypothesis" [label="no"];
    "State falsifiable hypothesis" -> "Isolate: poc/<slug> worktree or scratch dir";
    "Isolate: poc/<slug> worktree or scratch dir" -> "Build smallest experiment";
    "Build smallest experiment" -> "Read verdict honestly";
    "Read verdict honestly" -> "Record poc### (validated)" [label="validated"];
    "Read verdict honestly" -> "Record poc### (invalidated)" [label="invalidated"];
    "Read verdict honestly" -> "Refine hypothesis" [label="inconclusive"];
    "Refine hypothesis" -> "Build smallest experiment";
    "Record poc### (validated)" -> "Discard worktree / scratch";
    "Record poc### (invalidated)" -> "Discard worktree / scratch";
    "Discard worktree / scratch" -> "Feed recommendation to spec ## solution";
}
```

</process_flow>
