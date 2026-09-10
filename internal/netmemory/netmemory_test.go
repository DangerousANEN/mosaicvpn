package netmemory

import (
	"strings"
	"testing"
	"time"
)

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }

func TestFirstObservationSeedsInsteadOfCrawlingUp(t *testing.T) {
	m := New()
	m.Record("net1", "route-a", Outcome{Verified: true, LatencyMS: 40})

	score, known := m.Score("net1", "route-a")
	if !known {
		t.Fatal("a recorded route must be known")
	}
	// Seeding matters: with a 0 start and alpha=0.4 a working route would only
	// reach 0.4 after its first success and could lose to an untried route.
	if score < 0.99 {
		t.Fatalf("first success should seed near 1.0, got %.3f", score)
	}
}

func TestRepeatedFailuresDriveScoreDown(t *testing.T) {
	m := New()
	m.Record("net1", "route-a", Outcome{Verified: true, LatencyMS: 40})
	for i := 0; i < 4; i++ {
		m.Record("net1", "route-a", Outcome{Verified: false})
	}
	score, _ := m.Score("net1", "route-a")
	if score > 0.2 {
		t.Fatalf("four consecutive failures should sink the score, got %.3f", score)
	}
}

func TestMemoryIsPerNetwork(t *testing.T) {
	m := New()
	m.Record("home", "route-a", Outcome{Verified: true, LatencyMS: 30})
	m.Record("mobile", "route-a", Outcome{Verified: false})

	home, _ := m.Score("home", "route-a")
	mobile, _ := m.Score("mobile", "route-a")

	if home <= mobile {
		t.Fatalf("the same route must be judged per network: home=%.3f mobile=%.3f", home, mobile)
	}
	// This is the whole point of the feature: blocking is per-operator, so a
	// route can be healthy on one network and dead on another.
	if home < 0.9 || mobile > 0.1 {
		t.Fatalf("expected clear separation, got home=%.3f mobile=%.3f", home, mobile)
	}
}

func TestUnknownNetworkOrRouteReportsUnknown(t *testing.T) {
	m := New()
	m.Record("net1", "route-a", Outcome{Verified: true})

	if _, known := m.Score("other-net", "route-a"); known {
		t.Fatal("a network we have never seen must not report knowledge")
	}
	if _, known := m.Score("net1", "route-unknown"); known {
		t.Fatal("a route we have never tried must not report knowledge")
	}
}

func TestStaleKnowledgeDecaysTowardNeutral(t *testing.T) {
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	m := New()
	m.now = fixedClock(base)
	// A route that failed badly a long time ago.
	m.Record("net1", "route-a", Outcome{Verified: false, At: base})
	fresh, _ := m.Score("net1", "route-a")

	// Two half-lives later the verdict must have moved most of the way back to
	// neutral: networks change, and old evidence must not veto a retry forever.
	m.now = fixedClock(base.Add(2 * m.halfLife))
	stale, _ := m.Score("net1", "route-a")

	if !(stale > fresh) {
		t.Fatalf("stale score should rise toward neutral: fresh=%.3f stale=%.3f", fresh, stale)
	}
	if stale < 0.3 {
		t.Fatalf("after two half-lives the score should approach 0.5, got %.3f", stale)
	}
	if stale > 0.5 {
		t.Fatalf("decay must approach neutral from below, not overshoot: %.3f", stale)
	}
}

func TestReorderPrefersProvenRoutesButTriesUnknownBeforeBroken(t *testing.T) {
	m := New()
	// known good
	m.Record("net1", "good", Outcome{Verified: true, LatencyMS: 50})
	// known bad
	m.Record("net1", "bad", Outcome{Verified: false})
	m.Record("net1", "bad", Outcome{Verified: false})

	// Caller's ranking puts the broken route first (best latency on paper).
	got := m.Reorder("net1", []string{"bad", "unknown", "good"})
	want := []string{"good", "unknown", "bad"}

	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("reorder = %v, want %v", got, want)
	}
}

func TestReorderKeepsOriginalOrderOnUnseenNetwork(t *testing.T) {
	m := New()
	m.Record("home", "b", Outcome{Verified: true})

	in := []string{"a", "b", "c"}
	got := m.Reorder("cafe-wifi", in)
	if strings.Join(got, ",") != strings.Join(in, ",") {
		t.Fatalf("an unseen network must not reshuffle the caller's ranking: %v", got)
	}
}

