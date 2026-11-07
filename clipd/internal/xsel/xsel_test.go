package xsel

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

type call struct {
	env  []string
	name string
	args []string
}

type recRunner struct {
	mu    sync.Mutex
	calls []call
	out   []byte
	err   error
	block bool
}

func (r *recRunner) Output(ctx context.Context, env []string, limit int, name string, args ...string) ([]byte, error) {
	r.mu.Lock()
	r.calls = append(r.calls, call{env, name, args})
	r.mu.Unlock()
	if r.block {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	return r.out, r.err
}

func TestEnvReplacesInheritedDisplay(t *testing.T) {
	t.Setenv("DISPLAY", ":77")
	r := &recRunner{out: []byte("TARGETS\nUTF8_STRING\n")}
	x := &X{Display: ":93", Runner: r}
	if _, err := x.Targets(context.Background()); err != nil {
		t.Fatal(err)
	}
	c := r.calls[0]
	var disp []string
	for _, kv := range c.env {
		if strings.HasPrefix(kv, "DISPLAY=") {
			disp = append(disp, kv)
		}
	}
	if !reflect.DeepEqual(disp, []string{"DISPLAY=:93"}) {
		t.Fatalf("child DISPLAY entries %v", disp)
	}
	want := []string{"-display", ":93", "-selection", "clipboard", "-t", "TARGETS", "-o"}
	if c.name != "xclip" || !reflect.DeepEqual(c.args, want) {
		t.Fatalf("call %s %v", c.name, c.args)
	}
}

func TestWaitUsesDisplayToo(t *testing.T) {
	t.Setenv("DISPLAY", ":77")
	r := &recRunner{}
	x := &X{Display: ":93", Runner: r}
	if err := x.Wait(context.Background()); err != nil {
		t.Fatal(err)
	}
	c := r.calls[0]
	if c.name != "clipnotify" || !reflect.DeepEqual(c.args, []string{"-s", "clipboard"}) || c.env[len(c.env)-1] != "DISPLAY=:93" {
		t.Fatalf("call %+v", c)
	}
}

func TestTargetsParse(t *testing.T) {
	x := &X{Display: ":1", Runner: &recRunner{out: []byte("TARGETS\r\n image/png \n\nUTF8_STRING")}}
	ts, err := x.Targets(context.Background())
	if err != nil || !reflect.DeepEqual(ts, []string{"TARGETS", "image/png", "UTF8_STRING"}) {
		t.Fatalf("%v %v", ts, err)
	}
}

func TestReadTimeoutBounded(t *testing.T) {
	x := &X{Display: ":1", Timeout: 50 * time.Millisecond, Runner: &recRunner{block: true}}
	start := time.Now()
	_, err := x.Targets(context.Background())
	if !errors.Is(err, ErrTimeout) {
		t.Fatalf("err %v", err)
	}
	if d := time.Since(start); d > 3*time.Second { // unbounded = blocks forever
		t.Fatalf("took %v", d)
	}
}

func TestReadErrorCarriesNoOutput(t *testing.T) {
	x := &X{Display: ":1", Runner: &recRunner{out: []byte("hunter2"), err: errors.New("exit status 1: hunter2")}}
	_, err := x.Read(context.Background(), TargetUTF8, 100)
	if !errors.Is(err, ErrNoOwner) || strings.Contains(err.Error(), "hunter2") {
		t.Fatalf("err %v", err)
	}
}

func TestHintedBothSpellings(t *testing.T) {
	for _, h := range Hints {
		if !Hinted([]string{"UTF8_STRING", h}) {
			t.Fatalf("%s not detected", h)
		}
	}
	if Hinted([]string{"UTF8_STRING", "text/plain", "x-kde-passwordManagerHintX"}) {
		t.Fatal("false positive")
	}
}

func TestChoose(t *testing.T) {
	cases := []struct {
		ts   []string
		want string
		ok   bool
	}{
		{[]string{"UTF8_STRING", "image/png"}, TargetPNG, true},
		{[]string{"TARGETS", "UTF8_STRING", "STRING"}, TargetUTF8, true},
		{[]string{"TARGETS", "image/bmp"}, "", false},
		{[]string{"STRING"}, "", false},
		{nil, "", false},
	}
	for _, c := range cases {
		got, ok := Choose(c.ts)
		if got != c.want || ok != c.ok {
			t.Errorf("Choose(%v) = %q %v", c.ts, got, ok)
		}
	}
}

func TestExecRunnerLimit(t *testing.T) {
	ctx := context.Background()
	out, err := ExecRunner{}.Output(ctx, nil, 5, "sh", "-c", "printf 12345")
	if err != nil || string(out) != "12345" {
		t.Fatalf("at limit: %q %v", out, err)
	}
	if _, err := (ExecRunner{}).Output(ctx, nil, 5, "sh", "-c", "printf 123456"); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("over limit: %v", err)
	}
	// binary-safe: NUL and CR survive
	out, err = ExecRunner{}.Output(ctx, nil, 10, "sh", "-c", `printf 'a\000b\r\n'`)
	if err != nil || string(out) != "a\x00b\r\n" {
		t.Fatalf("binary: %q %v", out, err)
	}
}

