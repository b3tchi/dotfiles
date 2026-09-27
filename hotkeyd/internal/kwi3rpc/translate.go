// Package kwi3rpc is hotkeyd's client for kwi3's native JSON-RPC 2.0 NDJSON
// API (ft010, kwi3 repo's core/rpc.js) - sp004 Task 16 (bd kwi3-234.16).
// Translate turns one of hotkeyd's own i3-command-string actions
// (cmd/hotkeyd/config.go's cmdAction table) into the ft010 method calls that
// have the same effect; Client (client.go) is the NDJSON connection that
// actually sends them, over $KWI3SOCK, with reconnect.
//
// This file is deliberately a PARSER over a fixed, small grammar - the exact
// subset of i3 command syntax hotkeyd's own real bind table
// (cmd/hotkeyd/config.go) emits - not a general i3-command interpreter.
// core/i3ipc.js (the kwi3 repo) is the source of truth for what each verb
// means; see its own "COMMAND SURFACE" doc comment for the full i3 grammar
// kwi3 supports and its own "Deliberately NOT supported" list, which is
// where sticky/scratchpad/mark/criteria/mode all live - this translator
// agrees with that list rather than inventing a wider one.
package kwi3rpc

import (
	"fmt"
	"strconv"
	"strings"
)

// Call is one JSON-RPC method + params pair Translate decided an i3 command
// statement becomes. Params is nil for a method that takes none (e.g.
// window.close with no id - "the focused window").
//
// Method methodWorkspaceNeighbour is a PSEUDO-method: ft010's
// workspace.focus takes num|id|name only, no relative direction, so
// "workspace next"/"prev" cannot be a single wire call at all - Client
// resolves it locally (workspace.list, then workspace.focus{num}, see
// Client.Dispatch) and this method name must never reach the socket.
type Call struct {
	Method string
	Params interface{}
}

// methodWorkspaceNeighbour is unexported on purpose: Translate and Client
// are the only two things that need to agree on its spelling, and nothing
// outside this package should ever try to Call it directly - it is not a
// real ft010 method.
const methodWorkspaceNeighbour = "workspace.neighbour"

// UnsupportedVerbError names an i3 command hotkeyd's OWN bind table can
// issue that kwi3's JSON-RPC API has no method for AT ALL - not a gap in
// this translator, a gap in the protocol (ft010, core/rpc.js). Adding a
// method for it is a core kwi3 change outside sp004 Task 16's scope; see
// KnownUnsupportedVerbs's doc for the decision this records.
type UnsupportedVerbError struct {
	Cmd string // the exact i3 command text Translate was given, e.g. "sticky toggle"
	Why string
}

func (e *UnsupportedVerbError) Error() string {
	return fmt.Sprintf("kwi3rpc: %q has no ft010 method: %s", e.Cmd, e.Why)
}

func unsupported(cmd, why string) (*Call, error) {
	return nil, &UnsupportedVerbError{Cmd: cmd, Why: why}
}

// KnownUnsupportedVerbs is every i3 command VERB Translate can never map,
// because kwi3's Logic has no concept for it at all - core/i3ipc.js's own
// "Deliberately NOT supported" list (border is the one exception there:
// i3ipc.js refuses it too, but ft010's window.border has no i3 counterpart
// and DOES exist, so it is not in this set) plus workspace's
// "back_and_forth" (no previous-workspace method on the RPC surface
// either). Exported so:
//   - the daemon can log this whole list once at startup, naming exactly
//     which of hotkeyd's OWN chords are affected (validateTranslation does
//     that walk);
//   - the table-driven test in cmd/hotkeyd asserts the unsupported set
//     found in the REAL bind table is exactly this one, so a chord added
//     later with a brand new unmapped verb fails the build rather than
//     silently joining "things that just don't work under kwi3".
//
// sp004 Task 16's own decision point (kwi3-234.16): hotkeyd's real table
// DOES use sticky ($mod+Shift+P, "sticky toggle") and scratchpad
// ($mod+Shift+minus "move scratchpad", $mod+minus "scratchpad show").
// Neither can be mapped to an EXISTING ft010 method, because kwi3's Logic
// itself has no sticky or scratchpad concept to call - core/i3ipc.js's own
// i3 codec already answers both with a parse error today, on every session
// including a kwi3 one (kwi3's i3 IPC is still served alongside the RPC
// socket until sp004 Task 18). So routing these three chords through
// kwi3rpc changes NOTHING about whether they work: they are exactly as
// dead under kwi3 today as they are once this task ships. Reported, not
// silently mapped to something merely plausible.
var KnownUnsupportedVerbs = map[string]string{
	"sticky":     "kwi3 has no sticky concept at all - core/i3ipc.js already refuses it (\"Deliberately NOT supported\"); adding one is a core kwi3 change, not a translation",
	"scratchpad": "kwi3 has no scratchpad - core/i3ipc.js already refuses it (\"kwi3 has no scratchpad\"); adding one is a core kwi3 change, not a translation",
}

