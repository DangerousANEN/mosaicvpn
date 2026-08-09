package state

import (
	"errors"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// fakeSource is a GroupSource backed by maps, so the chain can be tested
// without a store, a daemon, or a network.
type fakeSource struct {
	groups   []proto.ServerGroup
	lastID   string
	servers  map[string]bool
	failFind bool
}

func (f *fakeSource) Groups() []proto.ServerGroup { return f.groups }

func (f *fakeSource) Group(id string) (proto.ServerGroup, bool) {
	for _, g := range f.groups {
		if g.ID == id {
			return g, true
		}
	}
	return proto.ServerGroup{}, false
}

func (f *fakeSource) LastGroup() string { return f.lastID }

func (f *fakeSource) FindServer(id string) (proto.Server, bool) {
	if f.failFind {
		return proto.Server{}, false
	}
	if f.servers == nil {
		return proto.Server{ID: id}, true
	}
	if f.servers[id] {
		return proto.Server{ID: id}, true
	}
	return proto.Server{}, false
}

func aliveNode(id string, latency, weight int) proto.NodeRef {
	return proto.NodeRef{ServerID: id, LatencyMs: latency, Weight: weight, Alive: true}
}

func deadNode(id string) proto.NodeRef {
	return proto.NodeRef{ServerID: id, Alive: false, Weight: 50}
}

func group(id, title string, nodes ...proto.NodeRef) proto.ServerGroup {
	return proto.ServerGroup{ID: id, Title: title, Nodes: nodes}
}

// --- step 1: explicit choice ---

func TestResolve_ExplicitServerWins(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{group("pool-auto", "Auto", aliveNode("a", 10, 50))},
	}

	got, err := Resolve(src, "", "pinned-node")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.ServerID != "pinned-node" {
		t.Errorf("server = %q, want the pinned node", got.ServerID)
	}
	if got.Step != StepExplicit {
		t.Errorf("step = %q, want %q", got.Step, StepExplicit)
	}
	if got.Degraded {
		t.Error("a satisfied explicit pick must not be marked degraded")
	}
}

func TestResolve_StaleExplicitServerErrorsInsteadOfSilentRedirect(t *testing.T) {
	// The user asked for one specific server. Quietly connecting them somewhere
	// else would misrepresent where their traffic goes.
	src := &fakeSource{
		groups:  []proto.ServerGroup{group("pool-auto", "Auto", aliveNode("other", 10, 50))},
		servers: map[string]bool{"other": true},
	}

	_, err := Resolve(src, "", "gone")
	if err == nil {
		t.Fatal("want an error for a server that no longer exists")
	}
	var rerr *ResolveError
	if !errors.As(err, &rerr) {
		t.Fatalf("error type = %T, want *ResolveError", err)
	}
	if rerr.Retryable {
		t.Error("a missing pinned server is not fixed by retrying")
	}
}

func TestResolve_ExplicitGroupUsed(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-de", "Германия", aliveNode("de1", 30, 50)),
			group("pool-auto", "Auto", aliveNode("a", 10, 50)),
		},
	}

	got, err := Resolve(src, "pool-de", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.GroupID != "pool-de" {
		t.Errorf("group = %q, want pool-de even though pool-auto is faster", got.GroupID)
	}
	if got.ServerID != "de1" {
		t.Errorf("server = %q, want de1", got.ServerID)
	}
}

func TestResolve_MissingExplicitGroupIsNotRetryable(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{group("pool-auto", "Auto", aliveNode("a", 10, 50))},
	}

	_, err := Resolve(src, "nope", "")
	var rerr *ResolveError
	if !errors.As(err, &rerr) {
		t.Fatalf("error type = %T, want *ResolveError", err)
	}
	if rerr.Retryable {
		t.Error("a group that does not exist will not appear on retry")
	}
}

// --- step 2: last successful group ---

