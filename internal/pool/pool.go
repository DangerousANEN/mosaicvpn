package pool

import (
	"context"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

// NodeState is a node's position in the pool lifecycle, per
// docs/GROUP_SYSTEM_SPEC.md §5.2:
//
//	source -> candidate -> alive
//	              |          |
//	          rejected     dead (after MaxRetries) -> candidate (retry)
type NodeState string

const (
	// NodeStateCandidate means fetched from a source but not yet proven.
	NodeStateCandidate NodeState = "candidate"
	// NodeStateAlive means the last health check succeeded.
	NodeStateAlive NodeState = "alive"
	// NodeStateRejected means the node failed its very first health check and
	// never entered service.
	NodeStateRejected NodeState = "rejected"
	// NodeStateDead means a previously alive node exhausted its retries.
	NodeStateDead NodeState = "dead"
)

// TrustLevel affects a node's starting weight. We do not treat every random
// public source as equally reliable.
type TrustLevel string

const (
	TrustHigh   TrustLevel = "high"
	TrustMedium TrustLevel = "medium"
	TrustLow    TrustLevel = "low"
)

// startingWeight maps trust to the initial static weight (1..100).
func (t TrustLevel) startingWeight() int {
	switch t {
	case TrustHigh:
		return 80
	case TrustLow:
		return 20
	default:
		return 50
	}
}

// Lifecycle and safety defaults.
const (
	// DefaultMaxRetries is how many consecutive health failures an alive node
	// tolerates before being marked dead.
	DefaultMaxRetries = 3
	// DeadRetryDelay is how long a dead node waits before returning to
	// candidate for another chance.
	DeadRetryDelay = 10 * time.Minute
	// DefaultSourceTimeout bounds a single source fetch.
	DefaultSourceTimeout = 15 * time.Second
	// DefaultMaxBytes bounds a source response body (2 MiB).
	DefaultMaxBytes = 2 * 1024 * 1024
	// healthDialTimeout bounds a single TCP health probe.
	healthDialTimeout = 5 * time.Second
)

// Errors returned during source validation and refresh.
var (
	// ErrInsecureSource is returned for any source that is not HTTPS. Pool
	// subscriptions travel over the open internet; plaintext would let a
	// network attacker hand us arbitrary proxy nodes to route users through.
	ErrInsecureSource = errors.New("pool source must use https")
	// ErrEmptySourceURL is returned for a blank source URL.
	ErrEmptySourceURL = errors.New("pool source url is empty")
	// ErrNoEnabledSources is returned when a refresh finds nothing to fetch.
	ErrNoEnabledSources = errors.New("no enabled pool sources configured")
	// ErrResponseTooLarge is returned when a source body exceeds its limit.
	ErrResponseTooLarge = errors.New("pool source response exceeds max_bytes")
)

// Source is a configured provider of free nodes. Sources come from config, not
// from hardcoded constants, so operators can change them without a rebuild.
type Source struct {
	URL        string       `json:"url" yaml:"url"`
	Format     proto.Format `json:"format" yaml:"format"` // empty/"auto" => auto-detect
	Enabled    bool         `json:"enabled" yaml:"enabled"`
	Trust      TrustLevel   `json:"trust" yaml:"trust"`
	TimeoutSec int          `json:"timeout_sec" yaml:"timeout_sec"`
	MaxBytes   int64        `json:"max_bytes" yaml:"max_bytes"`
}

// Validate enforces the HTTPS-only rule and fills defaults. It rejects at
// configuration time rather than silently skipping at fetch time, so a
// misconfigured source is loud instead of invisible.
func (s *Source) Validate() error {
	raw := strings.TrimSpace(s.URL)
	if raw == "" {
		return ErrEmptySourceURL
	}

	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("pool source %q: %w", raw, err)
	}
	if !strings.EqualFold(u.Scheme, "https") {
		return fmt.Errorf("pool source %q (scheme %q): %w", raw, u.Scheme, ErrInsecureSource)
	}
	if u.Host == "" {
		return fmt.Errorf("pool source %q: missing host", raw)
	}

	s.URL = raw
	if s.TimeoutSec <= 0 {
		s.TimeoutSec = int(DefaultSourceTimeout / time.Second)
	}
	if s.MaxBytes <= 0 {
		s.MaxBytes = DefaultMaxBytes
	}
	if s.Trust == "" {
		s.Trust = TrustMedium
	}
	return nil
}