var dirWords = map[string]bool{"left": true, "right": true, "up": true, "down": true}

// bindingName maps a hotkeyd action verb to the core/commands.js bindings()
// NAME that runs the same Logic via action.run - the escape hatch for
// actions ft010's typed methods cannot express directly (a stateful
// toggle with no boolean param, or a direction the typed method does not
// take). Every entry here is a REAL, already-registered kwi3 binding
// (i3kwin/core/commands.js's bindings() table) - action.run{name} is exactly
// what `kwi3 action <name>` / i3act already do headless.
var bindingNameFor = map[string]string{
	"focus:parent":      "focusParent",
	"focus:child":       "focusChild",
	"fullscreen:toggle": "fullScreen",
	"floating:toggle":   "float",
}

// Translate turns one hotkeyd i3-command-string action into the ft010
// call(s) that produce the same effect. A compound action
// ("split h;exec notify-send 'tile side'", hotkeyd's own $mod+s/$mod+b) is
// split into independent statements first, mirroring core/i3ipc.js's own
// ipcSplitStatements/ipcRunCommand - each becomes its own Call, run in
// order by Client.Dispatch.
//
// All-or-nothing: if ANY statement in cmd has no ft010 mapping, Translate
// returns that error and no calls at all, for two reasons - it is what lets
// a startup walk of the whole bind table (validateTranslation) name a
// broken CHORD rather than a broken half-statement, and none of hotkeyd's
// real compound actions mix a working statement with an unsupported one
// (the three unsupported verbs are all standalone chords), so this never
// costs a real partial-success case today.
func Translate(cmd string) ([]Call, error) {
	stmts := splitStatements(cmd)
	if len(stmts) == 0 {
		return nil, fmt.Errorf("kwi3rpc: empty command")
	}
	calls := make([]Call, 0, len(stmts))
	for _, stmt := range stmts {
		call, err := translateStatement(stmt)
		if err != nil {
			return nil, err
		}
		calls = append(calls, *call)
	}
	return calls, nil
}

// splitStatements is a straight port of the kwi3 repo's
// core/i3ipc.js:ipcSplitStatements - quote-aware split on ";" or ",",
// blank statements dropped - kept in step with it deliberately, since
// disagreeing about where one i3 command ends and the next begins would
// make this translator wrong in a way no test here could see (it would
// still parse SOME statement, just not the one kwi3 itself would parse).
func splitStatements(text string) []string {
	var out []string
	var cur strings.Builder
	var quote rune
	for _, ch := range text {
		if quote != 0 {
			cur.WriteRune(ch)
			if ch == quote {
				quote = 0
			}
			continue
		}
		switch ch {
		case '"', '\'':
			quote = ch
			cur.WriteRune(ch)
		case ';', ',':
			out = append(out, cur.String())
			cur.Reset()
		default:
			cur.WriteRune(ch)
		}
	}
	out = append(out, cur.String())
	kept := make([]string, 0, len(out))
	for _, s := range out {
		s = strings.TrimSpace(s)
		if s != "" {
			kept = append(kept, s)
		}
	}
	return kept
}

