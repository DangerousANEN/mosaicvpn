package state

import (
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

func TestBuildRouteRules_BaselineHasSniffAndHijackDNS(t *testing.T) {
	rules := buildRouteRules(nil)
	// rc53 — baseline is sniff + DNS-by-protocol + DNS-by-port = 3 entries.
	// rc48's "system bypass" entry was removed because it leaked the
	// real IP whenever a user app routed 2ip.ru / ipinfo.io / etc
	// through Mosaic-as-proxy.
	if len(rules) != 3 {
		t.Fatalf("want 3 baseline rules, got %d: %#v", len(rules), rules)
	}
	sniff, ok := rules[0].(map[string]any)
	if !ok || sniff["action"] != "sniff" {
		t.Fatalf("rule[0] not a sniff entry: %#v", rules[0])
	}
	for i := 1; i <= 2; i++ {
		dns, ok := rules[i].(map[string]any)
		if !ok || dns["action"] != "hijack-dns" {
			t.Fatalf("rule[%d] not a hijack-dns entry: %#v", i, rules[i])
		}
		if _, hasOutbound := dns["outbound"]; hasOutbound {
			t.Errorf("rule[%d] still has legacy outbound field: %#v", i, dns)
		}
	}
}

func TestBuildRouteRules_NoSystemBypassDirectRule(t *testing.T) {
	// rc53 regression — make sure we never re-introduce the global
	// system-bypass direct rule.  Any rule with outbound:"direct"
	// must come from a user-defined Rule, never from baseline.
	rules := buildRouteRules(nil)
	for i, r := range rules {
		m, _ := r.(map[string]any)
		if m["outbound"] == "direct" {
			t.Fatalf("baseline rule[%d] is a direct-outbound rule (leak): %#v", i, m)
		}
	}
}

func TestBuildRouteRules_AppendsEnabledDirectUserRules(t *testing.T) {
	user := []proto.Rule{
		{
			ID:      "r1",
			Name:    "Bypass list",
			Action:  proto.ActionDirect,
			Enabled: true,
			Match: proto.Match{
				DomainSuffix: []string{"corp.local", " "},
				IPCIDR:       []string{"10.0.0.0/8"},
			},
		},
		{
			ID:      "r2",
			Name:    "Disabled split",
			Action:  proto.ActionDirect,
			Enabled: false,
			Match:   proto.Match{DomainSuffix: []string{"skip.me"}},
		},
		{
			ID:      "r3",
			Name:    "Wrong action",
			Action:  proto.ActionProxy,
			Enabled: true,
			Match:   proto.Match{DomainSuffix: []string{"proxy.me"}},
		},
		{
			ID:      "r4",
			Name:    "Empty rule",
			Action:  proto.ActionDirect,
			Enabled: true,
			Match:   proto.Match{},
		},
	}
	rules := buildRouteRules(user)
	// rc53 — 3 baseline (sniff + 2 dns) + 1 valid user rule = 4
	if len(rules) != 4 {
		t.Fatalf("want 4 rules, got %d: %#v", len(rules), rules)
	}
	last, _ := rules[3].(map[string]any)
	if last["outbound"] != "direct" {
		t.Errorf("user rule outbound = %v, want direct", last["outbound"])
	}
	if doms, _ := last["domain_suffix"].([]any); len(doms) != 1 || doms[0] != "corp.local" {
		t.Errorf("user rule domain_suffix = %#v, want [corp.local]", doms)
	}
	if ips, _ := last["ip_cidr"].([]any); len(ips) != 1 || ips[0] != "10.0.0.0/8" {
		t.Errorf("user rule ip_cidr = %#v, want [10.0.0.0/8]", ips)
	}
}
