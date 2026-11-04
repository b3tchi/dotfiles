package xsel

import (
	"context"
	"errors"
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
	if d := time.Since(start); d > 500*time.Millisecond {
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
	if d := time.Since(start); d > time.Second {
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
	if d := time.Since(start); d > 300*time.Millisecond {
		t.Fatalf("cancel took %v", d)
	}
	// a result that raced in after cancel is still discarded
	ctx2, cancel2 := context.WithCancel(context.Background())
	cancel2()
	if out, err := (&X{Display: ":1", Runner: &recRunner{out: []byte("stale")}}).Read(ctx2, TargetUTF8, 10); out != nil || !errors.Is(err, ErrCanceled) {
		t.Fatalf("after cancel: %q %v", out, err)
	}
}
