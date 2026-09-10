package state

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/netmemory"
)

// These tests assert the payoff of the feature end to end: a route that
// black-holed on this network must not be dialled first again, and the same
// route must keep its good standing on a different network.

func newManagerWithMemory(fingerprint string) (*Manager, *netmemory.Memory) {
	mem := netmemory.New()
	m := &Manager{
		routeMemory:    mem,
		netFingerprint: func() string { return fingerprint },
	}
	return m, mem
}

func TestRouteMemoryDemotesRoutesThatBlackHoledHere(t *testing.T) {
	m, mem := newManagerWithMemory("home-net")

	// "fast" looks best to the resolver (lowest latency) but does not carry
	// traffic on this network; "slow" works.
	mem.Record("home-net", "fast", netmemory.Outcome{Verified: false})
	mem.Record("home-net", "fast", netmemory.Outcome{Verified: false})
	mem.Record("home-net", "slow", netmemory.Outcome{Verified: true, LatencyMS: 120})

	primary, fallbacks := m.applyRouteMemory("fast", []string{"slow"})

	if primary != "slow" {
		t.Fatalf("a route known to black-hole here must not stay primary; got %q", primary)
	}
	if len(fallbacks) != 1 || fallbacks[0] != "fast" {
		t.Fatalf("demoted route must remain available as a fallback, got %v", fallbacks)
	}
}

func TestRouteMemoryIsScopedToTheCurrentNetwork(t *testing.T) {
	m, mem := newManagerWithMemory("mobile-net")

	// The route failed on home broadband, but we are on mobile now: that
	// verdict must not follow us, because blocking is per-operator.
	mem.Record("home-net", "route-a", netmemory.Outcome{Verified: false})
	mem.Record("home-net", "route-a", netmemory.Outcome{Verified: false})

	primary, _ := m.applyRouteMemory("route-a", []string{"route-b"})
	if primary != "route-a" {
		t.Fatalf("another network's verdict leaked into this one; got %q", primary)
	}
}

func TestRouteMemoryIsANoOpWhenDisabled(t *testing.T) {
	m := &Manager{} // no memory configured
	primary, fallbacks := m.applyRouteMemory("a", []string{"b", "c"})
	if primary != "a" || strings.Join(fallbacks, ",") != "b,c" {
		t.Fatalf("disabled memory must not reorder: %q %v", primary, fallbacks)
	}
}

func TestRouteMemoryIsANoOpWithoutFingerprint(t *testing.T) {
	mem := netmemory.New()
	mem.Record("", "a", netmemory.Outcome{Verified: false})
	m := &Manager{routeMemory: mem, netFingerprint: func() string { return "" }}

	primary, fallbacks := m.applyRouteMemory("a", []string{"b"})
	if primary != "a" || len(fallbacks) != 1 {
		t.Fatalf("a blank fingerprint must disable reordering, got %q %v", primary, fallbacks)
	}
}

func TestRememberOutcomeRecordsOnlyVerifiedTruth(t *testing.T) {
	m, mem := newManagerWithMemory("net-x")

	m.rememberOutcome("route-a", true, 55)
	score, known := mem.Score("net-x", "route-a")
	if !known || score < 0.9 {
		t.Fatalf("a verified connection must be remembered as good: known=%v score=%.3f", known, score)
	}

	m.rememberOutcome("route-b", false, 0)
	score, known = mem.Score("net-x", "route-b")
	if !known || score > 0.1 {
		t.Fatalf("a black-holing route must be remembered as bad: known=%v score=%.3f", known, score)
	}
}

func TestRememberOutcomeIgnoresBlankInputs(t *testing.T) {
	m, mem := newManagerWithMemory("net-x")
	m.rememberOutcome("", true, 10)
	if len(mem.Snapshot()) != 0 {
		t.Fatal("a blank route id must not create an entry")
	}

	m2 := &Manager{routeMemory: mem, netFingerprint: func() string { return "" }}
	m2.rememberOutcome("route", true, 10)
	if len(mem.Snapshot()) != 0 {
		t.Fatal("a blank network must not create an entry")
	}
}

// The full loop: a black-holing primary is rejected by the truth-check, the
// walk falls over to a healthy route, and the next attempt starts with the
// route that actually worked.
func TestMemoryLearnsFromFailoverAndFixesTheNextAttempt(t *testing.T) {
	m, mem := newManagerWithMemory("net-1")

	blackHoles := map[string]bool{"first": true}
	connect := func(_ context.Context, id string) error {
		if blackHoles[id] {
			m.rememberOutcome(id, false, 0)
			return errors.Join(ErrTunnelUnverified, errors.New("no traffic"))
		}
		m.rememberOutcome(id, true, 80)
		return nil
	}

	// First attempt: resolver ranks the broken route first.
	primary, fallbacks := m.applyRouteMemory("first", []string{"second"})
	got, rejected, err := walkCandidates(context.Background(), primary, fallbacks, connect)
	if err != nil {
		t.Fatalf("failover should have found a working route: %v", err)
	}
	if got != "second" || len(rejected) != 1 {
		t.Fatalf("expected failover to 'second', got %q rejected=%v", got, rejected)
	}

	// Second attempt: same resolver ranking, but memory now knows better.
	primary2, fallbacks2 := m.applyRouteMemory("first", []string{"second"})
	if primary2 != "second" {
		t.Fatalf("memory failed to promote the proven route; primary=%q", primary2)
	}
	if len(fallbacks2) != 1 || fallbacks2[0] != "first" {
		t.Fatalf("the failed route should still be a fallback, got %v", fallbacks2)
	}

	if score, _ := mem.Score("net-1", "second"); score < 0.9 {
		t.Fatalf("the working route should be remembered well, got %.3f", score)
	}
}

func TestRouteMemorySnapshotIsNilWhenDisabled(t *testing.T) {
	m := &Manager{}
	if snap := m.RouteMemorySnapshot(); snap != nil {
		t.Fatalf("disabled memory must export nil, got %v", snap)
	}
	if n := m.PruneRouteMemory(0); n != 0 {
		t.Fatalf("pruning disabled memory must be a no-op, got %d", n)
	}
}

func TestEnableRouteMemoryDefaultsToLocalFingerprint(t *testing.T) {
	m := &Manager{}
	m.EnableRouteMemory(netmemory.New(), nil)
	if m.netFingerprint == nil {
		t.Fatal("a nil fingerprint func must fall back to the local detector")
	}
	// Must not panic and must return a usable value on a real host.
	_ = m.currentNetwork()
}
