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
