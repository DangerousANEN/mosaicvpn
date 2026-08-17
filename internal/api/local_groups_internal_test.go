package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
	"github.com/pupspochta-cpu/mosaicvpn/internal/subs"
)

func newInternalAPITestServer(t *testing.T, fetcher Fetcher) (*Server, *store.Store, *httptest.Server) {
	t.Helper()
	s, err := store.Open(filepath.Join(t.TempDir(), "store.json"))
	if err != nil {
		t.Fatal(err)
	}
	srv := NewServer(s, state.New(s, state.NewMockBackend(), "test"), fetcher)
	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(hs.Close)
	return srv, s, hs
}

func apiRequest(t *testing.T, hs *httptest.Server, token, method, path string, body any) *http.Response {
	t.Helper()
	var payload *bytes.Reader
	if body == nil {
		payload = bytes.NewReader(nil)
	} else {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		payload = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, hs.URL+path, payload)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	response, err := hs.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

func TestMosaicDirectFeedSynthesizesPublicSmartGroups(t *testing.T) {
	feed := []byte("vless://00000000-0000-0000-0000-000000000001@198.51.100.42:443?security=tls#Mosaic%20private%20node\n")
	srv, s, hs := newInternalAPITestServer(t, func(context.Context, string) ([]byte, string, error) {
		return feed, "text/plain", nil
	})

	if err := srv.refresh(context.Background(), proto.Subscription{
		ID: "mosaic-direct", Name: "MosaicVPN", URL: "https://example.test/api/sub/token",
	}); err != nil {
		t.Fatalf("refresh direct feed: %v", err)
	}

	response := apiRequest(t, hs, srv.Token(), http.MethodGet, "/v1/manifest", nil)
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("manifest status = %d", response.StatusCode)
	}
	var manifest proto.SubscriptionManifest
	if err := json.NewDecoder(response.Body).Decode(&manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Groups) == 0 {
		t.Fatal("official direct feed returned no public smart groups")
	}
	if _, ok := s.Group("rg-all"); !ok {
		t.Fatal("synthesized smart group was not synced to resolver store")
	}

	response = apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/connect", map[string]string{"group_id": "rg-all"})
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("connect official group status = %d", response.StatusCode)
	}
}

func TestLocalCollectionGroupServerAndConnectLifecycle(t *testing.T) {
	srv, s, hs := newInternalAPITestServer(t, nil)

	response := apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/groups", map[string]string{"name": "Работа"})
	if response.StatusCode != http.StatusCreated {
		response.Body.Close()
		t.Fatalf("create group status = %d", response.StatusCode)
	}
	var group proto.ServerGroup
	if err := json.NewDecoder(response.Body).Decode(&group); err != nil {
		response.Body.Close()
		t.Fatal(err)
	}
	response.Body.Close()
	if group.Source != proto.GroupSourceUser || group.ID == "" {
		t.Fatalf("unexpected local group: %#v", group)
	}

	response = apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/servers", map[string]any{
		"server": map[string]any{
			"name":     "Local SOCKS",
			"protocol": "socks",
			"address":  "127.0.0.1",
			"port":     1080,
			"tag":      group.ID,
		},
	})
	if response.StatusCode != http.StatusCreated {
		response.Body.Close()
		t.Fatalf("add local server status = %d", response.StatusCode)
	}
	var server proto.Server
	if err := json.NewDecoder(response.Body).Decode(&server); err != nil {
		response.Body.Close()
		t.Fatal(err)
	}
	response.Body.Close()
	if server.SubscriptionID != localCollectionID {
		t.Fatalf("server subscription = %q, want %q", server.SubscriptionID, localCollectionID)
	}
	storedGroup, ok := s.Group(group.ID)
	if !ok || len(storedGroup.Nodes) != 1 || storedGroup.Nodes[0].ServerID != server.ID {
		t.Fatalf("local group nodes = %#v", storedGroup.Nodes)
	}

	response = apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/connect", map[string]string{"group_id": group.ID})
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("connect local group status = %d", response.StatusCode)
	}
}

func TestSmartGroupCandidateShardAndBoundConnect(t *testing.T) {
	feed := []byte("vless://00000000-0000-0000-0000-000000000001@198.51.100.42:443?security=tls#Mosaic%20private%20node\n")
	srv, _, hs := newInternalAPITestServer(t, func(context.Context, string) ([]byte, string, error) {
		return feed, "text/plain", nil
	})
	if err := srv.refresh(context.Background(), proto.Subscription{
		ID: "mosaic-direct", Name: "MosaicVPN", URL: "https://example.test/api/sub/token",
	}); err != nil {
		t.Fatalf("refresh direct feed: %v", err)
	}

	response := apiRequest(t, hs, srv.Token(), http.MethodGet,
		"/v1/groups/rg-all/candidates?installation_id=test-install", nil)
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		t.Fatalf("candidate shard status = %d", response.StatusCode)
	}
	var shard proto.CandidateShard
	if err := json.NewDecoder(response.Body).Decode(&shard); err != nil {
		response.Body.Close()
		t.Fatal(err)
	}
	response.Body.Close()
	if shard.GroupID != "rg-all" || shard.Version == "" || len(shard.CandidateIDs) != 1 {
		t.Fatalf("unexpected shard: %#v", shard)
	}

	response = apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/connect", map[string]string{
		"group_id": "rg-all", "server_id": shard.CandidateIDs[0],
	})
	if response.StatusCode != http.StatusOK {
		response.Body.Close()
		t.Fatalf("bound candidate connect status = %d", response.StatusCode)
	}
	response.Body.Close()

	response = apiRequest(t, hs, srv.Token(), http.MethodPost, "/v1/connect", map[string]string{
		"group_id": "rg-all", "server_id": "not-a-member",
	})
	defer response.Body.Close()
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("foreign candidate status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestReservedLTECompatibilityGroupIsDisabled(t *testing.T) {
	manifest := subs.SynthesizeManifest("mosaic-direct", []proto.Server{{
		ID: "node-1", Address: "198.51.100.10", Port: 443,
	}})
	var reserved *proto.ManifestGroup
	for i := range manifest.Groups {
		if manifest.Groups[i].ID == "reserved-lte-compat" {
			reserved = &manifest.Groups[i]
			break
		}
	}
	if reserved == nil || !reserved.Disabled || reserved.DisabledReason == "" {
		t.Fatalf("reserved compatibility group must be disabled with a reason: %#v", reserved)
	}
}
