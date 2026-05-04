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

// rc51 — sing-box 1.13 removed the `block` and `dns` special
// outbounds.  Make sure we never emit them in the migrated config,
// otherwise the binary FATALs at startup with "unknown outbound
// type".  The migration replaces them with rule actions, so the only
// outbounds left are the user's chosen proxy + the built-in `direct`.
func TestBuildSingBoxConfig_NoLegacySpecialOutbounds(t *testing.T) {
	prefs := store.DefaultPrefs()
	raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 0)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	outs, _ := cfg["outbounds"].([]any)
	if len(outs) != 2 {
		t.Fatalf("want 2 outbounds (proxy+direct), got %d: %s", len(outs), raw)
	}
	for _, o := range outs {
		m := o.(map[string]any)
		switch m["type"] {
		case "block", "dns":
			t.Errorf("forbidden outbound type %q in 1.13 schema: %#v", m["type"], m)
		}
	}
}

// rc51 — DNS schema must use the typed-server form (`type: "https"`,
// `type: "udp"`).  The legacy `address: "https://..."` form was
// removed in sing-box 1.14 and FATALs in 1.13 without an env var.
func TestBuildSingBoxConfig_DNSUsesTypedServers(t *testing.T) {
	prefs := store.DefaultPrefs()
	raw, err := BuildSingBoxConfig(sampleVlessServer(), prefs, nil, 2080, 2081, 0)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	dns, _ := cfg["dns"].(map[string]any)
	servers, _ := dns["servers"].([]any)
	if len(servers) == 0 {
		t.Fatalf("dns.servers is empty: %s", raw)
	}
	for _, s := range servers {
		m := s.(map[string]any)
		typ, _ := m["type"].(string)
		if typ == "" {
			t.Errorf("dns server missing type field (legacy schema): %#v", m)
		}
		if _, hasAddress := m["address"]; hasAddress {
			t.Errorf("dns server still using legacy `address` field: %#v", m)
		}
		if _, hasResolver := m["address_resolver"]; hasResolver {
			t.Errorf("dns server still using legacy `address_resolver` field: %#v", m)
		}
	}
	if rules, ok := dns["rules"].([]any); ok {
		for _, r := range rules {
			m := r.(map[string]any)
			if m["outbound"] == "any" {
				t.Errorf("dns.rules still uses legacy outbound=any item: %#v", m)
			}
		}
	}
	route, _ := cfg["route"].(map[string]any)
	if _, ok := route["default_domain_resolver"]; !ok {
		t.Errorf("route.default_domain_resolver missing — required in 1.13: %s", raw)
	}
}

// rc51 — wireguard / amneziawg moved to the dedicated `endpoints`
// array.  The legacy `wireguard` outbound was removed in sing-box
// 1.13.  Verify the migration by building a config for an AmneziaWG
// server and confirming the wireguard block lives in `endpoints`,
// not `outbounds`.
func TestBuildSingBoxConfig_AmneziaWGEmitsEndpoint(t *testing.T) {
	wg := proto.Server{
		ID:       "wg-1",
		Name:     "DE-AWG",
		Protocol: proto.ProtoAmneziaWG,
		Address:  "wg.example.com",
		Port:     51820,
		Raw: map[string]any{
			"private_key":     "PRIV+KEY+BASE64==",
			"peer_public_key": "PUB+KEY+BASE64==",
			"local_address":   []any{"10.0.0.2/32"},
		},
	}
	prefs := store.DefaultPrefs()
	raw, err := BuildSingBoxConfig(wg, prefs, nil, 2080, 2081, 0)
	if err != nil {
		t.Fatalf("BuildSingBoxConfig: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	endpoints, _ := cfg["endpoints"].([]any)
	if len(endpoints) != 1 {
		t.Fatalf("want 1 endpoint for AmneziaWG, got %d: %s", len(endpoints), raw)
	}
	ep := endpoints[0].(map[string]any)
	if ep["type"] != "wireguard" || ep["tag"] != "proxy" {
		t.Errorf("endpoint shape wrong: %#v", ep)
	}
	peers, _ := ep["peers"].([]any)
	if len(peers) != 1 {
		t.Fatalf("want 1 peer, got %d: %#v", len(peers), ep)
	}
	peer := peers[0].(map[string]any)
	if peer["address"] != "wg.example.com" {
		t.Errorf("peer.address = %v, want wg.example.com", peer["address"])
	}
	if _, ok := peer["allowed_ips"]; !ok {
		t.Errorf("peer.allowed_ips missing — required in 1.13 endpoint schema: %#v", peer)
	}
	// Outbounds must NOT contain a wireguard block any more.
	outs, _ := cfg["outbounds"].([]any)
	for _, o := range outs {
		m := o.(map[string]any)
		if m["type"] == "wireguard" {
			t.Errorf("wireguard still in outbounds (1.13 schema violation): %#v", m)
		}
	}
}