func TestResolve_FallsBackToLastSuccessfulGroup(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-nl", "Нидерланды", aliveNode("nl1", 40, 50)),
			group("pool-auto", "Auto", aliveNode("a", 10, 50)),
		},
		lastID: "pool-nl",
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.Step != StepLastGood {
		t.Errorf("step = %q, want %q", got.Step, StepLastGood)
	}
	if got.GroupID != "pool-nl" {
		t.Errorf("group = %q, want the remembered group", got.GroupID)
	}
}

func TestResolve_SkipsLastGroupWhenItNoLongerExists(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{group("pool-auto", "Auto", aliveNode("a", 10, 50))},
		lastID: "deleted-group",
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.Step != StepPoolAuto {
		t.Errorf("step = %q, want fallthrough to %q", got.Step, StepPoolAuto)
	}
}

// --- step 3: pool-auto ---

func TestResolve_PoolAutoPicksLowestScore(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto",
				proto.NodeRef{ServerID: "slow", LatencyMs: 300, Weight: 50, Alive: true},
				proto.NodeRef{ServerID: "fast", LatencyMs: 20, Weight: 50, Alive: true},
				proto.NodeRef{ServerID: "loaded", LatencyMs: 20, Weight: 50, Load: 0.95, Alive: true},
			),
		},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.ServerID != "fast" {
		t.Errorf("server = %q, want fast (low latency, low load)", got.ServerID)
	}
}

func TestResolve_LoadOutweighsRawLatency(t *testing.T) {
	// A near-saturated node is a worse experience than a slightly slower idle
	// one, which is the whole point of scoring by load.
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto",
				proto.NodeRef{ServerID: "busy", LatencyMs: 30, Weight: 50, Load: 0.9, Alive: true},
				proto.NodeRef{ServerID: "idle", LatencyMs: 60, Weight: 50, Load: 0.0, Alive: true},
			),
		},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.ServerID != "idle" {
		t.Errorf("server = %q, want idle: 30/(1-0.9)=300 should lose to 60", got.ServerID)
	}
}

func TestResolve_SkipsNodesMissingFromServerList(t *testing.T) {
	// Handing Connect an unknown ID produces an instant failure, so the resolver
	// filters those out rather than passing the problem downstream.
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto",
				aliveNode("ghost", 10, 50),
				aliveNode("real", 90, 50),
			),
		},
		servers: map[string]bool{"real": true},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.ServerID != "real" {
		t.Errorf("server = %q, want real (ghost is not in the server list)", got.ServerID)
	}
}

func TestResolve_UnprobedNodeLosesToMeasuredNode(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto",
				proto.NodeRef{ServerID: "unprobed", LatencyMs: 0, Weight: 50, Alive: true},
				proto.NodeRef{ServerID: "measured", LatencyMs: 200, Weight: 50, Alive: true},
			),
		},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.ServerID != "measured" {
		t.Errorf("server = %q, want the measured node", got.ServerID)
	}
}

// --- step 4: emergency ---

func TestResolve_FallsToEmergencyWhenPoolAllDead(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto", deadNode("d1"), deadNode("d2")),
			group("emergency", "Аварийный", aliveNode("e1", 120, 100)),
		},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.Step != StepEmergency {
		t.Errorf("step = %q, want %q", got.Step, StepEmergency)
	}
	if !got.Degraded {
		t.Error("an emergency connection must be flagged degraded, not passed off as normal")
	}
	if len(got.Notes) == 0 {
		t.Error("want a user-facing note explaining the downgrade")
	}
}

func TestResolve_EmptyPoolFallsToEmergency(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto"),
			group("emergency", "Аварийный", aliveNode("e1", 120, 100)),
		},
	}

	got, err := Resolve(src, "", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.Step != StepEmergency {
		t.Errorf("step = %q, want %q for an empty pool", got.Step, StepEmergency)
	}
}

