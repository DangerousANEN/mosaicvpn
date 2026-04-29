// Package state owns the connection state machine of the Mosaic daemon.
//
// Transitions:
//
//	disconnected → connecting → connected
//	connecting   → error      (failure during connect)
//	connected    → disconnected (user disconnect or backend stop)
//	connected    → error      (backend dropped unexpectedly)
//	error        → connecting (retry)
//
// All state changes go through the manager so we can serialise
// connect/disconnect, expose a single Status snapshot, and broadcast
// events to API clients.
package state

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"os"
	"sync"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// Backend is the abstract VPN engine the manager drives. Phase 1 ships a
// MockBackend; Phase 2 supplies a sing-box backed implementation.
type Backend interface {
	Name() string
	Start(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error
	Stop(ctx context.Context) error
	Stats() (bytesIn, bytesOut uint64, latencyMS int)
}

// ProxyListener-aware backends expose loopback proxy endpoints (SOCKS
// and HTTP) once Start has succeeded. Backends that do not actually
// open ports (e.g. MockBackend) simply do not implement this and Status
// will report empty proxy fields.
type ProxyListener interface {
	Proxies() (socks, http string)
}

// Manager owns the connection state and is safe for concurrent use.
type Manager struct {
	mu       sync.Mutex
	st       proto.Status
	store    *store.Store
	backend  Backend
	cancel   context.CancelFunc
	subs     []chan proto.Status
	version  string
	pid      int
	started  time.Time
	// myLocation is populated once by mosaicd's startup IP-geo
	// lookup (see cmd/mosaicd/main.go). Folded into every Status
	// snapshot so the renderer can plant the "vous" pin on the
	// user's actual continent.
	myLocation *proto.GeoLocation
	// metricsCancel stops the per-second goroutine that re-emits a
	// live Status with fresh bytes_in / bytes_out / latency_ms folded
	// in. Started in Connect after a successful transition to
	// StateConnected and cancelled in Disconnect (or on the next
	// Connect, since reconnects implicitly disconnect first). nil
	// while there's no live tunnel — the metrics goroutine only
	// matters while we're actually moving bytes.
	metricsCancel context.CancelFunc
}

// New constructs a Manager around an existing store and backend.
func New(s *store.Store, backend Backend, version string) *Manager {
	m := &Manager{
		store:   s,
		backend: backend,
		version: version,
		pid:     osPID(),
		started: time.Now().UTC(),
	}
	prefs := s.Snapshot().Prefs
	m.st = proto.Status{
		State:         proto.StateDisconnected,
		TunnelMode:    prefs.TunnelMode,
		KillSwitch:    prefs.KillSwitch,
		DaemonVersion: version,
		DaemonPID:     m.pid,
	}
	return m
}

// Status returns a snapshot of the current state, with live counters from
// the backend folded in.
func (m *Manager) Status() proto.Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	st := m.st
	if m.backend != nil && st.State == proto.StateConnected {
		in, out, lat := m.backend.Stats()
		st.BytesIn = in
		st.BytesOut = out
		st.LatencyMS = lat
		if p, ok := m.backend.(ProxyListener); ok {
			st.ProxySOCKS, st.ProxyHTTP = p.Proxies()
		}
	}
	if m.myLocation != nil {
		// Copy so callers can't mutate the canonical struct.
		loc := *m.myLocation
		st.MyLocation = &loc
	}
	return st
}

// SetMyLocation publishes the user's resolved geo position. Called
// once by mosaicd's startup goroutine after the ip-api lookup
// succeeds; safe to call again later if a re-resolve is added.
func (m *Manager) SetMyLocation(loc *proto.GeoLocation) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.myLocation = loc
}

// Subscribe returns a buffered channel that receives every Status update.
// The returned cancel function detaches the subscriber.
func (m *Manager) Subscribe() (<-chan proto.Status, func()) {
	ch := make(chan proto.Status, 16)
	m.mu.Lock()
	m.subs = append(m.subs, ch)
	m.mu.Unlock()
	cancel := func() {
		m.mu.Lock()
		out := m.subs[:0]
		for _, c := range m.subs {
			if c != ch {
				out = append(out, c)
			}
		}
		m.subs = out
		m.mu.Unlock()
		close(ch)
	}
	return ch, cancel
}

