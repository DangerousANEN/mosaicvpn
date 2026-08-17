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
	"os"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// Backend is the abstract VPN engine the manager drives. Phase 1 ships a
// MockBackend; Phase 2 supplies a sing-box backed implementation.
type Backend interface {
	Name() string
	Start(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error
	Stop(ctx context.Context) error
	Stats() (bytesIn, bytesOut uint64, latencyMS int)
}

// ConnectionBackend is an optional interface a Backend can implement to
// expose live connection tracking (sing-box Clash API). Backends that do
// not implement it report empty connections.
type ConnectionBackend interface {
	Connections() []proto.Connection
	CloseConnection(id string) error
	CloseAllConnections() error
}

// StatsBackend is an optional interface for richer traffic statistics
// beyond the simple byte counters in Stats(). Returns time-series data.
type StatsBackend interface {
	TrafficStats() proto.TrafficStats
	ResetStats() error
}

// TestBackend is an optional interface for URL latency tests, IP egress
// detection, and speed tests through the active tunnel.
type TestBackend interface {
	TestURL(ctx context.Context, url string) (proto.TestResult, error)
	TestIP(ctx context.Context) (proto.IPInfo, error)
	SpeedTest(ctx context.Context) (proto.SpeedTestResult, error)
}

// ConfigurableSpeedBackend optionally accepts provider-defined bounded probe settings.
type ConfigurableSpeedBackend interface {
	SpeedTestWithPolicy(ctx context.Context, policy *proto.SpeedProbePolicy) (proto.SpeedTestResult, error)
}

// ProxyListener-aware backends expose loopback proxy endpoints (SOCKS
// and HTTP) once Start has succeeded. Backends that do not actually
// open ports (e.g. MockBackend) simply do not implement this and Status
// will report empty proxy fields.
type ProxyListener interface {
	Proxies() (socks, http string)
}

// RuntimeHealthBackend is implemented by engines that can detect a child
// runtime exit after a successful Start. It is intentionally optional so mock
// and embedded backends keep the existing contract.
type RuntimeHealthBackend interface {
	RuntimeHealth() error
}

// Manager owns the connection state and is safe for concurrent use.
type Manager struct {
	mu      sync.Mutex
	st      proto.Status
	store   *store.Store
	backend Backend
	cancel  context.CancelFunc
	subs    []chan proto.Status
	version string
	pid     int
	started time.Time
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
	// Reaching this method over the authenticated loopback API is itself proof
	// that mosaicd is alive. `agent_connected` must not mirror tunnel state.
	st.AgentConnected = true
	if m.backend != nil && st.State == proto.StateConnected {
		in, out, lat := m.backend.Stats()
		st.BytesIn = in
		st.BytesOut = out
		st.LatencyMS = lat
		if p, ok := m.backend.(ProxyListener); ok {
			st.ProxySOCKS, st.ProxyHTTP = p.Proxies()
		}
	}
	return st
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
func (m *Manager) Connect(ctx context.Context, serverID string) error {
	server, ok := m.store.FindServer(serverID)
	if !ok {
		return fmt.Errorf("server %q not found", serverID)
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
	m.mu.Unlock()

	if err := m.store.SetLastServer(serverID); err != nil {
		logx.Warn("could not persist last server", "err", err)
	}
	m.watchRuntime(cctx, server)
	return nil
}

// watchRuntime changes the visible session to error only when a backend that
// opted into RuntimeHealth reports an unexpected failure. Its context is
// cancelled by Disconnect, so an old connection can never overwrite a newer
// connection's state.
func (m *Manager) watchRuntime(ctx context.Context, server proto.Server) {
	health, ok := m.backend.(RuntimeHealthBackend)
	if !ok {
		return
	}
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				err := health.RuntimeHealth()
				if err == nil {
					continue
				}
				m.mu.Lock()
				if ctx.Err() == nil && m.st.State == proto.StateConnected &&
					m.st.Server != nil && m.st.Server.ID == server.ID {
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
				}
				m.mu.Unlock()
				return
			}
		}
	}()
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

// Started returns when the daemon began running.
func (m *Manager) Started() time.Time { return m.started }

// PID returns the daemon process id.
func (m *Manager) PID() int { return m.pid }

// Version returns the daemon version string.
func (m *Manager) Version() string { return m.version }

// Connections returns live connections if the backend supports it.
func (m *Manager) Connections() []proto.Connection {
	if cb, ok := m.backend.(ConnectionBackend); ok {
		return cb.Connections()
	}
	return []proto.Connection{}
}

// CloseConnection closes a specific connection by id.
func (m *Manager) CloseConnection(id string) error {
	if cb, ok := m.backend.(ConnectionBackend); ok {
		return cb.CloseConnection(id)
	}
	return errors.New("connection tracking not supported by current backend")
}

// CloseAllConnections closes all live connections.
func (m *Manager) CloseAllConnections() error {
	if cb, ok := m.backend.(ConnectionBackend); ok {
		return cb.CloseAllConnections()
	}
	return errors.New("connection tracking not supported by current backend")
}

// Stats returns detailed traffic statistics if the backend supports it.
// Falls back to a basic snapshot from Status() counters.
func (m *Manager) Stats() proto.TrafficStats {
	if sb, ok := m.backend.(StatsBackend); ok {
		return sb.TrafficStats()
	}
	// Fallback: construct from basic Stats() counters.
	st := m.Status()
	return proto.TrafficStats{
		TotalBytesIn:  st.BytesIn,
		TotalBytesOut: st.BytesOut,
	}
}

// ResetStats resets the traffic counters if the backend supports it.
func (m *Manager) ResetStats() error {
	if sb, ok := m.backend.(StatsBackend); ok {
		return sb.ResetStats()
	}
	return errors.New("stats reset not supported by current backend")
}

// TestURL tests latency to a URL through the active tunnel.
func (m *Manager) TestURL(ctx context.Context, url string) (proto.TestResult, error) {
	if tb, ok := m.backend.(TestBackend); ok {
		return tb.TestURL(ctx, url)
	}
	return proto.TestResult{}, errors.New("URL testing not supported by current backend")
}

// TestIP queries the apparent egress IP through the active tunnel.
func (m *Manager) TestIP(ctx context.Context) (proto.IPInfo, error) {
	if tb, ok := m.backend.(TestBackend); ok {
		return tb.TestIP(ctx)
	}
	return proto.IPInfo{}, errors.New("IP testing not supported by current backend")
}

// SpeedTest runs a download/upload speed test through the active tunnel.
func (m *Manager) SpeedTest(ctx context.Context) (proto.SpeedTestResult, error) {
	return m.SpeedTestWithPolicy(ctx, nil)
}

func (m *Manager) SpeedTestWithPolicy(ctx context.Context, policy *proto.SpeedProbePolicy) (proto.SpeedTestResult, error) {
	if cb, ok := m.backend.(ConfigurableSpeedBackend); ok {
		return cb.SpeedTestWithPolicy(ctx, policy)
	}
	if tb, ok := m.backend.(TestBackend); ok {
		return tb.SpeedTest(ctx)
	}
	return proto.SpeedTestResult{}, errors.New("speed testing not supported by current backend")
}

// HotReload reloads the running backend configuration without dropping the tunnel.
func (m *Manager) HotReload(ctx context.Context) error {
	m.mu.Lock()
	if m.st.State != proto.StateConnected || m.st.Server == nil {
		m.mu.Unlock()
		return nil
	}
	serverID := m.st.Server.ID
	m.mu.Unlock()

	server, ok := m.store.FindServer(serverID)
	if !ok {
		snap := m.store.Snapshot()
		if len(snap.Servers) > 0 {
			server = snap.Servers[0]
			serverID = server.ID
		} else {
			return nil
		}
	}

	snap := m.store.Snapshot()
	if hb, ok := m.backend.(interface {
		HotReload(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error
	}); ok {
		if err := hb.HotReload(ctx, server, snap.Prefs, snap.Rules); err != nil {
			logx.Warn("hot reload failed, reconnecting", "err", err)
			return m.Connect(ctx, serverID)
		}
	} else {
		return m.Connect(ctx, serverID)
	}

	m.mu.Lock()
	m.st.Server = &server
	m.mu.Unlock()
	return nil
}

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
