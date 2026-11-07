package status

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

var now = time.UnixMilli(1762160000000)

func ago(d time.Duration) time.Time { return now.Add(-d) }

func row(t *testing.T, r Report, name string) Row {
	t.Helper()
	for _, x := range r.Rows {
		if x.Name == name {
			return x
		}
	}
	t.Fatalf("no row %q in %+v", name, r.Rows)
	return Row{}
}

func TestStaleThreshold(t *testing.T) {
	for _, c := range []struct {
		age   time.Duration
		stale bool
	}{{0, false}, {89 * time.Second, false}, {90 * time.Second, false}, {91 * time.Second, true}, {time.Hour, true}} {
		r := Evaluate(Input{
			Self:       "me",
			Heartbeats: map[string]time.Time{"me": now, "peer": ago(c.age)},
			Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
			Now:        now,
		})
		p := row(t, r, "peer")
		if p.Stale != c.stale || !p.Seen || p.Age != c.age {
			t.Errorf("age %v: row %+v", c.age, p)
		}
		want := ExitOK
		if c.stale {
			want = ExitStale
		}
		if r.Exit != want {
			t.Errorf("age %v: exit %d want %d", c.age, r.Exit, want)
		}
	}
}

func TestNeverSeenIsStale(t *testing.T) {
	r := Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now},
		Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: false}},
		Now:        now,
	})
	p := row(t, r, "peer")
	if p.Seen || !p.Stale || r.Exit != ExitStale {
		t.Fatalf("row %+v exit %d", p, r.Exit)
	}
	var b bytes.Buffer
	r.Write(&b)
	if !strings.Contains(b.String(), "never") {
		t.Fatalf("output lacks never:\n%s", b.String())
	}
}

// A pinned recipient that no Syncthing device name or heartbeat accounts
// for is still a peer we expect to hear from.
func TestUnnamedPinnedPeerIsNeverSeen(t *testing.T) {
	r := Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now, "peer": now},
		Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
		Pinned:     3,
		Now:        now,
	})
	if r.Unnamed != 2 || r.Exit != ExitStale {
		t.Fatalf("unnamed %d exit %d", r.Unnamed, r.Exit)
	}
	r = Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now, "peer": now},
		Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
		Pinned:     1,
		Now:        now,
	})
	if r.Unnamed != 0 || r.Exit != ExitOK {
		t.Fatalf("unnamed %d exit %d", r.Unnamed, r.Exit)
	}
}

// adr0017: the Syncthing link is a third party's evidence. A connected
// link with no heartbeat from the peer, or no fresh beat of our own,
// is not ok.
func TestLinkUpButNoHeartbeatIsNotOK(t *testing.T) {
	r := Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now},
		Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
		Now:        now,
	})
	if r.Exit == ExitOK || !row(t, r, "peer").Stale {
		t.Fatalf("peer link up, no beat: exit %d", r.Exit)
	}
	r = Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"peer": now},
		Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
		Now:        now,
	})
	if r.Exit == ExitOK || !row(t, r, "me").Stale {
		t.Fatalf("own beat missing: exit %d", r.Exit)
	}
	var b bytes.Buffer
	r.Write(&b)
	if strings.Contains(b.String(), "status: ok") {
		t.Fatalf("reported ok:\n%s", b.String())
	}
}

func TestHeartbeatFromUnlistedOriginShown(t *testing.T) {
	r := Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now, "laptop": ago(10 * time.Second)},
		Now:        now,
	})
	if l := row(t, r, "laptop"); !l.Seen || l.Stale || l.Link != "not in folder" {
		t.Fatalf("row %+v", l)
	}
}

// --- Syncthing REST ---------------------------------------------------

const key = "s3cr3t-api-key-XYZ"