func TestExecRunnerTimeoutKills(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := ExecRunner{}.Output(ctx, nil, 10, "sleep", "5")
	if err == nil {
		t.Fatal("want error")
	}
	if d := time.Since(start); d > 3*time.Second { // sleep 5 not killed = 5 s
		t.Fatalf("hung %v", d)
	}
}

func TestReadCancelledByCaller(t *testing.T) {
	x := &X{Display: ":1", Timeout: time.Second, Runner: &recRunner{block: true}}
	ctx, cancel := context.WithCancel(context.Background())
	go func() { time.Sleep(30 * time.Millisecond); cancel() }()
	start := time.Now()
	_, err := x.Targets(ctx)
	if !errors.Is(err, ErrCanceled) || errors.Is(err, ErrTimeout) {
		t.Fatalf("err %v", err)
	}
	if d := time.Since(start); d > 3*time.Second { // not cancelled = blocks forever
		t.Fatalf("cancel took %v", d)
	}
	// a result that raced in after cancel is still discarded
	ctx2, cancel2 := context.WithCancel(context.Background())
	cancel2()
	if out, err := (&X{Display: ":1", Runner: &recRunner{out: []byte("stale")}}).Read(ctx2, TargetUTF8, 10); out != nil || !errors.Is(err, ErrCanceled) {
		t.Fatalf("after cancel: %q %v", out, err)
	}
}

type runnerFunc func(args []string) ([]byte, error)

func (f runnerFunc) Output(_ context.Context, _ []string, _ int, _ string, args ...string) ([]byte, error) {
	return f(args)
}

type feed struct {
	env   []string
	name  string
	args  []string
	stdin []byte
}

type recFeeder struct {
	feeds []feed
	err   error
}

func (r *recFeeder) Feed(_ context.Context, env []string, stdin []byte, name string, args ...string) error {
	r.feeds = append(r.feeds, feed{env, name, args, append([]byte(nil), stdin...)})
	return r.err
}

func selectionOf(args []string) string {
	for i, a := range args {
		if a == "-selection" {
			return args[i+1]
		}
	}
	return ""
}

