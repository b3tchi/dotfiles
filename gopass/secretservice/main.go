// Minimal org.freedesktop.Secret.Service provider backed by gopass.
// Enough of the API for libsecret (secret_password_store/lookup) and MSAL.
package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"
	"github.com/godbus/dbus/v5/prop"
)

const (
	svcName   = "org.freedesktop.secrets"
	svcPath   = "/org/freedesktop/secrets"
	collPath  = "/org/freedesktop/secrets/collection/login"
	aliasPath = "/org/freedesktop/secrets/aliases/default"
	itemBase  = "/org/freedesktop/secrets/collection/login/"

	// defaultPrefix namespaces everything this daemon touches, so Secret
	// Service traffic never reaches the rest of the store.
	defaultPrefix = "secretservice"
)

// gopassDir is the store namespace items live under. Override with
// GOPASS_SECRETSERVICE_PREFIX; nested paths ("svc/secrets") are fine.
var gopassDir = defaultPrefix

// maxSecretBytes caps a single item. The MSAL cache is ~4 KiB; the cap only
// stops a misbehaving client writing unbounded data into the store.
const maxSecretBytes = 1 << 20

// defaultAllow limits which callers may store secrets here, so this daemon
// holds canvas MCP tokens and nothing else. Matched as a prefix against the
// item's "xdg:schema" attribute (libsecret's schema name), with "Product" as
// a fallback for clients that omit it. Prefix rather than exact match on
// purpose: MSAL writes a sibling schema for its own persistence self-check,
// and refusing that would silently break sign-in. Override with
// GOPASS_SECRETSERVICE_ALLOW (comma-separated prefixes); "*" allows all.
var defaultAllow = []string{"com.microsoft.powerapps.canvasmcp"}

var allowPrefixes = defaultAllow

// allowed reports whether an item's attributes match the allowlist.
func allowed(attrs map[string]string) bool {
	for _, p := range allowPrefixes {
		if p == "*" {
			return true
		}
		if s := attrs["xdg:schema"]; s != "" && strings.HasPrefix(s, p) {
			return true
		}
	}
	// Fallback for clients that set no xdg:schema.
	return attrs["Product"] == "PowerAppsCanvasMcp"
}

// defaultPeers restricts which processes may read or delete secrets. The
// Secret Service spec has no caller authentication at all, so without this
// any process running as the user could ask for the token cache and get it
// in cleartext. Matched against the basename of the caller's
// /proc/<pid>/exe. Override with GOPASS_SECRETSERVICE_PEERS (comma
// separated); "*" allows any caller, which is what secret-tool needs.
//
// This is a speed bump, not a boundary: a same-user attacker can copy the
// permitted binary, and pid-based identification races against pid reuse.
// It exists so the tokens are not trivially readable by anything on the bus.
var defaultPeers = []string{"CanvasAuthoringMcpServer"}

var allowPeers = defaultPeers

// authorize resolves the calling connection to a pid, then to an executable,
// and reports whether that executable may touch secrets.
func (s *store) authorize(op string, sender dbus.Sender) *dbus.Error {
	for _, p := range allowPeers {
		if p == "*" {
			return nil
		}
	}
	var pid uint32
	err := s.conn.BusObject().Call("org.freedesktop.DBus.GetConnectionUnixProcessID", 0,
		string(sender)).Store(&pid)
	if err != nil {
		log.Printf("%s denied: cannot resolve sender %q: %v", op, sender, err)
		return dbus.NewError("org.freedesktop.DBus.Error.AccessDenied",
			[]interface{}{"caller could not be identified"})
	}
	exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		log.Printf("%s denied: pid %d exe unreadable: %v", op, pid, err)
		return dbus.NewError("org.freedesktop.DBus.Error.AccessDenied",
			[]interface{}{"caller could not be identified"})
	}
	base := exe
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[i+1:]
	}
	for _, p := range allowPeers {
		if base == p {
			return nil
		}
	}
	log.Printf("%s denied: pid %d (%s) not in peer allowlist %v", op, pid, base, allowPeers)
	return dbus.NewError("org.freedesktop.DBus.Error.AccessDenied",
		[]interface{}{"caller not permitted by this provider"})
}

// validID guards every store path this daemon builds. IDs are sha256
// prefixes we mint ourselves, so anything else -- most importantly a
// traversal like "../canva_client_secret" arriving as a D-Bus object path --
// is refused before it can reach gopass. This is what confines the daemon
// to its namespace.
var validID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// Secret is the D-Bus struct: (session, parameters, value, contentType)
type Secret struct {
	Session     dbus.ObjectPath
	Parameters  []byte
	Value       []byte
	ContentType string
}