func fakeSyncthing(t *testing.T) *httptest.Server {
	t.Helper()
	routes := map[string]any{
		"/rest/system/status": map[string]any{"myID": "SELF"},
		"/rest/config/folders/clipd": map[string]any{"id": "clipd", "devices": []map[string]any{
			{"deviceID": "SELF"}, {"deviceID": "PEER-A"}, {"deviceID": "PEER-B-LONGID"},
		}},
		"/rest/config/devices": []map[string]any{
			{"deviceID": "SELF", "name": "me"}, {"deviceID": "PEER-A", "name": "nothing"},
			{"deviceID": "PEER-B-LONGID", "name": ""}, {"deviceID": "OTHER", "name": "unrelated"},
		},
		"/rest/system/connections": map[string]any{"connections": map[string]any{
			"PEER-A": map[string]any{"connected": true}, "PEER-B-LONGID": map[string]any{"connected": false},
		}},
	}
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-Key") != key {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		v, ok := routes[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(v)
	}))
}

func TestLinksFromREST(t *testing.T) {
	srv := fakeSyncthing(t)
	defer srv.Close()
	links, err := Syncthing{BaseURL: srv.URL, APIKey: key, FolderID: "clipd"}.Links(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := []Link{{DeviceID: "PEER-A", Name: "nothing", Connected: true}, {DeviceID: "PEER-B-LONGID", Name: "PEER-B-", Connected: false}}
	if len(links) != 2 || links[0] != want[0] || links[1] != want[1] {
		t.Fatalf("links %+v", links)
	}
}

func TestSyncthingDownExit4(t *testing.T) {
	srv := fakeSyncthing(t)
	url := srv.URL
	srv.Close()
	_, err := Syncthing{BaseURL: url, APIKey: key, FolderID: "clipd"}.Links(context.Background())
	if err == nil {
		t.Fatal("stopped server answered")
	}
	if strings.Contains(err.Error(), key) {
		t.Fatal("api key in error")
	}
	r := Evaluate(Input{
		Self:       "me",
		Heartbeats: map[string]time.Time{"me": now, "peer": now},
		LinkErr:    err,
		Now:        now,
	})
	if r.Exit != ExitSyncthingDown {
		t.Fatalf("exit %d", r.Exit)
	}
	if p := row(t, r, "peer"); !p.Seen || p.Link != "unknown" {
		t.Fatalf("heartbeat info lost: %+v", p)
	}
	var b bytes.Buffer
	r.Write(&b)
	if !strings.Contains(b.String(), "syncthing: unreachable") || strings.Contains(b.String(), key) {
		t.Fatalf("output:\n%s", b.String())
	}
}

func TestWrongKeyIsUnreachableWithoutKeyLeak(t *testing.T) {
	srv := fakeSyncthing(t)
	defer srv.Close()
	_, err := Syncthing{BaseURL: srv.URL, APIKey: "wrong-" + key, FolderID: "clipd"}.Links(context.Background())
	if err == nil || strings.Contains(err.Error(), key) || !strings.Contains(err.Error(), "403") {
		t.Fatalf("err %v", err)
	}
}

func TestFolderNotConfigured(t *testing.T) {
	srv := fakeSyncthing(t)
	defer srv.Close()
	_, err := Syncthing{BaseURL: srv.URL, APIKey: key, FolderID: "nope"}.Links(context.Background())
	if err == nil || !strings.Contains(err.Error(), "/rest/config/folders/nope") {
		t.Fatalf("err %v", err)
	}
}

func TestLinksTimeoutBounded(t *testing.T) {
	block := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-block }))
	defer srv.Close()
	defer close(block)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := Syncthing{BaseURL: srv.URL, APIKey: key, FolderID: "clipd"}.Links(ctx)
	if err == nil || time.Since(start) > 2*time.Second {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
}

// --- config.xml -------------------------------------------------------

