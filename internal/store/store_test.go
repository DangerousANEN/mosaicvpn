package store_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

func newStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "store.json"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return s
}

func TestDefaultPrefs(t *testing.T) {
	s := newStore(t)
	snap := s.Snapshot()
	if snap.Prefs.TunnelMode != "tun" {
		t.Fatalf("expected default tunnel mode tun, got %q", snap.Prefs.TunnelMode)
	}
	if !snap.Prefs.KillSwitch {
		t.Fatal("expected kill-switch on by default")
	}
	if !snap.Prefs.MinimizeToTray {
		t.Fatal("expected minimize-to-tray on by default")
	}
}

func TestLegacyStoreDefaultsMinimizeToTray(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.json")
	legacy := []byte(`{"version":1,"prefs":{"socks_addr":"127.0.0.1:1080"}}`)
	if err := os.WriteFile(path, legacy, 0o600); err != nil {
		t.Fatalf("write legacy store: %v", err)
	}
	s, err := store.Open(path)
	if err != nil {
		t.Fatalf("open legacy store: %v", err)
	}
	if !s.Snapshot().Prefs.MinimizeToTray {
		t.Fatal("expected legacy store to migrate minimize-to-tray on")
	}
}

func TestAddSubscriptionAndServers(t *testing.T) {
	s := newStore(t)
	sub, err := s.AddOrUpdateSubscription(proto.Subscription{
		URL:    "https://example.com/sub",
		Name:   "Example",
		Format: proto.FormatSingbox,
	})
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if sub.ID == "" {
		t.Fatal("expected ID assigned")
	}

	servers := []proto.Server{
		{ID: "s1", Name: "tokyo", Protocol: proto.ProtoVLESS, Address: "1.2.3.4", Port: 443},
		{ID: "s2", Name: "amst", Protocol: proto.ProtoHysteria2, Address: "5.6.7.8", Port: 8443},
	}
	if err := s.ReplaceServersFor(sub.ID, servers); err != nil {
		t.Fatalf("replace servers: %v", err)
	}

	snap := s.Snapshot()
	if len(snap.Servers) != 2 {
		t.Fatalf("expected 2 servers, got %d", len(snap.Servers))
	}
	for _, sv := range snap.Servers {
		if sv.SubscriptionID != sub.ID {
			t.Fatalf("server %q has wrong sub id %q", sv.ID, sv.SubscriptionID)
		}
	}
	for _, su := range snap.Subscriptions {
		if su.ID == sub.ID && su.ServerCount != 2 {
			t.Fatalf("expected ServerCount=2, got %d", su.ServerCount)
		}
	}
}

func TestSubscriptionByURLAllowsDuplicates(t *testing.T) {
	s := newStore(t)
	a, _ := s.AddOrUpdateSubscription(proto.Subscription{URL: "u", Name: "A"})
	b, _ := s.AddOrUpdateSubscription(proto.Subscription{URL: "u", Name: "B"})
	if a.ID == b.ID {
		t.Fatalf("expected different IDs for same-URL adds, got same: %q", a.ID)
	}
	snap := s.Snapshot()
	if len(snap.Subscriptions) != 2 {
		t.Fatalf("expected 2 subscriptions, got %d", len(snap.Subscriptions))
	}
}

func TestPersistRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "store.json")

	s, err := store.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	sub, _ := s.AddOrUpdateSubscription(proto.Subscription{URL: "u", Name: "n"})
	_ = s.ReplaceServersFor(sub.ID, []proto.Server{
		{ID: "x", Name: "tokyo", Protocol: proto.ProtoVLESS, Address: "1.1.1.1", Port: 443},
	})
	_ = s.SetLastServer("x")

	s2, err := store.Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	snap := s2.Snapshot()
	if snap.LastServerID != "x" {
		t.Fatalf("expected LastServerID=x, got %q", snap.LastServerID)
	}
	if len(snap.Servers) != 1 {
		t.Fatalf("expected 1 server, got %d", len(snap.Servers))
	}
}

