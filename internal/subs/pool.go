package subs

import (
	"context"
	"fmt"
	"net"
	"sort"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// HealthStatus represents the current health of a single node.
type HealthStatus struct {
	NodeID    string    `json:"node_id"`
	Alive     bool      `json:"alive"`
	LatencyMS int       `json:"latency_ms"`
	Load      float64   `json:"load"`
	LastCheck time.Time `json:"last_check"`
	Error     string    `json:"error,omitempty"`
}

const (
	// admissionProbeBudget keeps control-plane cost fixed as the pool grows.
	// Client runtimes perform final protocol quality ranking from the user's
	// real network; this daemon filter only suppresses known-dead candidates.
	admissionProbeBudget = 8
	admissionProbeEvery  = 60 * time.Second
	admissionRecheck     = 6 * time.Hour
	admissionTimeout     = 2 * time.Second
)

// PoolEngine provides a low-cost server-side admission filter for manifest
// groups. It must not be used as the final user-quality selector: that work is
// intentionally performed by the local client runtime.
type PoolEngine struct {
	mu     sync.RWMutex
	health map[string]HealthStatus
	stopCh chan struct{}
	wg     sync.WaitGroup
	rrIdx  map[string]int // round-robin cursor per group ID
	rrMu   sync.Mutex
}

// NewPoolEngine creates a new PoolEngine.
func NewPoolEngine() *PoolEngine {
	return &PoolEngine{
		health: make(map[string]HealthStatus),
		stopCh: make(chan struct{}),
		rrIdx:  make(map[string]int),
	}
}

// Start launches the background health-check loop.
// Nodes are discovered from the provided manifest groups + servers.
func (e *PoolEngine) Start(ctx context.Context, groups []proto.ManifestGroup, servers []proto.Server) {
	e.wg.Add(1)
	go func() {
		defer e.wg.Done()
		ticker := time.NewTicker(admissionProbeEvery)
		defer ticker.Stop()
		e.checkAll(groups, servers) // immediate first check
		for {
			select {
			case <-ctx.Done():
				return
			case <-e.stopCh:
				return
			case <-ticker.C:
				e.checkAll(groups, servers)
			}
		}
	}()
}

// Stop signals the background loop to exit.
func (e *PoolEngine) Stop() {
	select {
	case <-e.stopCh:
	default:
		close(e.stopCh)
	}
	e.wg.Wait()
}

// CheckNode performs a bounded admission TCP dial. It deliberately does not
// rank nodes or attempt a full proxy handshake; those probes run locally on
// the selected user's device.
func (e *PoolEngine) CheckNode(nodeID, address string, port int) HealthStatus {
	start := time.Now()
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", address, port), admissionTimeout)
	latency := int(time.Since(start).Milliseconds())
	hs := HealthStatus{
		NodeID:    nodeID,
		LastCheck: time.Now().UTC(),
	}
	if err != nil {
		hs.Alive = false
		hs.Error = err.Error()
		hs.LatencyMS = 0
	} else {
		conn.Close()
		hs.Alive = true
		hs.LatencyMS = latency
	}
	e.mu.Lock()
	e.health[nodeID] = hs
	e.mu.Unlock()
	return hs
}

// SelectNode picks the best server from a group's pool using the group's strategy.
func (e *PoolEngine) SelectNode(group proto.ManifestGroup, servers []proto.Server) (proto.Server, error) {
	// Build pool: servers that match this group's node IDs
	pool := e.resolvePool(group, servers)
	if len(pool) == 0 {
		return proto.Server{}, fmt.Errorf("no servers in group %s", group.ID)
	}

	switch group.Type {
	case "urltest":
		return e.selectURLTest(pool, group), nil
	case "weighted_round_robin":
		return e.selectWeightedRR(group.ID, group, pool), nil
	case "fallback":
		return e.selectFallback(group, pool), nil
	case "direct_node":
		if len(pool) > 0 {
			// return the single node if alive
			hs := e.GetHealthStatus(pool[0].ID)
			if hs.Alive || hs.LastCheck.IsZero() {
				return pool[0], nil
			}
			return proto.Server{}, fmt.Errorf("node %s is down", pool[0].ID)
		}
		return proto.Server{}, fmt.Errorf("no node in direct_node group")
	default:
		// default to urltest
		return e.selectURLTest(pool, group), nil
	}
}

// resolvePool returns servers whose IDs match the group's Nodes list.
func (e *PoolEngine) resolvePool(group proto.ManifestGroup, servers []proto.Server) []proto.Server {
	if len(group.Nodes) == 0 {
		// no explicit nodes → use matchGroupFilter
		var pool []proto.Server
		for _, srv := range servers {
			if matchGroupFilter(group, srv) {
				pool = append(pool, srv)
			}
		}
		return pool
	}
	nodeSet := make(map[string]bool)
	for _, n := range group.Nodes {
		nodeSet[n.ID] = true
	}
	var pool []proto.Server
	for _, srv := range servers {
		if nodeSet[srv.ID] {
			pool = append(pool, srv)
		}
	}
	return pool
}

// TierRank returns integer rank for UserTier comparison (free=1, pro=2, vip=3).
func TierRank(t proto.UserTier) int {
	switch t {
	case proto.TierVIP:
		return 3
	case proto.TierPro:
		return 2
	default:
		return 1
	}
}

// IsTierAllowed checks if user's tier is sufficient for the required tier.
func IsTierAllowed(userTier, requiredTier proto.UserTier) bool {
	return TierRank(userTier) >= TierRank(requiredTier)
}

// selectURLTest picks the alive node with lowest latency, factoring in weight.
// Score = latency_ms / max(weight, 1). Lower weight → higher effective latency,
// so premium nodes (weight 30) beat free nodes (weight 5) at equal ping.
func (e *PoolEngine) selectURLTest(pool []proto.Server, group proto.ManifestGroup) proto.Server {
	e.mu.RLock()
	defer e.mu.RUnlock()
	best := pool[0]
	bestScore := -1.0
	for _, srv := range pool {
		hs, ok := e.health[srv.ID]
		if !ok || !hs.Alive {
			continue
		}
		weight := 1
		for _, n := range group.Nodes {
			if n.ID == srv.ID && n.Weight > 0 {
				weight = n.Weight
				break
			}
		}
		score := float64(hs.LatencyMS) / float64(weight)
		if bestScore < 0 || score < bestScore {
			bestScore = score
			best = srv
		}
	}
	return best
}

// selectWeightedRR picks a node considering server load, weight, latency, and health.
// Score (lower is better) = latency_ms / (weight * (1 - load))
// Hard filtering:
// - Nodes with Alive=false are never selected.
// - Nodes with Load >= 0.95 are excluded.
// Graceful degradation: if ALL alive nodes have Load >= 0.95, pick the node with the lowest Load.
func (e *PoolEngine) selectWeightedRR(groupID string, group proto.ManifestGroup, pool []proto.Server) proto.Server {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if len(pool) == 0 {
		return proto.Server{}
	}

	type nodeInfo struct {
		server  proto.Server
		weight  int
		load    float64
		latency int
		alive   bool
	}

	var candidates []nodeInfo
	var aliveOverloaded []nodeInfo

	for _, srv := range pool {
		hs, ok := e.health[srv.ID]
		// Determine latency & alive
		latency := hs.LatencyMS
		alive := hs.Alive
		if !ok {
			// If health check hasn't run or entry missing, treat as alive by default if LastCheck is zero or check pool[0] logic
			// But for health map: if hs not present, check srv.LastTestMS or fallback
			if srv.LastTestMS > 0 {
				latency = srv.LastTestMS
			}
			alive = true // Default to true if unprobed unless explicit dead
		} else {
			if !alive {
				continue // Мёртвые узлы (Alive=false) не выбираются никогда.
			}
		}

		weight := 1
		load := 0.0
		if ok {
			load = hs.Load
		}

		// Search in group.Nodes (ManifestNode)
		for _, n := range group.Nodes {
			if n.ID == srv.ID {
				if n.Weight > 0 {
					weight = n.Weight
				}
				break
			}
		}

		info := nodeInfo{
			server:  srv,
			weight:  weight,
			load:    load,
			latency: latency,
			alive:   alive,
		}

		if load >= 0.95 {
			aliveOverloaded = append(aliveOverloaded, info)
		} else {
			candidates = append(candidates, info)
		}
	}

	// If no candidates under 0.95 load, but we have overloaded alive nodes -> graceful degradation: pick least loaded
	if len(candidates) == 0 {
		if len(aliveOverloaded) > 0 {
			best := aliveOverloaded[0]
			for _, n := range aliveOverloaded[1:] {
				if n.load < best.load {
					best = n
				}
			}
			return best.server
		}
		// If no alive nodes at all, fallback to first node in pool
		return pool[0]
	}

	// Calculate score for candidate nodes
	best := candidates[0]
	bestScore := -1.0

	for _, c := range candidates {
		effLatency := float64(c.latency)
		if effLatency <= 0 {
			effLatency = 1.0 // avoid 0 score
		}
		score := effLatency / (float64(c.weight) * (1.0 - c.load))
		if bestScore < 0 || score < bestScore {
			bestScore = score
			best = c
		}
	}

	return best.server
}

// selectFallback picks the first alive node by priority order.
func (e *PoolEngine) selectFallback(group proto.ManifestGroup, pool []proto.Server) proto.Server {
	e.mu.RLock()
	defer e.mu.RUnlock()
	// Sort pool by priority (lower = higher priority)
	// We can't sort the slice, so iterate in priority order
	prioMap := make(map[int][]proto.Server)
	for _, srv := range pool {
		p := 999
		for _, n := range group.Nodes {
			if n.ID == srv.ID && n.Priority > 0 {
				p = n.Priority
				break
			}
		}
		prioMap[p] = append(prioMap[p], srv)
	}
	// Iterate priorities in order
	for p := 1; p <= 999; p++ {
		if servers, ok := prioMap[p]; ok {
			for _, srv := range servers {
				hs, ok := e.health[srv.ID]
				if !ok || hs.Alive || hs.LastCheck.IsZero() {
					return srv
				}
			}
		}
	}
	// all dead → return first
	if len(pool) > 0 {
		return pool[0]
	}
	return proto.Server{}
}

// SetHealth manually sets health/load telemetry for a node (used by telemetry sync / tests).
func (e *PoolEngine) SetHealth(status HealthStatus) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.health[status.NodeID] = status
}
func (e *PoolEngine) GetHealthStatus(nodeID string) HealthStatus {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.health[nodeID]
}

