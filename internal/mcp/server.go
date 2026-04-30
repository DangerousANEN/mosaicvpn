// Package mcp implements an HTTP+JSON-RPC 2.0 server that follows the
// Model Context Protocol (https://modelcontextprotocol.io) so that LLM
// agents can inspect and drive the Mosaic daemon.
//
// The server is intentionally thin: every tool delegates to the same
// *store.Store / *state.Manager that the main HTTP API uses, reusing
// the daemon's bearer token for auth. It binds to Prefs.MCPAddr
// (default 127.0.0.1:8731) and writes an `mcp.json` discovery file
// into DataDir so agents can read the endpoint + token without having
// to parse the Tauri config.
//
// Transport: a single POST `/` endpoint accepts JSON-RPC 2.0 requests.
// This is the fallback "Streamable HTTP" shape from the MCP spec with
// the SSE upgrade path omitted (not needed — Mosaic's tools are all
// short-lived). Clients that insist on SSE can use a shim like
// `mcp-remote`.
//
// Permission model:
//
//	read    : status / lists only
//	connect : adds connect, disconnect, url_test
//	full    : adds add/remove/refresh/update subscription, set_prefs
//
// A confirm-required flow (Prefs.MCPConfirm) is documented in the
// SKILL but not yet wired through the renderer — for now MCPConfirm
// only gates destructive tools by returning an error suggesting the
// user disable confirm in Settings. Future work: SSE bridge to UI.
package mcp

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/DangerousANEN/mosaicvpn/internal/logx"
	"github.com/DangerousANEN/mosaicvpn/internal/paths"
	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/state"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// Permission level for gating tools.
type Permission int

const (
	PermNone Permission = iota
	PermRead
	PermConnect
	PermFull
)

func parsePermission(s string) Permission {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "read":
		return PermRead
	case "connect", "":
		return PermConnect
	case "full":
		return PermFull
	default:
		return PermConnect
	}
}

// URLTestFn runs a Verify (URL test) probe through the given server and
// persists the result. Injected to avoid a circular dependency with
// internal/api.
type URLTestFn func(ctx context.Context, serverID string) error

// RefreshFn refreshes a subscription (fetch + parse + replace servers).
type RefreshFn func(ctx context.Context, sub proto.Subscription) error

// Server is the MCP JSON-RPC server.
type Server struct {
	store     *store.Store
	mgr       *state.Manager
	token     string
	version   string
	perm      Permission
	confirm   bool
	urlTest   URLTestFn
	refresh   RefreshFn
	dataDir   string

	listener net.Listener
	http     *http.Server
}

// Config bundles the bits needed to construct a Server.
type Config struct {
	Store   *store.Store
	Manager *state.Manager
	Token   string
	Version string
	DataDir string
	URLTest URLTestFn
	Refresh RefreshFn
}

// New constructs a disabled (not yet listening) MCP server.
func New(c Config) *Server {
	return &Server{
		store:   c.Store,
		mgr:     c.Manager,
		token:   c.Token,
		version: c.Version,
		dataDir: c.DataDir,
		urlTest: c.URLTest,
		refresh: c.Refresh,
	}
}

