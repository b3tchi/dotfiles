// Package bind is the Go port of hotkeyd/binds.py's declarative bind table:
// chord parsing, the bind/layer type shapes, and the validator that replaces
// i3's own duplicate-binding detection once binds leave i3 (sp021 Task 5,
// bd dotfiles-ylmp.4).
//
// It is pure: no X connection and no i3 connection, so Validate works
// headless — the same reason binds.py's validate() runs in a pre-commit hook
// with no display attached ([[us019]], [[us020]] AC2).
//
// # Rule catalogue — reconciled against binds.py's validator
//
// The task that produced this package ([[sp021]] Task 5) was written against
// a claim that binds.py's validator has "42 distinct rejection rules". A
// line-by-line read of every `problems.append(...)` and `raise BindError(...)`
// call site in hotkeyd/binds.py (verified 2026-07-30, commit at HEAD when
// this package was written) finds 20 call sites collapsing into 27 distinct
// CODE-BRANCH families (some call sites are shared helpers — parse_chord,
// _action_problem — invoked from more than one context, and each context is
// counted once). Two of those families are then expanded into multiple named
// tests because this task's own success_criteria and edge_cases explicitly
// demand independent per-spelling / per-scope proof, matching the "prove the
// exact code path fails when deleted" bar Task 3's review applied:
//
//   - RESERVED_CHORDS (rule 07) must independently prove all four spellings
//     named in [[ft011]] ("$mod token, Mod4 literal, Mod1 literal,
//     alias-folded") — the $mod token is additionally tested under both
//     $mod resolutions, since it resolves differently per display and a
//     single-pass test cannot prove the other resolution is also covered.
//     1 branch -> 5 named tests (07a-07e).
//   - Duplicate detection (rule 08) must independently prove the scope
//     variants this task's own edge_cases names: global, a layer's own
//     binds, a sublayer's own binds, and — the edge case called out by
//     name — duplication spanning "a layer's base binds AND its sublayer
//     tables", which share ONE `seen` map (see Validate). A true
//     base-vs-sublayer collision is structurally impossible (a layer's
//     own binds are constrained bare — rule 06 — while every sublayer
//     bind carries at least its resolved modifier, so their identities
//     can never coincide); what the shared map actually guards against,
//     and what 08d proves, is two DIFFERENTLY-LABELLED Mod sublayers
//     whose Modifier resolves to the same canonical value colliding on
//     the same bare key — undetectable if each sublayer scan got a
//     fresh map instead of sharing the layer's. Same-device-scope
//     duplication is also its own named test, paired with a
//     NOT-a-duplicate positive test for different device scope
//     ([[ft011]] api_surface, verbatim). 1 branch -> 5 named tests
//     (08a-08e).
//
// That yields 27 - 2 + 5 + 5 = 35 named rejection-rule tests sourced from
// binds.py. One further rule (27) is NOT from binds.py at all: it validates
// the DisplayMod field this package adds ahead of binds.py, per this task's
// design constraint ("Display qualifier exists from day one",
// [[us020]]) — binds.py has no display qualifier yet (us020 is still
// `status: draft`), so there is no Python source line to cite for it.
//
// Three further rules (28-30) are also NOT from binds.py: they validate the
// External declaration kind [[sp023]] Task 1 (bd dotfiles-1m4t.1) adds —
// a signal-only layer entered via a new `set-layer` verb instead of a
// chord, with no Python source line to cite since binds.py has no such
// concept. Rule 28 (an External layer declaring a behavioral field) is
// expanded into 7 named per-field tests (28a-28g), one per field the task's
// own success_criteria enumerates, because the edge_cases explicitly
// require Hold to be named on its own in the message ([[adr0016]]'s
// ask-the-server hold lifetime) rather than folded into a generic
// "behavioral field" rejection. Rule 29 (EnterLayer targeting an External
// layer) and rule 30 (a layer named "default" declaring External) are each
// one named test — 9 new tests total for rules 28-30. Rule 20 (a layer with
// no ExitKeys) also gains a SECOND test for the same task: the identical
// bare-layer shape WITHOUT External still trips it, proving the new R28
// exemption stayed scoped to the flag rather than silently widening to
// every layer (the task's own mutation-check instruction) — 1 more test
// under an existing rule, not a new rule.
//
// Total: 45 named tests in this package's *_test.go files, rule id in each
// test name (grep `func Test.*_R[0-9]` to enumerate). The 35-rule figure is
// DIFFERENT from binds.py task's stated "42" — the discrepancy and the full
// branch-by-branch working is recorded in that task's bd notes rather than
// re-litigated here, since a doc comment is not the place to re-derive it
// every time someone reads the package.
//
// Rule id : binds.py site : Go site : one-line description
//
//	R01 : binds.py:102     : ParseChord            : empty chord string
//	R02 : binds.py:106     : ParseChord            : no key after the last '+'
//	R03 : binds.py:111-113 : ParseChord            : bare multi-digit keycode instead of a keysym name
//	R04 : binds.py:121     : ParseChord            : unknown modifier alias
//	R05 : binds.py:124-126 : ParseChord            : unknown keysym name
//	R06 : binds.py:370-382 : bareProblem           : a layer/sublayer bind chord carries a modifier (must be a bare keysym)
//	R07a: binds.py:166     : scan (reserved)       : panic chord via $mod token, resolved on the native (Mod4) pass
//	R07b: binds.py:166     : scan (reserved)       : panic chord via $mod token, resolved on the xrdp (Mod1) pass
//	R07c: binds.py:166     : scan (reserved)       : panic chord literal, Mod4 form
//	R07d: binds.py:166     : scan (reserved)       : panic chord literal, Mod1 form
//	R07e: binds.py:166     : scan (reserved)       : panic chord, alias-folded spelling
//	R08a: binds.py:420-423 : scan (duplicate)      : duplicate chord in the global table
//	R08b: binds.py:420-423 : scan (duplicate)      : duplicate chord within one layer's own binds
//	R08c: binds.py:420-423 : scan (duplicate)      : duplicate chord within one sublayer's own binds
//	R08d: binds.py:489-503 : Validate (shared seen): duplicate chord across two of a layer's sublayer tables, via the seen map shared with the layer's own binds
//	R08e: binds.py:355-367 : scan (duplicate)      : duplicate chord, same device scope (device is part of the identity)
//	R09 : binds.py:329-330 : commandProblem        : action tuple is empty
//	R10 : binds.py:320-321 : actionProblem         : a Command (string) action is empty/whitespace
//	R11 : binds.py:322-323 : actionProblem         : a Run action has an empty/whitespace cmd
//	R12 : binds.py:349-351 : deviceProblem         : Device is set but blank/whitespace-only
//	R13 : binds.py:433-436 : scan (EnterLayer)     : EnterLayer targets a layer that does not exist
//	R14 : binds.py:445-448 : holdProblems          : OnHoldRelease declared with no Hold modifier
//	R15 : binds.py:452     : holdProblems          : unknown Hold modifier
//	R16 : binds.py:460-463 : holdProblems          : Hold modifier resolves to Shift (unobservable on xrdp :10)
//	R17 : binds.py:320-321 : holdProblems          : OnHoldRelease Command action is empty/whitespace
//	R18 : binds.py:322-323 : holdProblems          : OnHoldRelease Run action has an empty/whitespace cmd
//	R19 : binds.py:500-501 : Validate (sublayer)   : a Mod sublayer's Modifier field is unknown
//	R20 : binds.py:505-507 : Validate (layer)      : a layer declares no ExitKeys (could never be left); exempt when Layer.External is set (rule 28)
//	R21 : binds.py:102     : Validate (exit key)   : exit key chord is empty
//	R22 : binds.py:106     : Validate (exit key)   : exit key chord has no key after the last '+'
//	R23 : binds.py:111-113 : Validate (exit key)   : exit key chord is a bare multi-digit keycode
//	R24 : binds.py:121     : Validate (exit key)   : exit key chord has an unknown modifier
//	R25 : binds.py:124-126 : Validate (exit key)   : exit key chord has an unknown keysym
//	R26 : binds.py:515-524 : Validate (exit key)   : exit key carries a modifier (must be a bare keysym)
//	R27 : (new, no Python site) : canonDisplayMod  : DisplayMod is set to an unrecognised modifier name
//	R28 : (new, no Python site) : externalProblems : an External layer declares a behavioral field (Binds/Mods/ExitKeys/OneShot/Hold/OnHoldRelease/OnExit)
//	R29 : (new, no Python site) : scan (EnterLayer) : an EnterLayer action targets a layer declared External
//	R30 : (new, no Python site) : Validate (layer)  : a layer named "default" declares External
//
// # Display qualifier (us020, day-one design constraint)
//
// Bind.DisplayMod scopes a bind to ONE $mod resolution ("" — the zero value —
// means every display, i.e. today's behaviour, us020 AC5). Validate(mod)
// simulates one specific display: a bind whose DisplayMod is set and does not
// canonically match the mod passed to Validate is excluded from duplicate
// detection for THAT pass (it would not be grabbed on that display, so it
// cannot double-fire there) — but RESERVED_CHORDS is checked unconditionally
// for every bind regardless of pass membership, resolving the bind's own
// $mod token against its OWN DisplayMod when set (falling back to the pass's
// mod only when DisplayMod is unset). A display-qualified bind cannot dodge
// the panic-chord reservation by being scoped to a display the caller
// happens not to be validating right now — [[ft011]]: "the validator is
// display-agnostic while $mod is not" applies just as much to a qualifier
// added five years after that sentence was written as it did on day one.
package bind
