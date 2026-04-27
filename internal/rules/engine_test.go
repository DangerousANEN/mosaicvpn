package rules_test

import (
	"net/netip"
	"testing"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
	"github.com/pupspochta-cpu/mosaicvpn/internal/rules"
)

type fakeGeoSite map[string][]string

func (f fakeGeoSite) Categories(domain string) []string { return f[domain] }

type fakeGeoIP map[string]string

func (f fakeGeoIP) Country(addr netip.Addr) string { return f[addr.String()] }

func TestDomainSuffix(t *testing.T) {
	rs := []proto.Rule{
		{Enabled: true, Action: proto.ActionDirect, Match: proto.Match{DomainSuffix: []string{"yandex.ru"}}},
	}
	e := rules.New(rs, nil, nil)

	cases := []struct {
		domain string
		want   proto.Action
	}{
		{"www.yandex.ru", proto.ActionDirect},
		{"yandex.ru", proto.ActionDirect},
		{"google.com", proto.ActionDirect /* default */},
	}
	// override default to make distinct
	e.SetDefault(rules.Decision{Action: proto.ActionProxy})
	cases[2].want = proto.ActionProxy

	for _, c := range cases {
		got := e.Evaluate(rules.Flow{Domain: c.domain}).Action
		if got != c.want {
			t.Errorf("%s: got %s, want %s", c.domain, got, c.want)
		}
	}
}

func TestPriorityFirstMatchWins(t *testing.T) {
	rs := []proto.Rule{
		{Enabled: true, Action: proto.ActionBlock, Match: proto.Match{DomainKeyword: []string{"ads"}}},
		{Enabled: true, Action: proto.ActionDirect, Match: proto.Match{DomainSuffix: []string{"example.com"}}},
	}
	e := rules.New(rs, nil, nil)
	d := e.Evaluate(rules.Flow{Domain: "ads.example.com"})
	if d.Action != proto.ActionBlock {
		t.Fatalf("expected block (first rule), got %s", d.Action)
	}
}

func TestANDLogicAllMustMatch(t *testing.T) {
	rs := []proto.Rule{{
		Enabled: true,
		Action:  proto.ActionProxy,
		Target:  "tokyo",
		Match: proto.Match{
			Logic:        proto.LogicAnd,
			DomainSuffix: []string{"netflix.com"},
			Process:      []string{"chrome.exe"},
		},
	}}
	e := rules.New(rs, nil, nil)
	if e.Evaluate(rules.Flow{Domain: "www.netflix.com", Process: "chrome.exe"}).Action != proto.ActionProxy {
		t.Fatal("AND: both conditions should match")
	}
	if e.Evaluate(rules.Flow{Domain: "www.netflix.com", Process: "edge.exe"}).Action != proto.ActionDirect {
		t.Fatal("AND: should not match when process differs")
	}
}

func TestORLogic(t *testing.T) {
	rs := []proto.Rule{{
		Enabled: true,
		Action:  proto.ActionProxy,
		Target:  "tokyo",
		Match: proto.Match{
			Logic:   proto.LogicOr,
			Process: []string{"chrome.exe"},
			Port:    []string{"8080"},
		},
	}}
	e := rules.New(rs, nil, nil)
	if e.Evaluate(rules.Flow{Process: "chrome.exe", Port: 1234}).Action != proto.ActionProxy {
		t.Fatal("OR: process match alone should fire")
	}
	if e.Evaluate(rules.Flow{Process: "edge.exe", Port: 8080}).Action != proto.ActionProxy {
		t.Fatal("OR: port match alone should fire")
	}
	if e.Evaluate(rules.Flow{Process: "edge.exe", Port: 1234}).Action != proto.ActionDirect {
		t.Fatal("OR: neither match should fall through")
	}
}

func TestPortRange(t *testing.T) {
	rs := []proto.Rule{{
		Enabled: true, Action: proto.ActionDirect,
		Match: proto.Match{Port: []string{"6881-6889", "443"}},
	}}
	e := rules.New(rs, nil, nil)
	e.SetDefault(rules.Decision{Action: proto.ActionProxy})
	for _, port := range []int{443, 6881, 6885, 6889} {
		if e.Evaluate(rules.Flow{Port: port}).Action != proto.ActionDirect {
			t.Errorf("port %d should match direct", port)
		}
	}
	if e.Evaluate(rules.Flow{Port: 8080}).Action != proto.ActionProxy {
		t.Error("port 8080 should fall through to proxy default")
	}
}

func TestIPCIDR(t *testing.T) {
	rs := []proto.Rule{{
		Enabled: true, Action: proto.ActionDirect,
		Match: proto.Match{IPCIDR: []string{"192.168.0.0/16", "10.0.0.0/8"}},
	}}
	e := rules.New(rs, nil, nil)
	e.SetDefault(rules.Decision{Action: proto.ActionProxy})

	if e.Evaluate(rules.Flow{IP: "192.168.1.5"}).Action != proto.ActionDirect {
		t.Error("LAN IP should match direct")
	}
	if e.Evaluate(rules.Flow{IP: "8.8.8.8"}).Action != proto.ActionProxy {
		t.Error("public IP should fall through")
	}
}

func TestGeoSiteAndGeoIP(t *testing.T) {
	gs := fakeGeoSite{
		"www.netflix.com": {"netflix", "streaming"},
	}
	gi := fakeGeoIP{
		"203.0.113.1": "JP",
	}
	rs := []proto.Rule{
		{Enabled: true, Action: proto.ActionProxy, Target: "tokyo",
			Match: proto.Match{GeoSite: []string{"netflix"}}},
		{Enabled: true, Action: proto.ActionDirect,
			Match: proto.Match{GeoIP: []string{"JP"}}},
	}
	e := rules.New(rs, gs, gi)

	if e.Evaluate(rules.Flow{Domain: "www.netflix.com"}).Action != proto.ActionProxy {
		t.Error("netflix should match geosite proxy rule")
	}
	if e.Evaluate(rules.Flow{IP: "203.0.113.1"}).Action != proto.ActionDirect {
		t.Error("JP IP should match geoip direct rule")
	}
}

func TestDisabledRulesIgnored(t *testing.T) {
	rs := []proto.Rule{
		{Enabled: false, Action: proto.ActionBlock, Match: proto.Match{DomainSuffix: []string{"example.com"}}},
	}
	e := rules.New(rs, nil, nil)
	if e.Evaluate(rules.Flow{Domain: "example.com"}).Action == proto.ActionBlock {
		t.Fatal("disabled rule should not fire")
	}
}
