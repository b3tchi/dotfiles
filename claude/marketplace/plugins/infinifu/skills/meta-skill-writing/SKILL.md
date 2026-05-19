---
name: meta-skill-writing
description: Use when authoring or editing an infinifu skill — covers the house conventions (SKILL.md structure, rigidity_level, graphviz flowcharts, progressive disclosure via references/, pushy descriptions for triggering, the "why" over rigid MUSTs). For the full iterate-with-evals workflow (drafts, test prompts, benchmark viewer), use skill-creator instead; this skill is the style guide, skill-creator is the process.
---

<skill_overview>
Writing an infinifu skill means documenting a technique, pattern, or process so other Claude instances will find it and use it correctly under pressure. The house style is shaped by three ideas: progressive disclosure (SKILL.md is lean, depth lives in `references/`), why-over-MUST (explain the reason instead of issuing commands), and pushy descriptions (Claude undertriggiers by default). This skill is the style guide for those conventions.
</skill_overview>

<rigidity_level>
MEDIUM FREEDOM — the SKILL.md tag structure and the description format are fixed because consistency is what makes the corpus scannable: one glance tells you where to look. Content, examples, and depth adapt to the specific skill. For the iterate-with-evals authoring workflow (drafts → test prompts → benchmark viewer → packaging), use `skill-creator`; this skill is the style guide, that one is the process.
</rigidity_level>

<quick_reference>
| Aspect | Convention |
|--------|-----------|
| Frontmatter | `name` + `description` only; description 1–3 sentences, pushy, starts with "Use when…" |
| Top-of-file tags | `skill_overview`, `rigidity_level`, `quick_reference`, `when_to_use` |
| Body tags | `the_process`, `examples`, `critical_rules`, `verification_checklist`, `integration`, `references` |
| Length | SKILL.md under 300 lines; push depth into `references/` |
| Progressive disclosure | Load references on demand, not preemptively |
| Writing style | Why-over-MUST; explain the reason; reserve capitals for genuine gates |
| Flowcharts | `dot` graphviz for non-obvious decision points only |
| Cross-references | `infinifu:skill-name`, never `@skills/path/SKILL.md` |
| Naming | Verb-first; gerunds for processes (`idea-brainstorming`, `plan-supervised`) |
</quick_reference>

<when_to_use>
**Use when:**
- Authoring a new infinifu skill from scratch
- Refactoring an existing skill to match current conventions
- Reviewing a skill PR for style compliance
- The style drifts and you need a reference for what "on-style" looks like

**Don't use for:**
- The iterate-with-evals authoring workflow — use `skill-creator` (drafts, test prompts, eval loop, description optimizer, packaging)
- General Claude API or SDK guidance — use `claude-api`
- CLAUDE.md or repo-level conventions — those live in the repo itself
</when_to_use>

<the_process>

## Frontmatter

Two fields only: `name` and `description`. Total under 1024 characters.

**Name:** letters, numbers, hyphens only. Verb-first. Gerunds work well for processes.

- ✅ `domain-debug`, `idea-brainstorming`, `plan-supervised`
- ❌ `debugging-techniques`, `authentication-helpers`, `skill_utils_v2`

Name by what the skill *does* or its *core insight*, not by the subject area.

**Description:** 1–3 sentences that accomplish three things:

1. Name the situations that should invoke the skill (*"Use when…"*)
2. State what the skill produces (*"…gathers evidence with tools, forms a hypothesis…"*)
3. Distinguish from sibling skills if overlap is plausible (*"Pick this over X when Y"*)

Claude undertriggiers by default, so descriptions lean pushy:

- ✅ *"Use before writing any implementation code — walks through RED-GREEN-REFACTOR so every production line is driven by a test that was seen to fail. Invoke this whenever adding a feature or fixing a bug."*
- ❌ *"Use when implementing any feature or bugfix, before writing implementation code."* (no *what*, no push, no alternative)

**Never summarize the workflow in the description.** If the description tells the full story, Claude reads the description and doesn't load the skill body. Describe the trigger and the output; leave the steps for the body.

## The SKILL.md body

The house style uses XML-ish tag blocks for scannability. Every skill opens with the same four:

```markdown
<skill_overview>
One paragraph stating what this skill does in its simplest form.
</skill_overview>

<rigidity_level>
LOW FREEDOM / MEDIUM FREEDOM — and *why*. The why is load-bearing; a bare
"LOW FREEDOM" is cargo-culted. Explain which steps are non-negotiable, and
why (usually: because those are the steps under pressure to skip).
</rigidity_level>

<quick_reference>
A scannable table or short list. Claude should be able to consult this
without reading the whole process. Common columns:
  Step | Action | Deliverable
  Phase | What you do | Output
</quick_reference>

<when_to_use>
Bullet list of situations that match.

**Don't use for:** counter-bullets, each pointing at the right skill for
that situation.
</when_to_use>
```

Then the body. Common tag blocks:

- `<the_process>` — the step-by-step workflow
- `<examples>` — worked examples (move to `references/examples.md` once >100 lines)
- `<critical_rules>` — 8–12 non-negotiables with one-line explanations
- `<verification_checklist>` — per-step and overall checklists
- `<integration>` — which skills call this one and which it calls
- `<references>` — bulleted list of reference files with one-line load triggers

## Progressive disclosure

SKILL.md is loaded every time the skill triggers. `references/` files are loaded only when SKILL.md explicitly says "load this now". Put content into references when it is:

- A catalog (taxonomy, pattern list, audit command bank) consulted situationally
- A long worked example (>100 lines)
- A template used during the workflow but not needed to decide whether to
- Language- or framework-specific detail

Target: SKILL.md under 300 lines. If you're over, move something out.

## Writing style — why over MUST

An instruction that explains its reason generalizes; a bare MUST doesn't. Compare:

> ❌ *NEVER skip the regression test.*
>
> ✅ *The regression test is non-negotiable because bugs without one regress within a month — the same fix gets reapplied the next time someone refactors adjacent code.*

The ALL-CAPS version looks forceful but teaches nothing. The why version does the actual work of keeping future Claude on track when the situation differs from what the author anticipated.

**Where MUSTs are OK:** genuine process gates where Claude must literally stop. Examples that stayed capitalized across the corpus:

