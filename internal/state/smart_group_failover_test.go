package state

import (
	"encoding/json"
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