func translateStatement(stmt string) (*Call, error) {
	words := strings.Fields(stmt)
	if len(words) == 0 {
		return nil, fmt.Errorf("kwi3rpc: empty statement")
	}
	verb := strings.ToLower(words[0])
	arg := ""
	if len(words) > 1 {
		arg = strings.ToLower(words[1])
	}

	switch verb {
	case "kill":
		return &Call{Method: "window.close", Params: nil}, nil

	case "focus":
		if dirWords[arg] {
			return &Call{Method: "window.focus", Params: map[string]interface{}{"direction": arg}}, nil
		}
		if arg == "parent" || arg == "child" {
			return &Call{Method: "action.run", Params: map[string]interface{}{"name": bindingNameFor["focus:"+arg]}}, nil
		}
		return unsupported(stmt, "focus "+arg+" is not one of left, right, up, down, parent, child")

	case "move":
		if dirWords[arg] {
			return &Call{Method: "window.move", Params: map[string]interface{}{"direction": arg}}, nil
		}
		if arg == "scratchpad" {
			return unsupported(stmt, KnownUnsupportedVerbs["scratchpad"])
		}
		return unsupported(stmt, "move "+arg+" is not translated (only left, right, up, down, scratchpad are recognised)")

	case "scratchpad":
		return unsupported(stmt, KnownUnsupportedVerbs["scratchpad"])

	case "sticky":
		return unsupported(stmt, KnownUnsupportedVerbs["sticky"])

	case "resize":
		return translateResize(stmt, words)

	case "border":
		return translateBorder(stmt, arg)

	case "split":
		return translateSplit(stmt, arg)

	case "layout":
		return translateLayout(stmt, arg)

	case "fullscreen":
		return translateOnOffOrAction(stmt, arg, "window.fullscreen", "fullscreen:toggle")

	case "floating":
		return translateOnOffOrAction(stmt, arg, "window.float", "floating:toggle")

	case "workspace":
		return translateWorkspace(stmt, words)

	case "exec":
		return translateExec(stmt, words)
	}

	return unsupported(stmt, fmt.Sprintf("no ft010 mapping for verb %q", verb))
}

// resizeDirWords mirrors core/commands.js's resizeAxis: only the SIGN of
// delta matters (grow/shrink), the magnitude hotkeyd carries in its own
// action string ("5 px or 5 ppt", "10 px or 10 ppt") has nothing to bind
// to on the ft010 side (core/rpc.js's own doc: "delta's SIGN is grow/
// shrink, its magnitude is not" - resizeAxis always steps by RESIZE_STEP).
func translateResize(stmt string, words []string) (*Call, error) {
	if len(words) < 3 {
		return unsupported(stmt, "resize needs a direction and a dimension")
	}
	dirWord := strings.ToLower(words[1])
	dimWord := strings.ToLower(words[2])
	var delta int
	switch dirWord {
	case "grow":
		delta = 1
	case "shrink":
		delta = -1
	default:
		return unsupported(stmt, "resize "+dirWord+" is not grow or shrink")
	}
	var dim string
	switch dimWord {
	case "width", "height":
		dim = dimWord
	default:
		return unsupported(stmt, "resize dimension "+dimWord+" is not width or height")
	}
	return &Call{Method: "window.resize", Params: map[string]interface{}{"dimension": dim, "delta": delta}}, nil
}

func translateBorder(stmt, style string) (*Call, error) {
	switch style {
	case "none", "normal", "pixel":
		// The pixel WIDTH ("border pixel 4") has no home in ft010's
		// window.border (style only) - dropped, same as kwi3's own
		// titlebar frame draws one width regardless of what i3 asked for.
		return &Call{Method: "window.border", Params: map[string]interface{}{"style": style}}, nil
	}
	return unsupported(stmt, "border "+style+" is not none, normal or pixel")
}

func translateSplit(stmt, arg string) (*Call, error) {
	var orientation string
	switch arg {
	case "h", "horizontal":
		orientation = "horizontal"
	case "v", "vertical":
		orientation = "vertical"
	case "toggle":
		orientation = "toggle"
	default:
		return unsupported(stmt, "split "+arg+" is not h, v, horizontal, vertical or toggle")
	}
	return &Call{Method: "layout.split", Params: map[string]interface{}{"orientation": orientation}}, nil
}

// layoutWords mirrors core/i3ipc.js's IPC_LAYOUTS / core/rpc.js's
// RPC_LAYOUTS: "stacking" is kwi3's "stacked", both codecs normalise it the
// same way. A trailing word after "toggle"/"default" ("layout toggle
// split", "layout toggle all") is read by neither kwi3 codec - ipcCmdLayout
// only ever looks at w[1] - so it is not read here either.
var layoutWords = map[string]string{
	"tabbed": "tabbed", "stacking": "stacked", "stacked": "stacked",
	"splith": "splith", "splitv": "splitv",
}

