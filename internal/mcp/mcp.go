package mcp

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// Server implements an MCP (Model Context Protocol) JSON-RPC 2.0 endpoint
// and REST API bridge for script automation.
type Server struct {
	store       *store.Store
	state       *state.Manager
	token       string
	restMux     *http.ServeMux
	reloadMu    sync.Mutex
	lastReload  time.Time
}

// NewServer creates an MCP server instance.
func NewServer(st *store.Store, sm *state.Manager) *Server {
	s := &Server{
		store:   st,
		state:   sm,
		restMux: http.NewServeMux(),
	}
	s.registerREST()
	return s
}

// SetToken configures the daemon authorization token for privileged REST calls.
func (s *Server) SetToken(token string) {
	s.token = token
}

// ServeHTTP handles both REST API requests (/mcp/v1/*) and JSON-RPC 2.0 MCP requests (/mcp).
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-MCP-Token")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	path := r.URL.Path
	if strings.HasPrefix(path, "/mcp/v1/") || path == "/mcp/v1" {
		s.restMux.ServeHTTP(w, r)
		return
	}

	if r.Method != http.MethodPost && r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodGet {
		// Basic info page / health check
		json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"name":    "MosaicVPN MCP Server & REST Bridge",
			"version": "1.1.0",
			"rest_api": "/mcp/v1",
		})
		return
	}

	var req struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      any             `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0",
			"error": map[string]any{
				"code":    -32700,
				"message": "Parse error",
			},
			"id": nil,
		})
		return
	}

	res := s.handleMethod(req.Method, req.Params)
	response := map[string]any{
		"jsonrpc": "2.0",
		"id":      req.ID,
	}

	if err, isErr := res["error"]; isErr {
		response["error"] = err
	} else {
		response["result"] = res
	}

	json.NewEncoder(w).Encode(response)
}

func (s *Server) registerREST() {
	m := s.restMux
	m.HandleFunc("GET /mcp/v1/status", s.authWrap(s.restStatus))
	m.HandleFunc("GET /mcp/v1/servers", s.authWrap(s.restServers))
	m.HandleFunc("GET /mcp/v1/groups", s.authWrap(s.restGroups))
	m.HandleFunc("POST /mcp/v1/connect", s.authWrap(s.restConnect))
	m.HandleFunc("POST /mcp/v1/disconnect", s.authWrap(s.restDisconnect))
	m.HandleFunc("GET /mcp/v1/egresses", s.authWrap(s.restListEgresses))
	m.HandleFunc("POST /mcp/v1/egresses", s.authWrap(s.restAddEgress))
	m.HandleFunc("DELETE /mcp/v1/egresses/{id}", s.authWrap(s.restDeleteEgress))
	m.HandleFunc("POST /mcp/v1/egresses/{id}/toggle", s.authWrap(s.restToggleEgress))
}

func (s *Server) authWrap(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		snap := s.store.Snapshot()
		if !snap.Prefs.MCPEnabled {
			writeRestError(w, http.StatusForbidden, "MCP_DISABLED", "MCP server is disabled in client preferences.")
			return
		}

		// 1. Loopback read-only access is allowed without token
		isGet := r.Method == http.MethodGet
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if host == "" {
			host = r.RemoteAddr
		}
		isLoopback := host == "127.0.0.1" || host == "::1" || host == "localhost"

		// 2. Validate token if provided or for write operations
		token := extractToken(r)
		authenticated := false
		if token != "" && s.token != "" && subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) == 1 {
			authenticated = true
		}

		if !authenticated && !(isLoopback && isGet) {
			writeRestError(w, http.StatusUnauthorized, "AUTH_REQUIRED", "Authentication required for MCP REST endpoint. Provide Authorization: Bearer <token> or X-MCP-Token.")
			return
		}

		h(w, r)
	}
}

func extractToken(r *http.Request) string {
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		return strings.TrimPrefix(auth, "Bearer ")
	}
	if tok := r.Header.Get("X-MCP-Token"); tok != "" {
		return tok
	}
	return r.URL.Query().Get("token")
}

func writeRestError(w http.ResponseWriter, status int, code, msg string) {
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]any{
		"ok":    false,
		"code":  code,
		"error": msg,
	})
}

func writeRestOK(w http.ResponseWriter, data any) {
	json.NewEncoder(w).Encode(map[string]any{
		"ok":   true,
		"data": data,
	})
}

func (s *Server) safeHotReload(ctx context.Context) error {
	s.reloadMu.Lock()
	defer s.reloadMu.Unlock()
	// Debounce check: don't thrash backend if reloads come within 150ms
	if time.Since(s.lastReload) < 150*time.Millisecond {
		time.Sleep(150 * time.Millisecond)
	}
	s.lastReload = time.Now()
	return s.state.HotReload(ctx)
}

// REST Handlers
func (s *Server) restStatus(w http.ResponseWriter, _ *http.Request) {
	st := s.state.Status()
	writeRestOK(w, st)
}

func (s *Server) restServers(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	writeRestOK(w, snap.Servers)
}

func (s *Server) restGroups(w http.ResponseWriter, _ *http.Request) {
	snap := s.store.Snapshot()
	writeRestOK(w, snap.Groups)
}

func (s *Server) restConnect(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ServerID    string `json:"server_id"`
		GroupID     string `json:"group_id"`
		CountryCode string `json:"country_code"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)

	targetID := body.ServerID
	snap := s.store.Snapshot()

	if targetID == "" && body.GroupID != "" {
		// Try resolving through state.Resolve for group priority chain
		res, err := state.Resolve(s.store, body.GroupID, "")
		if err == nil && res.ServerID != "" {
			targetID = res.ServerID
		} else {
			// Fallback: search group nodes
			for _, g := range snap.Groups {
				if g.ID == body.GroupID && len(g.Nodes) > 0 {
					targetID = g.Nodes[0].ServerID
					break
				}
			}
		}
	}

	if targetID == "" && body.CountryCode != "" {
		code := strings.ToUpper(body.CountryCode)
		for _, srv := range snap.Servers {
			if strings.ToUpper(srv.Country) == code {
				targetID = srv.ID
				break
			}
		}
	}

	if targetID == "" && len(snap.Servers) > 0 {
		targetID = snap.Servers[0].ID
	}

	if targetID == "" {
		writeRestError(w, http.StatusBadRequest, "NO_SERVER_FOUND", "No matching server or group candidate available.")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	if err := s.state.Connect(ctx, targetID); err != nil {
		writeRestError(w, http.StatusInternalServerError, "CONNECT_FAILED", err.Error())
		return
	}

	writeRestOK(w, map[string]any{
		"connected": true,
		"server_id": targetID,
		"status":    s.state.Status(),
	})
}

