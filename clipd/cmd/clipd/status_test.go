package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"filippo.io/age"

	"clipd/internal/crypt"
	"clipd/internal/entry"
	"clipd/internal/store"
)

const stKey = "cli-test-api-key-123"

// statusRig: identity + one pinned peer, a folder with both heartbeats,
// and a fake Syncthing REST endpoint showing the peer connected.
func statusRig(t *testing.T) (cfg string) {
	t.Helper()
	cfg = t.TempDir()
	if _, err := crypt.Keygen(filepath.Join(cfg, "identity.txt")); err != nil {
		t.Fatal(err)
	}
	self, err := crypt.LoadIdentity(filepath.Join(cfg, "identity.txt"))
	if err != nil {
		t.Fatal(err)
	}
	peer, _ := age.GenerateX25519Identity()
	if err := crypt.AddRecipient(filepath.Join(cfg, "recipients.txt"), peer.Recipient().String()); err != nil {
		t.Fatal(err)
	}
	folder := t.TempDir()
	for _, w := range []*store.Store{
		{Dir: folder, Origin: "me", Self: self, Cap: entry.DefaultCap},
		{Dir: folder, Origin: "phone", Self: peer, Peers: []*age.X25519Recipient{self.Recipient()}, Cap: entry.DefaultCap},
	} {
		if err := w.WriteHeartbeat(); err != nil {
			t.Fatal(err)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-API-Key") != stKey {
			http.Error(w, "forbidden", 403)
			return
		}
		v := map[string]any{
			"/rest/system/status":        map[string]any{"myID": "SELF"},
			"/rest/config/folders/clipd": map[string]any{"devices": []map[string]any{{"deviceID": "SELF"}, {"deviceID": "PHONE"}}},
			"/rest/config/devices":       []map[string]any{{"deviceID": "PHONE", "name": "phone"}},
			"/rest/system/connections":   map[string]any{"connections": map[string]any{"PHONE": map[string]any{"connected": true}}},
		}[r.URL.Path]
		if v == nil {
			http.NotFound(w, r)
			return
		}
		json.NewEncoder(w).Encode(v)
	}))
	t.Cleanup(srv.Close)
	xml := filepath.Join(t.TempDir(), "config.xml")
	os.WriteFile(xml, []byte(`<configuration><gui tls="false"><address>`+
		strings.TrimPrefix(srv.URL, "http://")+`</address><apikey>`+stKey+`</apikey></gui></configuration>`), 0o600)
	t.Setenv("CLIPD_FOLDER", folder)
	t.Setenv("CLIPD_DEVICE", "me")
	t.Setenv("CLIPD_SYNCTHING_CONFIG", xml)
	return cfg
}

func TestStatusCLIOK(t *testing.T) {
	cfg := statusRig(t)
	code, out, errOut := runCLI(t, cfg, "status")
	if code != 0 || !strings.Contains(out, "status: ok") || !strings.Contains(out, "connected") {
		t.Fatalf("exit %d\nout:\n%s\nerr: %s", code, out, errOut)
	}
	if strings.Contains(out+errOut, stKey) {
		t.Fatal("api key printed")
	}
}

func TestStatusCLISyncthingDown(t *testing.T) {
	cfg := statusRig(t)
	t.Setenv("CLIPD_SYNCTHING_CONFIG", filepath.Join(t.TempDir(), "absent.xml"))
	code, out, _ := runCLI(t, cfg, "status")
	if code != 4 || !strings.Contains(out, "phone") || !strings.Contains(out, "syncthing: unreachable") {
		t.Fatalf("exit %d\n%s", code, out)
	}
}

func TestStatusCLIOwnAgentSilent(t *testing.T) {
	cfg := statusRig(t)
	os.Remove(filepath.Join(os.Getenv("CLIPD_FOLDER"), "hb-me.age"))
	code, out, _ := runCLI(t, cfg, "status")
	if code != 3 || !strings.Contains(out, "never") {
		t.Fatalf("exit %d\n%s", code, out)
	}
}

func TestStatusCLINoIdentity(t *testing.T) {
	if code, _, _ := runCLI(t, t.TempDir(), "status"); code != exitConfig {
		t.Fatalf("exit %d", code)
	}
}
