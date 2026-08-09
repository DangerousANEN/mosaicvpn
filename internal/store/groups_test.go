package store

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestDefaultGroups_MatchSpec(t *testing.T) {
	groups := DefaultGroups()
	if len(groups) != 5 {
		t.Fatalf("got %d default groups, want 5", len(groups))
	}

	want := map[string]struct {
		strategy  proto.GroupStrategy
		criterion proto.GroupCriterion
		value     string
		source    proto.GroupSource
	}{
		GroupIDPoolAuto:  {proto.GroupStrategyWeightedRoundRobin, proto.GroupCriterionAuto, "", proto.GroupSourcePool},
		GroupIDPoolFast:  {proto.GroupStrategyURLTest, proto.GroupCriterionMinPing, "", proto.GroupSourcePool},
		GroupIDPoolDE:    {proto.GroupStrategyURLTest, proto.GroupCriterionLocation, "DE", proto.GroupSourcePool},
		GroupIDPoolNL:    {proto.GroupStrategyURLTest, proto.GroupCriterionLocation, "NL", proto.GroupSourcePool},
		GroupIDEmergency: {proto.GroupStrategyDirectNode, "", "", proto.GroupSourceEmergency},
	}

	seen := map[string]bool{}
	for _, g := range groups {
		exp, ok := want[g.ID]
		if !ok {
			t.Errorf("unexpected default group %q", g.ID)
			continue
		}
		seen[g.ID] = true

		if g.Strategy != exp.strategy {
			t.Errorf("%s: strategy = %q, want %q", g.ID, g.Strategy, exp.strategy)
		}
		if g.Criterion != exp.criterion {
			t.Errorf("%s: criterion = %q, want %q", g.ID, g.Criterion, exp.criterion)
		}
		if g.CriterionValue != exp.value {
			t.Errorf("%s: criterion value = %q, want %q", g.ID, g.CriterionValue, exp.value)
		}
		if g.Source != exp.source {
			t.Errorf("%s: source = %q, want %q", g.ID, g.Source, exp.source)
		}
		if g.Title == "" {
			t.Errorf("%s: title is empty", g.ID)
		}
	}
	for id := range want {
		if !seen[id] {
			t.Errorf("missing default group %q", id)
		}
	}
}

func TestDefaultGroups_HaveNoInventedNodes(t *testing.T) {
	// Seeding fake endpoints would show the user servers that fail the moment
	// they tap connect. The pool fills these at runtime.
	for _, g := range DefaultGroups() {
		if len(g.Nodes) != 0 {
			t.Errorf("group %q ships with %d nodes, want 0", g.ID, len(g.Nodes))
		}
	}
}

func TestDefaultGroups_HealthDefaultsApplied(t *testing.T) {
	for _, g := range DefaultGroups() {
		if g.PingInterval <= 0 {
			t.Errorf("group %q: ping interval = %d, want > 0", g.ID, g.PingInterval)
		}
		if g.MaxRetries <= 0 {
			t.Errorf("group %q: max retries = %d, want > 0", g.ID, g.MaxRetries)
		}
	}
}

func TestOpen_FreshInstallHasFiveGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	if got := len(s.Groups()); got != 5 {
		t.Fatalf("fresh install has %d groups, want 5", got)
	}
	if _, ok := s.Group(GroupIDPoolAuto); !ok {
		t.Error("fresh install is missing pool-auto")
	}
	if _, ok := s.Group(GroupIDEmergency); !ok {
		t.Error("fresh install is missing emergency")
	}
}

