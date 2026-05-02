package state

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

func sampleVlessServer() proto.Server {
	return proto.Server{
		ID:       "srv-1",
		Name:     "DE-VLESS-WS",
		Protocol: proto.ProtoVLESS,
		Address:  "vps1.example.com",
		Port:     443,
		Raw: map[string]any{
			"uuid":     "00000000-0000-0000-0000-000000000000",
			"network":  "ws",
			"path":     "/ws",
			"security": "tls",
			"sni":      "vps1.example.com",
		},
	}
}

func TestBuildSingBoxConfig_ProxyModeOmitsTunInbound(t *testing.T) {
	prefs := store.DefaultPrefs()
	prefs.TunnelMode = "proxy"
	raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 9090)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	inbounds, _ := cfg["inbounds"].([]any)
	if len(inbounds) != 2 {
		t.Fatalf("proxy mode: want 2 inbounds (socks+http), got %d: %s", len(inbounds), raw)
	}
	for _, ib := range inbounds {
		m := ib.(map[string]any)
		if m["type"] == "tun" {
			t.Fatalf("proxy mode produced a tun inbound: %s", raw)
		}
	}
}

func TestBuildSingBoxConfig_TunModeAddsTunInbound(t *testing.T) {
	prefs := store.DefaultPrefs()
	prefs.TunnelMode = "tun"
	prefs.TunStack = "gvisor"
	raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 9090)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	inbounds, _ := cfg["inbounds"].([]any)
	if len(inbounds) != 3 {
		t.Fatalf("tun mode: want 3 inbounds (socks+http+tun), got %d: %s", len(inbounds), raw)
	}
	var tun map[string]any
	for _, ib := range inbounds {
		m := ib.(map[string]any)
		if m["type"] == "tun" {
			tun = m
			break
		}
	}
	if tun == nil {
		t.Fatalf("tun inbound not found in: %s", raw)
	}
	if tun["stack"] != "gvisor" {
		t.Errorf("stack = %v, want gvisor", tun["stack"])
	}
	if tun["auto_route"] != true {
		t.Errorf("auto_route = %v, want true", tun["auto_route"])
	}
	if tun["strict_route"] != true {
		t.Errorf("strict_route = %v, want true", tun["strict_route"])
	}
	if iface, _ := tun["interface_name"].(string); iface == "" {
		t.Errorf("interface_name empty")
	}
}

func TestBuildSingBoxConfig_TunStackFallback(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want string
	}{
		{"", "gvisor"},
		{"gvisor", "gvisor"},
		{"system", "system"},
		{"mixed", "mixed"},
		{"bogus", "gvisor"},
	} {
		prefs := store.DefaultPrefs()
		prefs.TunnelMode = "tun"
		prefs.TunStack = tc.in
		raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 0)
		if err != nil {
			t.Fatalf("BuildSingBoxConfig(%q): %v", tc.in, err)
		}
		if !strings.Contains(string(raw), `"stack": "`+tc.want+`"`) {
			t.Errorf("stack fallback: in=%q want=%q, config=%s", tc.in, tc.want, raw)
		}
	}
}

func TestBuildSingBoxConfig_ClashAPIDisabledWhenZero(t *testing.T) {
	prefs := store.DefaultPrefs()
	raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 0)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if _, ok := cfg["experimental"]; ok {
		t.Errorf("expected no experimental block when clashPort=0, got: %s", raw)
	}
}
