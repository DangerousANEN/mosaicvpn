package state

import (
	"encoding/json"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

func TestSingBoxDNSServerParsesUDPURL(t *testing.T) {
	entry := singBoxDNSServer("dns-primary", "udp://77.88.8.8", "")
	if entry["type"] != "udp" || entry["server"] != "77.88.8.8" || entry["server_port"] != 53 {
		t.Fatalf("UDP entry = %#v; want udp 77.88.8.8:53", entry)
	}
	if _, ok := entry["detour"]; ok {
		t.Fatalf("direct resolver unexpectedly has detour: %#v", entry)
	}
}

func TestSingBoxDNSServerParsesDoHURL(t *testing.T) {
	entry := singBoxDNSServer("dns-proxied", "https://1.1.1.1/dns-query", "proxy")
	if entry["type"] != "https" || entry["server"] != "1.1.1.1" || entry["server_port"] != 443 {
		t.Fatalf("DoH entry = %#v; want https 1.1.1.1:443", entry)
	}
	if entry["path"] != "/dns-query" || entry["detour"] != "proxy" {
		t.Fatalf("DoH path/detour = %#v; want /dns-query via proxy", entry)
	}
}

func TestAdBlockBuildSingBoxConfig(t *testing.T) {
	server := proto.Server{
		ID:       "srv1",
		Protocol: proto.ProtoVLESS,
		Address:  "example.com",
		Port:     443,
	}
	prefs := store.DefaultPrefs()
	prefs.AdBlock = true

	rawCfg, err := BuildSingBoxConfigWithServers(
		server, 1080, 1081, prefs, nil, proto.DNSConfig{Mode: "fake-ip"}, 0, "", []proto.Server{server}, nil,
	)
	if err != nil {
		t.Fatalf("BuildSingBoxConfigWithServers failed: %v", err)
	}

	var parsed map[string]any
	if err := json.Unmarshal(rawCfg, &parsed); err != nil {
		t.Fatalf("json.Unmarshal failed: %v", err)
	}

	dnsSection, ok := parsed["dns"].(map[string]any)
	if !ok {
		t.Fatalf("dns section missing in config: %s", string(rawCfg))
	}
	servers, ok := dnsSection["servers"].([]any)
	if !ok {
		t.Fatalf("dns.servers missing: %s", string(rawCfg))
	}

	hasBlockServer := false
	for _, s := range servers {
		if smap, ok := s.(map[string]any); ok && smap["tag"] == "dns-block" {
			hasBlockServer = true
			if smap["address"] != "rcode://success" {
				t.Fatalf("dns-block address = %v, want rcode://success", smap["address"])
			}
		}
	}
	if !hasBlockServer {
		t.Fatalf("dns.servers does not contain dns-block: %#v", servers)
	}
}

func TestPreferredListenerPort(t *testing.T) {
	cases := []struct {
		address  string
		fallback int
		want     int
	}{
		{"127.0.0.1:1080", 2080, 1080},
		{"[::1]:1081", 2081, 1081},
		{"invalid", 2080, 2080},
		{"127.0.0.1:70000", 2080, 2080},
	}
	for _, tc := range cases {
		if got := preferredListenerPort(tc.address, tc.fallback); got != tc.want {
			t.Errorf("preferredListenerPort(%q, %d) = %d; want %d", tc.address, tc.fallback, got, tc.want)
		}
	}
}
