package main

// transition.go parses the daemons' transition log ENGINE-NEUTRALLY.
//
// dotfiles-n0r4: the two engines quote the `device=` field differently —
// python's `!r` emits single quotes, Go's `%q` emits double quotes — and the
// mask/`none` spellings differ in the same cosmetic way. A comparison harness
// that compared raw log lines would report a divergence on every single
// transition and drown the real findings. So every field is tokenised,
// unquoted, and folded to one canonical spelling before anything is compared.
// The quoting difference is a real (filed) defect; it is just not a DISPATCH
// divergence, and this harness is grading dispatch.

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var reGrabSummary = regexp.MustCompile(`(\d+) chords grabbed on \S+ via XI2 \(\$mod=(\w+)\)`)

func parseGrabSummary(line string) (count int, mod string, ok bool) {
	m := reGrabSummary.FindStringSubmatch(line)
	if m == nil {
		return 0, "", false
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return 0, "", false
	}
	return n, m[2], true
}

// splitQuoted splits a log line on spaces, keeping quoted runs together.
// Handles BOTH quote characters, because that is exactly what differs between
// the engines.
func splitQuoted(s string) []string {
	var out []string
	var cur strings.Builder
	var quote rune
	for _, r := range s {
		switch {
		case quote != 0:
			cur.WriteRune(r)
			if r == quote {
				quote = 0
			}
		case r == '\'' || r == '"':
			quote = r
			cur.WriteRune(r)
		case r == ' ':
			if cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteRune(r)
		}
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// foldValue strips either engine's quoting and folds every spelling of
// "absent" onto one token.
func foldValue(v string) string {
	if len(v) >= 2 && (v[0] == '\'' || v[0] == '"') && v[len(v)-1] == v[0] {
		inner := v[1 : len(v)-1]
		if v[0] == '\'' {
			inner = strings.ReplaceAll(inner, `\'`, `'`)
		}
		if unq, err := strconv.Unquote(strconv.Quote(inner)); err == nil {
			inner = unq
		}
		v = inner
	}
	switch v {
	case "None", "none", "":
		return "none"
	}
	return v
}

// Transition is one parsed `transition ...` line, canonicalised.
type Transition struct {
	Raw    string
	Fields map[string]string
}

// transitionFields are the fields compared between arms, in report order.
// `device` is included deliberately — after folding, the two engines should
// agree on the DEVICE NAME even though they disagree on how to quote it, and
// a disagreement on the name itself would be a real attribution divergence.
var transitionFields = []string{
	"layer", "mod", "trigger", "keycode", "mask", "mods",
	"sourceid", "device", "held", "i3_mode", "note",
}

func parseTransition(line string) (Transition, bool) {
	if !strings.Contains(line, "transition ") {
		return Transition{}, false
	}
	toks := splitQuoted(line)
	start := -1
	for i, t := range toks {
		if t == "transition" {
			start = i
			break
		}
	}
	if start < 0 {
		return Transition{}, false
	}
	fields := map[string]string{}
	for _, t := range toks[start+1:] {
		k, v, ok := strings.Cut(t, "=")
		if !ok {
			continue
		}
		// layer= and mod= are COMPOSITE (`from->to`), so folding the whole
		// value would leave `mod=None->None` and `mod=none->none` — the same
		// event on the two engines — comparing unequal. Fold each side.
		if k == "layer" || k == "mod" {
			if from, to, ok := strings.Cut(v, "->"); ok {
				fields[k] = foldValue(from) + "->" + foldValue(to)
				continue
			}
		}
		fields[k] = foldValue(v)
	}
	if _, ok := fields["layer"]; !ok {
		return Transition{}, false
	}
	// mask is printed with different widths by the two engines (python pads
	// to four hex digits, Go does not). Normalise to a plain integer.
	if m, ok := fields["mask"]; ok && m != "none" {
		if v, err := strconv.ParseUint(strings.TrimPrefix(m, "0x"), 16, 32); err == nil {
			fields["mask"] = fmt.Sprintf("0x%x", v)
		}
	}
	return Transition{Raw: line, Fields: fields}, true
}

// Canon renders the transition as one comparable string.
func (t Transition) Canon() string {
	parts := make([]string, 0, len(t.Fields))
	seen := map[string]bool{}
	for _, k := range transitionFields {
		if v, ok := t.Fields[k]; ok {
			parts = append(parts, k+"="+v)
			seen[k] = true
		}
	}
	extra := make([]string, 0)
	for k, v := range t.Fields {
		if !seen[k] {
			extra = append(extra, k+"="+v)
		}
	}
	sort.Strings(extra)
	return strings.Join(append(parts, extra...), " ")
}

func transitionsIn(lines []string) []Transition {
	var out []Transition
	for _, l := range lines {
		if tr, ok := parseTransition(l); ok {
			out = append(out, tr)
		}
	}
	return out
}

func canonTransitions(trs []Transition) []string {
	out := make([]string, 0, len(trs))
	for _, t := range trs {
		out = append(out, t.Canon())
	}
	return out
}