func TestRules(t *testing.T) {
	s := newStore(t)
	r1, _ := s.AddRule(proto.Rule{Name: "block ads", Action: proto.ActionBlock, Match: proto.Match{GeoSite: []string{"category-ads"}}})
	r2, _ := s.AddRule(proto.Rule{Name: "stream", Action: proto.ActionProxy, Target: "auto", Match: proto.Match{GeoSite: []string{"netflix"}}})
	if r1.Priority != 1 || r2.Priority != 2 {
		t.Fatalf("expected default priorities 1,2, got %d %d", r1.Priority, r2.Priority)
	}
	if err := s.DeleteRule(r1.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	snap := s.Snapshot()
	if len(snap.Rules) != 1 || snap.Rules[0].ID != r2.ID {
		t.Fatalf("expected only r2 after deletion: %+v", snap.Rules)
	}
}

func TestProfilesRouteProfilesAndWARP(t *testing.T) {
	s := newStore(t)

	// 1. Initial State / Default check for Profiles / RouteProfiles / WARP
	snap := s.Snapshot()
	if len(snap.Profiles) != 0 {
		t.Fatalf("expected empty initial profiles, got %d", len(snap.Profiles))
	}
	if len(snap.RouteProfiles) != 0 {
		t.Fatalf("expected empty initial route profiles, got %d", len(snap.RouteProfiles))
	}
	if snap.WARP.Enabled {
		t.Fatal("expected WARP to be disabled by default")
	}

	// 2. Profile CRUD
	p, err := s.AddOrUpdateProfile(proto.Profile{
		Name:       "Test Profile",
		TunnelMode: "tun",
		KillSwitch: true,
	})
	if err != nil {
		t.Fatalf("AddProfile: %v", err)
	}
	if p.ID == "" {
		t.Fatal("expected profile ID to be generated")
	}
	if p.CreatedAt.IsZero() || p.UpdatedAt.IsZero() {
		t.Fatal("expected profile timestamps to be set")
	}

	found, ok := s.FindProfile(p.ID)
	if !ok || found.Name != "Test Profile" {
		t.Fatalf("FindProfile failed: found=%t, val=%+v", ok, found)
	}

	// Update Profile
	p.Name = "Updated Profile Name"
	p2, err := s.AddOrUpdateProfile(p)
	if err != nil {
		t.Fatalf("UpdateProfile: %v", err)
	}
	if p2.Name != "Updated Profile Name" {
		t.Fatalf("expected updated name, got %q", p2.Name)
	}
	if p2.UpdatedAt.Before(p.UpdatedAt) {
		t.Fatal("expected UpdatedAt to be updated")
	}

	// Set/Get Active Profile
	if err := s.SetActiveProfile(p2.ID); err != nil {
		t.Fatalf("SetActiveProfile failed: %v", err)
	}
	snap = s.Snapshot()
	if snap.ActiveProfileID != p2.ID {
		t.Fatalf("expected active profile ID %q, got %q", p2.ID, snap.ActiveProfileID)
	}

	// 3. RouteProfile CRUD
	rp, err := s.AddOrUpdateRouteProfile(proto.RouteProfile{
		Name:        "Test Route Profile",
		Description: "A test route profile",
		RuleIDs:     []string{"rule-1", "rule-2"},
	})
	if err != nil {
		t.Fatalf("AddRouteProfile: %v", err)
	}
	if rp.ID == "" {
		t.Fatal("expected route profile ID to be generated")
	}
	if rp.CreatedAt.IsZero() || rp.UpdatedAt.IsZero() {
		t.Fatal("expected route profile timestamps to be set")
	}

	// Update RouteProfile
	rp.Name = "Updated Route Profile"
	rp2, err := s.AddOrUpdateRouteProfile(rp)
	if err != nil {
		t.Fatalf("UpdateRouteProfile: %v", err)
	}
	if rp2.Name != "Updated Route Profile" {
		t.Fatalf("expected updated route profile name, got %q", rp2.Name)
	}

	// 4. WARP CRUD
	warpSetting := proto.WARPConfig{
		Enabled:    true,
		Mode:       "warp+",
		LicenseKey: "somekey",
	}
	if err := s.SetWARP(warpSetting); err != nil {
		t.Fatalf("SetWARP: %v", err)
	}
	gotWarp := s.GetWARP()
	if !gotWarp.Enabled || gotWarp.Mode != "warp+" || gotWarp.LicenseKey != "somekey" {
		t.Fatalf("GetWARP returned incorrect data: %+v", gotWarp)
	}

	// 5. Deletions
	if err := s.DeleteProfile(p2.ID); err != nil {
		t.Fatalf("DeleteProfile: %v", err)
	}
	if _, ok := s.FindProfile(p2.ID); ok {
		t.Fatal("expected profile to be deleted")
	}
	// Active profile should be cleared if the active profile was deleted
	snap = s.Snapshot()
	if snap.ActiveProfileID != "" {
		t.Fatalf("expected active profile to be cleared after deletion, got %q", snap.ActiveProfileID)
	}

	if err := s.DeleteRouteProfile(rp2.ID); err != nil {
		t.Fatalf("DeleteRouteProfile: %v", err)
	}
	snap = s.Snapshot()
	if len(snap.RouteProfiles) != 0 {
		t.Fatal("expected route profile to be deleted")
	}
}

