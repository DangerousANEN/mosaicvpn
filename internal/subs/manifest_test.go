package subs

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

func TestDeriveManifestURL(t *testing.T) {
	subURL := "https://sub.zxc1x1.ru/api/sub/token123"
	got := deriveManifestURL(subURL)
	want := "https://sub.zxc1x1.ru/api/manifest.json"
	if got != want {
		t.Errorf("deriveManifestURL(%q) = %q; want %q", subURL, got, want)
	}
}

func TestResolveGroupNodes(t *testing.T) {
	servers := []proto.Server{
		{ID: "srv-1", Name: "DE Server", Country: "DE", Protocol: "vless"},
		{ID: "srv-2", Name: "NL Server", Country: "NL", Protocol: "vless"},
		{ID: "srv-3", Name: "Whitelist 4G", Country: "RU", Protocol: "vless"},
	}

	groupSmartDE := proto.ManifestGroup{
		ID:       "auto-de",
		Category: "smart",
	}
	nodesDE := resolveGroupNodes(groupSmartDE, servers)
	if len(nodesDE) != 1 || nodesDE[0].ID != "srv-1" {
		t.Errorf("resolveGroupNodes(auto-de) got %v; want [srv-1]", nodesDE)
	}

	groupWhitelist := proto.ManifestGroup{
		ID:       "auto-whitelist",
		Category: "whitelist",
	}
	nodesWL := resolveGroupNodes(groupWhitelist, servers)
	if len(nodesWL) != 3 { // all 3 are vless or match whitelist
		t.Errorf("resolveGroupNodes(auto-whitelist) got len %d; want 3", len(nodesWL))
	}
}

func TestFetchProviderManifest(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/manifest.json" {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{
				"provider_name": "TestProvider",
				"groups": [{"id": "g1", "title": "Group 1"}],
				"profile": {
					"branding": {"provider_description": "Test Provider Desc"}
				}
			}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer server.Close()

	ctx := context.Background()
	manifest, err := FetchProviderManifest(ctx, server.URL+"/api/sub/123")
	if err != nil {
		t.Fatalf("FetchProviderManifest failed: %v", err)
	}
	if manifest == nil {
		t.Fatalf("expected non-nil manifest")
	}
	if manifest.ProviderName != "TestProvider" {
		t.Errorf("got provider_name = %q; want TestProvider", manifest.ProviderName)
	}
	if manifest.Profile == nil || manifest.Profile.Branding.ProviderDescription != "Test Provider Desc" {
		t.Errorf("got profile branding description = %v; want 'Test Provider Desc'", manifest.Profile)
	}
}

func TestResolveMosaicHintGroups(t *testing.T) {
	servers := []proto.Server{
		{
			ID:       "stable-fast",
			Protocol: "vless",
			Raw: map[string]any{
				"mosaic_stable":            true,
				"mosaic_stable_priority":   float64(2),
				"mosaic_speed_eligible":    true,
				"mosaic_allowlist":         false,
				"mosaic_failover_priority": float64(4),
			},
		},
		{
			ID:       "allowlist-primary",
			Protocol: "vless",
			Raw: map[string]any{
				"mosaic_stable":             true,
				"mosaic_stable_priority":    float64(1),
				"mosaic_speed_eligible":     false,
				"mosaic_allowlist":          true,
				"mosaic_allowlist_priority": float64(1),
			},
		},
		{
			ID:       "ordinary",
			Protocol: "shadowsocks",
			Raw: map[string]any{
				"mosaic_stable":         false,
				"mosaic_speed_eligible": false,
				"mosaic_allowlist":      false,
			},
		},
	}

	stable := resolveGroupNodes(proto.ManifestGroup{ID: "auto-stable", Category: "smart"}, servers)
	if len(stable) != 2 || stable[0].ID != "stable-fast" || stable[0].Priority != 2 || stable[1].ID != "allowlist-primary" || stable[1].Priority != 1 {
		t.Fatalf("stable group = %#v; expected exactly the two stable candidates with priorities", stable)
	}

	speed := resolveGroupNodes(proto.ManifestGroup{ID: "auto-speed", Category: "smart"}, servers)
	if len(speed) != 1 || speed[0].ID != "stable-fast" {
		t.Fatalf("speed group = %#v; expected only speed-eligible candidate", speed)
	}

	allowlist := resolveGroupNodes(proto.ManifestGroup{ID: "auto-allowlist", Category: "whitelist"}, servers)
	if len(allowlist) != 1 || allowlist[0].ID != "allowlist-primary" || allowlist[0].Priority != 1 {
		t.Fatalf("allowlist group = %#v; expected the assigned Reality candidate", allowlist)
	}
}

func TestParseManifestOrSynthesizeKeepsRawImportedFeedUnchanged(t *testing.T) {
	raw := []proto.Server{{
		ID:       "foreign-node",
		Name:     "Foreign VLESS",
		Protocol: proto.ProtoVLESS,
	}}

	manifest, servers := ParseManifestOrSynthesize(
		[]byte("vless://not-a-provider-manifest"),
		"foreign-subscription",
		raw,
	)

	if len(manifest.Groups) != 0 {
		t.Fatalf("raw imported feed received %d Mosaic groups; want none", len(manifest.Groups))
	}
	if len(servers) != 1 || servers[0].ID != "foreign-node" {
		t.Fatalf("raw imported feed servers = %#v; want exactly its original node", servers)
	}
	if servers[0].IsVirtualGroup {
		t.Fatal("raw imported feed node must not become a virtual group")
	}
}

func TestParseManifestOrSynthesizePreservesExplicitProviderGroups(t *testing.T) {
	raw := []proto.Server{{
		ID:       "provider-node",
		Name:     "Provider node",
		Protocol: proto.ProtoVLESS,
	}}
	content := []byte(`{
		"provider_name":"Example provider",
		"groups":[{"id":"example-fast","title":"Fast","type":"urltest","category":"smart"}]
	}`)

	manifest, servers := ParseManifestOrSynthesize(content, "example-subscription", raw)
	if len(manifest.Groups) != 1 || manifest.Groups[0].ID != "example-fast" {
		t.Fatalf("explicit groups = %#v; want example-fast", manifest.Groups)
	}
	if len(servers) != 2 || !servers[0].IsVirtualGroup || servers[1].ID != "provider-node" {
		t.Fatalf("explicit manifest servers = %#v; want virtual group and raw provider node", servers)
	}
}

func TestSynthesizeManifestIsExplicitlyOptIn(t *testing.T) {
	manifest := SynthesizeManifest("mosaic-direct", []proto.Server{{ID: "pool-node", Protocol: proto.ProtoVLESS}})
	if len(manifest.Groups) == 0 {
		t.Fatal("explicit Mosaic synthesis must still produce service groups")
	}
}
