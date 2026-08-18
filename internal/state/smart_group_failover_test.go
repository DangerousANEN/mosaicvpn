package state

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/store"
)

func TestStableVirtualGroupUsesOnlyHintedCandidates(t *testing.T) {
	group := proto.Server{
		ID:             "group-auto-stable",
		Name:           "Stable",
		Protocol:       proto.ProtoVLESS,
		SubscriptionID: "mosaic",
		IsVirtualGroup: true,
		Category:       "smart",
		GroupTag:       "auto-stable",
		Raw: map[string]any{
			"mosaic_ping_interval": 15,
		},
	}
	stable := proto.Server{
		ID:             "stable-node",
		Name:           "Stable node",
		Protocol:       proto.ProtoVLESS,
		Address:        "198.51.100.10",
		Port:           443,
		SubscriptionID: "mosaic",
		Raw: map[string]any{
			"uuid":          "00000000-0000-0000-0000-000000000001",
			"mosaic_stable": true,
		},
	}
	unstable := proto.Server{
		ID:             "unstable-node",
		Name:           "Unstable node",
		Protocol:       proto.ProtoVLESS,
		Address:        "198.51.100.11",
		Port:           443,
		SubscriptionID: "mosaic",
		Raw: map[string]any{
			"uuid":          "00000000-0000-0000-0000-000000000002",
			"mosaic_stable": false,
		},
	}

	config, err := BuildSingBoxConfigWithServers(
		group,
		1080,
		1081,
		store.Prefs{},
		nil,
		proto.DNSConfig{},
		0,
		"",
		[]proto.Server{group, stable, unstable},
		nil,
	)
	if err != nil {
		t.Fatalf("BuildSingBoxConfigWithServers: %v", err)
	}

	var decoded struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(config, &decoded); err != nil {
		t.Fatalf("decode config: %v", err)
	}

	var groupOutbound map[string]any
	var nodeTags []string
	for _, outbound := range decoded.Outbounds {
		tag, _ := outbound["tag"].(string)
		if tag == "proxy" {
			groupOutbound = outbound
		}
		if strings.HasPrefix(tag, "node-") {
			nodeTags = append(nodeTags, tag)
		}
	}
	if groupOutbound == nil || groupOutbound["type"] != "urltest" || groupOutbound["interval"] != "15s" {
		t.Fatalf("unexpected smart group outbound: %#v", groupOutbound)
	}
	if len(nodeTags) != 1 || !strings.Contains(nodeTags[0], "stable-node") {
		t.Fatalf("node tags = %#v; expected only stable-node", nodeTags)
	}
}

func TestVirtualGroupWithoutScopedCandidatesFailsClosed(t *testing.T) {
	group := proto.Server{
		ID:             "group-empty",
		Name:           "Empty group",
		Protocol:       proto.ProtoVLESS,
		SubscriptionID: "provider-account-a",
		IsVirtualGroup: true,
		Category:       "smart",
		GroupTag:       "auto-stable",
	}
	otherSubscriptionNode := proto.Server{
		ID:             "other-node",
		Name:           "Other provider node",
		Protocol:       proto.ProtoVLESS,
		Address:        "198.51.100.30",
		Port:           443,
		SubscriptionID: "provider-account-b",
		Raw: map[string]any{
			"uuid": "00000000-0000-0000-0000-000000000003",
		},
	}
	_, err := BuildSingBoxConfigWithServers(
		group,
		1080,
		1081,
		store.Prefs{},
		nil,
		proto.DNSConfig{},
		0,
		"",
		[]proto.Server{group, otherSubscriptionNode},
		nil,
	)
	if err == nil || !strings.Contains(err.Error(), "no usable provider candidates") {
		t.Fatalf("expected closed failure for empty scoped Smart Group, got %v", err)
	}
}

func TestGeneratedTunConfigPassesBundledSingBoxCheck(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("bundled Linux sing-box check")
	}
	binary := filepath.Join("..", "..", "dist", "linux", "MosaicVPN", "sing-box")
	if _, err := os.Stat(binary); err != nil {
		t.Skip("bundled sing-box is not available")
	}
	server := proto.Server{
		ID:       "node",
		Name:     "Node",
		Protocol: proto.ProtoVLESS,
		Address:  "198.51.100.40",
		Port:     443,
		Raw: map[string]any{
			"uuid": "00000000-0000-0000-0000-000000000004",
		},
	}
	config, err := BuildSingBoxConfigWithServers(
		server,
		1080,
		1081,
		store.Prefs{TunnelMode: "tun"},
		nil,
		proto.DNSConfig{},
		0,
		"",
		[]proto.Server{server},
		nil,
	)
	if err != nil {
		t.Fatalf("BuildSingBoxConfigWithServers: %v", err)
	}
	configPath := filepath.Join(t.TempDir(), "singbox.json")
	if err := os.WriteFile(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(binary, "check", "-c", configPath).CombinedOutput()
	if err != nil {
		t.Fatalf("bundled sing-box rejected generated config: %v\n%s", err, output)
	}
}

func TestTunConfigDetectsPhysicalDefaultInterface(t *testing.T) {
	server := proto.Server{
		ID:       "node",
		Name:     "Node",
		Protocol: proto.ProtoVLESS,
		Address:  "198.51.100.40",
		Port:     443,
		Raw: map[string]any{
			"uuid": "00000000-0000-0000-0000-000000000004",
		},
	}
	config, err := BuildSingBoxConfigWithServers(
		server,
		1080,
		1081,
		store.Prefs{TunnelMode: "tun"},
		nil,
		proto.DNSConfig{},
		0,
		"",
		[]proto.Server{server},
		nil,
	)
	if err != nil {
		t.Fatalf("BuildSingBoxConfigWithServers: %v", err)
	}
	var decoded struct {
		Route map[string]any `json:"route"`
	}
	if err := json.Unmarshal(config, &decoded); err != nil {
		t.Fatal(err)
	}
	if enabled, ok := decoded.Route["auto_detect_interface"].(bool); !ok || !enabled {
		t.Fatalf("TUN config must enable auto_detect_interface: %#v", decoded.Route)
	}
}
