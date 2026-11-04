// Package status answers `clipd status` (sp039 Task 8): is every peer —
// this device included — still writing heartbeats, and what does the
// local Syncthing say about the folder's links.
//
// Two kinds of evidence, kept apart per [[adr0017]]:
//
//   - A heartbeat is a device's own evidence about itself: its agent
//     decrypted-and-wrote `created` recently. Freshness is judged on that
//     alone; our own beat proves *our* agent is alive.
//   - The Syncthing link is a third party's view. It is shown, and an
//     unreachable Syncthing has its own exit code, but a connected link
//     never makes a peer without a fresh beat "ok".
//
// Exit codes: 0 every peer fresh, 3 any peer stale or never seen, 4
// Syncthing unreachable (heartbeats are still shown). 4 wins over 3: a
// reader that cannot see the link cannot tell a dead peer from a cut one.
//
// Nothing here prints the API key, and heartbeats carry no payload.
package status

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"clipd/internal/store"
)

const (
	// StaleAfter: three missed 30 s beats.
	StaleAfter = 90 * time.Second

	ExitOK            = 0
	ExitStale         = 3
	ExitSyncthingDown = 4
)

// Link is one remote device sharing the folder, as Syncthing reports it.
type Link struct {
	DeviceID  string
	Name      string // Syncthing device name, or a short device-id prefix
	Connected bool
}

type Input struct {
	Self       string               // this device's origin name
	Heartbeats map[string]time.Time // origin -> decrypted created
	Links      []Link               // remote folder devices; nil when unknown
	LinkErr    error                // Syncthing probe failure, if any
	// Pinned counts locally pinned recipients other than our own. Pinned
	// peers no name accounts for are reported as unnamed and never seen.
	Pinned int
	Now    time.Time
}

type Row struct {
	Name string
	Self bool
	Seen bool
	Age  time.Duration // since the last heartbeat's created; 0 if unseen
	// Ahead is how far the beat's created lies in our future, set only
	// past store.SkewTolerance; such a beat is stale, not fresh.
	Ahead time.Duration
	Stale bool
	Link  string // connected | disconnected | unknown | not in folder | self
}

type Report struct {
	Rows      []Row
	Unnamed   int    // pinned peers with no name and no heartbeat
	LinkError string // which Syncthing probe failed, key-free
	Exit      int
}

func judge(name string, hbs map[string]time.Time, now time.Time) Row {
	r := Row{Name: name, Stale: true}
	if c, ok := hbs[name]; ok {
		r.Seen = true
		r.Age = now.Sub(c)
		switch {
		case r.Age < -store.SkewTolerance:
			// A future-dated beat proves nothing about now: a clock a day
			// ahead would read fresh for a day after its agent died.
			r.Ahead, r.Age = -r.Age, 0
		case r.Age < 0:
			r.Age = 0 // ordinary skew
		}
		r.Stale = r.Ahead > 0 || r.Age > StaleAfter
	}
	return r
}

// Evaluate turns the evidence into rows and an exit code.
func Evaluate(in Input) Report {
	var rep Report
	self := judge(in.Self, in.Heartbeats, in.Now)
	self.Self, self.Link = true, "self"
	rep.Rows = append(rep.Rows, self)

	named := map[string]bool{in.Self: true}
	for _, l := range in.Links {
		if named[l.Name] {
			continue
		}
		named[l.Name] = true
		r := judge(l.Name, in.Heartbeats, in.Now)
		r.Link = "disconnected"
		if l.Connected {
			r.Link = "connected"
		}
		rep.Rows = append(rep.Rows, r)
	}
	var extra []string
	for o := range in.Heartbeats {
		if !named[o] {
			extra = append(extra, o)
		}
	}
	sort.Strings(extra)
	for _, o := range extra {
		r := judge(o, in.Heartbeats, in.Now)
		r.Link = "not in folder"
		if in.LinkErr != nil {
			r.Link = "unknown"
		}
		rep.Rows = append(rep.Rows, r)
	}
	if peers := len(rep.Rows) - 1; in.Pinned > peers {
		rep.Unnamed = in.Pinned - peers
	}

	stale := rep.Unnamed > 0
	for _, r := range rep.Rows {
		stale = stale || r.Stale
	}
	switch {
	case in.LinkErr != nil:
		rep.LinkError = in.LinkErr.Error()
		rep.Exit = ExitSyncthingDown
	case stale:
		rep.Exit = ExitStale
	default:
		rep.Exit = ExitOK
	}
	return rep
}