func translateLayout(stmt, arg string) (*Call, error) {
	if arg == "toggle" {
		return &Call{Method: "layout.set", Params: map[string]interface{}{"layout": "toggle"}}, nil
	}
	if arg == "default" {
		return &Call{Method: "layout.set", Params: map[string]interface{}{"layout": "default"}}, nil
	}
	if l, ok := layoutWords[arg]; ok {
		return &Call{Method: "layout.set", Params: map[string]interface{}{"layout": l}}, nil
	}
	return unsupported(stmt, "layout "+arg+" is not tabbed, stacking, splith, splitv, default or toggle")
}

// translateOnOffOrAction is the shared shape of "fullscreen ..." and
// "floating ...": enable/disable map straight to the typed ft010 method's
// boolean `on`, and toggle - which the typed method cannot express at all,
// see the file doc - goes through action.run instead, keyed by
// bindingNameFor[actionKey].
func translateOnOffOrAction(stmt, arg, method, actionKey string) (*Call, error) {
	switch arg {
	case "enable":
		return &Call{Method: method, Params: map[string]interface{}{"on": true}}, nil
	case "disable":
		return &Call{Method: method, Params: map[string]interface{}{"on": false}}, nil
	case "toggle", "", "global":
		// i3 itself treats a bare verb with no argument, and "fullscreen
		// global", as "toggle" (core/i3ipc.js's ipcCmdFullscreen: `var a =
		// (w[1] || "toggle").toLowerCase(); if (a === "global") a =
		// "toggle";`); mirrored here rather than refused.
		return &Call{Method: "action.run", Params: map[string]interface{}{"name": bindingNameFor[actionKey]}}, nil
	}
	return unsupported(stmt, arg+" is not enable, disable or toggle")
}

func translateWorkspace(stmt string, words []string) (*Call, error) {
	if len(words) < 2 {
		return unsupported(stmt, "workspace needs a name, number, next or prev")
	}
	arg := strings.ToLower(words[1])
	switch arg {
	case "next", "next_on_output":
		return &Call{Method: methodWorkspaceNeighbour, Params: map[string]interface{}{"step": 1}}, nil
	case "prev", "previous", "prev_on_output":
		return &Call{Method: methodWorkspaceNeighbour, Params: map[string]interface{}{"step": -1}}, nil
	case "back_and_forth":
		return unsupported(stmt, "ft010's workspace.focus has no previous-workspace method to call")
	}
	// A bare integer is a POSITION (num); anything else is a free-form
	// name - the same one-lookup-not-two convergence core/commands.js's
	// workspaceSlotFor() makes, mirrored here as two possible params
	// shapes rather than a single ambiguous one.
	name := strings.Join(words[1:], " ")
	if n, err := strconv.Atoi(words[1]); err == nil && len(words) == 2 {
		return &Call{Method: "workspace.focus", Params: map[string]interface{}{"num": n}}, nil
	}
	return &Call{Method: "workspace.focus", Params: map[string]interface{}{"name": name}}, nil
}

func translateExec(stmt string, words []string) (*Call, error) {
	at := 1
	for at < len(words) && strings.HasPrefix(words[at], "--") {
		at++ // --no-startup-id and friends, same skip as ipcCmdExec
	}
	if at >= len(words) {
		return unsupported(stmt, "exec needs a command")
	}
	// The rest of the STATEMENT text, not words rejoined with single
	// spaces - splitStatements already trimmed the statement, and
	// reconstructing from words would collapse any interior whitespace the
	// command itself cared about. Found by locating the exec verb's own
	// word boundary in the original (case-preserved) statement text.
	rest := stmt
	fields := strings.SplitN(stmt, " ", 2)
	if len(fields) == 2 {
		rest = fields[1]
	} else {
		rest = ""
	}
	for skip := 1; skip < at; skip++ {
		f := strings.SplitN(rest, " ", 2)
		if len(f) == 2 {
			rest = f[1]
		} else {
			rest = ""
		}
	}
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return unsupported(stmt, "exec needs a command")
	}
	return &Call{Method: "exec", Params: map[string]interface{}{"command": rest}}, nil
}