// Start binds the MCP HTTP listener using the live Prefs.MCPAddr and
// writes `{DataDir}/mcp.json` for agent discovery. Returns a shutdown
// func. Calling Start when Prefs.MCPEnabled=false returns a nil
// shutdown and nil error.
func (s *Server) Start(ctx context.Context) (func(context.Context) error, error) {
	prefs := s.store.Snapshot().Prefs
	if !prefs.MCPEnabled {
		logx.Info("mcp disabled via prefs")
		_ = s.clearDiscovery()
		return func(context.Context) error { return nil }, nil
	}
	s.perm = parsePermission(prefs.MCPPermission)
	s.confirm = prefs.MCPConfirm

	addr := strings.TrimSpace(prefs.MCPAddr)
	if addr == "" {
		addr = "127.0.0.1:8731"
	}
	// Guard against leaking the MCP endpoint off-box. Loopback or
	// unspecified-bound-to-loopback only.
	if !isLoopbackAddr(addr) {
		return nil, fmt.Errorf("mcp_addr %q must bind to 127.0.0.1/::1 only", addr)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("mcp listen %s: %w", addr, err)
	}
	s.listener = ln

	mux := http.NewServeMux()
	mux.HandleFunc("POST /", s.handleRPC)
	mux.HandleFunc("GET /healthz", s.handleHealth)
	s.http = &http.Server{
		Handler:           s.authMiddleware(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
	go func() {
		if err := s.http.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logx.Error("mcp server crashed", "err", err)
		}
	}()
	logx.Info("mcp listening",
		"addr", ln.Addr().String(),
		"permission", prefs.MCPPermission,
		"confirm", prefs.MCPConfirm,
	)
	if err := s.writeDiscovery(ln.Addr().String()); err != nil {
		logx.Warn("mcp discovery write failed", "err", err)
	}
	return s.http.Shutdown, nil
}

func isLoopbackAddr(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if host == "" || host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

// writeDiscovery writes mcp.json into DataDir so agents can find the
// endpoint + token. File is chmod 0600 on Unix (Windows ignores).
func (s *Server) writeDiscovery(actualAddr string) error {
	p := MCPDiscoveryPath(s.dataDir)
	payload := map[string]any{
		"url":        "http://" + actualAddr + "/",
		"token":      s.token,
		"permission": s.permString(),
		"confirm":    s.confirm,
		"version":    s.version,
		"pid":        os.Getpid(),
		"started":    time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(payload, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	return os.WriteFile(p, data, 0o600)
}

func (s *Server) clearDiscovery() error {
	p := MCPDiscoveryPath(s.dataDir)
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// MCPDiscoveryPath returns the canonical path to the mcp.json discovery
// file inside dir (the daemon's DataDir). Exposed so the CLI / UI can
// read it the same way agents do.
func MCPDiscoveryPath(dir string) string {
	if dir == "" {
		dir = paths.DataDir()
	}
	return filepath.Join(dir, "mcp.json")
}

func (s *Server) permString() string {
	switch s.perm {
	case PermRead:
		return "read"
	case PermConnect:
		return "connect"
	case PermFull:
		return "full"
	default:
		return "none"
	}
}

// ---------- auth / RPC plumbing ---------------------------------------

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeJSONRPCError(w, nil, -32000, "missing bearer token")
			return
		}
		got := strings.TrimPrefix(auth, "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(s.token)) != 1 {
			writeJSONRPCError(w, nil, -32000, "bad token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"ok":true}`))
}

type jsonRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonRPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *jsonRPCErr     `json:"error,omitempty"`
}

type jsonRPCErr struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

func writeJSONRPCError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	resp := jsonRPCResponse{JSONRPC: "2.0", ID: id, Error: &jsonRPCErr{Code: code, Message: msg}}
	b, _ := json.Marshal(resp)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(b)
}

func writeJSONRPCResult(w http.ResponseWriter, id json.RawMessage, result any) {
	resp := jsonRPCResponse{JSONRPC: "2.0", ID: id, Result: result}
	b, _ := json.Marshal(resp)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(b)
}

func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	var req jsonRPCRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONRPCError(w, nil, -32700, "parse error: "+err.Error())
		return
	}
	if req.JSONRPC != "2.0" {
		writeJSONRPCError(w, req.ID, -32600, "jsonrpc must be 2.0")
		return
	}
	switch req.Method {
	case "initialize":
		s.rpcInitialize(w, r, req)
	case "ping":
		writeJSONRPCResult(w, req.ID, map[string]any{})
	case "tools/list":
		s.rpcToolsList(w, r, req)
	case "tools/call":
		s.rpcToolsCall(w, r, req)
	case "notifications/initialized", "initialized":
		// Notification: no response body.
		w.WriteHeader(http.StatusNoContent)
	default:
		writeJSONRPCError(w, req.ID, -32601, "method not found: "+req.Method)
	}
}

// ---------- initialize / tools/list ------------------------------------

func (s *Server) rpcInitialize(w http.ResponseWriter, _ *http.Request, req jsonRPCRequest) {
	writeJSONRPCResult(w, req.ID, map[string]any{
		"protocolVersion": "2024-11-05",
		"capabilities": map[string]any{
			"tools": map[string]any{"listChanged": false},
		},
		"serverInfo": map[string]any{
			"name":       "mosaicvpn",
			"version":    s.version,
			"permission": s.permString(),
		},
	})
}

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`

	// internal
	minPerm Permission
	handler func(ctx context.Context, args map[string]any) (any, error)
}

func (s *Server) tools() []toolDef {
	objSchema := func(props map[string]any, required ...string) map[string]any {
		m := map[string]any{"type": "object", "properties": props}
		if len(required) > 0 {
			m["required"] = required
		}
		return m
	}
	empty := objSchema(map[string]any{})
	return []toolDef{
		{
			Name:        "mosaic_status",
			Description: "Return the current Mosaic daemon status: connection state, active server, bytes in/out, uptime, my-location.",
			InputSchema: empty,
			minPerm:     PermRead,
			handler:     s.toolStatus,
		},
		{
			Name:        "mosaic_list_subscriptions",
			Description: "List all configured subscriptions with id, name, URL, server count, last refresh, and traffic/expiry info when available.",
			InputSchema: empty,
			minPerm:     PermRead,
			handler:     s.toolListSubscriptions,
		},
		{
			Name:        "mosaic_list_servers",
			Description: "List servers aggregated from all subscriptions. Supports filtering by subscription_id, country (ISO-3166), city substring, protocol, and a limit. Default limit is 50; pass limit:-1 for no limit.",
			InputSchema: objSchema(map[string]any{
				"subscription_id": map[string]any{"type": "string"},
				"country":         map[string]any{"type": "string", "description": "ISO-3166 alpha-2 country code, case-insensitive"},
				"city":            map[string]any{"type": "string", "description": "Case-insensitive substring match on server.city"},
				"protocol":        map[string]any{"type": "string", "enum": []string{"vless", "hysteria2", "naive", "shadowsocks", "amneziawg"}},
				"limit":           map[string]any{"type": "integer", "description": "Max rows; default 50, -1 = all"},
			}),
			minPerm: PermRead,
			handler: s.toolListServers,
		},
		{
			Name:        "mosaic_connect",
			Description: "Connect the tunnel to the given server_id. Blocks until the manager reports Connected or an error occurs.",
			InputSchema: objSchema(map[string]any{
				"server_id": map[string]any{"type": "string"},
			}, "server_id"),
			minPerm: PermConnect,
			handler: s.toolConnect,
		},
		{
			Name:        "mosaic_disconnect",
			Description: "Disconnect the active tunnel, if any.",
			InputSchema: empty,
			minPerm:     PermConnect,
			handler:     s.toolDisconnect,
		},
		{
			Name:        "mosaic_url_test",
			Description: "Run a Verify probe through the given server_id: spin up a transient sing-box, fetch the configured URLTestEndpoint, persist the RTT / status / error on the server record, and return the result.",
			InputSchema: objSchema(map[string]any{
				"server_id": map[string]any{"type": "string"},
			}, "server_id"),
			minPerm: PermConnect,
			handler: s.toolURLTest,
		},
		{
			Name:        "mosaic_add_subscription",
			Description: "Add a new subscription by URL and immediately refresh it. Accepts VLESS/Trojan/SS/Hysteria2/VMess aggregator URLs or a single-server URI.",
			InputSchema: objSchema(map[string]any{
				"url":    map[string]any{"type": "string"},
				"name":   map[string]any{"type": "string"},
				"format": map[string]any{"type": "string", "description": "Subscription format hint, usually empty"},
			}, "url"),
			minPerm: PermFull,
			handler: s.toolAddSubscription,
		},
		{
			Name:        "mosaic_remove_subscription",
			Description: "Delete a subscription and all of its servers. Irreversible.",
			InputSchema: objSchema(map[string]any{
				"subscription_id": map[string]any{"type": "string"},
			}, "subscription_id"),
			minPerm: PermFull,
			handler: s.toolRemoveSubscription,
		},
		{
			Name:        "mosaic_refresh_subscription",
			Description: "Re-fetch a subscription from its URL and replace its server list.",
			InputSchema: objSchema(map[string]any{
				"subscription_id": map[string]any{"type": "string"},
			}, "subscription_id"),
			minPerm: PermConnect,
			handler: s.toolRefreshSubscription,
		},
		{
			Name:        "mosaic_get_prefs",
			Description: "Return the current Prefs object (all daemon-level preferences).",
			InputSchema: empty,
			minPerm:     PermRead,
			handler:     s.toolGetPrefs,
		},
	}
}

func (s *Server) rpcToolsList(w http.ResponseWriter, _ *http.Request, req jsonRPCRequest) {
	all := s.tools()
	out := make([]toolDef, 0, len(all))
	for _, t := range all {
		if t.minPerm > s.perm {
			continue
		}
		out = append(out, t)
	}
	writeJSONRPCResult(w, req.ID, map[string]any{"tools": out})
}

// ---------- tools/call -------------------------------------------------

func (s *Server) rpcToolsCall(w http.ResponseWriter, r *http.Request, req jsonRPCRequest) {
	var params struct {
		Name      string         `json:"name"`
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil {
		writeJSONRPCError(w, req.ID, -32602, "invalid params: "+err.Error())
		return
	}
	var chosen *toolDef
	for _, t := range s.tools() {
		if t.Name == params.Name {
			tt := t
			chosen = &tt
			break
		}
	}
	if chosen == nil {
		writeJSONRPCError(w, req.ID, -32601, "unknown tool: "+params.Name)
		return
	}
	if chosen.minPerm > s.perm {
		writeJSONRPCError(w, req.ID, -32000, fmt.Sprintf(
			"tool %q requires %s permission, but MCP permission is %s — change in Settings → MCP",
			chosen.Name, permLabel(chosen.minPerm), s.permString()))
		return
	}
	if s.confirm && chosen.minPerm >= PermConnect {
		// Confirm-required flow not yet wired to renderer; surface a
		// clear error so agents know what to tell the user.
		writeJSONRPCError(w, req.ID, -32000, fmt.Sprintf(
			"tool %q requires user confirmation (Prefs.MCPConfirm=true); toggle confirm off in Settings → MCP to allow agent-driven actions",
			chosen.Name))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	result, err := chosen.handler(ctx, params.Arguments)
	if err != nil {
		writeJSONRPCResult(w, req.ID, map[string]any{
			"content":  []map[string]any{{"type": "text", "text": err.Error()}},
			"isError":  true,
		})
		return
	}
	// Spec-compliant shape: content[] + structuredContent for agents
	// that want the raw JSON.
	text, _ := json.MarshalIndent(result, "", "  ")
	writeJSONRPCResult(w, req.ID, map[string]any{
		"content":           []map[string]any{{"type": "text", "text": string(text)}},
		"structuredContent": result,
		"isError":           false,
	})
}

func permLabel(p Permission) string {
	switch p {
	case PermRead:
		return "read"
	case PermConnect:
		return "connect"
	case PermFull:
		return "full"
	default:
		return "none"
	}
}

// ---------- tool implementations --------------------------------------

func (s *Server) toolStatus(_ context.Context, _ map[string]any) (any, error) {
	return s.mgr.Status(), nil
}

func (s *Server) toolListSubscriptions(_ context.Context, _ map[string]any) (any, error) {
	snap := s.store.Snapshot()
	type subSummary struct {
		ID             string    `json:"id"`
		Name           string    `json:"name"`
		URL            string    `json:"url"`
		ServerCount    int       `json:"server_count"`
		LastFetched    time.Time `json:"last_fetched,omitempty"`
		LastError      string    `json:"last_error,omitempty"`
	}
	out := make([]subSummary, 0, len(snap.Subscriptions))
	for _, sub := range snap.Subscriptions {
		n := 0
		for _, sv := range snap.Servers {
			if sv.SubscriptionID == sub.ID {
				n++
			}
		}
		out = append(out, subSummary{
			ID:          sub.ID,
			Name:        sub.Name,
			URL:         sub.URL,
			ServerCount: n,
			LastFetched: sub.LastFetched,
			LastError:   sub.LastError,
		})
	}
	return out, nil
}

func (s *Server) toolListServers(_ context.Context, args map[string]any) (any, error) {
	snap := s.store.Snapshot()
	subID, _ := args["subscription_id"].(string)
	country, _ := args["country"].(string)
	country = strings.ToUpper(strings.TrimSpace(country))
	city, _ := args["city"].(string)
	city = strings.ToLower(strings.TrimSpace(city))
	protocol, _ := args["protocol"].(string)
	protocol = strings.ToLower(strings.TrimSpace(protocol))
	limit := 50
	if v, ok := args["limit"].(float64); ok {
		limit = int(v)
	}

	filtered := make([]proto.Server, 0, len(snap.Servers))
	for _, sv := range snap.Servers {
		if subID != "" && sv.SubscriptionID != subID {
			continue
		}
		if country != "" && !strings.EqualFold(sv.Country, country) {
			continue
		}
		if city != "" && !strings.Contains(strings.ToLower(sv.City), city) {
			continue
		}
		if protocol != "" && !strings.EqualFold(string(sv.Protocol), protocol) {
			continue
		}
		filtered = append(filtered, sv)
	}
	// Stable-ish ordering: by LastURLTestMS ascending, then by name.
	sort.SliceStable(filtered, func(i, j int) bool {
		ai, aj := filtered[i].LastURLTestMS, filtered[j].LastURLTestMS
		if ai > 0 && aj > 0 && ai != aj {
			return ai < aj
		}
		if ai > 0 && aj == 0 {
			return true
		}
		if aj > 0 && ai == 0 {
			return false
		}
		return filtered[i].Name < filtered[j].Name
	})
	total := len(filtered)
	if limit > 0 && len(filtered) > limit {
		filtered = filtered[:limit]
	}
	return map[string]any{
		"total":    total,
		"returned": len(filtered),
		"servers":  filtered,
	}, nil
}

func (s *Server) toolConnect(ctx context.Context, args map[string]any) (any, error) {
	id, _ := args["server_id"].(string)
	if id == "" {
		return nil, errors.New("server_id is required")
	}
	if err := s.mgr.Connect(ctx, id); err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return s.mgr.Status(), nil
}

func (s *Server) toolDisconnect(ctx context.Context, _ map[string]any) (any, error) {
	if err := s.mgr.Disconnect(ctx); err != nil {
		return nil, fmt.Errorf("disconnect: %w", err)
	}
	return s.mgr.Status(), nil
}

func (s *Server) toolURLTest(ctx context.Context, args map[string]any) (any, error) {
	if s.urlTest == nil {
		return nil, errors.New("url_test not wired")
	}
	id, _ := args["server_id"].(string)
	if id == "" {
		return nil, errors.New("server_id is required")
	}
	if err := s.urlTest(ctx, id); err != nil {
		return nil, fmt.Errorf("url_test: %w", err)
	}
	// Return the updated server record so the agent can see the
	// verdict without a second list call.
	for _, sv := range s.store.Snapshot().Servers {
		if sv.ID == id {
			return sv, nil
		}
	}
	return nil, errors.New("server not found after url_test")
}

func (s *Server) toolAddSubscription(ctx context.Context, args map[string]any) (any, error) {
	url, _ := args["url"].(string)
	url = strings.TrimSpace(url)
	if url == "" {
		return nil, errors.New("url is required")
	}
	name, _ := args["name"].(string)
	format, _ := args["format"].(string)
	if name == "" {
		name = url
	}
	sub, err := s.store.AddOrUpdateSubscription(proto.Subscription{
		URL:                    url,
		Name:                   name,
		Format:                 proto.Format(format),
		AutoRefresh:            true,
		RefreshIntervalSeconds: 3600,
	})
	if err != nil {
		return nil, fmt.Errorf("store subscription: %w", err)
	}
	if s.refresh != nil {
		if err := s.refresh(ctx, sub); err != nil {
			_ = s.store.MarkSubscriptionError(sub.ID, err.Error())
			return nil, fmt.Errorf("refresh: %w", err)
		}
	}
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == sub.ID {
			return su, nil
		}
	}
	return sub, nil
}

func (s *Server) toolRemoveSubscription(_ context.Context, args map[string]any) (any, error) {
	id, _ := args["subscription_id"].(string)
	if id == "" {
		return nil, errors.New("subscription_id is required")
	}
	if err := s.store.DeleteSubscription(id); err != nil {
		return nil, fmt.Errorf("delete: %w", err)
	}
	return map[string]any{"deleted": id}, nil
}

func (s *Server) toolRefreshSubscription(ctx context.Context, args map[string]any) (any, error) {
	if s.refresh == nil {
		return nil, errors.New("refresh not wired")
	}
	id, _ := args["subscription_id"].(string)
	if id == "" {
		return nil, errors.New("subscription_id is required")
	}
	var target *proto.Subscription
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == id {
			cp := su
			target = &cp
			break
		}
	}
	if target == nil {
		return nil, errors.New("subscription not found")
	}
	if err := s.refresh(ctx, *target); err != nil {
		_ = s.store.MarkSubscriptionError(id, err.Error())
		return nil, fmt.Errorf("refresh: %w", err)
	}
	for _, su := range s.store.Snapshot().Subscriptions {
		if su.ID == id {
			return su, nil
		}
	}
	return target, nil
}

func (s *Server) toolGetPrefs(_ context.Context, _ map[string]any) (any, error) {
	return s.store.Snapshot().Prefs, nil
}