// timeout returns the per-source fetch timeout.
func (s Source) timeout() time.Duration {
	if s.TimeoutSec <= 0 {
		return DefaultSourceTimeout
	}
	return time.Duration(s.TimeoutSec) * time.Second
}

// ID is a stable identifier for the source, derived from its URL.
func (s Source) ID() string {
	sum := sha1.Sum([]byte(s.URL))
	return "src_" + hex.EncodeToString(sum[:])[:10]
}

// Node is a pool node plus its lifecycle and health bookkeeping.
type Node struct {
	Server   proto.Server `json:"server"`
	SourceID string       `json:"source_id"`
	State    NodeState    `json:"state"`
	Weight   int          `json:"weight"`

	ConsecutiveFails int       `json:"consecutive_fails"`
	LastCheck        time.Time `json:"last_check,omitempty"`
	LastAlive        time.Time `json:"last_alive,omitempty"`
	DeadUntil        time.Time `json:"dead_until,omitempty"`
	LatencyMs        int       `json:"latency_ms"`
	LastError        string    `json:"last_error,omitempty"`
}

// ID returns the node's underlying server ID.
func (n *Node) ID() string { return n.Server.ID }

// endpoint returns host:port for probing.
func (n *Node) endpoint() string {
	return net.JoinHostPort(n.Server.Address, fmt.Sprint(n.Server.Port))
}

// HealthChecker probes whether a node is reachable, returning latency.
// Swapped out in tests so the suite never touches the network.
type HealthChecker interface {
	Check(ctx context.Context, endpoint string) (time.Duration, error)
}

// tcpHealthChecker probes reachability with a plain TCP connect. It proves the
// endpoint accepts connections; it deliberately does not attempt a protocol
// handshake, which would require per-protocol credentials.
type tcpHealthChecker struct{ timeout time.Duration }

func (c tcpHealthChecker) Check(ctx context.Context, endpoint string) (time.Duration, error) {
	timeout := c.timeout
	if timeout <= 0 {
		timeout = healthDialTimeout
	}
	dialer := net.Dialer{Timeout: timeout}

	start := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", endpoint)
	if err != nil {
		return 0, err
	}
	_ = conn.Close()
	return time.Since(start), nil
}

// Pool holds free nodes gathered from configured HTTPS sources.
type Pool struct {
	mu      sync.RWMutex
	sources []Source
	nodes   map[string]*Node

	client  *http.Client
	health  HealthChecker
	load    *LoadTracker
	now     func() time.Time
	retries int
}

// Option customises a Pool at construction.
type Option func(*Pool)

// WithHTTPClient overrides the HTTP client used to fetch sources.
func WithHTTPClient(c *http.Client) Option {
	return func(p *Pool) {
		if c != nil {
			p.client = c
		}
	}
}

// WithHealthChecker overrides the health probe.
func WithHealthChecker(h HealthChecker) Option {
	return func(p *Pool) {
		if h != nil {
			p.health = h
		}
	}
}

// WithClock overrides the time source. Tests use this to advance past
// DeadRetryDelay without sleeping.
func WithClock(now func() time.Time) Option {
	return func(p *Pool) {
		if now != nil {
			p.now = now
			p.load.mu.Lock()
			p.load.now = now
			p.load.mu.Unlock()
		}
	}
}

// WithMaxRetries overrides the failure tolerance before a node is dead.
func WithMaxRetries(n int) Option {
	return func(p *Pool) {
		if n > 0 {
			p.retries = n
		}
	}
}

// New builds a Pool. Sources are validated; any invalid source is an error and
// no partial configuration is retained.
func New(sources []Source, opts ...Option) (*Pool, error) {
	validated := make([]Source, 0, len(sources))
	for i := range sources {
		s := sources[i]
		if err := s.Validate(); err != nil {
			return nil, err
		}
		validated = append(validated, s)
	}

	p := &Pool{
		sources: validated,
		nodes:   make(map[string]*Node),
		client:  &http.Client{Timeout: DefaultSourceTimeout},
		load:    NewLoadTracker(),
		now:     time.Now,
		retries: DefaultMaxRetries,
	}
	p.health = tcpHealthChecker{timeout: healthDialTimeout}

	for _, opt := range opts {
		opt(p)
	}
	return p, nil
}

// LoadTracker exposes the pool's load estimator so callers can record their
// own client assignments against pool nodes.
func (p *Pool) LoadTracker() *LoadTracker { return p.load }

