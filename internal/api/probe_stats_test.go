package api

import "testing"

func TestComputeProbeStatsPreservesObservationJitter(t *testing.T) {
	median, p95, jitter := computeProbeStats([]int{10, 100, 20, 90, 30})
	if median != 30 {
		t.Fatalf("median=%d want 30", median)
	}
	if p95 != 100 {
		t.Fatalf("p95=%d want 100", p95)
	}
	// Consecutive deltas: 90,80,70,60 => mean 75. Sorting first would
	// incorrectly report 22, so this guards the observation-order contract.
	if jitter != 75 {
		t.Fatalf("jitter=%d want 75", jitter)
	}
}

func TestComputeProbeStatsEmptyAndSingle(t *testing.T) {
	median, p95, jitter := computeProbeStats(nil)
	if median != 0 || p95 != 0 || jitter != 0 {
		t.Fatalf("empty=(%d,%d,%d)", median, p95, jitter)
	}
	median, p95, jitter = computeProbeStats([]int{7})
	if median != 7 || p95 != 7 || jitter != 0 {
		t.Fatalf("single=(%d,%d,%d)", median, p95, jitter)
	}
}
