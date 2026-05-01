// Package egress runs auxiliary long-lived proxy listeners ("egresses")
// independently of the main user-facing Connect/Disconnect flow (rc44).
// Each egress is a separate sing-box subprocess pinned to a single
// server, exposing one SOCKS5 or HTTP inbound on a user-chosen port.
// Useful for routing specific apps through a different geo without
// flipping the main tunnel.
package egress

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// Manager owns the per-egress sing-box subprocesses.  All operations
// are safe to call concurrently from the HTTP API and the MCP server.
type Manager struct {
	mu      sync.Mutex
	binary  string
	dataDir string
	store   *store.Store
	running map[string]*runtime
}

// runtime is the live state of one egress subprocess.
type runtime struct {
	cancel    context.CancelFunc
	cmd       *exec.Cmd
	startedAt time.Time
	lastError string
	pid       int
}

// New returns a fresh Manager.  binary is the absolute path to
// sing-box.exe (or "" to use state.LocateSingBox()), dataDir is where
// per-egress configs and logs land — typically the same daemon data
// directory used by the main tunnel.
func New(binary, dataDir string, st *store.Store) *Manager {
	return &Manager{
		binary:  binary,
		dataDir: dataDir,
		store:   st,
		running: make(map[string]*runtime),
	}
}

// AutoStartAll starts every egress whose AutoStart flag is true.  Used
// by mosaicd at daemon launch.  Errors are logged but do not abort
// startup — a single misconfigured egress should not block the whole
// daemon from coming up.
func (m *Manager) AutoStartAll(ctx context.Context) {
	snap := m.store.Snapshot()
	for _, eg := range snap.Egresses {
		if !eg.AutoStart {
			continue
		}
		if err := m.Start(ctx, eg.ID); err != nil {
			logx.Warn("egress auto-start failed", "id", eg.ID, "name", eg.Name, "err", err)
		}
	}
}

// Start launches the sing-box subprocess for the egress with the given
// id.  Idempotent: starting an already-running egress is a no-op.
func (m *Manager) Start(ctx context.Context, id string) error {
	m.mu.Lock()
	if _, alive := m.running[id]; alive {
		m.mu.Unlock()
		return nil
	}
	m.mu.Unlock()

	cfg, ok := m.store.FindEgress(id)
	if !ok {
		return fmt.Errorf("egress %q not found", id)
	}
	server, ok := m.store.FindServer(cfg.ServerID)
	if !ok {
		return fmt.Errorf("egress %q: server %q not found", id, cfg.ServerID)
	}
	prefs := m.store.Snapshot().Prefs
	// Force proxy mode — egresses must never open a TUN inbound.
	prefs.TunnelMode = "proxy"

	cfgBytes, err := state.BuildEgressConfig(cfg, server, prefs)
	if err != nil {
		return fmt.Errorf("egress %q: build config: %w", id, err)
	}

	bin := m.binary
	if bin == "" {
		bin = state.LocateSingBox()
	}
	if bin == "" {
		return errors.New("sing-box binary not found")
	}
	dataDir := m.dataDir
	if dataDir == "" {
		dataDir = os.TempDir()
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return fmt.Errorf("egress %q: ensure data dir: %w", id, err)
	}
	cfgPath := filepath.Join(dataDir, fmt.Sprintf("singbox-egress-%s.json", id))
	if err := os.WriteFile(cfgPath, cfgBytes, 0o600); err != nil {
		return fmt.Errorf("egress %q: write config: %w", id, err)
	}

	rctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(rctx, bin, "run", "-c", cfgPath, "-D", dataDir)
	cmd.Dir = dataDir
	logPath := filepath.Join(dataDir, fmt.Sprintf("singbox-egress-%s.log", id))
	if logFile, err := os.Create(logPath); err == nil {
		cmd.Stdout = logFile
		cmd.Stderr = logFile
	}
	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("egress %q: spawn sing-box: %w", id, err)
	}

	rt := &runtime{
		cancel:    cancel,
		cmd:       cmd,
		startedAt: time.Now().UTC(),
		pid:       cmd.Process.Pid,
	}
	m.mu.Lock()
	m.running[id] = rt
	m.mu.Unlock()

	go m.reapAfterExit(id, rt)
	logx.Info("egress started", "id", id, "name", cfg.Name, "port", cfg.Port, "protocol", cfg.Protocol, "pid", rt.pid)
	return nil
}

// reapAfterExit waits for the subprocess to terminate and clears the
// running entry.  Captures the exit error so /v1/egresses can report
// "running=false, last_error=..." for the user.
func (m *Manager) reapAfterExit(id string, rt *runtime) {
	err := rt.cmd.Wait()
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.running[id]
	if !ok || cur != rt {
		return
	}
	if err != nil {
		cur.lastError = err.Error()
	}
	delete(m.running, id)
}

// Stop terminates the egress subprocess.  Idempotent: stopping an
// already-stopped egress is a no-op.
func (m *Manager) Stop(_ context.Context, id string) error {
	m.mu.Lock()
	rt, ok := m.running[id]
	if !ok {
		m.mu.Unlock()
		return nil
	}
	delete(m.running, id)
	m.mu.Unlock()

	rt.cancel()
	_ = rt.cmd.Process.Kill()
	_, _ = rt.cmd.Process.Wait()
	logx.Info("egress stopped", "id", id)
	return nil
}

// StopAll terminates every running egress.  Called from mosaicd's
// graceful shutdown path so we don't leak sing-box processes.
func (m *Manager) StopAll() {
	m.mu.Lock()
	ids := make([]string, 0, len(m.running))
	for id := range m.running {
		ids = append(ids, id)
	}
	m.mu.Unlock()
	for _, id := range ids {
		_ = m.Stop(context.Background(), id)
	}
}

// Status returns the live state of one egress.
func (m *Manager) Status(id string) proto.EgressStatus {
	m.mu.Lock()
	defer m.mu.Unlock()
	rt, ok := m.running[id]
	if !ok {
		return proto.EgressStatus{Running: false}
	}
	return proto.EgressStatus{
		Running:   true,
		StartedAt: rt.startedAt,
		LastError: rt.lastError,
		PID:       rt.pid,
	}
}

// ListStatus returns the live state of every egress, indexed by id.
// Egresses configured but not running show Running=false.
func (m *Manager) ListStatus() map[string]proto.EgressStatus {
	snap := m.store.Snapshot()
	out := make(map[string]proto.EgressStatus, len(snap.Egresses))
	for _, eg := range snap.Egresses {
		out[eg.ID] = m.Status(eg.ID)
	}
	return out
}