// Sources returns a copy of the validated source list.
func (p *Pool) Sources() []Source {
	p.mu.RLock()
	defer p.mu.RUnlock()
	out := make([]Source, len(p.sources))
	copy(out, p.sources)
	return out
}

// RefreshResult reports the outcome of a Refresh pass.
type RefreshResult struct {
	SourcesFetched  int
	SourcesFailed   int
	NodesDiscovered int
	NodesAdded      int
	Errors          []error
}

// Refresh fetches every enabled source and merges the results into the pool.
// New nodes enter as candidates; nodes already known keep their lifecycle
// state so a refresh does not reset health history.
func (p *Pool) Refresh(ctx context.Context) (RefreshResult, error) {
	sources := p.Sources()

	enabled := make([]Source, 0, len(sources))
	for _, s := range sources {
		if s.Enabled {
			enabled = append(enabled, s)
		}
	}
	if len(enabled) == 0 {
		return RefreshResult{}, ErrNoEnabledSources
	}

	var res RefreshResult
	for _, src := range enabled {
		servers, err := p.fetchSource(ctx, src)
		if err != nil {
			res.SourcesFailed++
			res.Errors = append(res.Errors, fmt.Errorf("source %s: %w", src.URL, err))
			continue
		}
		res.SourcesFetched++
		res.NodesDiscovered += len(servers)
		res.NodesAdded += p.mergeNodes(src, servers)
	}

	// A refresh where every source failed is an error: callers should not read
	// an unchanged pool as a successful update.
	if res.SourcesFetched == 0 {
		return res, fmt.Errorf("all %d pool sources failed: %w", res.SourcesFailed, errors.Join(res.Errors...))
	}
	return res, nil
}

// fetchSource downloads and parses one source, enforcing its byte limit.
func (p *Pool) fetchSource(ctx context.Context, src Source) ([]proto.Server, error) {
	// Re-validate defensively: a Source could reach here from a caller that
	// bypassed New, and the HTTPS rule must hold at fetch time too.
	check := src
	if err := check.Validate(); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(ctx, src.timeout())
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, src.URL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "MosaicVPN-Pool/1.0")

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}

	limit := src.MaxBytes
	if limit <= 0 {
		limit = DefaultMaxBytes
	}
	// Read one byte past the limit to detect oversize bodies rather than
	// silently parsing a truncated subscription.
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, ErrResponseTooLarge
	}
	if len(body) == 0 {
		return nil, errors.New("empty response body")
	}

	subID := src.ID()
	var result subs.Result
	if src.Format == "" || src.Format == proto.Format("auto") {
		result, err = subs.Parse(subID, body)
	} else {
		result, err = subs.ParseAs(subID, body, src.Format)
	}
	if err != nil {
		return nil, err
	}
	return result.Servers, nil
}

// mergeNodes adds newly seen servers as candidates and returns how many were
// actually new.
func (p *Pool) mergeNodes(src Source, servers []proto.Server) int {
	p.mu.Lock()
	defer p.mu.Unlock()

	sourceID := src.ID()
	added := 0
	for _, srv := range servers {
		if srv.ID == "" || srv.Address == "" || srv.Port <= 0 {
			continue // unusable entry, nothing to probe
		}
		if existing, ok := p.nodes[srv.ID]; ok {
			// Refresh the descriptor but preserve lifecycle/health state.
			existing.Server = srv
			continue
		}
		p.nodes[srv.ID] = &Node{
			Server:   srv,
			SourceID: sourceID,
			State:    NodeStateCandidate,
			Weight:   src.Trust.startingWeight(),
		}
		added++
	}
	return added
}

// HealthCheckAll probes every node that is due for a check and advances the
// lifecycle. Dead nodes past DeadRetryDelay return to candidate first.
func (p *Pool) HealthCheckAll(ctx context.Context) {
	p.promoteExpiredDead()

	p.mu.RLock()
	targets := make([]*Node, 0, len(p.nodes))
	for _, n := range p.nodes {
		if n.State == NodeStateCandidate || n.State == NodeStateAlive {
			targets = append(targets, n)
		}
	}
	p.mu.RUnlock()

	var wg sync.WaitGroup
	// Bound concurrency so a large pool does not open hundreds of sockets.
	sem := make(chan struct{}, 16)

	for _, node := range targets {
		if ctx.Err() != nil {
			break
		}
		wg.Add(1)
		go func(n *Node) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			latency, err := p.health.Check(ctx, n.endpoint())
			p.applyHealthResult(n, latency, err)
		}(node)
	}
	wg.Wait()
}

