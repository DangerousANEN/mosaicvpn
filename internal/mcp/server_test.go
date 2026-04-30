package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

func newTestServer(t *testing.T, perm string) (*Server, string, func()) {
	t.Helper()
	dir := t.TempDir()
	st, err := store.Open(dir + "/store.json")
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	p := st.Snapshot().Prefs
	p.MCPEnabled = true
	p.MCPAddr = "127.0.0.1:0" // random free port
	p.MCPPermission = perm
	p.MCPConfirm = false
	if err := st.SetPrefs(p); err != nil {
		t.Fatalf("SetPrefs: %v", err)
	}
	mgr := state.New(st, state.NewMockBackend(), "test")

	srv := New(Config{
		Store:   st,
		Manager: mgr,
		Token:   "test-token",
		Version: "test",
		DataDir: dir,
	})
	shutdown, err := srv.Start(context.Background())
	if err != nil {
		t.Fatalf("mcp.Start: %v", err)
	}
	addr := srv.listener.Addr().String()
	return srv, "http://" + addr, func() { _ = shutdown(context.Background()) }
}

func call(t *testing.T, url, method string, params any) map[string]any {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  method,
		"params":  params,
	})
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-token")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	var out map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return out
}

func TestMCPAuth(t *testing.T) {
	_, url, cleanup := newTestServer(t, "connect")
	defer cleanup()

	// No auth header
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"})
	req, _ := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if out["error"] == nil {
		t.Fatalf("expected error without bearer, got %v", out)
	}
}

func TestMCPInitialize(t *testing.T) {
	_, url, cleanup := newTestServer(t, "connect")
	defer cleanup()

	out := call(t, url, "initialize", map[string]any{})
	res, ok := out["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result: %v", out)
	}
	if res["protocolVersion"] != "2024-11-05" {
		t.Fatalf("protocolVersion wrong: %v", res)
	}
	info := res["serverInfo"].(map[string]any)
	if info["name"] != "mosaicvpn" {
		t.Fatalf("serverInfo wrong: %v", info)
	}
}

func TestMCPToolsListRespectsPermission(t *testing.T) {
	_, url, cleanup := newTestServer(t, "read")
	defer cleanup()

	out := call(t, url, "tools/list", map[string]any{})
	res := out["result"].(map[string]any)
	tools := res["tools"].([]any)
	for _, t0 := range tools {
		name := t0.(map[string]any)["name"].(string)
		if strings.HasPrefix(name, "mosaic_add_") ||
			strings.HasPrefix(name, "mosaic_remove_") ||
			name == "mosaic_connect" ||
			name == "mosaic_disconnect" {
			t.Fatalf("read permission leaked %s", name)
		}
	}
}

func TestMCPToolCallStatus(t *testing.T) {
	_, url, cleanup := newTestServer(t, "read")
	defer cleanup()

	out := call(t, url, "tools/call", map[string]any{
		"name":      "mosaic_status",
		"arguments": map[string]any{},
	})
	res := out["result"].(map[string]any)
	if res["isError"] == true {
		t.Fatalf("status returned error: %v", res)
	}
	sc := res["structuredContent"].(map[string]any)
	if _, ok := sc["state"]; !ok {
		fmt.Printf("keys: %v\n", sc)
		t.Fatalf("structuredContent missing 'state': %v", sc)
	}
}

func TestMCPToolCallPermissionDenied(t *testing.T) {
	_, url, cleanup := newTestServer(t, "read")
	defer cleanup()

	out := call(t, url, "tools/call", map[string]any{
		"name":      "mosaic_connect",
		"arguments": map[string]any{"server_id": "does-not-matter"},
	})
	if out["error"] == nil {
		t.Fatalf("expected error for permission denied, got %v", out)
	}
}

func TestMCPDiscoveryFile(t *testing.T) {
	srv, _, cleanup := newTestServer(t, "connect")
	defer cleanup()

	p := MCPDiscoveryPath(srv.dataDir)
	var disc map[string]any
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read discovery: %v", err)
	}
	if err := json.Unmarshal(data, &disc); err != nil {
		t.Fatalf("decode discovery: %v", err)
	}
	if disc["token"] != "test-token" {
		t.Fatalf("token mismatch in discovery: %v", disc)
	}
	if disc["permission"] != "connect" {
		t.Fatalf("permission mismatch: %v", disc)
	}
}