- `meta-bootstrap`: *"you ABSOLUTELY MUST invoke the skill"* — counteracts skill undertriggering
- `plan-bd`: the user-approval gate before execution
- `domain-verification`: *"MUST FAIL"* in the mutation check (that's the test of the test)
- `idea-brainstorming`: *"you MUST present the design and get approval"*

These are real pauses in a workflow, not decorative emphasis.

**The senior-SRE persona.** Used in review skills (`spec-refinement`, `work-audit`, `domain-test-effectiveness`) to signal scrutiny. Works when the persona brings something (consistency of standards, junior-engineer-review framing); it's noise when it just decorates. Default: don't use the persona unless the skill *is* about applying review rigor.

## Cross-referencing other skills

Use the `infinifu:` prefix with the bare skill name:

- ✅ `infinifu:domain-tdd`
- ✅ *"Use `infinifu:domain-debug` before attempting a fix"*
- ❌ `@skills/domain-tdd/SKILL.md` — the `@` syntax force-loads the file and burns context before you need it
- ❌ *"See skills/domain-tdd"* — ambiguous (required? optional? what does "see" mean?)

When one skill is a hard prerequisite for another, say so explicitly in prose rather than with heavy markers — *"Prerequisite: infinifu:domain-tdd"* is enough.

## Flowcharts

Use `dot` graphviz for non-obvious decision points only — typically in `<when_to_use>` sections to disambiguate from sibling skills.

**Don't use flowcharts for:**

- Reference material → use tables
- Code examples → use markdown code blocks
- Linear instructions → use numbered lists
- Anything with `step1`, `helper2` labels — labels must carry meaning

Full conventions live in `graphviz-conventions.dot`. Preview flowcharts with `./render-graphs.js ../some-skill` (or `--combine` for one SVG).

</the_process>

<bulletproofing_discipline_skills>

This section only applies when writing a **discipline-enforcing skill** (`domain-tdd`, `domain-verification`, `idea-brainstorming` — skills whose job is to make Claude follow a rule under pressure). Technique, pattern, and reference skills don't need this treatment.

Claude is smart. Under time pressure, social pressure, or sunk-cost pressure, Claude will rationalize around rules. The skill's job is to close those loopholes in advance, not to state them more forcefully.

**Close every loophole explicitly.** Don't just state the rule; name the specific workaround and forbid it.

> *"Write code before the test? Delete it. Start over. No exceptions: don't keep it as 'reference', don't 'adapt' it while writing tests, don't even look at it."*

**Address spirit-vs-letter.** Add a line like *"Violating the letter of the rules is violating the spirit of the rules."* early in the skill. This cuts off an entire class of rationalization in one stroke.

**Build a rationalization table.** Run the skill through a pressure scenario (methodology in `references/testing-skills-with-subagents.md`) and capture every rationalization Claude produces verbatim. Each gets a row:

| Excuse | Reality |
|--------|---------|
| *"Too simple to test"* | Simple code breaks. Test takes 30 seconds. |
| *"Tests after achieve the same goals"* | Tests-after = "what does this do?". Tests-first = "what should this do?". |

**Red flags list.** Name the thoughts Claude has when it's *about* to violate the rule. *"Quick fix for now, investigate later"* is itself the red flag. Make it easy to self-catch.

Why this works: see `references/persuasion-principles.md` for the research (Cialdini, Meincke et al.) on commitment, authority, unity, and why pre-committed rules resist in-the-moment rationalization better than case-by-case judgment.

</bulletproofing_discipline_skills>

<anti_patterns>

- **Narrative example.** *"In session 2025-10-03, we found empty projectDir caused…"* — too specific, won't generalize. State the pattern, not the incident.
- **Multi-language dilution.** Five mediocre examples in JS / Python / Go / Rust / Swift instead of one excellent example in the most-relevant language.
- **Code in flowcharts.** Flowcharts describe decisions; implementations belong in markdown code blocks.
- **Generic labels.** `helper1`, `step3`, `pattern_A` — labels must carry semantic meaning.
- **Description summarises the workflow.** If the description tells the full story, Claude reads it and skips the body.
- **Cargo-cult rigidity.** `<rigidity_level>LOW FREEDOM</rigidity_level>` with no explanation. The "why" is the load-bearing part.
- **ALL-CAPS decoration.** `MUST` / `NEVER` / `ALWAYS` at points that aren't genuine stop-gates.
- **Heavy "REQUIRED BACKGROUND" markers.** Prose like *"Prerequisite: `infinifu:X`. This skill extends Y."* reads better.
- **Duplicating content across skills.** If two skills explain the same taxonomy, one should point to the other — duplication means they drift out of sync.

</anti_patterns>

<verification_checklist>
Before committing a new or refactored skill:

- [ ] Description is 1–3 sentences, pushy, names triggers + output, distinguishes from siblings
- [ ] Description does *not* summarise the workflow (otherwise Claude won't load the body)
- [ ] SKILL.md has `skill_overview`, `rigidity_level`, `quick_reference`, `when_to_use` in that order
- [ ] `rigidity_level` explains *why* the rigidity matters, not just the label
- [ ] SKILL.md is under 300 lines; depth lives in `references/`
- [ ] Every reference file has a one-line "load this when…" trigger
- [ ] All-caps imperatives are at genuine gates, not decoration
- [ ] Cross-references use `infinifu:` prefix, not `@` force-loads
- [ ] Naming is verb-first; gerunds for processes
- [ ] If discipline-enforcing: rationalization table and red-flags list included
- [ ] No multi-language examples, no narrative war stories, no `helper1` labels
</verification_checklist>

<integration>

**Complements:** `skill-creator` — the iterate-with-evals *process* (drafts, test prompts, benchmark viewer, description optimizer, packaging). Use `skill-creator` to *build* a skill; use this skill to make sure it matches infinifu house style.

**Called:** ad hoc, by you when authoring or refactoring an infinifu skill.

**Calls:** nothing at author-time — this is a style reference, not a workflow skill.

</integration>

<references>
Deeper material, load on demand:

- `anthropic-best-practices.md` — Anthropic's official skill-authoring guidance; complements the infinifu conventions above without replacing them
- `persuasion-principles.md` — research on why bulletproofing-against-rationalization works (authority, commitment, unity principles; Cialdini 2021, Meincke et al. 2025)
- `testing-skills-with-subagents.md` — methodology for testing discipline-enforcing skills with pressure scenarios (the full iterate-with-evals workflow lives in `skill-creator`; this is the infinifu-specific pressure-scenario pattern)
- `examples/CLAUDE_MD_TESTING.md` — example of how CLAUDE.md-level tests interact with skill testing
- `graphviz-conventions.dot` — graphviz style rules for skill flowcharts
- `render-graphs.js` — renders a skill's flowcharts to SVG for visual review
</references>
