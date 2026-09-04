// canvas-mcp-relay bridges 127.0.0.1:<port> -> [::1]:<port> for the
// canvas-authoring MCP server's OAuth redirect listener.
//
// Why: the server binds its redirect listener on [::1] only, while WSL
// forwards Windows `localhost` over IPv4. The browser therefore lands on
// nothing and `connect` hangs forever waiting for a sign-in that can never
// complete. The port is not fixed -- MSAL picks a fresh high port per
// sign-in -- so this watches for new listeners instead of taking one port.
//
// Only ports owned by the canvas MCP process are bridged; bridging every
// IPv6-only loopback port would silently defeat services that bind [::1]
// deliberately.
package main

import (
	"io"
	"log"
	"net"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	owner    = "CanvasAuthoring"
	interval = time.Second
)

var listenRe = regexp.MustCompile(`\[::1\]:(\d+)\s`)
var v4Re = regexp.MustCompile(`127\.0\.0\.1:(\d+)\s`)

type relay struct {
	mu     sync.Mutex
	active map[int]bool
}

// ports returns the ports the canvas MCP server listens on over IPv6
// loopback that have no IPv4 counterpart yet.
func ports() (want map[int]bool, taken map[int]bool) {
	want, taken = map[int]bool{}, map[int]bool{}
	out, err := exec.Command("ss", "-ltnp").Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		if m := listenRe.FindStringSubmatch(line); m != nil && strings.Contains(line, owner) {
			if p, err := strconv.Atoi(m[1]); err == nil {
				want[p] = true
			}
		}
		if m := v4Re.FindStringSubmatch(line); m != nil {
			if p, err := strconv.Atoi(m[1]); err == nil {
				taken[p] = true
			}
		}
	}
	return
}

func splice(a, b net.Conn) {
	defer a.Close()
	defer b.Close()
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if c, ok := dst.(*net.TCPConn); ok {
			c.CloseWrite()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
}

func (r *relay) serve(port int) {
	l, err := net.Listen("tcp4", "127.0.0.1:"+strconv.Itoa(port))
	if err != nil {
		log.Printf("bind 127.0.0.1:%d: %v", port, err)
		r.mu.Lock()
		delete(r.active, port)
		r.mu.Unlock()
		return
	}
	defer l.Close()
	log.Printf("relay up 127.0.0.1:%d -> [::1]:%d", port, port)

	for {
		down, err := l.Accept()
		if err != nil {
			log.Printf("accept %d: %v", port, err)
			r.mu.Lock()
			delete(r.active, port)
			r.mu.Unlock()
			return
		}
		up, err := net.DialTimeout("tcp6", "[::1]:"+strconv.Itoa(port), 5*time.Second)
		if err != nil {
			log.Printf("upstream [::1]:%d: %v", port, err)
			down.Close()
			continue
		}
		log.Printf("forwarding connection on %d", port)
		go splice(down, up)
	}
}

func main() {
	log.SetFlags(log.Ltime)
	log.Printf("canvas-mcp-relay watching for %s listeners on [::1]", owner)

	r := &relay{active: map[int]bool{}}
	for {
		want, taken := ports()
		for p := range want {
			if taken[p] {
				continue
			}
			r.mu.Lock()
			if !r.active[p] {
				r.active[p] = true
				go r.serve(p)
			}
			r.mu.Unlock()
		}
		time.Sleep(interval)
	}
}
