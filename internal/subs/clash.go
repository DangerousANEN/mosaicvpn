package subs

import (
	"fmt"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"gopkg.in/yaml.v3"
)

// clashDoc only describes the bits we care about.
type clashDoc struct {
	Proxies []map[string]any `yaml:"proxies"`
}

// ParseClash parses a Clash/Mihomo YAML configuration. Only proxies of
// supported types are returned as Servers; proxy-groups, rules, etc. are
// ignored at this layer.
func ParseClash(subID string, payload []byte) ([]proto.Server, error) {
	var doc clashDoc
	if err := yaml.Unmarshal(payload, &doc); err != nil {
		return nil, fmt.Errorf("clash: yaml: %w", err)
	}
	var out []proto.Server
	for _, p := range doc.Proxies {
		t, _ := p["type"].(string)
		switch t {
		case "vless":
			out = append(out, clashVLESS(subID, p))
		case "hysteria2":
			out = append(out, clashHysteria2(subID, p))
		case "ss":
			out = append(out, clashSS(subID, p))
		case "wireguard":
			out = append(out, clashWG(subID, p))
		}
	}
	return out, nil
}

func clashCommon(p map[string]any, kind proto.Protocol) proto.Server {
	name, _ := p["name"].(string)
	server, _ := p["server"].(string)
	port := portFromString(p["port"])
	if name == "" {
		name = fmt.Sprintf("%s://%s:%d", kind, server, port)
	}
	return proto.Server{
		Name:     name,
		Protocol: kind,
		Address:  server,
		Port:     port,
		Raw:      p,
	}
}

func clashVLESS(subID string, p map[string]any) proto.Server {
	s := clashCommon(p, proto.ProtoVLESS)
	s.SubscriptionID = subID
	uuid, _ := p["uuid"].(string)
	s.ID = serverID(subID, "clash-vless", s.Address, fmt.Sprint(s.Port, s.Name), uuid)
	if flow, _ := p["flow"].(string); flow != "" {
		s.Tag = flow
	}
	return s
}

func clashHysteria2(subID string, p map[string]any) proto.Server {
	s := clashCommon(p, proto.ProtoHysteria2)
	s.SubscriptionID = subID
	pw, _ := p["password"].(string)
	s.ID = serverID(subID, "clash-hy2", s.Address, fmt.Sprint(s.Port, s.Name), pw)
	return s
}

func clashSS(subID string, p map[string]any) proto.Server {
	s := clashCommon(p, proto.ProtoShadowsocks)
	s.SubscriptionID = subID
	cipher, _ := p["cipher"].(string)
	pw, _ := p["password"].(string)
	s.Tag = cipher
	s.ID = serverID(subID, "clash-ss", s.Address, fmt.Sprint(s.Port, s.Name), cipher, pw)
	return s
}

func clashWG(subID string, p map[string]any) proto.Server {
	s := clashCommon(p, proto.ProtoAmneziaWG)
	s.SubscriptionID = subID
	pk, _ := p["private-key"].(string)
	s.ID = serverID(subID, "clash-wg", s.Address, fmt.Sprint(s.Port, s.Name), pk)
	return s
}
