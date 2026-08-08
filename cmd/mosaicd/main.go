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

	"github.com/pupspochta-cpu/mosaicvpn/internal/api"
	"github.com/pupspochta-cpu/mosaicvpn/internal/billing"
	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/paths"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/single"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
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
		// Use EnsureDataDir which falls back to %LOCALAPPDATA% if
		// %ProgramData%\Mosaic is not writable (non-elevated daemon).
		dir, err := paths.EnsureDataDir()
		if err != nil {
			return fmt.Errorf("create data dir: %w", err)
		}
		dataDir = dir
	} else {
		if err := paths.EnsureDir(dataDir); err != nil {
			return fmt.Errorf("create data dir: %w", err)
		}
	}

	store, err := store.Open(paths.StoreFile(dataDir))
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}

	var backend state.Backend
	if bin := state.LocateSingBox(); bin != "" {
		logx.Info("sing-box backend enabled", "bin", bin)
		backend = state.NewSingBoxBackend(bin, dataDir, store)
	} else {
		logx.Warn("sing-box not found next to mosaicd or on PATH; falling back to mock backend (Connect will pretend to work but no proxy is opened)")
		backend = state.NewMockBackend()
	}
	mgr := state.New(store, backend, Version)

	apiSrv := api.NewServer(store, mgr, nil)

	// Load persisted billing credentials so the billing.Client is seeded
	// with the user's previously-saved Remnawave/CryptoBot settings on
	// startup — not just when the UI re-POSTs them.
	if rURL, rTok, cURL, cTok := store.GetBillingCredentials(); rURL != "" || cURL != "" {
		yShop, yKey := store.GetYookassaCredentials()
		apiSrv.SetBillingConfig(billing.Config{
			Remnawave: billing.RemnawaveConfig{BaseURL: rURL, APIToken: rTok},
			CryptoBot: billing.CryptoBotConfig{APIToken: cTok, BaseURL: cURL},
			Yookassa:  billing.YookassaConfig{ShopID: yShop, SecretKey: yKey},
		})
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start background auto-update & sync loop (startup sync + 4h periodic refresh)
	go apiSrv.StartAutoUpdate(ctx)

	// Start background auto-renew loop (expiry checks every 1h)
	go apiSrv.StartAutoRenew(ctx)

	// Start pool health-check loop (node selection for manifest groups)
	go apiSrv.StartPool(ctx)

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
		if errors.Is(err, single.ErrAlreadyRunning) {
			// prev may be empty when the previous instance held a
			// different lockfile (e.g. a stale dev-mode mosaicd
			// holding the same global mutex but writing into a
			// different MOSAIC_DATA_DIR). Avoid a misleading ":0
			// (pid 0)" in that case.
			if prev != nil && prev.Port != 0 && prev.PID != 0 {
				return fmt.Errorf("another daemon is already running on %s:%d (pid %d)",
					prev.Host, prev.Port, prev.PID)
			}
			return fmt.Errorf("another mosaic daemon is already running (single-instance lock held by another process); stop it via 'Get-Process mosaicd | Stop-Process' on Windows or 'pkill mosaicd' on Unix")
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