type item struct {
	Attributes  map[string]string `json:"attributes"`
	Label       string            `json:"label"`
	ValueB64    string            `json:"value"`
	ContentType string            `json:"content_type"`
	Created     uint64            `json:"created"`
	Modified    uint64            `json:"modified"`
}

type store struct {
	mu    sync.Mutex
	conn  *dbus.Conn
	props *prop.Properties
}

func gopassPath(id string) (string, error) {
	if !validID.MatchString(id) {
		return "", fmt.Errorf("refusing id outside namespace: %q", id)
	}
	return gopassDir + "/" + id, nil
}

func attrID(attrs map[string]string) string {
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	h := sha256.New()
	for _, k := range keys {
		fmt.Fprintf(h, "%s=%s\x00", k, attrs[k])
	}
	return hex.EncodeToString(h.Sum(nil))[:32]
}

// agePassword returns the gopass age passphrase, preferring an inherited
// GOPASS_AGE_PASSWORD and otherwise reading the same file nushell/env.nu
// uses. Without it gopass falls back to pinentry, which has no tty under
// systemd: the call blocks forever and the daemon drops its bus name.
func agePassword() string {
	if pw := os.Getenv("GOPASS_AGE_PASSWORD"); pw != "" {
		return pw
	}
	paths := []string{"/mnt/c/Users/jbecka/.gopass-age-password"}
	if home, err := os.UserHomeDir(); err == nil {
		paths = append(paths, home+"/.gopass-age-password")
	}
	for _, p := range paths {
		if b, err := os.ReadFile(p); err == nil {
			if pw := strings.TrimSpace(string(b)); pw != "" {
				return pw
			}
		}
	}
	return ""
}

// runMu serializes gopass invocations. Unbounded concurrent spawns are how a
// single blocked call (pinentry with no tty) turned into 3.7 GB of resident
// gopass processes; one at a time keeps a stall bounded.
var runMu sync.Mutex

func gopassRun(args []string, stdin string) (string, error) {
	runMu.Lock()
	defer runMu.Unlock()

	cmd := exec.Command("gopass", args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	cmd.Env = os.Environ()
	if pw := agePassword(); pw != "" {
		cmd.Env = append(cmd.Env, "GOPASS_AGE_PASSWORD="+pw)
	}
	var out strings.Builder
	var errb strings.Builder
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("gopass %v: %v: %s", args, err, errb.String())
	}
	return out.String(), nil
}

func (s *store) load(id string) (*item, error) {
	p, err := gopassPath(id)
	if err != nil {
		return nil, err
	}
	out, err := gopassRun([]string{"cat", p}, "")
	if err != nil {
		return nil, err
	}
	var it item
	if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &it); err != nil {
		return nil, err
	}
	return &it, nil
}

func (s *store) save(id string, it *item) error {
	p, err := gopassPath(id)
	if err != nil {
		return err
	}
	b, err := json.Marshal(it)
	if err != nil {
		return err
	}
	_, err = gopassRun([]string{"cat", p}, string(b))
	return err
}

// ids lists only the namespace, so the daemon never enumerates the rest of
// the store -- not even secret names.
func (s *store) ids() []string {
	out, err := gopassRun([]string{"ls", "--flat", gopassDir}, "")
	if err != nil {
		return nil
	}
	var ids []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		l = strings.TrimPrefix(l, gopassDir+"/")
		if validID.MatchString(l) {
			ids = append(ids, l)
		}
	}
	return ids
}

func (s *store) matching(attrs map[string]string) []dbus.ObjectPath {
	var res []dbus.ObjectPath
	for _, id := range s.ids() {
		it, err := s.load(id)
		if err != nil {
			continue
		}
		ok := true
		for k, v := range attrs {
			if it.Attributes[k] != v {
				ok = false
				break
			}
		}
		if ok {
			res = append(res, dbus.ObjectPath(itemBase+id))
		}
	}
	return res
}

func idFromPath(p dbus.ObjectPath) string { return strings.TrimPrefix(string(p), itemBase) }

// ---------- Service ----------

type service struct{ s *store }

