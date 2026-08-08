package subs

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// HealthStatus represents the current health of a single node.
type HealthStatus struct {
	NodeID    string    `json:"node_id"`
	Alive     bool      `json:"alive"`
	LatencyMS int       `json:"latency_ms"`
	LastCheck time.Time `json:"last_check"`
	Error     string    `json:"error,omitempty"`
}

// PoolEngine manages health checks and node selection for manifest groups.
type PoolEngine struct {
	mu      sync.RWMutex
	health  map[string]HealthStatus
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
		ticker := time.NewTicker(30 * time.Second)
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

// CheckNode performs a TCP dial to measure latency.
func (e *PoolEngine) CheckNode(nodeID, address string, port int) HealthStatus {
	start := time.Now()
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", address, port), 5*time.Second)
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

// selectWeightedRR picks a node using weighted round-robin.
func (e *PoolEngine) selectWeightedRR(groupID string, group proto.ManifestGroup, pool []proto.Server) proto.Server {
	e.rrMu.Lock()
	defer e.rrMu.Unlock()
	idx := e.rrIdx[groupID]
	// Build weighted list
	var weighted []proto.Server
	for _, srv := range pool {
		w := 1
		for _, n := range group.Nodes {
			if n.ID == srv.ID && n.Weight > 0 {
				w = n.Weight
				break
			}
		}
		for i := 0; i < w; i++ {
			weighted = append(weighted, srv)
		}
	}
	if len(weighted) == 0 {
		return pool[0]
	}
	if idx >= len(weighted) {
		idx = 0
	}
	picked := weighted[idx]
	e.rrIdx[groupID] = (idx + 1) % len(weighted)
	return picked
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

// GetHealthStatus returns the cached health status for a node.
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

// checkAll runs health checks for all nodes across all groups.
func (e *PoolEngine) checkAll(groups []proto.ManifestGroup, servers []proto.Server) {
	// Collect unique server IDs to check
	checked := make(map[string]bool)
	for _, g := range groups {
		pool := e.resolvePool(g, servers)
		for _, srv := range pool {
			if !checked[srv.ID] {
				checked[srv.ID] = true
				go e.CheckNode(srv.ID, srv.Address, srv.Port)
			}
		}
	}
}
