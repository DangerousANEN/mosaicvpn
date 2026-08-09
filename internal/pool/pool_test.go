package pool

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// --- test doubles -----------------------------------------------------------

// fakeChecker returns a scripted result per endpoint. HealthCheckAll probes
// nodes concurrently, so the counter is mutex-guarded.
type fakeChecker struct {
	latency time.Duration
	err     error
	// failing endpoints (host:port) always error, regardless of the defaults.
	failing map[string]bool

	mu    sync.Mutex
	calls int
}

func (f *fakeChecker) Check(_ context.Context, endpoint string) (time.Duration, error) {
	f.mu.Lock()
	f.calls++
	f.mu.Unlock()

	if f.failing[endpoint] {
		return 0, errors.New("connection refused")
	}
	if f.err != nil {
		return 0, f.err
	}
	return f.latency, nil
}

// callCount reports how many probes ran.
func (f *fakeChecker) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls
}

// v2raySource builds a base64 v2ray subscription body with n vless nodes.
func v2raySource(n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "vless://11111111-2222-3333-4444-55555555555%d@node%d.example.com:%d?type=tcp&security=tls#Node%d\n",
			i, i, 8443+i, i)
	}
	return base64.StdEncoding.EncodeToString([]byte(b.String()))
}

// --- source validation ------------------------------------------------------

func TestSourceValidate_RejectsPlainHTTP(t *testing.T) {
	s := Source{URL: "http://example.org/sub.txt", Enabled: true}
	err := s.Validate()
	if !errors.Is(err, ErrInsecureSource) {
		t.Fatalf("expected ErrInsecureSource for http:// source, got %v", err)
	}
}

func TestSourceValidate_RejectsOtherSchemes(t *testing.T) {
	for _, raw := range []string{
		"ftp://example.org/sub.txt",
		"ws://example.org/sub",
		"file:///etc/passwd",
	} {
		s := Source{URL: raw}
		if err := s.Validate(); !errors.Is(err, ErrInsecureSource) {
			t.Errorf("source %q: expected ErrInsecureSource, got %v", raw, err)
		}
	}
}

func TestSourceValidate_RejectsEmpty(t *testing.T) {
	s := Source{URL: "   "}
	if err := s.Validate(); !errors.Is(err, ErrEmptySourceURL) {
		t.Fatalf("expected ErrEmptySourceURL, got %v", err)
	}
}

func TestSourceValidate_AcceptsHTTPSAndFillsDefaults(t *testing.T) {
	s := Source{URL: "https://example.org/sub.txt", Enabled: true}
	if err := s.Validate(); err != nil {
		t.Fatalf("https source rejected: %v", err)
	}
	if s.TimeoutSec != int(DefaultSourceTimeout/time.Second) {
		t.Errorf("timeout default = %d, want %d", s.TimeoutSec, int(DefaultSourceTimeout/time.Second))
	}
	if s.MaxBytes != DefaultMaxBytes {
		t.Errorf("max bytes default = %d, want %d", s.MaxBytes, DefaultMaxBytes)
	}
	if s.Trust != TrustMedium {
		t.Errorf("trust default = %q, want %q", s.Trust, TrustMedium)
	}
}

func TestNew_RejectsPoolWithInsecureSource(t *testing.T) {
	_, err := New([]Source{
		{URL: "https://good.example.org/sub", Enabled: true},
		{URL: "http://bad.example.org/sub", Enabled: true},
	})
	if !errors.Is(err, ErrInsecureSource) {
		t.Fatalf("expected New to reject insecure source, got %v", err)
	}
}

func TestTrustAffectsStartingWeight(t *testing.T) {
	if TrustHigh.startingWeight() <= TrustMedium.startingWeight() {
		t.Error("high trust should outweigh medium")
	}
	if TrustMedium.startingWeight() <= TrustLow.startingWeight() {
		t.Error("medium trust should outweigh low")
	}
}

// --- refresh ----------------------------------------------------------------

func TestRefresh_ParsesNodesAsCandidates(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(v2raySource(3)))
	}))
	defer srv.Close()

	p := newTestPool(t, srv, Source{URL: srv.URL, Enabled: true, Trust: TrustHigh}, nil)

	res, err := p.Refresh(context.Background())
	if err != nil {
		t.Fatalf("refresh: %v", err)
	}
	if res.NodesAdded != 3 {
		t.Fatalf("added %d nodes, want 3", res.NodesAdded)
	}

	st := p.Stats()
	if st.Candidate != 3 || st.Alive != 0 {
		t.Errorf("stats = %+v, want 3 candidates and 0 alive before health check", st)
	}
}

func TestRefresh_RejectsOversizeBody(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(strings.Repeat("A", 4096)))
	}))
	defer srv.Close()

	p := newTestPool(t, srv, Source{URL: srv.URL, Enabled: true, MaxBytes: 512}, nil)

	_, err := p.Refresh(context.Background())
	if err == nil {
		t.Fatal("expected refresh to fail on oversize body")
	}
	if !strings.Contains(err.Error(), ErrResponseTooLarge.Error()) {
		t.Errorf("error = %v, want it to mention %v", err, ErrResponseTooLarge)
	}
}

