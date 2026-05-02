package state

import (
	"testing"

	"github.com/DangerousANEN/mosaicvpn/internal/proto"
)

func TestBuildRouteRules_AlwaysIncludesSystemBypass(t *testing.T) {
	rules := buildRouteRules(nil)
	// DNS-by-protocol, DNS-by-port, then system bypass = at least 3 entries.
	if len(rules) < 3 {
		t.Fatalf("want >=3 baseline rules, got %d: %#v", len(rules), rules)
	}
	bypass, ok := rules[2].(map[string]any)
	if !ok || bypass["outbound"] != "direct" {
		t.Fatalf("rule[2] not a direct bypass entry: %#v", rules[2])
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
	// 3 baseline + 1 valid user rule = 4
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
