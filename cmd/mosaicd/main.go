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
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/api"
	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/mcp"
	"github.com/DangerousANEN/mosaicvpn/internal/paths"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/single"
	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// geoEndpoint is one public-IP geolocation source.  We try them in
// order on startup; the first to answer with a finite lat/lon wins.
// Russian and Iranian carriers routinely block ip-api.com, so rc41
// adds ipapi.co and ipinfo.io as fallbacks — between the three, at
// least one is reachable from every network we have seen in the
// wild.  The decoded fields are normalised into proto.GeoLocation.
type geoEndpoint struct {
	name string
	url  string
	// decode runs on the raw response body and returns the
	// normalised geo or an error.  Keeping parsing per-endpoint
	// means we can tolerate schema drift without one bad
	// provider breaking the whole cascade.
	decode func([]byte) (*proto.GeoLocation, error)
}

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
	go resolveMyLocation(mgr, store)

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

	// MCP server: loopback JSON-RPC 2.0 endpoint agents can drive.
	// Shares the API's bearer token and lives on Prefs.MCPAddr (or
	// the default 127.0.0.1:8731). Failures are logged and non-fatal
	// so a port conflict on the MCP port never blocks the daemon
	// itself from starting.
	mcpSrv := mcp.New(mcp.Config{
		Store:   store,
		Manager: mgr,
		Token:   apiSrv.Token(),
		Version: Version,
		DataDir: dataDir,
		URLTest: apiSrv.URLTestServer,
		Refresh: apiSrv.Refresh,
	})
	mcpShutdown, err := mcpSrv.Start(ctx)
	if err != nil {
		logx.Warn("mcp server failed to start", "err", err)
		mcpShutdown = func(context.Context) error { return nil }
	}

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
	_ = mcpShutdown(shutdownCtx)
	_ = shutdown(shutdownCtx)
	return nil
}

