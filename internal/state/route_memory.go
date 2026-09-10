package state

import (
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/logx"
	"github.com/pupspochta-cpu/mosaicvpn/internal/netmemory"
)

// Adaptive route memory, wired to the runtime truth-check.
//
// WHY THIS IS WORTH THE CODE
// --------------------------
// Blocking in Russia is per-operator and per-region and it shifts during the
// day: a node that works on home broadband can be dead on a mobile carrier.
// Ranking purely by latency (what a plain urltest does) discards the strongest
// signal available — whether the route actually carried traffic on THIS network
// last time. The truth-check already measures exactly that, so feeding its
// verdict into a per-network ledger costs almost nothing and turns every
// connection attempt into training data.

// EnableRouteMemory turns on adaptive per-network route ranking.
//
// It is opt-in at construction so tests and headless callers keep fully
// deterministic behaviour, and so a caller that has no persistence available
// simply does not enable it.
func (m *Manager) EnableRouteMemory(mem *netmemory.Memory, fingerprint func() string) {
	if fingerprint == nil {
		fingerprint = netmemory.LocalFingerprint
	}
	m.mu.Lock()
	m.routeMemory = mem
	m.netFingerprint = fingerprint
	m.mu.Unlock()
}

// RouteMemorySnapshot exports the ledger so the caller can persist it.
// Returns nil when the feature is disabled.
func (m *Manager) RouteMemorySnapshot() map[string]map[string]netmemory.RouteStat {
	m.mu.Lock()
	mem := m.routeMemory
	m.mu.Unlock()
	if mem == nil {
		return nil
	}
	return mem.Snapshot()
}

// currentNetwork returns the fingerprint of the network in use, or "" when the
// feature is off or the fingerprint cannot be determined.
func (m *Manager) currentNetwork() string {
	m.mu.Lock()
	mem := m.routeMemory
	fp := m.netFingerprint
	m.mu.Unlock()

	if mem == nil || fp == nil {
		return ""
	}
	return fp()
}

// rememberOutcome folds a truth-check verdict into the ledger.
//
// Deliberately fed from the verification result rather than from Start(): a
// core that starts is not a route that works, and recording "started" as
// success would poison the ledger with exactly the false positives this
// feature exists to route around.
func (m *Manager) rememberOutcome(routeID string, verified bool, latencyMS int) {
	m.mu.Lock()
	mem := m.routeMemory
	fp := m.netFingerprint
	m.mu.Unlock()

	if mem == nil || fp == nil || routeID == "" {
		return
	}
	network := fp()
	if network == "" {
		// No usable fingerprint (e.g. no active interface) — recording under a
		// blank key would merge unrelated networks into one identity.
		return
	}

	mem.Record(network, routeID, netmemory.Outcome{
		Verified:  verified,
		LatencyMS: latencyMS,
		At:        time.Now(),
	})
	logx.Debug("route memory updated",
		"route", routeID, "verified", verified, "latency_ms", latencyMS)

	// Persist immediately: a ledger that only lives in RAM relearns every
	// block from scratch on the next launch, which is exactly when the user
	// least wants to sit through a failing route.
	if m.store != nil {
		if err := m.store.SaveRouteMemory(mem.Snapshot()); err != nil {
			logx.Warn("could not persist route memory", "err", err)
		}
	}
}

// applyRouteMemory reorders candidates by what we remember about this network.
//
// The resolver's ranking (latency, load, weight) is kept as the tiebreaker, so
// this only ever promotes routes with a proven record and demotes ones known to
// black-hole here. On an unseen network it is a no-op.
func (m *Manager) applyRouteMemory(primary string, fallbacks []string) (string, []string) {
	m.mu.Lock()
	mem := m.routeMemory
	m.mu.Unlock()
	if mem == nil || len(fallbacks) == 0 {
		return primary, fallbacks
	}

	network := m.currentNetwork()
	if network == "" {
		return primary, fallbacks
	}

	ordered := mem.Reorder(network, append([]string{primary}, fallbacks...))
	if len(ordered) == 0 {
		return primary, fallbacks
	}
	if ordered[0] != primary {
		logx.Info("route memory promoted a different route for this network",
			"was", primary, "now", ordered[0])
	}
	return ordered[0], ordered[1:]
}

// PruneRouteMemory drops entries older than maxAge, keeping the ledger small
// on a device that roams between many networks.
func (m *Manager) PruneRouteMemory(maxAge time.Duration) int {
	m.mu.Lock()
	mem := m.routeMemory
	m.mu.Unlock()
	if mem == nil {
		return 0
	}
	return mem.Prune(maxAge)
}
