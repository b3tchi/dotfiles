package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// config holds all injectable runtime configuration.
type config struct {
	// RouterPort is the port for the main listener (default 4800).
	RouterPort string
	// RegistryPath is the path to projects.yaml (ft001 schema).
	RegistryPath string
	// D2Bin is the d2 binary path (test seam for fake children).
	D2Bin string
	// ChildPortBase is the starting port for child process assignment.
	ChildPortBase string
	// IdleTimeout is the idle reaper duration.
	IdleTimeout string
}

func loadConfig() config {
	c := config{
		RouterPort:    getenv("D2_ROUTER_PORT", "4800"),
		RegistryPath:  getenv("D2_ROUTER_REGISTRY", defaultRegistryPath()),
		D2Bin:         getenv("D2_ROUTER_D2_BIN", "d2"),
		ChildPortBase: getenv("D2_ROUTER_CHILD_PORT_BASE", "4801"),
		IdleTimeout:   getenv("D2_ROUTER_IDLE", "30m"),
	}
	return c
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func defaultRegistryPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "project", "projects.yaml")
}

func main() {
	log.SetFlags(log.Ldate | log.Ltime | log.Lmsgprefix)
	log.SetPrefix("d2-router: ")

	cfg := loadConfig()

	reg, registryMissing := loadRegistryWithFallback(cfg.RegistryPath)
	idx := buildIndex(reg)

	mux := http.NewServeMux()
	mux.Handle("/", newIndexHandler(idx, registryMissing))

	addr := net.JoinHostPort("127.0.0.1", cfg.RouterPort)
	srv := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	// Start listening in a goroutine.
	listenErr := make(chan error, 1)
	go func() {
		log.Printf("listening on http://%s", addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			listenErr <- err
		}
	}()

	// Wait for OS signal or listen failure.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-listenErr:
		log.Fatalf("listen error: %v", err)
	case sig := <-quit:
		log.Printf("received signal %v — shutting down", sig)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
	log.Println("stopped")
}

// loadRegistryWithFallback loads the registry and returns it plus a missing flag.
// On missing/unreadable file: returns empty registry + missing=true (daemon still serves).
func loadRegistryWithFallback(path string) (Registry, bool) {
	if path == "" {
		log.Printf("registry path not configured — serving empty index")
		return Registry{}, true
	}

	// Expand ~ manually since os.ReadFile doesn't.
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			path = filepath.Join(home, path[2:])
		}
	}

	reg, err := loadRegistry(path)
	if err != nil {
		if os.IsNotExist(underlyingErr(err)) {
			log.Printf("registry file not found at %s — serving empty index", path)
		} else {
			log.Printf("registry load error: %v — serving empty index", err)
		}
		return Registry{}, true
	}
	return reg, false
}

// underlyingErr unwraps to find the root cause (for os.IsNotExist checks).
func underlyingErr(err error) error {
	for {
		u, ok := err.(interface{ Unwrap() error })
		if !ok {
			return err
		}
		if unwrapped := u.Unwrap(); unwrapped == nil {
			return err
		} else {
			err = unwrapped
		}
	}
}
