package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/state"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

// Server implements an MCP (Model Context Protocol) JSON-RPC 2.0 endpoint.
type Server struct {
	store *store.Store
	state *state.Manager
}

// NewServer creates an MCP server instance.
func NewServer(st *store.Store, sm *state.Manager) *Server {
	return &Server{store: st, state: sm}
}

// ServeHTTP handles JSON-RPC 2.0 MCP requests over HTTP POST.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodGet {
		// Basic info page / health check
		json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"name":    "MosaicVPN MCP Server",
			"version": "1.0.0",
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
				"version": "1.0.0",
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
					"name":        "mosaic_connect",
					"description": "Connect to a specific server by ID or country code (e.g., DE, NL, US)",
					"inputSchema": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"server_id":    map[string]any{"type": "string", "description": "Server ID"},
							"country_code": map[string]any{"type": "string", "description": "2-letter ISO country code (e.g. DE)"},
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

	case "mosaic_connect":
		var arg struct {
			ServerID    string `json:"server_id"`
			CountryCode string `json:"country_code"`
		}
		json.Unmarshal(args, &arg)

		targetID := arg.ServerID
		if targetID == "" && arg.CountryCode != "" {
			for _, srv := range st.Servers {
				if srv.Country == arg.CountryCode {
					targetID = srv.ID
					break
				}
			}
		}

		if targetID == "" && len(st.Servers) > 0 {
			targetID = st.Servers[0].ID
		}

		if targetID == "" {
			return "", fmt.Errorf("no matching server found")
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