func (v *service) OpenSession(algorithm string, input dbus.Variant) (dbus.Variant, dbus.ObjectPath, *dbus.Error) {
	if algorithm != "plain" {
		return dbus.MakeVariant(""), "/", dbus.NewError("org.freedesktop.DBus.Error.NotSupported",
			[]interface{}{"only plain algorithm supported"})
	}
	sp := dbus.ObjectPath(fmt.Sprintf("/org/freedesktop/secrets/session/s%d", time.Now().UnixNano()))
	v.s.conn.Export(&session{}, sp, "org.freedesktop.Secret.Session")
	return dbus.MakeVariant(""), sp, nil
}

func (v *service) SearchItems(sender dbus.Sender, attrs map[string]string) ([]dbus.ObjectPath, []dbus.ObjectPath, *dbus.Error) {
	if err := v.s.authorize("Service.SearchItems", sender); err != nil {
		return nil, nil, err
	}
	return v.s.matching(attrs), []dbus.ObjectPath{}, nil
}

func (v *service) Unlock(paths []dbus.ObjectPath) ([]dbus.ObjectPath, dbus.ObjectPath, *dbus.Error) {
	return paths, "/", nil
}

func (v *service) Lock(paths []dbus.ObjectPath) ([]dbus.ObjectPath, dbus.ObjectPath, *dbus.Error) {
	return paths, "/", nil
}

func (v *service) GetSecrets(sender dbus.Sender, items []dbus.ObjectPath, sess dbus.ObjectPath) (map[dbus.ObjectPath]Secret, *dbus.Error) {
	if err := v.s.authorize("Service.GetSecrets", sender); err != nil {
		return nil, err
	}
	res := map[dbus.ObjectPath]Secret{}
	for _, p := range items {
		it, err := v.s.load(idFromPath(p))
		if err != nil {
			continue
		}
		val, _ := base64.StdEncoding.DecodeString(it.ValueB64)
		res[p] = Secret{Session: sess, Parameters: []byte{}, Value: val, ContentType: it.ContentType}
	}
	return res, nil
}

func (v *service) CreateCollection(props map[string]dbus.Variant, alias string) (dbus.ObjectPath, dbus.ObjectPath, *dbus.Error) {
	return collPath, "/", nil
}

func (v *service) ReadAlias(name string) (dbus.ObjectPath, *dbus.Error) {
	if name == "default" {
		return collPath, nil
	}
	return "/", nil
}

func (v *service) SetAlias(name string, coll dbus.ObjectPath) *dbus.Error { return nil }

// ---------- Collection ----------

type collection struct{ s *store }

func (c *collection) CreateItem(sender dbus.Sender, props map[string]dbus.Variant, secret Secret, replace bool) (dbus.ObjectPath, dbus.ObjectPath, *dbus.Error) {
	if err := c.s.authorize("Collection.CreateItem", sender); err != nil {
		return "/", "/", err
	}
	attrs := map[string]string{}
	label := ""
	if v, ok := props["org.freedesktop.Secret.Item.Attributes"]; ok {
		if m, ok := v.Value().(map[string]string); ok {
			attrs = m
		}
	}
	if v, ok := props["org.freedesktop.Secret.Item.Label"]; ok {
		if s, ok := v.Value().(string); ok {
			label = s
		}
	}
	if !allowed(attrs) {
		log.Printf("CreateItem refused: schema %q product %q not in allowlist %v",
			attrs["xdg:schema"], attrs["Product"], allowPrefixes)
		return "/", "/", dbus.NewError("org.freedesktop.DBus.Error.AccessDenied",
			[]interface{}{"attributes not permitted by this provider"})
	}
	if len(secret.Value) > maxSecretBytes {
		log.Printf("CreateItem refused: %d bytes exceeds %d", len(secret.Value), maxSecretBytes)
		return "/", "/", dbus.NewError("org.freedesktop.DBus.Error.LimitsExceeded",
			[]interface{}{fmt.Sprintf("secret exceeds %d bytes", maxSecretBytes)})
	}

	id := attrID(attrs)
	now := uint64(time.Now().Unix())
	it := &item{
		Attributes:  attrs,
		Label:       label,
		ValueB64:    base64.StdEncoding.EncodeToString(secret.Value),
		ContentType: secret.ContentType,
		Created:     now,
		Modified:    now,
	}
	if err := c.s.save(id, it); err != nil {
		log.Printf("save %s: %v", id, err)
		return "/", "/", dbus.NewError("org.freedesktop.Secret.Error.IsLocked", []interface{}{err.Error()})
	}
	p := dbus.ObjectPath(itemBase + id)
	c.s.exportItem(id)
	log.Printf("CreateItem %s (label=%q attrs=%d)", id, label, len(attrs))
	return p, "/", nil
}

