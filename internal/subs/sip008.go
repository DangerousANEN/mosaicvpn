package subs

import (
	"encoding/json"
	"fmt"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// sip008Doc is the published SIP008 schema.
type sip008Doc struct {
	Version int `json:"version"`
	Servers []struct {
		ID         string `json:"id"`
		Remarks    string `json:"remarks"`
		Server     string `json:"server"`
		ServerPort int    `json:"server_port"`
		Method     string `json:"method"`
		Password   string `json:"password"`
		Plugin     string `json:"plugin,omitempty"`
		PluginOpts string `json:"plugin_opts,omitempty"`
	} `json:"servers"`
}

// ParseSIP008 parses a SIP008 Shadowsocks subscription.
func ParseSIP008(subID string, payload []byte) ([]proto.Server, error) {
	var doc sip008Doc
	if err := json.Unmarshal(payload, &doc); err != nil {
		return nil, fmt.Errorf("sip008: json: %w", err)
	}
	out := make([]proto.Server, 0, len(doc.Servers))
	for _, s := range doc.Servers {
		name := s.Remarks
		if name == "" {
			name = fmt.Sprintf("ss://%s:%d", s.Server, s.ServerPort)
		}
		id := s.ID
		if id == "" {
			id = serverID(subID, "sip008", s.Server, fmt.Sprint(s.ServerPort), s.Method, s.Password)
		}
		out = append(out, proto.Server{
			ID:             id,
			Name:           name,
			Protocol:       proto.ProtoShadowsocks,
			Address:        s.Server,
			Port:           s.ServerPort,
			Tag:            s.Method,
			SubscriptionID: subID,
			Raw: map[string]any{
				"method":      s.Method,
				"password":    s.Password,
				"plugin":      s.Plugin,
				"plugin_opts": s.PluginOpts,
			},
		})
	}
	return out, nil
}
