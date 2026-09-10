package mcp_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/mcp"
	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

func setupTestServer(t *testing.T) (*mcp.Server, *store.Store, *state.Manager) {
	dir := t.TempDir()
	st, err := store.Open(filepath.Join(dir, "store.json"))
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}

	prefs := store.DefaultPrefs()
	prefs.MCPEnabled = true
	if err := st.SetPrefs(prefs); err != nil {
		t.Fatalf("SetPrefs: %v", err)
	}

	mb := state.NewMockBackend()
	mgr := state.New(st, mb, "test")
	srv := mcp.NewServer(st, mgr)
	srv.SetToken("test-secret-token")
	return srv, st, mgr
}

func TestMcpREST_LoopbackRead(t *testing.T) {
	srv, st, _ := setupTestServer(t)

	// Add test server via subscription
	sub, err := st.AddOrUpdateSubscription(proto.Subscription{
		Name: "Test Sub",
		URL:  "https://example.com/sub",
	})
	if err != nil {
		t.Fatalf("AddSub: %v", err)
	}

	err = st.ReplaceServersFor(sub.ID, []proto.Server{
		{
			ID:             "srv-de-1",
			SubscriptionID: sub.ID,
			Name:           "Germany Node 1",
			Country:        "DE",
			Address:        "1.2.3.4",
			Port:           443,
			Protocol:       "vless",
		},
	})
	if err != nil {
		t.Fatalf("ReplaceServers: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/mcp/v1/servers", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	rec := httptest.NewRecorder()

	srv.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var res struct {
		OK   bool           `json:"ok"`
		Data []proto.Server `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &res); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !res.OK || len(res.Data) != 1 || res.Data[0].ID != "srv-de-1" {
		t.Fatalf("unexpected data: %+v", res)
	}
}

func TestMcpREST_EgressLifecycle(t *testing.T) {
	srv, _, _ := setupTestServer(t)

	// 1. Add Egress
	addPayload := []byte(`{"name":"Local-Socks","protocol":"socks","listen":"127.0.0.1:1085"}`)
	req := httptest.NewRequest(http.MethodPost, "/mcp/v1/egresses", bytes.NewReader(addPayload))
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("Authorization", "Bearer test-secret-token")
	rec := httptest.NewRecorder()

	srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("add egress status %d: %s", rec.Code, rec.Body.String())
	}

	var addRes struct {
		OK   bool `json:"ok"`
		Data struct {
			Egress          proto.Egress `json:"egress"`
			ReloadTriggered bool         `json:"reload_triggered"`
		} `json:"data"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &addRes); err != nil {
		t.Fatalf("unmarshal addRes: %v", err)
	}
	egressID := addRes.Data.Egress.ID
	if egressID == "" || !addRes.Data.Egress.Active {
		t.Fatalf("invalid added egress: %+v", addRes)
	}

	// 2. List Egresses
	reqList := httptest.NewRequest(http.MethodGet, "/mcp/v1/egresses", nil)
	reqList.RemoteAddr = "127.0.0.1:54321"
	recList := httptest.NewRecorder()
	srv.ServeHTTP(recList, reqList)

	var listRes struct {
		OK   bool           `json:"ok"`
		Data []proto.Egress `json:"data"`
	}
	if err := json.Unmarshal(recList.Body.Bytes(), &listRes); err != nil {
		t.Fatalf("unmarshal listRes: %v", err)
	}
	if len(listRes.Data) != 1 || listRes.Data[0].ID != egressID {
		t.Fatalf("list egresses unexpected: %+v", listRes)
	}

	// 3. Toggle Egress
	togglePayload := []byte(`{"active":false}`)
	reqToggle := httptest.NewRequest(http.MethodPost, "/mcp/v1/egresses/"+egressID+"/toggle", bytes.NewReader(togglePayload))
	reqToggle.RemoteAddr = "127.0.0.1:54321"
	reqToggle.Header.Set("X-MCP-Token", "test-secret-token")
	recToggle := httptest.NewRecorder()
	srv.ServeHTTP(recToggle, reqToggle)

	if recToggle.Code != http.StatusOK {
		t.Fatalf("toggle status %d: %s", recToggle.Code, recToggle.Body.String())
	}
	var toggleRes struct {
		OK   bool `json:"ok"`
		Data struct {
			Egress *proto.Egress `json:"egress"`
		} `json:"data"`
	}
	if err := json.Unmarshal(recToggle.Body.Bytes(), &toggleRes); err != nil {
		t.Fatalf("unmarshal toggleRes: %v", err)
	}
	if toggleRes.Data.Egress == nil || toggleRes.Data.Egress.Active {
		t.Fatalf("expected inactive egress, got: %+v", toggleRes.Data.Egress)
	}

	// 4. Delete Egress
	reqDel := httptest.NewRequest(http.MethodDelete, "/mcp/v1/egresses/"+egressID, nil)
	reqDel.RemoteAddr = "127.0.0.1:54321"
	reqDel.Header.Set("Authorization", "Bearer test-secret-token")
	recDel := httptest.NewRecorder()
	srv.ServeHTTP(recDel, reqDel)

	if recDel.Code != http.StatusOK {
		t.Fatalf("delete egress status %d: %s", recDel.Code, recDel.Body.String())
	}
}

func TestMcpJSONRPC_ToolsCall(t *testing.T) {
	srv, _, _ := setupTestServer(t)

	// Test tools/list
	body := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	req := httptest.NewRequest(http.MethodPost, "/mcp", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	srv.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("tools/list status %d: %s", rec.Code, rec.Body.String())
	}

	var rpcRes struct {
		Result struct {
			Tools []map[string]any `json:"tools"`
		} `json:"result"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &rpcRes); err != nil {
		t.Fatalf("unmarshal tools: %v", err)
	}
	if len(rpcRes.Result.Tools) < 8 {
		t.Fatalf("expected >= 8 tools, got %d", len(rpcRes.Result.Tools))
	}
}