// Write prints the report as an aligned table plus a verdict line.
func (rep Report) Write(w io.Writer) {
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "PEER\tHEARTBEAT\tSTATE\tLINK")
	for _, r := range rep.Rows {
		name, seen, state := r.Name, "never", "stale"
		if r.Self {
			name += " (self)"
		}
		if r.Seen {
			seen = r.Age.Truncate(time.Second).String() + " ago"
		}
		if r.Ahead > 0 {
			seen = r.Ahead.Truncate(time.Second).String() + " in future"
			state = "stale (clock ahead)"
		}
		if !r.Stale {
			state = "fresh"
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\n", name, seen, state, r.Link)
	}
	if rep.Unnamed > 0 {
		fmt.Fprintf(tw, "%d unnamed pinned peer(s)\tnever\tstale\tunknown\n", rep.Unnamed)
	}
	tw.Flush()
	if rep.LinkError != "" {
		fmt.Fprintf(w, "syncthing: unreachable (%s)\n", rep.LinkError)
	}
	switch rep.Exit {
	case ExitOK:
		fmt.Fprintln(w, "status: ok")
	case ExitStale:
		fmt.Fprintln(w, "status: stale — a peer (or this agent) has no heartbeat within the last 90 s, or its clock runs ahead by more than 60 s")
	default:
		fmt.Fprintln(w, "status: unknown — heartbeats shown above, link state unavailable")
	}
}

// --- Syncthing REST ---------------------------------------------------

// Syncthing is the local Syncthing REST endpoint. FolderID is the clipd
// folder's id.
type Syncthing struct {
	BaseURL  string
	APIKey   string
	FolderID string
	Client   *http.Client // nil = loopback client that accepts the GUI's self-signed cert
}

var loopbackClient = &http.Client{Transport: &http.Transport{
	// The GUI certificate is self-signed and the endpoint is loopback
	// (ReadConfig maps wildcard binds to it); there is no CA to verify.
	// Proxy stays nil: never route the API key through a proxy.
	TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
}}