func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "config.xml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestReadConfig(t *testing.T) {
	for _, c := range []struct{ gui, url string }{
		{`<gui enabled="true" tls="false"><address>127.0.0.1:8384</address><apikey>` + key + `</apikey></gui>`, "http://127.0.0.1:8384"},
		{`<gui tls="true"><address>0.0.0.0:8385</address><apikey>` + key + `</apikey></gui>`, "https://127.0.0.1:8385"},
		{`<gui><address>[::]:8386</address><apikey>` + key + `</apikey></gui>`, "http://[::1]:8386"},
	} {
		p := writeConfig(t, `<configuration version="37"><folder id="x"></folder>`+c.gui+`</configuration>`)
		st, err := ReadConfig(p)
		if err != nil {
			t.Fatal(err)
		}
		if st.BaseURL != c.url || st.APIKey != key {
			t.Errorf("%s: got %s", c.gui, st.BaseURL)
		}
	}
}

func TestReadConfigErrorsHideKey(t *testing.T) {
	for _, body := range []string{
		`<configuration><gui><address>127.0.0.1:8384</address></gui></configuration>`,
		`<configuration><gui><address>unix:///run/st.sock</address><apikey>` + key + `</apikey></gui></configuration>`,
		`<configuration><gui><apikey>` + key + `</apikey><address>`,
	} {
		_, err := ReadConfig(writeConfig(t, body))
		if err == nil || strings.Contains(err.Error(), key) {
			t.Errorf("body %q: err %v", body, err)
		}
	}
	if _, err := ReadConfig(filepath.Join(t.TempDir(), "missing.xml")); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("missing: %v", err)
	}
}

// A beat dated in the future is not evidence of recent life: a writer
// with a clock a day ahead would otherwise read fresh for a day after
// its agent died. Up to SkewTolerance ahead is ordinary skew.
func TestFutureHeartbeatIsNotFresh(t *testing.T) {
	for _, c := range []struct {
		name  string
		ahead time.Duration
		fresh bool
	}{{"peer", 30 * time.Second, true}, {"peer", 60 * time.Second, true}, {"peer", 61 * time.Second, false},
		{"peer", 24 * time.Hour, false}, {"me", 24 * time.Hour, false}} {
		hbs := map[string]time.Time{"me": now, "peer": now}
		hbs[c.name] = now.Add(c.ahead)
		r := Evaluate(Input{
			Self:       "me",
			Heartbeats: hbs,
			Links:      []Link{{DeviceID: "PEER", Name: "peer", Connected: true}},
			Now:        now,
		})
		x := row(t, r, c.name)
		want := ExitOK
		if !c.fresh {
			want = ExitStale
		}
		if x.Stale == c.fresh || r.Exit != want {
			t.Errorf("%s ahead %v: row %+v exit %d", c.name, c.ahead, x, r.Exit)
		}
		var b bytes.Buffer
		r.Write(&b)
		if !c.fresh && (!strings.Contains(b.String(), "clock ahead") || strings.Contains(b.String(), "status: ok")) {
			t.Errorf("%s ahead %v: output\n%s", c.name, c.ahead, b.String())
		}
	}
}

// sp039 T9: clipd runs its own Syncthing (home $XDG_STATE_HOME/clipd/syncthing)
// beside any instance the user already has. Status must read that one and
// never fall back to the user's own, whose link state says nothing about clipd.
func TestConfigPathsPointAtDedicatedInstance(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("linux layout")
	}
	state := t.TempDir()
	t.Setenv("XDG_STATE_HOME", state)
	got := ConfigPaths()
	want := []string{filepath.Join(state, "clipd", "syncthing", "config.xml")}
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Fatalf("ConfigPaths %v, want %v", got, want)
	}
	t.Setenv("XDG_STATE_HOME", "")
	home, _ := os.UserHomeDir()
	if got := ConfigPaths(); len(got) != 1 || got[0] != filepath.Join(home, ".local", "state", "clipd", "syncthing", "config.xml") {
		t.Fatalf("default ConfigPaths %v", got)
	}
}
