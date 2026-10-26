//go:build win32 && windows

package main

import (
	"reflect"
	"strings"
	"testing"

	"hotkeyd/internal/proc"
)

// Every Run the Windows table can start splits, with internal/proc's own
// Windows word splitter (the one Run uses - no shell), into exactly the
// program and arguments meant. No command carries a `"`: the splitter has
// no escape, so a literal quote cannot reach a program.
func TestWin32_RunsSplitWithTheWindowsSplitter(t *testing.T) {
	runs := allRuns()
	if len(runs) == 0 {
		t.Fatal("no Run in the Windows table at all")
	}
	for where, cmd := range runs {
		if strings.Contains(cmd, `"`) {
			t.Errorf("%s: %q has a double quote, which SplitCommand cannot pass through", where, cmd)
		}
		got, err := proc.SplitCommand(cmd)
		if err != nil {
			t.Errorf("%s: SplitCommand(%q): %v", where, cmd, err)
			continue
		}
		var want []string
		switch {
		case cmd == "wt.exe -w new":
			want = []string{"wt.exe", "-w", "new"}
		case strings.HasPrefix(cmd, "kwi3-run.exe "):
			want = []string{"kwi3-run.exe", strings.TrimPrefix(cmd, "kwi3-run.exe ")}
		default:
			t.Errorf("%s: unexpected program %q", where, cmd)
			continue
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: SplitCommand(%q) = %q, want %q", where, cmd, got, want)
		}
	}
}
