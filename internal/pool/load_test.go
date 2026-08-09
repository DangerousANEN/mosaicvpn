package pool

import (
	"testing"
	"time"
)

func TestLoad_UnknownNodeIsZero(t *testing.T) {
	lt := NewLoadTracker()
	if got := lt.Load("never-seen"); got != 0 {
		t.Fatalf("load = %v for unknown node, want 0", got)
	}
}

func TestAssignedLoad_GrowsWithAssignments(t *testing.T) {
	lt := NewLoadTracker()

	half := saturationAssignments / 2
	for i := 0; i < half; i++ {
		lt.RecordAssignment("n1")
	}

	got := lt.AssignedLoad("n1")
	if got <= 0.4 || got >= 0.6 {
		t.Fatalf("assigned load = %v after half saturation, want ~0.5", got)
	}
}

func TestAssignedLoad_SaturatesAtOne(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < saturationAssignments*3; i++ {
		lt.RecordAssignment("n1")
	}
	if got := lt.AssignedLoad("n1"); got != 1 {
		t.Fatalf("assigned load = %v past saturation, want exactly 1", got)
	}
}

func TestAssignedLoad_ForgetsOldAssignments(t *testing.T) {
	now := time.Now()
	lt := NewLoadTracker()
	lt.now = func() time.Time { return now }

	for i := 0; i < saturationAssignments; i++ {
		lt.RecordAssignment("n1")
	}
	if lt.AssignedLoad("n1") != 1 {
		t.Fatal("setup: node should be saturated")
	}

	// Walk past the window: those assignments no longer describe current load.
	now = now.Add(assignmentWindow + time.Minute)
	if got := lt.AssignedLoad("n1"); got != 0 {
		t.Fatalf("assigned load = %v after window elapsed, want 0", got)
	}
}

func TestLatencyLoad_NeedsBaselineBeforeReporting(t *testing.T) {
	lt := NewLoadTracker()

	// A single wild sample must not be read as degradation: there is nothing
	// to compare it against yet.
	lt.RecordLatency("n1", 900)
	if got := lt.LatencyLoad("n1"); got != 0 {
		t.Fatalf("latency load = %v with one sample, want 0", got)
	}

	for i := 0; i < minSamplesForBaseline; i++ {
		lt.RecordLatency("n1", 100)
	}
	if got := lt.LatencyLoad("n1"); got != 0 {
		t.Fatalf("latency load = %v at stable baseline, want 0", got)
	}
}

func TestLatencyLoad_RisesWithDegradation(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 100)
	}

	// 2x the median sits halfway to the 3x ceiling.
	lt.RecordLatency("n1", 200)
	got := lt.LatencyLoad("n1")
	if got <= 0.3 || got >= 0.7 {
		t.Fatalf("latency load = %v at 2x baseline, want ~0.5", got)
	}
}

func TestLatencyLoad_ClampsAtCeiling(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 100)
	}
	lt.RecordLatency("n1", 100_000) // absurdly degraded

	if got := lt.LatencyLoad("n1"); got != 1 {
		t.Fatalf("latency load = %v far past ceiling, want exactly 1", got)
	}
}

func TestLatencyLoad_FasterThanBaselineIsNotLoad(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 200)
	}
	lt.RecordLatency("n1", 50) // improved

	if got := lt.LatencyLoad("n1"); got != 0 {
		t.Fatalf("latency load = %v when faster than baseline, want 0", got)
	}
}

func TestLatencyLoad_IgnoresFailedProbes(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 100)
	}
	before := lt.LatencyLoad("n1")

	// A failed probe reports -1/0; that is a health signal, not a load signal.
	lt.RecordLatency("n1", -1)
	lt.RecordLatency("n1", 0)

	if after := lt.LatencyLoad("n1"); after != before {
		t.Fatalf("latency load changed from %v to %v after failed probes", before, after)
	}
}

func TestLoad_CombinesBothSignalsWithSpecWeights(t *testing.T) {
	lt := NewLoadTracker()

	// Drive assigned_load to exactly 1.
	for i := 0; i < saturationAssignments; i++ {
		lt.RecordAssignment("n1")
	}
	// Keep latency at baseline so latency_load stays 0.
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 100)
	}

	got := lt.Load("n1")
	if diff := got - assignedLoadWeight; diff > 0.001 || diff < -0.001 {
		t.Fatalf("load = %v with only assigned load saturated, want %v", got, assignedLoadWeight)
	}
}

func TestLoad_AlwaysWithinUnitRange(t *testing.T) {
	lt := NewLoadTracker()

	for i := 0; i < saturationAssignments*5; i++ {
		lt.RecordAssignment("n1")
	}
	for i := 0; i < 5; i++ {
		lt.RecordLatency("n1", 10)
	}
	lt.RecordLatency("n1", 10_000_000)

	got := lt.Load("n1")
	if got < 0 || got > 1 {
		t.Fatalf("load = %v, want within 0..1", got)
	}
	if got != 1 {
		t.Fatalf("load = %v with both signals maxed, want exactly 1", got)
	}
}

func TestForget_ClearsNodeState(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < saturationAssignments; i++ {
		lt.RecordAssignment("n1")
	}
	if lt.Tracked() != 1 {
		t.Fatal("setup: expected one tracked node")
	}

	lt.Forget("n1")

	if lt.Tracked() != 0 {
		t.Error("tracked node remained after Forget")
	}
	if got := lt.Load("n1"); got != 0 {
		t.Errorf("load = %v after Forget, want 0", got)
	}
}

func TestLatencySamples_AreBounded(t *testing.T) {
	lt := NewLoadTracker()
	for i := 0; i < latencySamplesKept*4; i++ {
		lt.RecordLatency("n1", 100)
	}

	lt.mu.RLock()
	got := len(lt.nodes["n1"].latencySamples)
	lt.mu.RUnlock()

	if got > latencySamplesKept {
		t.Fatalf("kept %d latency samples, want at most %d", got, latencySamplesKept)
	}
}

func TestMedianInt(t *testing.T) {
	cases := []struct {
		name string
		in   []int
		want int
	}{
		{"empty", nil, 0},
		{"single", []int{42}, 42},
		{"odd", []int{30, 10, 20}, 20},
		{"even", []int{10, 20, 30, 40}, 25},
		{"unsorted duplicates", []int{5, 1, 5, 1}, 3},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := medianInt(tc.in); got != tc.want {
				t.Errorf("medianInt(%v) = %d, want %d", tc.in, got, tc.want)
			}
		})
	}
}

func TestMedianInt_DoesNotMutateInput(t *testing.T) {
	in := []int{30, 10, 20}
	_ = medianInt(in)
	if in[0] != 30 || in[1] != 10 || in[2] != 20 {
		t.Fatalf("input reordered to %v; medianInt must not mutate the caller's slice", in)
	}
}

func TestLoadTracker_ConcurrentUse(t *testing.T) {
	lt := NewLoadTracker()
	done := make(chan struct{})

	for i := 0; i < 8; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			for j := 0; j < 200; j++ {
				lt.RecordAssignment("n1")
				lt.RecordLatency("n1", 100)
				_ = lt.Load("n1")
			}
		}()
	}
	for i := 0; i < 8; i++ {
		<-done
	}

	if got := lt.Load("n1"); got < 0 || got > 1 {
		t.Fatalf("load = %v after concurrent use, want within 0..1", got)
	}
}