func (s *Server) restDisconnect(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	if err := s.state.Disconnect(ctx); err != nil {
		writeRestError(w, http.StatusInternalServerError, "DISCONNECT_FAILED", err.Error())
		return
	}
	writeRestOK(w, map[string]any{"disconnected": true})
}

func (s *Server) restListEgresses(w http.ResponseWriter, _ *http.Request) {
	eg := s.store.ListEgresses()
	if eg == nil {
		eg = []proto.Egress{}
	}
	writeRestOK(w, eg)
}

func (s *Server) restAddEgress(w http.ResponseWriter, r *http.Request) {
	var e proto.Egress
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		writeRestError(w, http.StatusBadRequest, "INVALID_BODY", "Invalid JSON payload")
		return
	}
	if e.Name == "" {
		writeRestError(w, http.StatusBadRequest, "NAME_REQUIRED", "Egress name is required")
		return
	}
	if e.Protocol == "" {
		e.Protocol = "mixed"
	}
	if e.Listen == "" {
		e.Listen = "127.0.0.1:0"
	}
	e.Active = true

	saved, err := s.store.AddEgress(e)
	if err != nil {
		writeRestError(w, http.StatusInternalServerError, "ADD_FAILED", err.Error())
		return
	}

	_ = s.safeHotReload(r.Context())
	writeRestOK(w, map[string]any{
		"egress":          saved,
		"reload_triggered": true,
	})
}