// get fetches path into v. Errors name the probe, never the key or body.
func (s Syncthing) get(ctx context.Context, path string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.BaseURL+path, nil)
	if err != nil {
		return fmt.Errorf("GET %s: bad url", path)
	}
	req.Header.Set("X-API-Key", s.APIKey)
	c := s.Client
	if c == nil {
		c = loopbackClient
	}
	resp, err := c.Do(req)
	if err != nil {
		var ue *url.Error
		if errors.As(err, &ue) {
			err = ue.Err
		}
		return fmt.Errorf("GET %s: %v", path, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(v); err != nil {
		return fmt.Errorf("GET %s: unparseable response", path)
	}
	return nil
}

// Links returns the folder's remote devices with their connection state.
func (s Syncthing) Links(ctx context.Context) ([]Link, error) {
	var sys struct {
		MyID string `json:"myID"`
	}
	if err := s.get(ctx, "/rest/system/status", &sys); err != nil {
		return nil, err
	}
	var folder struct {
		Devices []struct {
			DeviceID string `json:"deviceID"`
		} `json:"devices"`
	}
	if err := s.get(ctx, "/rest/config/folders/"+url.PathEscape(s.FolderID), &folder); err != nil {
		return nil, err
	}
	var devs []struct {
		DeviceID string `json:"deviceID"`
		Name     string `json:"name"`
	}
	if err := s.get(ctx, "/rest/config/devices", &devs); err != nil {
		return nil, err
	}
	var conns struct {
		Connections map[string]struct {
			Connected bool `json:"connected"`
		} `json:"connections"`
	}
	if err := s.get(ctx, "/rest/system/connections", &conns); err != nil {
		return nil, err
	}
	names := map[string]string{}
	for _, d := range devs {
		names[d.DeviceID] = d.Name
	}
	var links []Link
	for _, d := range folder.Devices {
		if d.DeviceID == sys.MyID {
			continue
		}
		name := names[d.DeviceID]
		if name == "" {
			name = d.DeviceID
			if len(name) > 7 {
				name = name[:7]
			}
		}
		links = append(links, Link{DeviceID: d.DeviceID, Name: name, Connected: conns.Connections[d.DeviceID].Connected})
	}
	return links, nil
}

// --- config.xml -------------------------------------------------------

var ErrConfig = errors.New("syncthing config")

// ReadConfig reads the GUI address and API key from Syncthing's
// config.xml. A wildcard bind is reached on loopback. Errors never quote
// the file: it holds the key.
func ReadConfig(path string) (Syncthing, error) {
	f, err := os.Open(path)
	if err != nil {
		return Syncthing{}, err
	}
	defer f.Close()
	var cfg struct {
		GUI struct {
			TLS     bool   `xml:"tls,attr"`
			Address string `xml:"address"`
			APIKey  string `xml:"apikey"`
		} `xml:"gui"`
	}
	if err := xml.NewDecoder(io.LimitReader(f, 16<<20)).Decode(&cfg); err != nil {
		return Syncthing{}, fmt.Errorf("%w: %s unparseable", ErrConfig, path)
	}
	g := cfg.GUI
	key := strings.TrimSpace(g.APIKey)
	if key == "" {
		return Syncthing{}, fmt.Errorf("%w: %s has no gui apikey", ErrConfig, path)
	}
	host, port, err := net.SplitHostPort(strings.TrimSpace(g.Address))
	if err == nil {
		_, err = strconv.ParseUint(port, 10, 16) // also refuses unix:// sockets
	}
	if err != nil {
		return Syncthing{}, fmt.Errorf("%w: %s gui address is not host:port", ErrConfig, path)
	}
	switch host {
	case "", "0.0.0.0":
		host = "127.0.0.1"
	case "::":
		host = "::1"
	}
	scheme := "http"
	if g.TLS {
		scheme = "https"
	}
	return Syncthing{BaseURL: scheme + "://" + net.JoinHostPort(host, port), APIKey: key}, nil
}

// ConfigPaths lists where Syncthing keeps config.xml on this OS, most
// recent layout first ($XDG_STATE_HOME since Syncthing 1.27).
func ConfigPaths() []string {
	var ps []string
	if runtime.GOOS == "windows" {
		if d := os.Getenv("LOCALAPPDATA"); d != "" {
			ps = append(ps, filepath.Join(d, "Syncthing", "config.xml"))
		}
		return ps
	}
	home, _ := os.UserHomeDir()
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" && home != "" {
		state = filepath.Join(home, ".local", "state")
	}
	if state != "" {
		ps = append(ps, filepath.Join(state, "syncthing", "config.xml"))
	}
	if d, err := os.UserConfigDir(); err == nil {
		ps = append(ps, filepath.Join(d, "syncthing", "config.xml"))
	}
	return ps
}

// FindConfig reads the first config.xml in paths that exists.
func FindConfig(paths []string) (Syncthing, error) {
	for _, p := range paths {
		st, err := ReadConfig(p)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		return st, err
	}
	return Syncthing{}, fmt.Errorf("%w: no config.xml in %s", ErrConfig, strings.Join(paths, ", "))
}
