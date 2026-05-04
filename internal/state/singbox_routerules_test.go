package state

import (
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

func TestBuildRouteRules_AlwaysIncludesSystemBypass(t *testing.T) {
	rules := buildRouteRules(nil)
	// rc51 — sniff + DNS-by-protocol + DNS-by-port + system bypass = 4 entries.
	if len(rules) < 4 {
		t.Fatalf("want >=4 baseline rules, got %d: %#v", len(rules), rules)
	}
	sniff, ok := rules[0].(map[string]any)
	if !ok || sniff["action"] != "sniff" {
		t.Fatalf("rule[0] not a sniff entry: %#v", rules[0])
	}
	// rc51 — sing-box 1.13 removed the `dns` special outbound, so
	// the DNS-hijack entries now use `action: "hijack-dns"` instead
	// of `outbound: "dns-out"`.  Verify both forms are present.
	for i := 1; i <= 2; i++ {
		dns, ok := rules[i].(map[string]any)
		if !ok || dns["action"] != "hijack-dns" {
			t.Fatalf("rule[%d] not a hijack-dns entry: %#v", i, rules[i])
		}
		if _, hasOutbound := dns["outbound"]; hasOutbound {
			t.Errorf("rule[%d] still has legacy outbound field: %#v", i, dns)
		}
	}
	bypass, ok := rules[3].(map[string]any)
	if !ok || bypass["outbound"] != "direct" {
		t.Fatalf("rule[3] not a direct bypass entry: %#v", rules[3])
	}
	doms, ok := bypass["domain_suffix"].([]any)
	if !ok || len(doms) == 0 {
		t.Fatalf("bypass entry missing domain_suffix: %#v", bypass)
	}
	wantHosts := map[string]bool{
		"ip-api.com":   false,
		"2ip.ru":       false,
		"ifconfig.me":  false,
		"api.ipify.org": false,
	}
	for _, d := range doms {
		if s, ok := d.(string); ok {
			if _, want := wantHosts[s]; want {
				wantHosts[s] = true
			}
		}
	}
	for h, found := range wantHosts {
		if !found {
			t.Errorf("system bypass missing %q", h)
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
	// rc51 — 4 baseline (sniff + 2 dns + system bypass) + 1 valid user rule = 5
	if len(rules) != 5 {
		t.Fatalf("want 5 rules, got %d: %#v", len(rules), rules)
	}
	last, _ := rules[4].(map[string]any)
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