// Connect starts the backend against the supplied server. If the manager
// is already connected, it will disconnect first.
//
// When the user has selected TUN tunnel mode but the daemon process is
// not running with administrator privileges, Connect refuses early
// with a recognisable error string. The renderer matches on the
// "tun:elevation_required" prefix to surface the rc18 admin-gate
// modal — without this guard sing-box would start, fail to install
// the wintun adapter, and exit a few seconds later with an opaque
// "operation not permitted" buried in singbox.err.log.
func (m *Manager) Connect(ctx context.Context, serverID string) error {
	// Empty serverID means "reconnect to the last-used server".
	// The UI passes "" from the Main toggle and the tray after a
	// disconnect so the user doesn't get bounced to servers[0]; we
	// fall back to LastServerID from the persistent store, then to
	// the first available server only when the store has nothing
	// recorded yet.
	if serverID == "" {
		snap := m.store.Snapshot()
		if snap.LastServerID != "" {
			serverID = snap.LastServerID
		} else if len(snap.Servers) > 0 {
			serverID = snap.Servers[0].ID
		}
		if serverID == "" {
			return errors.New("no server available; add a subscription first")
		}
	}
	server, ok := m.store.FindServer(serverID)
	if !ok {
		return fmt.Errorf("server %q not found", serverID)
	}
	prefsSnap := m.store.Snapshot().Prefs
	if prefsSnap.TunnelMode == "tun" && !IsElevated() {
		return errors.New("tun:elevation_required: TUN tunnel mode requires administrator privileges; restart Mosaic as administrator or switch to Proxy mode in Folio → Network")
	}
	m.mu.Lock()
	if m.st.State == proto.StateConnecting {
		m.mu.Unlock()
		return errors.New("already connecting")
	}
	if m.st.State == proto.StateConnected || m.st.State == proto.StateError {
		m.mu.Unlock()
		_ = m.Disconnect(ctx)
		m.mu.Lock()
	}

	m.transitionLocked(proto.Status{
		State:         proto.StateConnecting,
		Server:        &server,
		Since:         time.Now().UTC(),
		TunnelMode:    m.st.TunnelMode,
		KillSwitch:    m.st.KillSwitch,
		DaemonVersion: m.st.DaemonVersion,
		DaemonPID:     m.st.DaemonPID,
	})

	cctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.mu.Unlock()

	snap := m.store.Snapshot()
	if err := m.backend.Start(cctx, server, snap.Prefs, snap.Rules); err != nil {
		m.mu.Lock()
		m.transitionLocked(proto.Status{
			State:         proto.StateError,
			LastError:     err.Error(),
			Server:        &server,
			Since:         time.Now().UTC(),
			TunnelMode:    m.st.TunnelMode,
			KillSwitch:    m.st.KillSwitch,
			DaemonVersion: m.st.DaemonVersion,
			DaemonPID:     m.st.DaemonPID,
		})
		m.mu.Unlock()
		return err
	}

	m.mu.Lock()
	m.transitionLocked(proto.Status{
		State:         proto.StateConnected,
		Server:        &server,
		Since:         time.Now().UTC(),
		TunnelMode:    m.st.TunnelMode,
		KillSwitch:    m.st.KillSwitch,
		DaemonVersion: m.st.DaemonVersion,
		DaemonPID:     m.st.DaemonPID,
	})
	// Start the live-metrics ticker. Cancels any previous instance
	// (defensive — Disconnect already cancels, but a reconnect could
	// race with the previous goroutine on slow shutdown).
	if m.metricsCancel != nil {
		m.metricsCancel()
	}
	mctx, mcancel := context.WithCancel(context.Background())
	m.metricsCancel = mcancel
	go m.runMetricsTicker(mctx)
	m.mu.Unlock()

	if err := m.store.SetLastServer(serverID); err != nil {
		logx.Warn("could not persist last server", "err", err)
	}
	return nil
}

// runMetricsTicker re-broadcasts a Status snapshot every second
// while a tunnel is up. The renderer's SSE stream then drives live
// updates on the Atlas latency / bytes fields without forcing the
// user to F5 — fixes the rc26-era "metrics frozen until refresh"
// report. Pure broadcast; does not mutate m.st (which is reserved
// for state-machine transitions).
func (m *Manager) runMetricsTicker(ctx context.Context) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			m.publishLive()
		}
	}
}

// publishLive computes the same status shape Status() returns
// (with backend stats + my-location folded in) and broadcasts it
// to every subscriber without changing the cached state-machine
// snapshot. Safe to call from any goroutine.
func (m *Manager) publishLive() {
	m.mu.Lock()
	if m.st.State != proto.StateConnected {
		m.mu.Unlock()
		return
	}
	snap := m.st
	if m.backend != nil {
		in, out, lat := m.backend.Stats()
		snap.BytesIn = in
		snap.BytesOut = out
		snap.LatencyMS = lat
		if p, ok := m.backend.(ProxyListener); ok {
			snap.ProxySOCKS, snap.ProxyHTTP = p.Proxies()
		}
	}
	if m.myLocation != nil {
		loc := *m.myLocation
		snap.MyLocation = &loc
	}
	subs := append([]chan proto.Status(nil), m.subs...)
	m.mu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- snap:
		default:
		}
	}
}