func TestPublishFeedsBothSelectionsOnStdin(t *testing.T) {
	t.Setenv("DISPLAY", ":77")
	payload := []byte("a\x00b\r\nžluť\n")
	f := &recFeeder{}
	x := &X{Display: ":93", Feeder: f, Runner: runnerFunc(func([]string) ([]byte, error) { return bytes.Clone(payload), nil })}
	if err := x.Publish(context.Background(), TargetUTF8, payload); err != nil {
		t.Fatal(err)
	}
	if len(f.feeds) != 2 {
		t.Fatalf("feeds %d, want 2", len(f.feeds))
	}
	for i, sel := range []string{"clipboard", "primary"} {
		c := f.feeds[i]
		want := []string{"-display", ":93", "-selection", sel, "-t", TargetUTF8, "-i"}
		if c.name != "xclip" || !reflect.DeepEqual(c.args, want) {
			t.Fatalf("feed %d: %s %v", i, c.name, c.args)
		}
		if string(c.stdin) != string(payload) {
			t.Fatalf("feed %d stdin %q", i, c.stdin)
		}
		for _, kv := range c.env {
			if kv == "DISPLAY=:77" {
				t.Fatal("inherited DISPLAY reached xclip")
			}
		}
	}
}

// xclip forks before it owns the selection: exit 0 is not yet a paste that
// works, so Publish keeps reading until the display serves the bytes back.
func TestPublishWaitsUntilServedBack(t *testing.T) {
	reads := 0
	x := &X{Display: ":93", Feeder: &recFeeder{}, SettlePoll: time.Millisecond,
		Runner: runnerFunc(func([]string) ([]byte, error) {
			reads++
			if reads <= 3 {
				return []byte("stale"), nil
			}
			return []byte("fresh"), nil
		})}
	if err := x.Publish(context.Background(), TargetUTF8, []byte("fresh")); err != nil {
		t.Fatal(err)
	}
	if reads < 5 { // 3 stale + clipboard + primary
		t.Fatalf("reads %d: returned before both selections served it", reads)
	}
}

func TestPublishChecksPrimaryToo(t *testing.T) {
	x := &X{Display: ":93", Feeder: &recFeeder{}, SettlePoll: time.Millisecond, PublishTimeout: 50 * time.Millisecond,
		Runner: runnerFunc(func(args []string) ([]byte, error) {
			if selectionOf(args) == "primary" {
				return []byte("stale"), nil
			}
			return []byte("sekret"), nil
		})}
	err := x.Publish(context.Background(), TargetUTF8, []byte("sekret"))
	if !errors.Is(err, ErrNotServed) {
		t.Fatalf("err %v, want ErrNotServed", err)
	}
	if strings.Contains(err.Error(), "sekret") {
		t.Fatalf("payload in error: %v", err)
	}
}

func TestPublishFeedFailureStops(t *testing.T) {
	f := &recFeeder{err: errors.New("exit status 1")}
	x := &X{Display: ":93", Feeder: f, Runner: runnerFunc(func([]string) ([]byte, error) {
		t.Error("read after a failed feed")
		return nil, nil
	})}
	if err := x.Publish(context.Background(), TargetUTF8, []byte("sekret")); err == nil || strings.Contains(err.Error(), "sekret") {
		t.Fatalf("err %v", err)
	}
	if len(f.feeds) != 1 {
		t.Fatalf("feeds %d after CLIPBOARD failed", len(f.feeds))
	}
}

// A real xclip backgrounds itself and keeps serving. Feed must return when
// the parent exits, not when the daemon does, and must deliver stdin.
func TestFeedReturnsWhileDaemonLives(t *testing.T) {
	dir := t.TempDir()
	got := filepath.Join(dir, "got")
	script := "cat >" + got + "; sleep 30 & echo noise; exit 0"
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := (ExecRunner{}).Feed(ctx, os.Environ(), []byte("in\x00put"), "sh", "-c", script); err != nil {
		t.Fatal(err)
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("Feed waited %v for the backgrounded child", d)
	}
	b, err := os.ReadFile(got)
	if err != nil || string(b) != "in\x00put" {
		t.Fatalf("stdin %q %v", b, err)
	}
}

func TestFeedFailureIsAnError(t *testing.T) {
	if err := (ExecRunner{}).Feed(context.Background(), os.Environ(), nil, "sh", "-c", "exit 3"); err == nil {
		t.Fatal("want error")
	}
}