// GetAllHealth returns all cached health statuses.
func (e *PoolEngine) GetAllHealth() map[string]HealthStatus {
	e.mu.RLock()
	defer e.mu.RUnlock()
	result := make(map[string]HealthStatus, len(e.health))
	for k, v := range e.health {
		result[k] = v
	}
	return result
}

// checkAll performs a fixed-size admission batch. Earlier versions spawned a
// TCP dial for every pool node every 30 seconds, which scales poorly and makes
// the VPS an unnecessary measurement bottleneck. New/unprobed nodes are first;
// known candidates are revisited only after a long, jitter-tolerant interval.
func (e *PoolEngine) checkAll(groups []proto.ManifestGroup, servers []proto.Server) {
	byID := make(map[string]proto.Server)
	for _, group := range groups {
		if group.Disabled {
			continue
		}
		for _, server := range e.resolvePool(group, servers) {
			byID[server.ID] = server
		}
	}

	now := time.Now()
	e.mu.RLock()
	statusByID := make(map[string]HealthStatus, len(e.health))
	for id, status := range e.health {
		statusByID[id] = status
	}
	e.mu.RUnlock()

	targets := make([]proto.Server, 0, len(byID))
	for id, server := range byID {
		status, known := statusByID[id]
		if !known || status.LastCheck.IsZero() || now.Sub(status.LastCheck) >= admissionRecheck {
			targets = append(targets, server)
		}
	}
	sort.Slice(targets, func(i, j int) bool {
		left := statusByID[targets[i].ID].LastCheck
		right := statusByID[targets[j].ID].LastCheck
		if left.Equal(right) {
			return targets[i].ID < targets[j].ID
		}
		return left.Before(right)
	})
	if len(targets) > admissionProbeBudget {
		targets = targets[:admissionProbeBudget]
	}
	for _, server := range targets {
		server := server
		go e.CheckNode(server.ID, server.Address, server.Port)
	}
}