func TestRefresh_ErrorsWhenNoSourcesEnabled(t *testing.T) {
	p, err := New([]Source{{URL: "https://example.org/sub", Enabled: false}})
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if _, err := p.Refresh(context.Background()); !errors.Is(err, ErrNoEnabledSources) {
		t.Fatalf("expected ErrNoEnabledSources, got %v", err)
	}
}

func TestRefresh_PreservesLifecycleStateOnRepeat(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(v2raySource(2)))
	}))
	defer srv.Close()

	checker := &fakeChecker{latency: 40 * time.Millisecond}
	p := newTestPool(t, srv, Source{URL: srv.URL, Enabled: true}, checker)

	if _, err := p.Refresh(context.Background()); err != nil {
		t.Fatalf("first refresh: %v", err)
	}
	p.HealthCheckAll(context.Background())
	if got := p.Stats().Alive; got != 2 {
		t.Fatalf("alive after health check = %d, want 2", got)
	}

	// Second refresh must not knock alive nodes back to candidate.
	res, err := p.Refresh(context.Background())
	if err != nil {
		t.Fatalf("second refresh: %v", err)
	}
	if res.NodesAdded != 0 {
		t.Errorf("second refresh added %d nodes, want 0", res.NodesAdded)
	}
	if got := p.Stats().Alive; got != 2 {
		t.Errorf("alive after second refresh = %d, want 2 (state must survive refresh)", got)
	}
}

// --- lifecycle --------------------------------------------------------------

func TestLifecycle_FirstFailureRejectsNeverAliveNode(t *testing.T) {
	p := poolWithNodes(t, 1)
	p.health = &fakeChecker{err: errors.New("unreachable")}

	p.HealthCheckAll(context.Background())

	if st := p.Stats(); st.Rejected != 1 || st.Dead != 0 {
		t.Fatalf("stats = %+v, want 1 rejected and 0 dead (node never proved itself)", st)
	}
}

func TestLifecycle_AliveNodeDiesOnlyAfterMaxRetries(t *testing.T) {
	p := poolWithNodes(t, 1)
	good := &fakeChecker{latency: 30 * time.Millisecond}
	p.health = good

	p.HealthCheckAll(context.Background())
	if p.Stats().Alive != 1 {
		t.Fatal("node should be alive after a passing probe")
	}

	p.health = &fakeChecker{err: errors.New("timeout")}
	for i := 1; i < DefaultMaxRetries; i++ {
		p.HealthCheckAll(context.Background())
		if p.Stats().Dead != 0 {
			t.Fatalf("node died after %d failures, want it to survive until %d", i, DefaultMaxRetries)
		}
	}

	p.HealthCheckAll(context.Background())
	if st := p.Stats(); st.Dead != 1 {
		t.Fatalf("stats = %+v, want 1 dead after %d failures", st, DefaultMaxRetries)
	}
}

func TestLifecycle_DeadNodeReturnsToCandidateAfterDelay(t *testing.T) {
	now := time.Now()
	clock := func() time.Time { return now }

	p := poolWithNodes(t, 1, WithClock(clock))
	p.health = &fakeChecker{latency: 20 * time.Millisecond}
	p.HealthCheckAll(context.Background())

	p.health = &fakeChecker{err: errors.New("down")}
	for i := 0; i < DefaultMaxRetries; i++ {
		p.HealthCheckAll(context.Background())
	}
	if p.Stats().Dead != 1 {
		t.Fatal("setup: node should be dead")
	}

	// Before the delay elapses it stays dead.
	p.promoteExpiredDead()
	if p.Stats().Dead != 1 {
		t.Error("node left dead state before DeadRetryDelay elapsed")
	}

	now = now.Add(DeadRetryDelay + time.Minute)
	p.promoteExpiredDead()
	if st := p.Stats(); st.Candidate != 1 || st.Dead != 0 {
		t.Fatalf("stats = %+v, want node back to candidate after retry delay", st)
	}
}

func TestLifecycle_RecoveryResetsFailureCount(t *testing.T) {
	p := poolWithNodes(t, 1)
	p.health = &fakeChecker{latency: 25 * time.Millisecond}
	p.HealthCheckAll(context.Background())

	p.health = &fakeChecker{err: errors.New("blip")}
	p.HealthCheckAll(context.Background())

	p.health = &fakeChecker{latency: 25 * time.Millisecond}
	p.HealthCheckAll(context.Background())

	nodes := p.AliveNodes()
	if len(nodes) != 1 {
		t.Fatalf("alive nodes = %d, want 1", len(nodes))
	}
	if nodes[0].ConsecutiveFails != 0 {
		t.Errorf("consecutive fails = %d after recovery, want 0", nodes[0].ConsecutiveFails)
	}
}

