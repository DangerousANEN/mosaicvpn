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

func TestDeriveCandidateFeedURL(t *testing.T) {
	subURL := "https://sub.zxc1x1.ru/reftcT_frzSCwhav"
	got := deriveCandidateFeedURL(subURL)
	want := "https://sub.zxc1x1.ru/api/client-candidates/reftcT_frzSCwhav"
	if got != want {
		t.Errorf("deriveCandidateFeedURL(%q) = %q; want %q", subURL, got, want)
	}
}

func TestResolveGroupNodes(t *testing.T) {
	servers := []proto.Server{
		{ID: "srv-1", Name: "DE Server", Country: "DE", Protocol: "vless", Raw: map[string]any{"mosaic_client_candidate": true}},
		{ID: "srv-2", Name: "NL Server", Country: "NL", Protocol: "vless", Raw: map[string]any{"mosaic_client_candidate": true}},
		{ID: "srv-3", Name: "Whitelist 4G", Country: "RU", Protocol: "vless", Raw: map[string]any{"mosaic_client_candidate": true}},
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

func TestDirectPathNeverMatchesClientCandidates(t *testing.T) {
	servers := []proto.Server{
		{ID: "direct", Protocol: proto.ProtoVLESS, Raw: map[string]any{"path": "/direct"}},
		{ID: "candidate", Protocol: proto.ProtoVLESS, Raw: map[string]any{
			"path": "/direct", "mosaic_client_candidate": true,
		}},
	}
	nodes := resolveGroupNodes(proto.ManifestGroup{
		ID: "direct", RouteType: "direct", Category: "direct", DirectPath: "/direct",
	}, servers)
	if len(nodes) != 1 || nodes[0].ID != "direct" {
		t.Fatalf("direct nodes = %#v; want only ordinary /direct profile", nodes)
	}
}

func TestFetchClientCandidates(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/client-candidates/token123" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"outbounds":[{"type":"vless","tag":"candidate-1","server":"candidate.example","server_port":443,"uuid":"test","mosaic_client_candidate":true,"mosaic_country":"DE"}]}`))
	}))
	defer server.Close()

	candidates, err := FetchClientCandidates(context.Background(), server.URL+"/token123", "sub-id")
	if err != nil {
		t.Fatalf("FetchClientCandidates error: %v", err)
	}
	if len(candidates) != 1 || candidates[0].Country != "DE" || !boolRaw(candidates[0], "mosaic_client_candidate") {
		t.Fatalf("candidates = %#v; want one marked DE candidate", candidates)
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
				"mosaic_client_candidate":  true,
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
				"mosaic_client_candidate":   true,
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
				"mosaic_client_candidate": true,
				"mosaic_stable":           false,
				"mosaic_speed_eligible":   false,
				"mosaic_allowlist":        false,
			},
		},
	}

	stable := resolveGroupNodes(proto.ManifestGroup{ID: "stable", Category: "smart"}, servers)
	if len(stable) != 2 || stable[0].ID != "stable-fast" || stable[0].Priority != 2 || stable[1].ID != "allowlist-primary" || stable[1].Priority != 1 {
		t.Fatalf("stable group = %#v; expected exactly the two stable candidates with priorities", stable)
	}

	speed := resolveGroupNodes(proto.ManifestGroup{ID: "max-speed", Category: "smart"}, servers)
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

func TestParseManifestOrSynthesizeResolvesExplicitDirectRoute(t *testing.T) {
	raw := []proto.Server{
		{ID: "de-public", Name: "Public DE", Country: "DE", Protocol: proto.ProtoVLESS},
		{ID: "ca-private", Name: "Private CA", Country: "CA", Protocol: proto.ProtoVLESS},
	}
	content := []byte(`{
		"provider_name":"Example provider",
		"direct_routes":[{
			"id":"direct-de",
			"title":"Example Direct · Germany",
			"route_type":"direct",
			"type":"direct_node",
			"pool_id":"example-public-de",
			"country_code":"DE",
			"protocol":"vless",
			"category":"direct"
		}]
	}`)

	manifest, servers := ParseManifestOrSynthesize(content, "example-subscription", raw)
	if len(manifest.Groups) != 0 || len(manifest.DirectRoutes) != 1 {
		t.Fatalf("routes = groups:%d direct:%d; want groups:0 direct:1", len(manifest.Groups), len(manifest.DirectRoutes))
	}
	route := manifest.DirectRoutes[0]
	if len(route.Nodes) != 1 || route.Nodes[0].ID != "de-public" {
		t.Fatalf("direct route resolved nodes = %#v; want only confirmed DE node", route.Nodes)
	}
	if len(servers) != 3 || !servers[0].IsVirtualGroup || servers[0].Country != "DE" {
		t.Fatalf("virtual direct row = %#v; want a DE virtual route plus untouched raw nodes", servers)
	}
	if got := servers[0].Raw["mosaic_route_type"]; got != "direct" {
		t.Fatalf("virtual direct route type = %#v; want direct", got)
	}

	missingGeo := resolveGroupNodes(proto.ManifestGroup{
		ID: "direct-unverified", Category: "direct", RouteType: "direct",
	}, raw)
	if len(missingGeo) != 0 {
		t.Fatalf("direct route without verified country must not include nodes: %#v", missingGeo)
	}
}

func TestSynthesizeManifestIsExplicitlyOptIn(t *testing.T) {
	manifest := SynthesizeManifest("mosaic-direct", []proto.Server{{ID: "pool-node", Protocol: proto.ProtoVLESS}})
	if len(manifest.Groups) == 0 {
		t.Fatal("explicit Mosaic synthesis must still produce service groups")
	}
}
