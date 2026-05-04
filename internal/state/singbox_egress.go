package state

import (
	"encoding/json"
	"fmt"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
	"github.com/DangerousANEN/mosaicvpn/internal/store"
)

// BuildEgressConfig assembles a sing-box config for a single auxiliary
// proxy listener (rc44).  Unlike BuildSingBoxConfig (which sets up the
// main user-facing tunnel with both socks/http inbounds, optional TUN
// and clash-api), an egress exposes exactly one inbound on the
// configured port and protocol, never sets up TUN, and never enables
// clash-api.  Anti-DPI overrides from prefs are still applied so the
// egress and the main tunnel use the same DPI treatment.
//
// listenAddr is "127.0.0.1" when cfg.ShareLAN is false, "0.0.0.0"
// otherwise.  When ShareLAN exposes the listener to the LAN and a
// user/pass pair is configured, the inbound gets a `users` array so
// remote clients have to authenticate; loopback-only listeners stay
// anonymous (matches the historic behaviour of the main proxy).
func BuildEgressConfig(eg proto.EgressConfig, server proto.Server, prefs store.Prefs) ([]byte, error) {
	out, err := outboundFor(server)
	if err != nil {
		return nil, err
	}
	applyAntiDPI(out, prefs)

	listen := "127.0.0.1"
	if eg.ShareLAN {
		listen = "0.0.0.0"
	}
	proto2sb := map[string]string{
		"socks5": "socks",
		"socks":  "socks",
		"http":   "http",
		"":       "socks",
	}
	inboundType, ok := proto2sb[eg.Protocol]
	if !ok {
		return nil, fmt.Errorf("egress %q: unsupported protocol %q", eg.ID, eg.Protocol)
	}
	if eg.Port <= 0 {
		return nil, fmt.Errorf("egress %q: port must be > 0", eg.ID)
	}

	// rc51 — `sniff: true` was a legacy inbound field removed in
	// sing-box 1.13.  See singbox_backend.go for context; the
	// route below now carries an `{action: "sniff"}` rule which
	// has the same effect inbound-listener-agnostically.
	inbound := map[string]any{
		"type":        inboundType,
		"tag":         "egress-in",
		"listen":      listen,
		"listen_port": eg.Port,
	}
	if eg.ShareLAN && eg.ShareUser != "" && eg.SharePass != "" {
		inbound["users"] = []any{map[string]any{
			"username": eg.ShareUser,
			"password": eg.SharePass,
		}}
	}

	// rc51 — same DNS / outbound / endpoint migration as
	// BuildSingBoxConfig: typed DNS servers, no `outbound: "any"`
	// DNS rule, no `block` outbound, and wireguard / amneziawg go
	// to the `endpoints` array.  See singbox_backend.go for the
	// rationale; both builders feed the same sing-box binary, so
	// the schema has to match.
	cfg := map[string]any{
		"log": map[string]any{
			"level":     "warn",
			"timestamp": true,
		},
		"dns": map[string]any{
			"servers": []any{
				map[string]any{
					"type":   "https",
					"tag":    "remote-doh",
					"server": "1.1.1.1",
					"detour": "proxy",
				},
				// rc52 fixup — see BuildSingBoxConfig for context;
				// 1.13.7 forbids `detour: "direct"` on a DNS server
				// when the direct outbound has no custom dialer
				// options.  `type: "local"` uses the OS resolver
				// without going through any outbound and is the
				// modern idiom for "bypass the proxy".
				map[string]any{
					"type": "local",
					"tag":  "local",
				},
			},
			"final":             "local",
			"strategy":          "ipv4_only",
			"independent_cache": true,
		},
		"inbounds": []any{inbound},
		"route": map[string]any{
			"final":                   "proxy",
			"auto_detect_interface":   true,
			"default_domain_resolver": "local",
			"rules": []any{
				map[string]any{"action": "sniff"},
			},
		},
	}
	directOut := map[string]any{"type": "direct", "tag": "direct"}
	if IsEndpointProtocol(server.Protocol) {
		cfg["endpoints"] = []any{out}
		cfg["outbounds"] = []any{directOut}
	} else {
		cfg["outbounds"] = []any{out, directOut}
	}
	return json.MarshalIndent(cfg, "", "  ")
}