func (c *collection) SearchItems(sender dbus.Sender, attrs map[string]string) ([]dbus.ObjectPath, *dbus.Error) {
	if err := c.s.authorize("Collection.SearchItems", sender); err != nil {
		return nil, err
	}
	return c.s.matching(attrs), nil
}

func (c *collection) Delete() (dbus.ObjectPath, *dbus.Error) { return "/", nil }

// ---------- Item ----------

type itemObj struct {
	s  *store
	id string
}

func (i *itemObj) GetSecret(sender dbus.Sender, sess dbus.ObjectPath) (Secret, *dbus.Error) {
	if err := i.s.authorize("Item.GetSecret", sender); err != nil {
		return Secret{}, err
	}
	it, err := i.s.load(i.id)
	if err != nil {
		return Secret{}, dbus.NewError("org.freedesktop.Secret.Error.NoSuchObject", []interface{}{err.Error()})
	}
	val, _ := base64.StdEncoding.DecodeString(it.ValueB64)
	log.Printf("GetSecret %s (%d bytes)", i.id, len(val))
	return Secret{Session: sess, Parameters: []byte{}, Value: val, ContentType: it.ContentType}, nil
}

func (i *itemObj) SetSecret(sender dbus.Sender, secret Secret) *dbus.Error {
	if err := i.s.authorize("Item.SetSecret", sender); err != nil {
		return err
	}
	if len(secret.Value) > maxSecretBytes {
		log.Printf("SetSecret refused: %d bytes exceeds %d", len(secret.Value), maxSecretBytes)
		return dbus.NewError("org.freedesktop.DBus.Error.LimitsExceeded",
			[]interface{}{fmt.Sprintf("secret exceeds %d bytes", maxSecretBytes)})
	}
	it, err := i.s.load(i.id)
	if err != nil {
		it = &item{Attributes: map[string]string{}}
	}
	it.ValueB64 = base64.StdEncoding.EncodeToString(secret.Value)
	it.ContentType = secret.ContentType
	it.Modified = uint64(time.Now().Unix())
	if err := i.s.save(i.id, it); err != nil {
		return dbus.NewError("org.freedesktop.Secret.Error.IsLocked", []interface{}{err.Error()})
	}
	return nil
}

func (i *itemObj) Delete(sender dbus.Sender) (dbus.ObjectPath, *dbus.Error) {
	if err := i.s.authorize("Item.Delete", sender); err != nil {
		return "/", err
	}
	p, err := gopassPath(i.id)
	if err != nil {
		log.Printf("Delete refused: %v", err)
		return "/", dbus.NewError("org.freedesktop.Secret.Error.NoSuchObject", []interface{}{err.Error()})
	}
	gopassRun([]string{"delete", "--force", p}, "")
	return "/", nil
}

type session struct{}

func (s *session) Close() *dbus.Error { return nil }

func (s *store) exportItem(id string) {
	p := dbus.ObjectPath(itemBase + id)
	io := &itemObj{s: s, id: id}
	s.conn.Export(io, p, "org.freedesktop.Secret.Item")
	s.conn.Export(introspect.Introspectable(itemIntro), p, "org.freedesktop.DBus.Introspectable")
	it, err := s.load(id)
	attrs := map[string]string{}
	label := ""
	if err == nil {
		attrs, label = it.Attributes, it.Label
	}
	prop.Export(s.conn, p, prop.Map{
		"org.freedesktop.Secret.Item": {
			"Locked":     {Value: false, Writable: false, Emit: prop.EmitFalse},
			"Attributes": {Value: attrs, Writable: true, Emit: prop.EmitFalse},
			"Label":      {Value: label, Writable: true, Emit: prop.EmitFalse},
			"Created":    {Value: uint64(0), Writable: false, Emit: prop.EmitFalse},
			"Modified":   {Value: uint64(0), Writable: false, Emit: prop.EmitFalse},
		},
	})
}

const svcIntro = `<node>
 <interface name="org.freedesktop.Secret.Service">
  <method name="OpenSession"><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="v" direction="out"/><arg type="o" direction="out"/></method>
  <method name="CreateCollection"><arg type="a{sv}" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
  <method name="SearchItems"><arg type="a{ss}" direction="in"/><arg type="ao" direction="out"/><arg type="ao" direction="out"/></method>
  <method name="Unlock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
  <method name="Lock"><arg type="ao" direction="in"/><arg type="ao" direction="out"/><arg type="o" direction="out"/></method>
  <method name="GetSecrets"><arg type="ao" direction="in"/><arg type="o" direction="in"/><arg type="a{o(oayays)}" direction="out"/></method>
  <method name="ReadAlias"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
  <method name="SetAlias"><arg type="s" direction="in"/><arg type="o" direction="in"/></method>
  <property name="Collections" type="ao" access="read"/>
 </interface>` + introspect.IntrospectDataString + `</node>`

