// rc48/rc53 — buildRouteRules generates the `route.rules` array of
// a sing-box config from the user's rule chain.
//
// Historical note: rc48 used to inject a hard-coded "system bypass"
// list (ip-api.com / 2ip.ru / ifconfig.me / ...) here so that
// mosaicd's home-IP probes always escaped the tunnel.  rc53 strips
// that out — the in-process geo loop already runs only while the
// daemon is in a non-Connected state and goes through Go's default
// HTTP transport (not via SOCKS), so the rule was redundant.  Worse,
// it was an active leak: any user app pointed at our SOCKS inbound
// at 127.0.0.1:2080 also matched the rule, so visiting 2ip.ru in a
// browser configured to use Mosaic-as-proxy resolved to the *real*
// IP instead of the tunnelled one.
//
// User-defined Rules with Action="direct" Enabled=true are still
// honoured here so personal additions (corporate VPN endpoints,
// banking IPs, RU domain bypass preset, anything the user wants to
// skip the tunnel for) take effect.

package state

import (
	"strings"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

// SystemBypassDomains is the historic set of "always-direct"
// domains that the daemon hits to figure out the user's real IP.
// Kept here as a Go-level constant so the in-process geo loop and
// the offline IP probe can consult it (e.g. "is this URL one we
// expect to bypass the proxy?"), but it is no longer injected into
// sing-box's route.rules — see the package comment above.
var SystemBypassDomains = []string{
	"ip-api.com",
	"ipapi.co",
	"ipinfo.io",
	"db-ip.com",
	"2ip.ru",
	"2ip.io",
	"ifconfig.me",
	"ifconfig.co",
	"icanhazip.com",
	"api.ipify.org",
	"ipify.org",
}

// buildRouteRules assembles the sing-box `route.rules` array.  Order
// matters: sniff first, DNS-hijack rules next, user direct rules
// after, then the implicit `final: proxy` fallthrough.
//
// rc51 — migrated from legacy `outbound: "dns-out"` / `outbound: "block"`
// to rule actions `action: "hijack-dns"` / `action: "reject"`.  The
// `block` and `dns` special outbounds were removed in sing-box 1.13.0
// (they used to be `{type: "block"}` / `{type: "dns"}` entries in the
// `outbounds` array); rule actions are the only way to hijack DNS or
// drop traffic from 1.13 onwards.
//
// rc53 — the hard-coded SystemBypassDomains entry was dropped: it
// affected all SOCKS / HTTP / TUN inbound traffic, which let user-
// driven browser hits to e.g. 2ip.ru leak the real IP whenever the
// browser was using Mosaic as its proxy.  See package comment above.
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