func TestHealthCheckAll_ProbesEveryLiveNode(t *testing.T) {
	p := poolWithNodes(t, 5)
	checker := &fakeChecker{latency: 30 * time.Millisecond}
	p.health = checker

	p.HealthCheckAll(context.Background())

	if got := checker.callCount(); got != 5 {
		t.Fatalf("probed %d nodes, want 5", got)
	}
	if st := p.Stats(); st.Alive != 5 {
		t.Errorf("stats = %+v, want all 5 alive", st)
	}
}

func TestHealthCheckAll_SkipsRejectedNodes(t *testing.T) {
	p := poolWithNodes(t, 3)
	p.health = &fakeChecker{err: errors.New("down")}
	p.HealthCheckAll(context.Background()) // all rejected

	// Rejected nodes are out of service; a later sweep must not waste probes
	// on them.
	counter := &fakeChecker{latency: 20 * time.Millisecond}
	p.health = counter
	p.HealthCheckAll(context.Background())

	if got := counter.callCount(); got != 0 {
		t.Fatalf("probed %d rejected nodes, want 0", got)
	}
}

func TestPrune_RemovesRejectedKeepsDead(t *testing.T) {
	p := poolWithNodes(t, 2)
	p.health = &fakeChecker{err: errors.New("nope")}
	p.HealthCheckAll(context.Background()) // both rejected (never alive)

	if got := p.Prune(); got != 2 {
		t.Fatalf("pruned %d, want 2", got)
	}
	if st := p.Stats(); st.Total != 0 {
		t.Errorf("stats = %+v, want empty pool after prune", st)
	}
}

// --- output shape -----------------------------------------------------------

func TestAliveNodes_SortedByLatency(t *testing.T) {
	p := poolWithNodes(t, 3)
	p.health = &fakeChecker{latency: 50 * time.Millisecond}
	p.HealthCheckAll(context.Background())

	// Rewrite latencies to a known unsorted order.
	p.mu.Lock()
	i := 0
	for _, n := range p.nodes {
		n.LatencyMs = []int{300, 100, 200}[i]
		i++
	}
	p.mu.Unlock()

	alive := p.AliveNodes()
	if len(alive) != 3 {
		t.Fatalf("alive = %d, want 3", len(alive))
	}
	for i := 1; i < len(alive); i++ {
		if alive[i-1].LatencyMs > alive[i].LatencyMs {
			t.Fatalf("not sorted ascending: %d before %d", alive[i-1].LatencyMs, alive[i].LatencyMs)
		}
	}
}

func TestNodeRefs_CarryLoadEstimate(t *testing.T) {
	p := poolWithNodes(t, 1)
	p.health = &fakeChecker{latency: 60 * time.Millisecond}
	p.HealthCheckAll(context.Background())

	alive := p.AliveNodes()
	if len(alive) != 1 {
		t.Fatalf("alive = %d, want 1", len(alive))
	}
	id := alive[0].ID()

	for i := 0; i < saturationAssignments/2; i++ {
		p.LoadTracker().RecordAssignment(id)
	}

	refs := p.NodeRefs()
	if len(refs) != 1 {
		t.Fatalf("refs = %d, want 1", len(refs))
	}
	if refs[0].Load <= 0 {
		t.Errorf("load = %v, want > 0 after assignments", refs[0].Load)
	}
	if !refs[0].Alive {
		t.Error("ref should be marked alive")
	}
	if refs[0].LatencyMs <= 0 {
		t.Error("ref should carry probe latency")
	}
}

// --- helpers ----------------------------------------------------------------

// newTestPool builds a pool that talks to the given TLS test server.
func newTestPool(t *testing.T, srv *httptest.Server, src Source, checker HealthChecker) *Pool {
	t.Helper()
	if checker == nil {
		checker = &fakeChecker{latency: 50 * time.Millisecond}
	}
	p, err := New([]Source{src},
		WithHTTPClient(srv.Client()),
		WithHealthChecker(checker),
	)
	if err != nil {
		t.Fatalf("new pool: %v", err)
	}
	return p
}

// poolWithNodes builds a pool pre-seeded with n candidate nodes, no network.
func poolWithNodes(t *testing.T, n int, opts ...Option) *Pool {
	t.Helper()
	p, err := New([]Source{{URL: "https://example.org/sub", Enabled: true}}, opts...)
	if err != nil {
		t.Fatalf("new pool: %v", err)
	}
	for i := 0; i < n; i++ {
		id := fmt.Sprintf("node-%d", i)
		p.nodes[id] = &Node{
			Server: proto.Server{
				ID:      id,
				Name:    "Test " + id,
				Address: fmt.Sprintf("10.0.0.%d", i+1),
				Port:    8443 + i,
			},
			State:  NodeStateCandidate,
			Weight: 50,
		}
	}
	return p
}
