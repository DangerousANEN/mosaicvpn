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
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/api"
	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/paths"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/single"
	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
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

	// Reap any sing-box.exe processes that survived a previous crash
	// of the UI / daemon. With Job Object kill-on-close (rc20+) this
	// is normally a no-op; on first launch after upgrading from
	// rc<=19 a stale sing-box may still be running and holding our
	// loopback ports, which would block this start with "could not
	// bind a free port for sing-box proxies".
	reapStaleSingBox(dataDir)

	store, err := store.Open(paths.StoreFile(dataDir))
	if err != nil {
		return fmt.Errorf("open store: %w", err)
	}

	var backend state.Backend
	if bin := state.LocateSingBox(); bin != "" {
		logx.Info("sing-box backend enabled", "bin", bin)
		backend = state.NewSingBoxBackend(bin, dataDir)
	} else {
		logx.Warn("sing-box not found next to mosaicd or on PATH; falling back to mock backend (Connect will pretend to work but no proxy is opened)")
		backend = state.NewMockBackend()
	}
	mgr := state.New(store, backend, Version)

	// Best-effort: resolve the user's public-IP location once at
	// startup so the renderer can plant the "vous" pin on the
	// correct continent. Failures (no internet at boot, ip-api
	// rate-limiting, captive portal, etc.) leave Status.MyLocation
	// nil and the renderer falls back to its hardcoded default.
	go resolveMyLocation(mgr)

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

	// Auto-connect to the last server the user picked, if Prefs.AutoConnect
	// is on and we still have it. This is best-effort: failures are logged
	// and the daemon proceeds in the disconnected state so the user can pick
	// something else from the UI.
	go func() {
		snap := store.Snapshot()
		if !snap.Prefs.AutoConnect || snap.LastServerID == "" {
			return
		}
		// Wait briefly so the API + frontend have a chance to come up
		// before we flip the manager into 'connecting'. The UI then sees
		// the transition exactly as if the user had clicked Connect.
		select {
		case <-ctx.Done():
			return
		case <-time.After(750 * time.Millisecond):
		}
		cctx, ccancel := context.WithTimeout(ctx, 30*time.Second)
		defer ccancel()
		if err := mgr.Connect(cctx, snap.LastServerID); err != nil {
			logx.Warn("auto-connect to last server failed", "server_id", snap.LastServerID, "err", err)
			return
		}
		logx.Info("auto-connected to last server", "server_id", snap.LastServerID)
	}()

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

// resolveMyLocation does a one-shot ip-api.com lookup for the user's
// public-IP geolocation. Result is published to the manager so every
// subsequent /v1/status snapshot carries Status.MyLocation. We do not
// persist this — re-resolved on every daemon start so a user moving
// laptops between countries doesn't end up with a stale "vous" pin.
//
// Failure modes (no internet, ip-api rate limit, DNS hijack returning
// a 200 with junk body, captive portal) are silently ignored; the
// renderer already has a default-fallback path.
func resolveMyLocation(mgr *state.Manager) {
	// Generous overall budget but a tight per-attempt timeout so a
	// flaky resolver can't block the daemon's startup banner for
	// the full window. Three attempts spaced ~5 s apart cover the
	// "wifi just connected, DHCP still settling" boot case.
	for attempt := 0; attempt < 3; attempt++ {
		if attempt > 0 {
			time.Sleep(5 * time.Second)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet,
			"http://ip-api.com/json/?fields=status,country,city,lat,lon,query", nil)
		if err != nil {
			cancel()
			continue
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			cancel()
			continue
		}
		var body struct {
			Status  string  `json:"status"`
			Country string  `json:"country"`
			City    string  `json:"city"`
			Lat     float64 `json:"lat"`
			Lon     float64 `json:"lon"`
			Query   string  `json:"query"`
		}
		dec := json.NewDecoder(resp.Body)
		decErr := dec.Decode(&body)
		_ = resp.Body.Close()
		cancel()
		if decErr != nil || body.Status != "success" {
			continue
		}
		mgr.SetMyLocation(&proto.GeoLocation{
			Lat:     body.Lat,
			Lon:     body.Lon,
			City:    body.City,
			Country: body.Country,
			IP:      body.Query,
		})
		logx.Info("resolved user location",
			"city", body.City, "country", body.Country,
			"lat", body.Lat, "lon", body.Lon)
		return
	}
	logx.Warn("failed to resolve user IP location; vous pin will use fallback")
}
