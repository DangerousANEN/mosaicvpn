package subs

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// ParseSingbox accepts a JSON document that contains an "outbounds" array
// in the standard sing-box configuration shape. Outbounds whose type is
// "selector", "urltest", "block", "direct", or "dns" are skipped — only
// real proxy outbounds become Servers.
func ParseSingbox(subID string, payload []byte) ([]proto.Server, error) {
	var doc struct {
		Outbounds []map[string]any `json:"outbounds"`
	}
	if err := json.Unmarshal(payload, &doc); err != nil {
		return nil, fmt.Errorf("singbox: parse: %w", err)
	}

	var out []proto.Server
	for _, ob := range doc.Outbounds {
		t, _ := ob["type"].(string)
		switch strings.ToLower(t) {
		case "vless":
			out = append(out, singboxVLESS(subID, ob))
		case "hysteria2":
			out = append(out, singboxHysteria2(subID, ob))
		case "shadowsocks":
			out = append(out, singboxShadowsocks(subID, ob))
		case "naive":
			out = append(out, singboxNaive(subID, ob))
		case "wireguard":
			// Treat plain wireguard outbounds as AmneziaWG-compatible
			// containers; the actual obfuscation params are passed through
			// in Raw and applied at config-generation time.
			out = append(out, singboxWireguard(subID, ob))
		default:
			// skip selectors, urltest, dns, block, direct, etc.
		}
	}
	return out, nil
}

func singboxCommon(ob map[string]any, p proto.Protocol) proto.Server {
	tag, _ := ob["tag"].(string)
	server, _ := ob["server"].(string)
	port := portFromString(ob["server_port"])
	if port == 0 {
		port = portFromString(ob["port"])
	}
	name := tag
	if name == "" {
		name = fmt.Sprintf("%s://%s:%d", p, server, port)
	}
	return proto.Server{
		Name:           name,
		Protocol:       p,
		Address:        server,
		Port:           port,
		Tag:            tag,
		SubscriptionID: "", // filled by caller
		Raw:            ob,
	}
}

func singboxVLESS(subID string, ob map[string]any) proto.Server {
	s := singboxCommon(ob, proto.ProtoVLESS)
	s.SubscriptionID = subID
	s.ID = serverID(subID, "vless", s.Address, fmt.Sprint(s.Port), fmt.Sprint(ob["uuid"]))
	if flow, ok := ob["flow"].(string); ok && flow != "" {
		s.Tag = flow
	}
	return s
}

func singboxHysteria2(subID string, ob map[string]any) proto.Server {
	s := singboxCommon(ob, proto.ProtoHysteria2)
	s.SubscriptionID = subID
	s.ID = serverID(subID, "hy2", s.Address, fmt.Sprint(s.Port), fmt.Sprint(ob["password"]))
	return s
}

func singboxShadowsocks(subID string, ob map[string]any) proto.Server {
	s := singboxCommon(ob, proto.ProtoShadowsocks)
	s.SubscriptionID = subID
	s.ID = serverID(subID, "ss", s.Address, fmt.Sprint(s.Port), fmt.Sprint(ob["method"]), fmt.Sprint(ob["password"]))
	if m, ok := ob["method"].(string); ok {
		s.Tag = m
	}
	return s
}

func singboxNaive(subID string, ob map[string]any) proto.Server {
	s := singboxCommon(ob, proto.ProtoNaive)
	s.SubscriptionID = subID
	s.ID = serverID(subID, "naive", s.Address, fmt.Sprint(s.Port), fmt.Sprint(ob["username"]))
	return s
}

func singboxWireguard(subID string, ob map[string]any) proto.Server {
	s := singboxCommon(ob, proto.ProtoAmneziaWG)
	s.SubscriptionID = subID
	s.ID = serverID(subID, "awg", s.Address, fmt.Sprint(s.Port), fmt.Sprint(ob["private_key"]))
	return s
}