func (s *Server) restDeleteEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if err := s.store.DeleteEgress(id); err != nil {
		writeRestError(w, http.StatusNotFound, "NOT_FOUND", err.Error())
		return
	}
	_ = s.safeHotReload(r.Context())
	writeRestOK(w, map[string]any{"deleted": id, "reload_triggered": true})
}

func (s *Server) restToggleEgress(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req struct {
		Active *bool `json:"active"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)

	eg := s.store.ListEgresses()
	var current *proto.Egress
	for _, item := range eg {
		if item.ID == id {
			cpy := item
			current = &cpy
			break
		}
	}
	if current == nil {
		writeRestError(w, http.StatusNotFound, "NOT_FOUND", "Egress not found")
		return
	}

	newActive := !current.Active
	if req.Active != nil {
		newActive = *req.Active
	}

	if err := s.store.ToggleEgress(id, newActive); err != nil {
		writeRestError(w, http.StatusInternalServerError, "TOGGLE_FAILED", err.Error())
		return
	}
	_ = s.safeHotReload(r.Context())
	current.Active = newActive
	writeRestOK(w, map[string]any{"egress": current, "reload_triggered": true})
}

// JSON-RPC 2.0 Handlers
func (s *Server) handleMethod(method string, params json.RawMessage) map[string]any {
	switch method {
	case "initialize":
		return map[string]any{
			"protocolVersion": "2024-11-05",
			"capabilities": map[string]any{
				"tools": map[string]any{},
			},
			"serverInfo": map[string]any{
				"name":    "mosaic-mcp",
				"version": "1.1.0",
			},
		}

	case "notifications/initialized":
		return map[string]any{"status": "ok"}

	case "tools/list":
		return map[string]any{
			"tools": []any{
				map[string]any{
					"name":        "mosaic_status",
					"description": "Get current Mosaic VPN connection status, traffic stats, and active server",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_list_servers",
					"description": "List all imported VPN servers with location, country code, and latency",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_list_groups",
					"description": "List all Smart Groups and route clusters (e.g. min-latency, max-speed, germany, etc.)",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_connect",
					"description": "Connect to a specific server by ID, Smart Group ID, or 2-letter country code (e.g., DE, NL, US)",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"server_id":    map[string]any{"type": "string", "description": "Specific server ID"},
							"group_id":     map[string]any{"type": "string", "description": "Smart Group ID (e.g., min-latency, stable, germany)"},
							"country_code": map[string]any{"type": "string", "description": "2-letter ISO country code (e.g. DE, US, NL)"},
						},
					},
				},
				map[string]any{
					"name":        "mosaic_disconnect",
					"description": "Disconnect the active VPN tunnel",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_list_egresses",
					"description": "List all local proxy egresses (SOCKS5/HTTP listeners) configured in the client",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_add_egress",
					"description": "Add a new local egress proxy listener (e.g. 127.0.0.1:1082) with hot reload",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"name":     map[string]any{"type": "string", "description": "Human-friendly label"},
							"protocol": map[string]any{"type": "string", "enum": []string{"mixed", "socks", "http"}, "description": "Proxy protocol"},
							"listen":   map[string]any{"type": "string", "description": "Bind address:port (e.g. 127.0.0.1:1082)"},
						},
						"required": []string{"name"},
					},
				},
				map[string]any{
					"name":        "mosaic_delete_egress",
					"description": "Remove an egress proxy listener by ID and trigger hot reload",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"id": map[string]any{"type": "string", "description": "Egress UUID"},
						},
						"required": []string{"id"},
					},
				},
				map[string]any{
					"name":        "mosaic_toggle_egress",
					"description": "Toggle an egress proxy listener active/inactive with hot reload",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"id": map[string]any{"type": "string", "description": "Egress UUID"},
						},
						"required": []string{"id"},
					},
				},
				map[string]any{
					"name":        "mosaic_list_subscriptions",
					"description": "List configured subscription feeds",
					"inputSchema": map[string]any{
						"type":       "object",
						"properties": map[string]any{},
					},
				},
				map[string]any{
					"name":        "mosaic_add_subscription",
					"description": "Add a new subscription feed URL to import servers",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"name": map[string]any{"type": "string"},
							"url":  map[string]any{"type": "string"},
						},
						"required": []string{"name", "url"},
					},
				},
				map[string]any{
					"name":        "mosaic_set_tunnel_mode",
					"description": "Switch between 'tun' (full-system VPN) and 'proxy' (SOCKS5/HTTP only) mode",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"mode": map[string]any{"type": "string", "enum": []string{"tun", "proxy"}},
						},
						"required": []string{"mode"},
					},
				},
				map[string]any{
					"name":        "mosaic_test_url",
					"description": "Measure a URL through the active VPN proxy",
					"inputSchema": map[string]any{"type": "object", "properties": map[string]any{"url": map[string]any{"type": "string"}}, "required": []string{"url"}},
				},
				map[string]any{
					"name":        "mosaic_test_speed",
					"description": "Run the bounded speed test through the active VPN proxy",
					"inputSchema": map[string]any{"type": "object", "properties": map[string]any{}},
				},
			},
		}

	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return map[string]any{
				"error": map[string]any{"code": -32602, "message": "Invalid params"},
			}
		}

		resText, err := s.callTool(p.Name, p.Arguments)
		if err != nil {
			return map[string]any{
				"content": []any{
					map[string]any{"type": "text", "text": fmt.Sprintf("Error: %v", err)},
				},
				"isError": true,
			}
		}

		return map[string]any{
			"content": []any{
				map[string]any{"type": "text", "text": resText},
			},
		}

	default:
		return map[string]any{
			"error": map[string]any{"code": -32601, "message": "Method not found"},
		}
	}
}

func (s *Server) callTool(name string, args json.RawMessage) (string, error) {
	st := s.store.Snapshot()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	switch name {
	case "mosaic_status":
		status := s.state.Status()
		b, _ := json.MarshalIndent(status, "", "  ")
		return string(b), nil

	case "mosaic_list_servers":
		b, _ := json.MarshalIndent(st.Servers, "", "  ")
		return string(b), nil

	case "mosaic_list_groups":
		b, _ := json.MarshalIndent(st.Groups, "", "  ")
		return string(b), nil

	case "mosaic_connect":
		var arg struct {
			ServerID    string `json:"server_id"`
			GroupID     string `json:"group_id"`
			CountryCode string `json:"country_code"`
		}
		json.Unmarshal(args, &arg)

		targetID := arg.ServerID
		if targetID == "" && arg.GroupID != "" {
			res, err := state.Resolve(s.store, arg.GroupID, "")
			if err == nil && res.ServerID != "" {
				targetID = res.ServerID
			} else {
				for _, g := range st.Groups {
					if g.ID == arg.GroupID && len(g.Nodes) > 0 {
						targetID = g.Nodes[0].ServerID
						break
					}
				}
			}
		}

		if targetID == "" && arg.CountryCode != "" {
			code := strings.ToUpper(arg.CountryCode)
			for _, srv := range st.Servers {
				if strings.ToUpper(srv.Country) == code {
					targetID = srv.ID
					break
				}
			}
		}

		if targetID == "" && len(st.Servers) > 0 {
			targetID = st.Servers[0].ID
		}

		if targetID == "" {
			return "", fmt.Errorf("no matching server or group candidate found")
		}

		if err := s.state.Connect(ctx, targetID); err != nil {
			return "", err
		}
		return fmt.Sprintf("Successfully connected to server %s", targetID), nil

	case "mosaic_disconnect":
		if err := s.state.Disconnect(ctx); err != nil {
			return "", err
		}
		return "Disconnected successfully", nil

	case "mosaic_list_egresses":
		eg := s.store.ListEgresses()
		if eg == nil {
			eg = []proto.Egress{}
		}
		b, _ := json.MarshalIndent(eg, "", "  ")
		return string(b), nil

	case "mosaic_add_egress":
		var arg struct {
			Name     string `json:"name"`
			Protocol string `json:"protocol"`
			Listen   string `json:"listen"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || arg.Name == "" {
			return "", fmt.Errorf("name is required")
		}
		if arg.Protocol == "" {
			arg.Protocol = "mixed"
		}
		if arg.Listen == "" {
			arg.Listen = "127.0.0.1:0"
		}
		eg, err := s.store.AddEgress(proto.Egress{
			Name:     arg.Name,
			Protocol: arg.Protocol,
			Listen:   arg.Listen,
			Active:   true,
		})
		if err != nil {
			return "", err
		}
		_ = s.safeHotReload(ctx)
		b, _ := json.MarshalIndent(eg, "", "  ")
		return string(b), nil

	case "mosaic_delete_egress":
		var arg struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || arg.ID == "" {
			return "", fmt.Errorf("id is required")
		}
		if err := s.store.DeleteEgress(arg.ID); err != nil {
			return "", err
		}
		_ = s.safeHotReload(ctx)
		return fmt.Sprintf("Egress %s deleted successfully", arg.ID), nil

	case "mosaic_toggle_egress":
		var arg struct {
			ID     string `json:"id"`
			Active *bool  `json:"active"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || arg.ID == "" {
			return "", fmt.Errorf("id is required")
		}
		eg := s.store.ListEgresses()
		var current *proto.Egress
		for _, item := range eg {
			if item.ID == arg.ID {
				cpy := item
				current = &cpy
				break
			}
		}
		if current == nil {
			return "", fmt.Errorf("egress %s not found", arg.ID)
		}
		newActive := !current.Active
		if arg.Active != nil {
			newActive = *arg.Active
		}
		if err := s.store.ToggleEgress(arg.ID, newActive); err != nil {
			return "", err
		}
		_ = s.safeHotReload(ctx)
		return fmt.Sprintf("Egress %s active set to %v", arg.ID, newActive), nil

	case "mosaic_list_subscriptions":
		b, _ := json.MarshalIndent(st.Subscriptions, "", "  ")
		return string(b), nil

	case "mosaic_add_subscription":
		var arg struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || arg.Name == "" || arg.URL == "" {
			return "", fmt.Errorf("invalid name or url")
		}

		sub, err := s.store.AddOrUpdateSubscription(proto.Subscription{
			Name: arg.Name,
			URL:  arg.URL,
		})
		if err != nil {
			return "", err
		}
		b, _ := json.MarshalIndent(sub, "", "  ")
		return string(b), nil

	case "mosaic_set_tunnel_mode":
		var arg struct {
			Mode string `json:"mode"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || (arg.Mode != "tun" && arg.Mode != "proxy") {
			return "", fmt.Errorf("mode must be 'tun' or 'proxy'")
		}

		prefs := st.Prefs
		prefs.TunnelMode = arg.Mode
		if err := s.store.SetPrefs(prefs); err != nil {
			return "", err
		}
		return fmt.Sprintf("Tunnel mode updated to %s", arg.Mode), nil

	case "mosaic_test_url":
		var arg struct {
			URL string `json:"url"`
		}
		if err := json.Unmarshal(args, &arg); err != nil || arg.URL == "" {
			return "", fmt.Errorf("url is required")
		}
		result, err := s.state.TestURL(ctx, arg.URL)
		if err != nil {
			return "", err
		}
		b, _ := json.MarshalIndent(result, "", "  ")
		return string(b), nil

	case "mosaic_test_speed":
		result, err := s.state.SpeedTest(ctx)
		if err != nil {
			return "", err
		}
		b, _ := json.MarshalIndent(result, "", "  ")
		return string(b), nil

	default:
		return "", fmt.Errorf("unknown tool: %s", name)
	}
}
