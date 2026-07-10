package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

const defaultPort = "4810"

// watchDebounce coalesces editor save bursts into a single rebuild+broadcast.
const watchDebounce = 300 * time.Millisecond

func main() {
	rootFlag := flag.String("root", "", "notes repo root (default: $AKM_GRAPH_ROOT or cwd)")
	flag.Parse()

	root := resolveRoot(*rootFlag)
	port := resolvePort()

	srv, err := NewServer(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	addr := net.JoinHostPort("localhost", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "akm-graph: cannot bind %s: %v\n", addr, err)
		os.Exit(1)
	}

	// Live-reload: watch the notes tree, rebuild + WS-broadcast on change.
	if err := srv.StartWatcher(srv.WatchContext(), watchDebounce); err != nil {
		fmt.Fprintf(os.Stderr, "akm-graph: watch: %v\n", err)
		os.Exit(1)
	}

	httpSrv := &http.Server{Handler: srv.Handler()}

	// Graceful shutdown on POST /api/stop (srv.Done) or SIGINT/SIGTERM.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		select {
		case <-srv.Done():
		case <-sig:
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(ctx)
	}()

	g := srv.Snapshot()
	log.Printf("akm-graph listening on http://%s (root=%s, nodes=%d, links=%d)",
		addr, root, len(g.Nodes), len(g.Links))

	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "akm-graph: serve: %v\n", err)
		os.Exit(1)
	}
}

// resolveRoot prefers the --root flag, then $AKM_GRAPH_ROOT, then cwd.
func resolveRoot(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if env := os.Getenv("AKM_GRAPH_ROOT"); env != "" {
		return env
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return cwd
}

// resolvePort prefers $AKM_GRAPH_PORT, else the 4810 default.
func resolvePort() string {
	if p := os.Getenv("AKM_GRAPH_PORT"); p != "" {
		return p
	}
	return defaultPort
}
