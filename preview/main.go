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

const defaultPort = "4200"

func main() {
	rootFlag := flag.String("root", "", "preview root directory (default: cwd)")
	flag.Parse()

	root := resolveRoot(*rootFlag)
	port := resolvePort()

	srv, err := NewServer(root, port)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	addr := net.JoinHostPort("localhost", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		// Port already in use -> fail fast, naming the port (akm-graph
		// NewServer precedent; sp008 Task 1 edge case).
		fmt.Fprintf(os.Stderr, "preview-d: cannot bind %s: %v\n", addr, err)
		os.Exit(1)
	}

	httpSrv := &http.Server{Handler: srv.Handler()}

	// Graceful shutdown on POST /stop (srv.Done) or SIGINT/SIGTERM.
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

	log.Printf("preview-d listening on http://%s (root=%s)", addr, root)

	if err := httpSrv.Serve(ln); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "preview-d: serve: %v\n", err)
		os.Exit(1)
	}
}

// resolveRoot prefers the --root flag, else cwd. An explicit -root that
// doesn't exist is validated by NewServer (fail-fast, not an empty serve —
// sp008 Task 1 edge case).
func resolveRoot(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return cwd
}

// resolvePort prefers $PREVIEW_PORT, else the 4200 default (sp008 Task 1
// edge case: $PREVIEW_PORT unset -> 4200).
func resolvePort() string {
	if p := os.Getenv("PREVIEW_PORT"); p != "" {
		return p
	}
	return defaultPort
}
