package state

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"github.com/DangerousANEN/mosaic/internal/proto"
	"github.com/DangerousANEN/mosaic/internal/store"
)

// MockBackend simulates a VPN connection without touching the network. It
// is used until the real sing-box backend is wired up (Phase 2) and is
// also handy in tests.
type MockBackend struct {
	mu        sync.Mutex
	running   bool
	startErr  error
	bytesIn   atomic.Uint64
	bytesOut  atomic.Uint64
	latency   int
	connectAt time.Time
	stopCh    chan struct{}
	tickEvery time.Duration
}

// NewMockBackend returns a MockBackend that ramps up bytes counters at a
// realistic rate while connected.
func NewMockBackend() *MockBackend {
	return &MockBackend{
		tickEvery: 200 * time.Millisecond,
		latency:   38,
	}
}

// Name implements Backend.
func (m *MockBackend) Name() string { return "mock" }

// SetStartError makes the next Start return err.
func (m *MockBackend) SetStartError(err error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.startErr = err
}

// Start implements Backend.
func (m *MockBackend) Start(ctx context.Context, server proto.Server, prefs store.Prefs, rules []proto.Rule) error {
	m.mu.Lock()
	if m.running {
		m.mu.Unlock()
		return errors.New("mock backend already running")
	}
	if m.startErr != nil {
		err := m.startErr
		m.startErr = nil
		m.mu.Unlock()
		return err
	}
	m.running = true
	m.connectAt = time.Now().UTC()
	m.bytesIn.Store(0)
	m.bytesOut.Store(0)
	m.stopCh = make(chan struct{})
	stopCh := m.stopCh
	m.mu.Unlock()

	go m.tick(ctx, stopCh)
	return nil
}

// Stop implements Backend.
func (m *MockBackend) Stop(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if !m.running {
		return nil
	}
	m.running = false
	if m.stopCh != nil {
		close(m.stopCh)
		m.stopCh = nil
	}
	return nil
}

// Stats implements Backend.
func (m *MockBackend) Stats() (uint64, uint64, int) {
	return m.bytesIn.Load(), m.bytesOut.Load(), m.latency
}

func (m *MockBackend) tick(ctx context.Context, stop <-chan struct{}) {
	t := time.NewTicker(m.tickEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-stop:
			return
		case <-t.C:
			// Simulate ~12 MB/s down, ~860 KB/s up
			m.bytesIn.Add(2_500_000)
			m.bytesOut.Add(170_000)
		}
	}
}