// Disconnect stops the backend and returns to disconnected state.
func (m *Manager) Disconnect(ctx context.Context) error {
	m.mu.Lock()
	if m.st.State == proto.StateDisconnected {
		m.mu.Unlock()
		return nil
	}
	if m.cancel != nil {
		m.cancel()
		m.cancel = nil
	}
	if m.metricsCancel != nil {
		m.metricsCancel()
		m.metricsCancel = nil
	}
	m.mu.Unlock()

	if err := m.backend.Stop(ctx); err != nil {
		return err
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	m.transitionLocked(proto.Status{
		State:         proto.StateDisconnected,
		Since:         time.Now().UTC(),
		TunnelMode:    m.st.TunnelMode,
		KillSwitch:    m.st.KillSwitch,
		DaemonVersion: m.st.DaemonVersion,
		DaemonPID:     m.st.DaemonPID,
	})
	return nil
}

// SetTunnelPrefs informs the manager of the current tunnel-mode/kill-switch
// configuration so that Status reflects them even before reconnect.
func (m *Manager) SetTunnelPrefs(mode string, killSwitch bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	st := m.st
	st.TunnelMode = mode
	st.KillSwitch = killSwitch
	m.transitionLocked(st)
}

// SpeedtestResult is the outcome of a one-shot bandwidth test through
// the active proxy backend.
type SpeedtestResult struct {
	URL          string  `json:"url"`
	Bytes        int64   `json:"bytes"`
	DurationMS   int64   `json:"duration_ms"`
	MbitPerSec   float64 `json:"mbit_per_sec"`
	HTTPStatus   int     `json:"http_status"`
	StartedAtUTC string  `json:"started_at_utc"`
}

// Speedtest pulls a fixed-size payload through the active SOCKS proxy
// and reports throughput. The request is short-circuited if the
// backend isn't connected. The default payload is Cloudflare's
// public speed-test endpoint at 10 MB; callers may override the URL.
func (m *Manager) Speedtest(ctx context.Context, url string) (SpeedtestResult, error) {
	m.mu.Lock()
	st := m.st
	be := m.backend
	m.mu.Unlock()
	res := SpeedtestResult{StartedAtUTC: time.Now().UTC().Format(time.RFC3339)}
	if st.State != proto.StateConnected {
		return res, fmt.Errorf("speedtest: not connected")
	}
	pl, ok := be.(ProxyListener)
	if !ok {
		return res, fmt.Errorf("speedtest: backend has no proxy listener")
	}
	socks, _ := pl.Proxies()
	if socks == "" {
		return res, fmt.Errorf("speedtest: SOCKS listener not advertised")
	}
	if url == "" {
		url = "https://speed.cloudflare.com/__down?bytes=10485760"
	}
	res.URL = url
	proxyURL, err := neturl.Parse("socks5h://" + socks)
	if err != nil {
		return res, fmt.Errorf("speedtest: bad proxy: %w", err)
	}
	transport := &http.Transport{
		Proxy:                 http.ProxyURL(proxyURL),
		ResponseHeaderTimeout: 15 * time.Second,
		IdleConnTimeout:       30 * time.Second,
		ForceAttemptHTTP2:     false,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   90 * time.Second,
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return res, err
	}
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return res, fmt.Errorf("speedtest: %w", err)
	}
	defer resp.Body.Close()
	res.HTTPStatus = resp.StatusCode
	n, err := io.Copy(io.Discard, resp.Body)
	dur := time.Since(start)
	res.Bytes = n
	res.DurationMS = dur.Milliseconds()
	if dur > 0 {
		res.MbitPerSec = float64(n*8) / dur.Seconds() / 1_000_000.0
	}
	if err != nil {
		return res, fmt.Errorf("speedtest: download: %w", err)
	}
	return res, nil
}

// Started returns when the daemon began running.
func (m *Manager) Started() time.Time { return m.started }

// PID returns the daemon process id.
func (m *Manager) PID() int { return m.pid }

// Version returns the daemon version string.
func (m *Manager) Version() string { return m.version }

func (m *Manager) transitionLocked(next proto.Status) {
	m.st = next
	for _, ch := range m.subs {
		select {
		case ch <- next:
		default:
			// drop if subscriber is slow; subscribers should be fast.
		}
	}
}

// osPID returns the daemon's PID. Wrapped so tests can override.
var osPID = func() int { return os.Getpid() }