const collIntro = `<node>
 <interface name="org.freedesktop.Secret.Collection">
  <method name="Delete"><arg type="o" direction="out"/></method>
  <method name="SearchItems"><arg type="a{ss}" direction="in"/><arg type="ao" direction="out"/></method>
  <method name="CreateItem"><arg type="a{sv}" direction="in"/><arg type="(oayays)" direction="in"/><arg type="b" direction="in"/><arg type="o" direction="out"/><arg type="o" direction="out"/></method>
  <property name="Items" type="ao" access="read"/>
  <property name="Label" type="s" access="readwrite"/>
  <property name="Locked" type="b" access="read"/>
 </interface>` + introspect.IntrospectDataString + `</node>`

const itemIntro = `<node>
 <interface name="org.freedesktop.Secret.Item">
  <method name="Delete"><arg type="o" direction="out"/></method>
  <method name="GetSecret"><arg type="o" direction="in"/><arg type="(oayays)" direction="out"/></method>
  <method name="SetSecret"><arg type="(oayays)" direction="in"/></method>
  <property name="Locked" type="b" access="read"/>
  <property name="Attributes" type="a{ss}" access="readwrite"/>
  <property name="Label" type="s" access="readwrite"/>
 </interface>` + introspect.IntrospectDataString + `</node>`

func main() {
	log.SetFlags(log.Ltime)
	if p := strings.Trim(os.Getenv("GOPASS_SECRETSERVICE_PREFIX"), "/ "); p != "" {
		gopassDir = p
	}
	if a := strings.TrimSpace(os.Getenv("GOPASS_SECRETSERVICE_ALLOW")); a != "" {
		allowPrefixes = nil
		for _, p := range strings.Split(a, ",") {
			if p = strings.TrimSpace(p); p != "" {
				allowPrefixes = append(allowPrefixes, p)
			}
		}
	}
	if a := strings.TrimSpace(os.Getenv("GOPASS_SECRETSERVICE_PEERS")); a != "" {
		allowPeers = nil
		for _, p := range strings.Split(a, ",") {
			if p = strings.TrimSpace(p); p != "" {
				allowPeers = append(allowPeers, p)
			}
		}
	}
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		log.Fatalf("session bus: %v", err)
	}
	defer conn.Close()

	s := &store{conn: conn}

	reply, err := conn.RequestName(svcName, dbus.NameFlagDoNotQueue)
	if err != nil {
		log.Fatalf("RequestName: %v", err)
	}
	if reply != dbus.RequestNameReplyPrimaryOwner {
		log.Fatalf("%s already owned by another process", svcName)
	}

	conn.Export(&service{s: s}, svcPath, "org.freedesktop.Secret.Service")
	conn.Export(introspect.Introspectable(svcIntro), svcPath, "org.freedesktop.DBus.Introspectable")
	prop.Export(conn, svcPath, prop.Map{
		"org.freedesktop.Secret.Service": {
			"Collections": {Value: []dbus.ObjectPath{collPath}, Writable: false, Emit: prop.EmitFalse},
		},
	})

	for _, cp := range []dbus.ObjectPath{collPath, aliasPath} {
		conn.Export(&collection{s: s}, cp, "org.freedesktop.Secret.Collection")
		conn.Export(introspect.Introspectable(collIntro), cp, "org.freedesktop.DBus.Introspectable")
		prop.Export(conn, cp, prop.Map{
			"org.freedesktop.Secret.Collection": {
				"Items":    {Value: []dbus.ObjectPath{}, Writable: false, Emit: prop.EmitFalse},
				"Label":    {Value: "login", Writable: true, Emit: prop.EmitFalse},
				"Locked":   {Value: false, Writable: false, Emit: prop.EmitFalse},
				"Created":  {Value: uint64(0), Writable: false, Emit: prop.EmitFalse},
				"Modified": {Value: uint64(0), Writable: false, Emit: prop.EmitFalse},
			},
		})
	}
	for _, id := range s.ids() {
		s.exportItem(id)
	}

	log.Printf("gopass-secretservice up: %s (store %s/, schemas %v, peers %v, pid %d)",
		svcName, gopassDir, allowPrefixes, allowPeers, os.Getpid())
	select {}
}