func TestOpen_SeedsGroupsIntoPreexistingStore(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")

	// A store written before groups existed: valid JSON, no groups key.
	legacy := `{"subscriptions":[],"servers":[],"rules":[],"version":1,
	            "prefs":{"socks_addr":"127.0.0.1:1080"}}`
	if err := os.WriteFile(path, []byte(legacy), 0o600); err != nil {
		t.Fatalf("write legacy store: %v", err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open legacy store: %v", err)
	}
	if got := len(s.Groups()); got != 5 {
		t.Fatalf("legacy store upgraded to %d groups, want 5", got)
	}
}

func TestOpen_DoesNotDuplicateGroupsAcrossRestarts(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")

	for i := 0; i < 3; i++ {
		s, err := Open(path)
		if err != nil {
			t.Fatalf("open #%d: %v", i+1, err)
		}
		if got := len(s.Groups()); got != 5 {
			t.Fatalf("after %d opens: %d groups, want 5", i+1, got)
		}
	}
}

func TestOpen_PreservesUserEditsToDefaultGroups(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	g, ok := s.Group(GroupIDPoolDE)
	if !ok {
		t.Fatal("setup: pool-de missing")
	}
	g.Title = "Мой Франкфурт"
	if err := s.SaveGroup(g); err != nil {
		t.Fatalf("save group: %v", err)
	}

	// Restart: the rename must survive, not be reverted by re-seeding.
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	got, ok := s2.Group(GroupIDPoolDE)
	if !ok {
		t.Fatal("pool-de vanished after restart")
	}
	if got.Title != "Мой Франкфурт" {
		t.Errorf("title = %q after restart, want the user's edit to survive", got.Title)
	}
}

func TestOpen_ReSeedsDeletedDefaultGroup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := s.DeleteGroup(GroupIDEmergency); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, ok := s.Group(GroupIDEmergency); ok {
		t.Fatal("setup: emergency should be gone")
	}

	// A user must never end up with nothing to connect to.
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if _, ok := s2.Group(GroupIDEmergency); !ok {
		t.Error("emergency group was not re-seeded after deletion")
	}
}

func TestSaveGroup_AddsAndUpdates(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	custom := proto.ServerGroup{
		ID:       "my-group",
		Title:    "Custom",
		Source:   proto.GroupSourceUser,
		Strategy: proto.GroupStrategyFallback,
	}
	if err := s.SaveGroup(custom); err != nil {
		t.Fatalf("save: %v", err)
	}
	if got := len(s.Groups()); got != 6 {
		t.Fatalf("groups = %d after adding one, want 6", got)
	}

	custom.Title = "Renamed"
	if err := s.SaveGroup(custom); err != nil {
		t.Fatalf("update: %v", err)
	}
	if got := len(s.Groups()); got != 6 {
		t.Fatalf("groups = %d after update, want 6 (update must not append)", got)
	}

	g, ok := s.Group("my-group")
	if !ok {
		t.Fatal("custom group missing")
	}
	if g.Title != "Renamed" {
		t.Errorf("title = %q, want %q", g.Title, "Renamed")
	}
	if g.PingInterval <= 0 {
		t.Error("SaveGroup should apply health defaults")
	}
}

func TestSetGroupNodes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	nodes := []proto.NodeRef{
		{ServerID: "n1", Weight: 50, Alive: true, LatencyMs: 40},
		{ServerID: "n2", Weight: 50, Alive: true, LatencyMs: 90},
	}
	if err := s.SetGroupNodes(GroupIDPoolAuto, nodes); err != nil {
		t.Fatalf("set nodes: %v", err)
	}

	g, ok := s.Group(GroupIDPoolAuto)
	if !ok {
		t.Fatal("pool-auto missing")
	}
	if len(g.Nodes) != 2 {
		t.Fatalf("nodes = %d, want 2", len(g.Nodes))
	}

	// Must survive a restart: the pool refreshes into the store, and a lost
	// write means an empty group after every daemon bounce.
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	g2, _ := s2.Group(GroupIDPoolAuto)
	if len(g2.Nodes) != 2 {
		t.Errorf("nodes = %d after restart, want 2", len(g2.Nodes))
	}
}

func TestGroups_ReturnsCopy(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	groups := s.Groups()
	groups[0].Title = "mutated by caller"

	fresh := s.Groups()
	if fresh[0].Title == "mutated by caller" {
		t.Error("Groups() handed out a slice aliasing internal state")
	}
}
