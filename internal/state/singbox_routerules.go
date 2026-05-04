// rc48 — buildRouteRules generates the `route.rules` array of a
// sing-box config from the user's rule chain plus a hard-coded list
// of "system bypass" hosts that always skip the tunnel.
//
// Why a system bypass?  mosaicd resolves the user's home-IP location
// by hitting ip-api.com / ipapi.co / ipinfo.io while the tunnel is
// disconnected.  In TUN mode with auto_route the OS routing table
// captures every outbound socket — including the daemon's own
// HTTP probes — so once a user reconnects after their first launch
// the next geo refresh would resolve to the egress IP and the "vous"
// pin would jump to whatever country their server lives in.
//
// Sending those probe hosts straight through the `direct` outbound
// (which uses auto_detect_interface=true to escape its own TUN
// capture) keeps the daemon talking to the real internet regardless
// of tunnel state, so the user's location stays accurate.
//
// User-defined Rules with Action="direct" Enabled=true are appended
// after the system list so personal additions (corporate VPN
// endpoints, banking IPs, anything the user wants to skip the
// tunnel for) take effect alongside the built-in bypass.

package state

import (
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// SystemBypassDomains is the set of domain suffixes that always skip
// the tunnel.  The list mirrors mosaicd's geo-resolution chain plus a
// small set of user-recognisable IP-check sites the user is likely to
// open in their browser to verify "am I leaking my home IP?".
//
// Exposed so the renderer can show the same list in the Folio Bypass
// chapter as a read-only "system" group, and so tests can assert the
// invariant.
var SystemBypassDomains = []string{
	// mosaicd's own geo-resolution chain
	"ip-api.com",
	"ipapi.co",
	"ipinfo.io",
	// db-ip.com city-lite download (rc47 offline GeoIP)
	"db-ip.com",
	// user-recognisable "what's my IP" sites that double as a
	// reality-check for VOUS positioning
	"2ip.ru",
	"2ip.io",
	"ifconfig.me",
	"ifconfig.co",
	"icanhazip.com",
	"api.ipify.org",
	"ipify.org",
}

// buildRouteRules assembles the sing-box `route.rules` array.  Order
// matters: DNS rules first, system bypass next, user direct rules
// after, then the implicit `final: proxy` fallthrough.
//
// rc51 — migrated from legacy `outbound: "dns-out"` / `outbound: "block"`
// to rule actions `action: "hijack-dns"` / `action: "reject"`.  The
// `block` and `dns` special outbounds were removed in sing-box 1.13.0
// (they used to be `{type: "block"}` / `{type: "dns"}` entries in the
// `outbounds` array); rule actions are the only way to hijack DNS or
// drop traffic from 1.13 onwards.
func buildRouteRules(userRules []proto.Rule) []any {
	rules := []any{
		// rc51 — sniff every inbound flow.  The legacy
		// per-inbound `sniff: true` listen field was removed
		// in sing-box 1.13; the only way to populate
		// `metadata.protocol` / `metadata.host` (used by
		// downstream domain_suffix matchers in the user's
		// bypass list) is via an explicit `{action: "sniff"}`
		// rule that runs first.
		map[string]any{"action": "sniff"},
		// All UDP/TCP DNS traffic captured by TUN gets handed to
		// sing-box's internal DNS resolver.
		map[string]any{"protocol": "dns", "action": "hijack-dns"},
		// Belt-and-braces: anything destined for port 53 (e.g.
		// apps that bypass the system resolver) also gets
		// coerced into the internal resolver.
		map[string]any{"port": []any{53}, "action": "hijack-dns"},
		// System bypass: geo-resolution + IP-check hosts always
		// dial through `direct` so the user's home-IP detection
		// keeps working while the tunnel is up.
		map[string]any{
			"domain_suffix": stringsToAny(SystemBypassDomains),
			"outbound":      "direct",
		},
	}

	for _, r := range userRules {
		if !r.Enabled {
			continue
		}
		if string(r.Action) != "direct" {
			continue
		}
		entry := map[string]any{"outbound": "direct"}
		if domains := cleanList(r.Match.DomainSuffix); len(domains) > 0 {
			entry["domain_suffix"] = stringsToAny(domains)
		}
		if ips := cleanList(r.Match.IPCIDR); len(ips) > 0 {
			entry["ip_cidr"] = stringsToAny(ips)
		}
		// A rule with no targets matches nothing and would be
		// rejected by sing-box on launch — skip silently.
		if _, hasD := entry["domain_suffix"]; !hasD {
			if _, hasI := entry["ip_cidr"]; !hasI {
				continue
			}
		}
		rules = append(rules, entry)
	}
	return rules
}

func cleanList(in []string) []string {
	out := make([]string, 0, len(in))
	for _, s := range in {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		out = append(out, s)
	}
	return out
}

func stringsToAny(in []string) []any {
	out := make([]any, 0, len(in))
	for _, s := range in {
		out = append(out, s)
	}
	return out
}