// applyHealthResult moves a node through the lifecycle based on one probe.
func (p *Pool) applyHealthResult(n *Node, latency time.Duration, probeErr error) {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := p.now()
	n.LastCheck = now

	if probeErr != nil {
		n.ConsecutiveFails++
		n.LastError = probeErr.Error()

		switch {
		case n.State == NodeStateCandidate && n.LastAlive.IsZero():
			// Never proved itself: rejected, not dead.
			n.State = NodeStateRejected
		case n.ConsecutiveFails >= p.retries:
			n.State = NodeStateDead
			n.DeadUntil = now.Add(DeadRetryDelay)
			// Drop load history so a later revival starts from a clean
			// baseline instead of inheriting pre-failure latency.
			p.load.Forget(n.ID())
		}
		return
	}

	n.ConsecutiveFails = 0
	n.LastError = ""
	n.State = NodeStateAlive
	n.LastAlive = now
	n.DeadUntil = time.Time{}
	n.LatencyMs = int(latency.Milliseconds())
	if n.LatencyMs <= 0 {
		n.LatencyMs = 1 // sub-millisecond probe still means reachable
	}
	p.load.RecordLatency(n.ID(), n.LatencyMs)
}

// promoteExpiredDead returns dead nodes to candidate once their retry delay
// has elapsed.
func (p *Pool) promoteExpiredDead() {
	p.mu.Lock()
	defer p.mu.Unlock()

	now := p.now()
	for _, n := range p.nodes {
		if n.State == NodeStateDead && !n.DeadUntil.IsZero() && now.After(n.DeadUntil) {
			n.State = NodeStateCandidate
			n.ConsecutiveFails = 0
			n.DeadUntil = time.Time{}
		}
	}
}

// AliveNodes returns the currently alive nodes, sorted by latency ascending.
func (p *Pool) AliveNodes() []*Node {
	p.mu.RLock()
	defer p.mu.RUnlock()

	out := make([]*Node, 0, len(p.nodes))
	for _, n := range p.nodes {
		if n.State == NodeStateAlive {
			copied := *n
			out = append(out, &copied)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].LatencyMs != out[j].LatencyMs {
			return out[i].LatencyMs < out[j].LatencyMs
		}
		return out[i].ID() < out[j].ID()
	})
	return out
}

// NodeRefs returns alive nodes as proto.NodeRef with current load estimates
// attached, ready to drop into a ServerGroup.
func (p *Pool) NodeRefs() []proto.NodeRef {
	alive := p.AliveNodes()
	refs := make([]proto.NodeRef, 0, len(alive))
	for _, n := range alive {
		refs = append(refs, proto.NodeRef{
			ServerID:  n.ID(),
			Weight:    n.Weight,
			Load:      p.load.Load(n.ID()),
			LatencyMs: n.LatencyMs,
			Alive:     true,
			LastSeen:  n.LastAlive.Unix(),
			Country:   n.Server.Country,
			City:      n.Server.City,
		})
	}
	return refs
}

// Stats is a lifecycle census of the pool.
type Stats struct {
	Total     int `json:"total"`
	Candidate int `json:"candidate"`
	Alive     int `json:"alive"`
	Rejected  int `json:"rejected"`
	Dead      int `json:"dead"`
}

// Stats returns the current node census.
func (p *Pool) Stats() Stats {
	p.mu.RLock()
	defer p.mu.RUnlock()

	st := Stats{Total: len(p.nodes)}
	for _, n := range p.nodes {
		switch n.State {
		case NodeStateCandidate:
			st.Candidate++
		case NodeStateAlive:
			st.Alive++
		case NodeStateRejected:
			st.Rejected++
		case NodeStateDead:
			st.Dead++
		}
	}
	return st
}

// Node returns a copy of a tracked node by ID.
func (p *Pool) Node(id string) (*Node, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	n, ok := p.nodes[id]
	if !ok {
		return nil, false
	}
	copied := *n
	return &copied, true
}

// Prune permanently removes rejected nodes and returns how many were dropped.
// Dead nodes are kept: they still hold a retry appointment.
func (p *Pool) Prune() int {
	p.mu.Lock()
	defer p.mu.Unlock()

	removed := 0
	for id, n := range p.nodes {
		if n.State == NodeStateRejected {
			delete(p.nodes, id)
			p.load.Forget(id)
			removed++
		}
	}
	return removed
}
