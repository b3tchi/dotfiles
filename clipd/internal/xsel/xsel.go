// Package xsel drives one X display's CLIPBOARD through clipnotify and
// xclip (sp039 Task 4). It is the only place clipd talks to X.
//
// The display is always named by the caller and never taken from the
// inherited $DISPLAY: every child gets DISPLAY replaced with X.Display and
// xclip is also passed -display. adr0004 keeps two X servers live, and a
// shell that starts the agent may carry the other session's DISPLAY, a
// dead one, or a test's Xvfb (the clip-sync.sh contract).
//
// Every selection read runs under a context deadline (X.Timeout, default
// 1 s): a hung owner costs one bounded call. clipnotify is not bounded —
// blocking until the next change is its job — but it dies with its ctx.
//
// Payload bytes only ever pass through xclip's stdin and stdout pipes and
// memory. They are never written to a file, and errors carry the target and
// exit class only, never output: xclip's stderr is discarded.
//
// Publish is the one write, used by `clipd pick` (Task 5). xclip forks before
// it owns the selection, so its exit 0 is not yet a paste that works: Publish
// reads both selections back until they serve the bytes, under one deadline.
package xsel

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	DefaultTimeout = time.Second
	// DefaultPublishTimeout bounds one whole Publish: both xclip feeds (up
	// to the 8 MiB cap) and the read-back.
	DefaultPublishTimeout = 5 * time.Second
	DefaultSettlePoll     = 50 * time.Millisecond

	TargetPNG  = "image/png"
	TargetUTF8 = "UTF8_STRING"
)

// Hints are the password-manager markers, in both spellings seen in the
// wild (clip-store.sh carries the same pair).
var Hints = []string{"application/x-kde-passwordManagerHint", "x-kde-passwordManagerHint"}

var (
	ErrTimeout  = errors.New("xsel: selection read timed out")
	ErrTooLarge = errors.New("xsel: selection over size limit")
	ErrNoOwner  = errors.New("xsel: selection read failed")
	ErrCanceled = errors.New("xsel: selection read cancelled")
	// ErrNotServed: xclip accepted the bytes but the display never served
	// them back before the deadline. The selections are indeterminate.
	ErrNotServed = errors.New("xsel: selection not served back")
)

// Runner runs one external command. Output returns at most limit bytes of
// stdout, or ErrTooLarge if there were more; limit 0 means discard stdout.
// The env is the complete child environment.
type Runner interface {
	Output(ctx context.Context, env []string, limit int, name string, args ...string) ([]byte, error)
}

// Feeder runs one command with stdin holding the given bytes and returns
// when that process exits, even if a child it backgrounded lives on.
type Feeder interface {
	Feed(ctx context.Context, env []string, stdin []byte, name string, args ...string) error
}

type X struct {
	Display        string
	Timeout        time.Duration // per selection read; 0 = DefaultTimeout
	PublishTimeout time.Duration // one whole Publish; 0 = DefaultPublishTimeout
	SettlePoll     time.Duration // read-back interval; 0 = DefaultSettlePoll
	Xclip          string        // default "xclip"
	Clipnotify     string        // default "clipnotify"
	Runner         Runner        // default ExecRunner
	Feeder         Feeder        // default ExecRunner
}

func (x *X) timeout() time.Duration {
	if x.Timeout > 0 {
		return x.Timeout
	}
	return DefaultTimeout
}

func (x *X) runner() Runner {
	if x.Runner != nil {
		return x.Runner
	}
	return ExecRunner{}
}

func orDefault(s, d string) string {
	if s != "" {
		return s
	}
	return d
}

// Env is os.Environ with DISPLAY replaced by x.Display.
func (x *X) Env() []string {
	var env []string
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "DISPLAY=") {
			env = append(env, kv)
		}
	}
	return append(env, "DISPLAY="+x.Display)
}

func (x *X) read(parent context.Context, selection, target string, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(parent, x.timeout())
	defer cancel()
	out, err := x.runner().Output(ctx, x.Env(), limit, orDefault(x.Xclip, "xclip"),
		"-display", x.Display, "-selection", selection, "-t", target, "-o")
	if parent.Err() != nil {
		// The caller gave up on this read (a newer copy superseded it):
		// whatever it returned is stale.
		clear(out)
		return nil, fmt.Errorf("%w: %s", ErrCanceled, target)
	}
	switch {
	case err == nil:
		return out, nil
	case errors.Is(err, ErrTooLarge):
		return nil, fmt.Errorf("%w: %s", ErrTooLarge, target)
	case ctx.Err() != nil:
		return nil, fmt.Errorf("%w: %s after %v", ErrTimeout, target, x.timeout())
	default:
		return nil, fmt.Errorf("%w: %s", ErrNoOwner, target)
	}
}