func TestResolve_ExplicitGroupFailureStillReachesEmergency(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-de", "Германия", deadNode("de1")),
			group("pool-auto", "Auto", deadNode("a1")),
			group("emergency", "Аварийный", aliveNode("e1", 120, 100)),
		},
	}

	got, err := Resolve(src, "pool-de", "")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if got.Step != StepEmergency {
		t.Errorf("step = %q, want %q", got.Step, StepEmergency)
	}
	// The user picked Germany and did not get it; that has to be visible.
	joined := strings.Join(got.Notes, " ")
	if !strings.Contains(joined, "Германия") {
		t.Errorf("notes = %q, want a mention of the group the user actually chose", got.Notes)
	}
}

// --- step 5: honest error ---

func TestResolve_NoNodesAnywhereGivesStructuredError(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto", deadNode("a1")),
			group("emergency", "Аварийный", deadNode("e1")),
		},
	}

	_, err := Resolve(src, "", "")
	if err == nil {
		t.Fatal("want an error when nothing is connectable")
	}
	if !errors.Is(err, ErrNoNodeAvailable) {
		t.Error("want errors.Is(err, ErrNoNodeAvailable) to hold")
	}

	var rerr *ResolveError
	if !errors.As(err, &rerr) {
		t.Fatalf("error type = %T, want *ResolveError", err)
	}
	if rerr.Reason == "" {
		t.Error("want a user-facing reason, not an empty message")
	}
	if !rerr.Retryable {
		t.Error("dead nodes may recover, so this should be retryable")
	}
	// Diagnostics are the difference between a fixable report and a shrug.
	if len(rerr.Tried) == 0 {
		t.Error("want the attempted steps recorded")
	}
	if len(rerr.Details) == 0 {
		t.Error("want per-step details recorded")
	}
	if !strings.Contains(rerr.Error(), rerr.Reason) {
		t.Errorf("Error() = %q, want it to include the reason", rerr.Error())
	}
}

func TestResolve_MissingEmergencyGroupIsReported(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{group("pool-auto", "Auto", deadNode("a1"))},
	}

	_, err := Resolve(src, "", "")
	var rerr *ResolveError
	if !errors.As(err, &rerr) {
		t.Fatalf("error type = %T, want *ResolveError", err)
	}
	joined := strings.Join(rerr.Details, "; ")
	if !strings.Contains(joined, "аварийная группа отсутствует") {
		t.Errorf("details = %q, want the missing emergency group named", rerr.Details)
	}
}

func TestResolve_NoGroupsAtAllDoesNotPanic(t *testing.T) {
	src := &fakeSource{}

	_, err := Resolve(src, "", "")
	if err == nil {
		t.Fatal("want an error when there are no groups")
	}
	if !errors.Is(err, ErrNoNodeAvailable) {
		t.Error("want ErrNoNodeAvailable")
	}
}

func TestResolve_ChainOrderIsRecorded(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-de", "Германия", deadNode("de1")),
			group("pool-nl", "Нидерланды", deadNode("nl1")),
			group("pool-auto", "Auto", deadNode("a1")),
		},
		lastID: "pool-nl",
	}

	_, err := Resolve(src, "pool-de", "")
	var rerr *ResolveError
	if !errors.As(err, &rerr) {
		t.Fatalf("error type = %T, want *ResolveError", err)
	}

	want := []ResolveStep{StepExplicit, StepLastGood, StepPoolAuto, StepEmergency}
	if len(rerr.Tried) != len(want) {
		t.Fatalf("tried = %v, want %v", rerr.Tried, want)
	}
	for i := range want {
		if rerr.Tried[i] != want[i] {
			t.Errorf("tried[%d] = %q, want %q", i, rerr.Tried[i], want[i])
		}
	}
}

func TestResolve_DeterministicTiebreak(t *testing.T) {
	src := &fakeSource{
		groups: []proto.ServerGroup{
			group("pool-auto", "Auto",
				aliveNode("zzz", 50, 50),
				aliveNode("aaa", 50, 50),
			),
		},
	}

	for i := 0; i < 5; i++ {
		got, err := Resolve(src, "", "")
		if err != nil {
			t.Fatalf("resolve: %v", err)
		}
		if got.ServerID != "aaa" {
			t.Fatalf("run %d: server = %q, want a stable pick of aaa", i, got.ServerID)
		}
	}
}