// resolveMyLocation queries ip-api.com for the user's real public-IP
// geolocation and publishes the result to the manager so every
// subsequent /v1/status snapshot carries Status.MyLocation.
//
// The lookup MUST run while the VPN is disconnected — running it
// over an active tunnel would resolve the egress server's IP
// instead of the user's home location and the "vous" pin would
// snap to whatever country the user is currently tunneling
// through.  rc40: this is a long-running loop that
//   1. waits for the manager to be in a non-Connected state,
//   2. queries ip-api,
//   3. on success, republishes only if state is still non-Connected,
//   4. re-runs after every Connected → Disconnected transition so
//      a user roaming between Wi-Fi networks gets refreshed.
//
// Failure modes (no internet, ip-api rate limit, DNS hijack returning
// a 200 with junk body, captive portal) are logged at WARN and
// retried; the renderer keeps its fallback default in the meantime.
func resolveMyLocation(mgr *state.Manager, st *store.Store) {
	const minRetryGap = 5 * time.Second
	const refreshGap = 30 * time.Minute

	endpoints := []geoEndpoint{
		{
			name: "ip-api.com",
			url:  "http://ip-api.com/json/?fields=status,country,city,lat,lon,query",
			decode: func(data []byte) (*proto.GeoLocation, error) {
				var body struct {
					Status  string  `json:"status"`
					Country string  `json:"country"`
					City    string  `json:"city"`
					Lat     float64 `json:"lat"`
					Lon     float64 `json:"lon"`
					Query   string  `json:"query"`
				}
				if err := json.Unmarshal(data, &body); err != nil {
					return nil, err
				}
				if body.Status != "success" {
					return nil, fmt.Errorf("status %q", body.Status)
				}
				return &proto.GeoLocation{
					Lat: body.Lat, Lon: body.Lon,
					City: body.City, Country: body.Country, IP: body.Query,
				}, nil
			},
		},
		{
			name: "ipapi.co",
			url:  "https://ipapi.co/json/",
			decode: func(data []byte) (*proto.GeoLocation, error) {
				var body struct {
					IP          string  `json:"ip"`
					City        string  `json:"city"`
					CountryName string  `json:"country_name"`
					Lat         float64 `json:"latitude"`
					Lon         float64 `json:"longitude"`
					Error       bool    `json:"error"`
					Reason      string  `json:"reason"`
				}
				if err := json.Unmarshal(data, &body); err != nil {
					return nil, err
				}
				if body.Error {
					return nil, fmt.Errorf("ipapi.co: %s", body.Reason)
				}
				return &proto.GeoLocation{
					Lat: body.Lat, Lon: body.Lon,
					City: body.City, Country: body.CountryName, IP: body.IP,
				}, nil
			},
		},
		{
			name: "ipinfo.io",
			url:  "https://ipinfo.io/json",
			decode: func(data []byte) (*proto.GeoLocation, error) {
				// ipinfo returns "loc": "55.7558,37.6173" as a
				// single string; split manually.
				var body struct {
					IP      string `json:"ip"`
					City    string `json:"city"`
					Country string `json:"country"` // ISO-2
					Loc     string `json:"loc"`
				}
				if err := json.Unmarshal(data, &body); err != nil {
					return nil, err
				}
				parts := strings.SplitN(body.Loc, ",", 2)
				if len(parts) != 2 {
					return nil, fmt.Errorf("ipinfo loc %q", body.Loc)
				}
				lat, err := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
				if err != nil {
					return nil, err
				}
				lon, err := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
				if err != nil {
					return nil, err
				}
				return &proto.GeoLocation{
					Lat: lat, Lon: lon,
					City: body.City, Country: body.Country, IP: body.IP,
				}, nil
			},
		},
	}

	wasConnected := false
	lastResolved := time.Time{}
	// On first launch we may already have a persisted location from
	// the store (hydrated into mgr); treat that as "resolved long
	// ago" so the loop still attempts a fresh lookup.  The sleep
	// below is the only fast-path gate.

	for {
		status := mgr.Status()
		connected := status.State == proto.StateConnected

		// Edge: connected → disconnected.  Force a refresh so a
		// user that disconnects from one country and reconnects
		// from another sees their pin update.
		if !connected && wasConnected {
			lastResolved = time.Time{}
		}
		wasConnected = connected

		if connected {
			time.Sleep(minRetryGap)
			continue
		}

		if !lastResolved.IsZero() && time.Since(lastResolved) < refreshGap {
			time.Sleep(minRetryGap)
			continue
		}

		loc := tryGeoEndpoints(endpoints)
		if loc == nil {
			// All endpoints failed.  Keep whatever persisted
			// value is already published by the manager (from
			// store hydration) and retry after the short gap.
			time.Sleep(minRetryGap)
			continue
		}

		// Re-check connected state right before publishing — a
		// Connect that landed during the HTTP round-trip means
		// our resolved IP is the egress, not the user.  Drop.
		if mgr.Status().State == proto.StateConnected {
			logx.Warn("geo result discarded — connect happened mid-lookup, would mistake egress for home")
			time.Sleep(minRetryGap)
			continue
		}

		mgr.SetMyLocation(loc)
		if err := st.SetMyLocation(loc); err != nil {
			logx.Warn("persist my_location failed", "err", err.Error())
		}
		lastResolved = time.Now()
		logx.Info("resolved user location",
			"city", loc.City, "country", loc.Country,
			"lat", loc.Lat, "lon", loc.Lon, "ip", loc.IP)
		time.Sleep(refreshGap / 2)
	}
}

// tryGeoEndpoints runs each endpoint in sequence with a short per-
// request timeout, returning the first valid geo or nil if every
// endpoint failed.  "Valid" means finite lat/lon that isn't literally
// (0, 0) — some providers return zeroes on private IP or ratelimit.
func tryGeoEndpoints(endpoints []geoEndpoint) *proto.GeoLocation {
	client := &http.Client{Timeout: 6 * time.Second}
	for _, ep := range endpoints {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, ep.url, nil)
		if err != nil {
			cancel()
			continue
		}
		req.Header.Set("User-Agent", "mosaicvpn/0.1 (geo)")
		resp, err := client.Do(req)
		if err != nil {
			cancel()
			logx.Warn("geo endpoint failed", "src", ep.name, "err", err.Error())
			continue
		}
		data, readErr := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		cancel()
		if readErr != nil {
			logx.Warn("geo endpoint read failed", "src", ep.name, "err", readErr.Error())
			continue
		}
		loc, decErr := ep.decode(data)
		if decErr != nil {
			logx.Warn("geo endpoint decode failed", "src", ep.name, "err", decErr.Error())
			continue
		}
		if loc == nil || (loc.Lat == 0 && loc.Lon == 0) {
			logx.Warn("geo endpoint returned empty coords", "src", ep.name)
			continue
		}
		return loc
	}
	return nil
}