// Targets returns the MIME targets the CLIPBOARD owner advertises. For a
// password-manager copy this is the only thing ever read.
func (x *X) Targets(ctx context.Context) ([]string, error) {
	out, err := x.read(ctx, "clipboard", "TARGETS", 64<<10)
	if err != nil {
		return nil, err
	}
	var ts []string
	for _, l := range strings.Split(string(out), "\n") {
		if l = strings.TrimSpace(l); l != "" {
			ts = append(ts, l)
		}
	}
	return ts, nil
}

// Read returns the CLIPBOARD converted to target, at most limit bytes.
func (x *X) Read(ctx context.Context, target string, limit int) ([]byte, error) {
	if limit <= 0 {
		return nil, fmt.Errorf("%w: limit %d", ErrTooLarge, limit)
	}
	return x.read(ctx, "clipboard", target, limit)
}

// Publish puts data on CLIPBOARD and PRIMARY as target and returns once both
// serve it back. Any error may leave either selection changed.
func (x *X) Publish(parent context.Context, target string, data []byte) error {
	limit := x.PublishTimeout
	if limit <= 0 {
		limit = DefaultPublishTimeout
	}
	ctx, cancel := context.WithTimeout(parent, limit)
	defer cancel()
	var feeder Feeder = ExecRunner{}
	if x.Feeder != nil {
		feeder = x.Feeder
	}
	selections := []string{"clipboard", "primary"}
	for _, sel := range selections {
		err := feeder.Feed(ctx, x.Env(), data, orDefault(x.Xclip, "xclip"),
			"-display", x.Display, "-selection", sel, "-t", target, "-i")
		if err != nil {
			return fmt.Errorf("xsel: publish %s on %s: %w", sel, x.Display, err)
		}
	}
	poll := x.SettlePoll
	if poll <= 0 {
		poll = DefaultSettlePoll
	}
	for {
		for len(selections) > 0 && x.serves(ctx, selections[0], target, data) {
			selections = selections[1:]
		}
		if len(selections) == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("%w: %s on %s", ErrNotServed, selections[0], x.Display)
		case <-time.After(poll):
		}
	}
}

func (x *X) serves(ctx context.Context, selection, target string, data []byte) bool {
	out, err := x.read(ctx, selection, target, len(data))
	defer clear(out)
	return err == nil && bytes.Equal(out, data)
}

// Wait blocks until the next CLIPBOARD change (clipnotify exits 0) or ctx
// ends. A non-nil error with ctx still live means clipnotify failed —
// usually the display is gone.
func (x *X) Wait(ctx context.Context) error {
	_, err := x.runner().Output(ctx, x.Env(), 0, orDefault(x.Clipnotify, "clipnotify"), "-s", "clipboard")
	if err != nil && ctx.Err() == nil {
		return fmt.Errorf("xsel: clipnotify on %s: %w", x.Display, err)
	}
	return err
}

// Hinted reports whether targets carry a password-manager marker.
func Hinted(targets []string) bool {
	for _, t := range targets {
		for _, h := range Hints {
			if t == h {
				return true
			}
		}
	}
	return false
}

// Choose picks the one target worth reading: image/png when advertised,
// else UTF8_STRING. Anything else (image/bmp-only owners, STRING-only
// legacy owners) is not offered: xclip answers any target with whatever
// the owner serves, so reading an unadvertised target would launder an
// image into "text" (xclip-serves-any-target).
func Choose(targets []string) (string, bool) {
	has := func(want string) bool {
		for _, t := range targets {
			if t == want {
				return true
			}
		}
		return false
	}
	switch {
	case has(TargetPNG):
		return TargetPNG, true
	case has(TargetUTF8):
		return TargetUTF8, true
	}
	return "", false
}

// ExecRunner runs real processes. stderr is discarded (it may echo
// selection content in some xclip builds' error paths); WaitDelay stops a
// leaked pipe from outliving the deadline.
type ExecRunner struct{}

// Feed leaves stdout and stderr on /dev/null: xclip's backgrounded child
// inherits them, and a pipe there would hold Wait open until it exits.
func (ExecRunner) Feed(ctx context.Context, env []string, stdin []byte, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(stdin)
	cmd.WaitDelay = 200 * time.Millisecond
	return cmd.Run()
}

func (ExecRunner) Output(ctx context.Context, env []string, limit int, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = env
	cmd.WaitDelay = 200 * time.Millisecond
	if limit == 0 {
		return nil, cmd.Run()
	}
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	_, rerr := io.Copy(&buf, io.LimitReader(pipe, int64(limit)+1))
	if buf.Len() > limit {
		cmd.Process.Kill()
		cmd.Wait()
		clear(buf.Bytes())
		return nil, ErrTooLarge
	}
	if werr := cmd.Wait(); werr != nil {
		clear(buf.Bytes())
		return nil, werr
	}
	if rerr != nil {
		return nil, rerr
	}
	return buf.Bytes(), nil
}
