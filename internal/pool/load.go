// Package pool maintains the free server pool: it fetches nodes from
// configured HTTPS sources, health-checks them, tracks their lifecycle, and
// estimates how loaded each node is.
//
// A note on load estimation: these are third-party nodes. We do not control
// them and they expose no telemetry, so their true load is unknowable. What
// this package computes is an honest *estimate* derived from two things we can
// actually observe — how many of our own clients we sent to a node, and how
// much its latency has degraded relative to its own baseline. It is presented
// to users as "loadedness", never as an exact percentage.
package pool

import (
	"sort"
	"sync"
	"time"
)

// Load estimation weights, per docs/GROUP_SYSTEM_SPEC.md §5.3:
//
//	load = clamp(0.6 * assigned_load + 0.4 * latency_load, 0, 1)
const (
	assignedLoadWeight = 0.6
	latencyLoadWeight  = 0.4

	// assignmentWindow is how far back client assignments count toward load.
	assignmentWindow = 5 * time.Minute

	// saturationAssignments is the number of assignments within the window
	// that we treat as "fully loaded" from our own traffic alone. It is a
	// calibration constant, not a measurement of node capacity.
	saturationAssignments = 40

	// latencyDegradationCeiling is the ratio of current-to-baseline latency
	// treated as fully degraded. 3x the node's own median => latency_load 1.0.
	latencyDegradationCeiling = 3.0

	// minSamplesForBaseline is how many latency probes are needed before the
	// median is considered meaningful. Below this, latency_load stays 0 rather
	// than inventing degradation from a single sample.
	minSamplesForBaseline = 3

	// latencySamplesKept bounds the per-node latency ring buffer.
	latencySamplesKept = 32
)

// LoadTracker estimates per-node load from observable signals. It is safe for
// concurrent use.
type LoadTracker struct {
	mu    sync.RWMutex
	nodes map[string]*nodeLoadState
	now   func() time.Time // injectable for tests
}

type nodeLoadState struct {
	assignments    []time.Time
	latencySamples []int // milliseconds, insertion-ordered ring
}

// NewLoadTracker returns an empty tracker using the wall clock.
func NewLoadTracker() *LoadTracker {
	return &LoadTracker{
		nodes: make(map[string]*nodeLoadState),
		now:   time.Now,
	}
}

// stateFor returns the mutable state for a node, creating it if absent.
// Caller must hold the write lock.
func (lt *LoadTracker) stateFor(nodeID string) *nodeLoadState {
	st, ok := lt.nodes[nodeID]
	if !ok {
		st = &nodeLoadState{}
		lt.nodes[nodeID] = st
	}
	return st
}

// RecordAssignment notes that we routed one of our clients to a node. This is
// the signal behind assigned_load.
func (lt *LoadTracker) RecordAssignment(nodeID string) {
	if nodeID == "" {
		return
	}
	lt.mu.Lock()
	defer lt.mu.Unlock()

	st := lt.stateFor(nodeID)
	st.assignments = append(st.assignments, lt.now())
	lt.pruneAssignmentsLocked(st)
}

// RecordLatency stores a successful latency probe. Non-positive values are
// ignored: a failed probe says nothing about load, only about health.
func (lt *LoadTracker) RecordLatency(nodeID string, latencyMs int) {
	if nodeID == "" || latencyMs <= 0 {
		return
	}
	lt.mu.Lock()
	defer lt.mu.Unlock()

	st := lt.stateFor(nodeID)
	st.latencySamples = append(st.latencySamples, latencyMs)
	if len(st.latencySamples) > latencySamplesKept {
		st.latencySamples = st.latencySamples[len(st.latencySamples)-latencySamplesKept:]
	}
}

// pruneAssignmentsLocked drops assignments older than the window.
// Caller must hold the write lock.
func (lt *LoadTracker) pruneAssignmentsLocked(st *nodeLoadState) {
	cutoff := lt.now().Add(-assignmentWindow)
	keep := st.assignments[:0]
	for _, t := range st.assignments {
		if t.After(cutoff) {
			keep = append(keep, t)
		}
	}
	st.assignments = keep
}

// AssignedLoad is the share of our own recent traffic pointed at a node,
// in 0..1.
func (lt *LoadTracker) AssignedLoad(nodeID string) float64 {
	lt.mu.Lock()
	defer lt.mu.Unlock()

	st, ok := lt.nodes[nodeID]
	if !ok {
		return 0
	}
	lt.pruneAssignmentsLocked(st)
	return clamp01(float64(len(st.assignments)) / float64(saturationAssignments))
}

// LatencyLoad is how far a node's most recent latency has drifted above its
// own median, in 0..1. Returns 0 until there are enough samples to have a
// baseline worth comparing against.
func (lt *LoadTracker) LatencyLoad(nodeID string) float64 {
	lt.mu.RLock()
	defer lt.mu.RUnlock()

	st, ok := lt.nodes[nodeID]
	if !ok || len(st.latencySamples) < minSamplesForBaseline {
		return 0
	}

	baseline := medianInt(st.latencySamples)
	if baseline <= 0 {
		return 0
	}

	current := st.latencySamples[len(st.latencySamples)-1]
	ratio := float64(current) / float64(baseline)
	if ratio <= 1 {
		// At or below its own baseline: no degradation to report.
		return 0
	}

	// Map ratio 1.0..ceiling onto 0.0..1.0.
	return clamp01((ratio - 1) / (latencyDegradationCeiling - 1))
}

// Load is the combined estimate for a node, in 0..1.
func (lt *LoadTracker) Load(nodeID string) float64 {
	assigned := lt.AssignedLoad(nodeID)
	latency := lt.LatencyLoad(nodeID)
	return clamp01(assignedLoadWeight*assigned + latencyLoadWeight*latency)
}

// Forget drops all tracked state for a node. Used when a node leaves the pool
// so a later re-add starts from a clean baseline instead of inheriting stale
// latency history.
func (lt *LoadTracker) Forget(nodeID string) {
	lt.mu.Lock()
	defer lt.mu.Unlock()
	delete(lt.nodes, nodeID)
}

// Tracked returns how many nodes currently have load state. Diagnostics only.
func (lt *LoadTracker) Tracked() int {
	lt.mu.RLock()
	defer lt.mu.RUnlock()
	return len(lt.nodes)
}

// medianInt returns the median of a slice without mutating the caller's copy.
func medianInt(values []int) int {
	if len(values) == 0 {
		return 0
	}
	sorted := make([]int, len(values))
	copy(sorted, values)
	sort.Ints(sorted)

	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	return (sorted[mid-1] + sorted[mid]) / 2
}

// clamp01 constrains v to the 0..1 range.
func clamp01(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}
