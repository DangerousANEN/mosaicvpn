// mosaicd is the Mosaic VPN daemon. It acquires a single-instance lock,
// loads on-disk state, exposes an HTTP API on the loopback interface, and
// drives the VPN backend.
//
// In Phase 1 the backend is a deterministic mock that simulates connect /
// disconnect transitions and ramps up byte counters; the wiring (single-
// instance, store, state machine, API) is otherwise production-shaped and
// will be reused unchanged when the real sing-box backend lands in Phase 2.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/DangerousANEN/mosaic/internal/api"
	"github.com/DangerousANEN/mosaic/internal/logx"
	"github.com/DangerousANEN/mosaic/internal/paths"
	"github.com/DangerousANEN/mosaic/internal/proto"
	"github.com/DangerousANEN/mosaic/internal/single"
	"github.com/DangerousANEN/mosaic/internal/state"
	"github.com/DangerousANEN/mosaic/internal/store"
)

// Version is set at build time via -ldflags "-X main.Version=...".
var Version = "0.1.0-dev"

func main() {
	var (
		dataDir = flag.String("data-dir", "", "override Mosaic data directory")
		verbose = flag.Bool("v", false, "verbose logging")
	)
	flag.Parse()

	if *verbose {
		logx.SetLevel(logx.LevelDebug)
	}

	if err := run(*dataDir); err != nil {
		fmt.Fprintf(os.Stderr, "mosaicd: %v\n", err)
		os.Exit(1)
	}
}

func run(dataDirOverride string) error {
	dataDir := dataDirOverride
	if dataDir == "" {
		dataDir = paths.DataDir()
	}
	if err := paths.EnsureDir(dataDir); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	store, err := store.Open(paths.StoreFile(dataDir))
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}

	mb := state.NewMockBackend()
	mgr := state.New(store, mb, Version)

	apiSrv := api.NewServer(store, mgr, nil)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	addr, shutdown, err := apiSrv.Listen(ctx)
	if err != nil {
		return fmt.Errorf("api listen: %w", err)
	}

	host, portStr, _ := net.SplitHostPort(addr)
	port, _ := strconv.Atoi(portStr)
	endpoint := proto.DaemonEndpoint{
		Host:    host,
		Port:    port,
		Token:   apiSrv.Token(),
		PID:     os.Getpid(),
		Version: Version,
		Started: time.Now().UTC().Format(time.RFC3339),
	}

	lock, prev, err := single.Acquire(paths.LockFile(dataDir), endpoint)
	if err != nil {
		_ = shutdown(context.Background())
		if errors.Is(err, single.ErrAlreadyRunning) && prev != nil {
			return fmt.Errorf("another daemon is already running on %s:%d (pid %d)",
				prev.Host, prev.Port, prev.PID)
		}
		return fmt.Errorf("acquire lock: %w", err)
	}
	defer lock.Release()

	logx.Info("mosaicd started",
		"version", Version,
		"data_dir", dataDir,
		"api", fmt.Sprintf("http://%s:%d", host, port),
	)

	// Wait for SIGINT/SIGTERM.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig

	logx.Info("shutting down")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	_ = mgr.Disconnect(shutdownCtx)
	_ = shutdown(shutdownCtx)
	return nil
}