func TestReorderIsStableForEquallyKnownRoutes(t *testing.T) {
	m := New()
	in := []string{"x", "y", "z"}
	for i := 0; i < 3; i++ {
		if got := m.Reorder("net1", in); strings.Join(got, ",") != strings.Join(in, ",") {
			t.Fatalf("ordering must be deterministic, run %d gave %v", i, got)
		}
	}
}

func TestReorderHandlesTrivialInputs(t *testing.T) {
	m := New()
	if got := m.Reorder("", []string{"a", "b"}); len(got) != 2 || got[0] != "a" {
		t.Fatalf("empty network must be a no-op, got %v", got)
	}
	if got := m.Reorder("net", []string{"only"}); len(got) != 1 {
		t.Fatalf("single candidate must be a no-op, got %v", got)
	}
	if got := m.Reorder("net", nil); got != nil {
		t.Fatalf("nil candidates must stay nil, got %v", got)
	}
}

func TestSnapshotAndLoadRoundTrip(t *testing.T) {
	m := New()
	m.Record("net1", "route-a", Outcome{Verified: true, LatencyMS: 42})
	m.Record("net2", "route-b", Outcome{Verified: false})

	snap := m.Snapshot()

	restored := New()
	restored.Load(snap)

	for _, tc := range []struct{ net, route string }{{"net1", "route-a"}, {"net2", "route-b"}} {
		before, _ := m.Score(tc.net, tc.route)
		after, known := restored.Score(tc.net, tc.route)
		if !known {
			t.Fatalf("%s/%s lost across persistence", tc.net, tc.route)
		}
		if diff := before - after; diff > 0.0001 || diff < -0.0001 {
			t.Fatalf("%s/%s score drifted: %.4f -> %.4f", tc.net, tc.route, before, after)
		}
	}
}

func TestSnapshotIsADeepCopy(t *testing.T) {
	m := New()
	m.Record("net1", "route-a", Outcome{Verified: true})
	snap := m.Snapshot()

	// Mutating the snapshot must not corrupt live state.
	snap["net1"]["route-a"] = RouteStat{SuccessRate: 0, Attempts: 99}
	score, _ := m.Score("net1", "route-a")
	if score < 0.9 {
		t.Fatalf("snapshot mutation leaked into live memory: %.3f", score)
	}
}

func TestPruneDropsStaleEntriesAndEmptyNetworks(t *testing.T) {
	base := time.Date(2026, 9, 1, 12, 0, 0, 0, time.UTC)
	m := New()
	m.now = fixedClock(base)
	m.Record("old-net", "route-a", Outcome{Verified: true, At: base.Add(-30 * 24 * time.Hour)})
	m.Record("live-net", "route-b", Outcome{Verified: true, At: base})

	removed := m.Prune(7 * 24 * time.Hour)
	if removed != 1 {
		t.Fatalf("expected 1 stale entry removed, got %d", removed)
	}
	if _, known := m.Score("old-net", "route-a"); known {
		t.Fatal("stale entry survived prune")
	}
	if _, known := m.Score("live-net", "route-b"); !known {
		t.Fatal("prune must not touch fresh entries")
	}
	if _, ok := m.Snapshot()["old-net"]; ok {
		t.Fatal("an emptied network must be dropped entirely")
	}
}

func TestRecordIgnoresEmptyKeys(t *testing.T) {
	m := New()
	m.Record("", "route", Outcome{Verified: true})
	m.Record("net", "", Outcome{Verified: true})
	if len(m.Snapshot()) != 0 {
		t.Fatal("empty keys must not create entries")
	}
}

func TestFingerprintIsStableOrderIndependentAndOpaque(t *testing.T) {
	a := Fingerprint("wlan0/192.168.1.0", "eth0/10.0.0.0")
	b := Fingerprint("eth0/10.0.0.0", "wlan0/192.168.1.0")
	if a != b {
		t.Fatal("fingerprint must not depend on input order")
	}
	if a == "" {
		t.Fatal("fingerprint must not be empty for real inputs")
	}
	// Privacy: the raw network identity must not be recoverable from what we
	// store, because it can reveal a home or employer network.
	if strings.Contains(a, "192.168") || strings.Contains(a, "wlan0") {
		t.Fatalf("fingerprint leaked its inputs: %q", a)
	}
	if Fingerprint("", "  ") != "" {
		t.Fatal("blank inputs must yield no fingerprint")
	}
	if Fingerprint("wlan0/192.168.1.0") == a {
		t.Fatal("different networks must not collide")
	}
}

func TestFingerprintIsCaseInsensitive(t *testing.T) {
	if Fingerprint("WLAN0/192.168.1.0") != Fingerprint("wlan0/192.168.1.0") {
		t.Fatal("interface casing must not create a second identity")
	}
}
