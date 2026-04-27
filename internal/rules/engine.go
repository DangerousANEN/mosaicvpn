// Package rules implements Mosaic's routing rule engine: matching a flow
// (domain, ip, process, port) against a prioritised list of Rules and
// returning the first action that fires.
//
// The matcher is intentionally generic — it operates on a Flow struct with
// already-extracted fields. The daemon collects those fields from sing-box's
// per-connection callbacks before invoking Match.
package rules

import (
	"net"
	"net/netip"
	"strconv"
	"strings"

	"github.com/DangerousANEN/mosaic/internal/proto"
)

// Flow describes the connection being routed.
type Flow struct {
	Domain  string // host name as resolved by application; may be empty
	IP      string // dotted-quad or IPv6 string; may be empty
	Process string // executable name (e.g. "chrome.exe")
	Port    int    // destination port
}

// Decision is the verdict produced by the engine.
type Decision struct {
	Rule   *proto.Rule // nil if no rule fired
	Action proto.Action
	Target string
}

// Default is the verdict to apply when no rule matches.
var Default = Decision{Action: proto.ActionDirect}

// GeoSiteResolver maps a domain to the set of geosite categories it
// belongs to (e.g. "google", "category-ads", "netflix"). Implementations
// can be backed by a downloaded GeoSite file at runtime; in this package
// we leave it injectable so the engine itself stays pure.
type GeoSiteResolver interface {
	Categories(domain string) []string
}

// GeoIPResolver maps an IP to a country code (e.g. "JP").
type GeoIPResolver interface {
	Country(ip netip.Addr) string
}

// Engine evaluates Flows against an ordered, snapshot-of-rules list.
type Engine struct {
	rules     []proto.Rule
	geoSite   GeoSiteResolver
	geoIP     GeoIPResolver
	defaultDx Decision
}

// New creates an Engine. Either resolver may be nil; conditions referring
// to a missing resolver simply never match.
func New(rules []proto.Rule, geoSite GeoSiteResolver, geoIP GeoIPResolver) *Engine {
	cp := append([]proto.Rule(nil), rules...)
	return &Engine{rules: cp, geoSite: geoSite, geoIP: geoIP, defaultDx: Default}
}

// SetDefault overrides the verdict applied when no rule matches.
func (e *Engine) SetDefault(d Decision) { e.defaultDx = d }

// Evaluate returns the first matching rule's decision, or the engine
// default if no rule matched.
func (e *Engine) Evaluate(f Flow) Decision {
	for i := range e.rules {
		r := &e.rules[i]
		if !r.Enabled {
			continue
		}
		if !e.match(r.Match, f) {
			continue
		}
		return Decision{Rule: r, Action: r.Action, Target: r.Target}
	}
	return e.defaultDx
}

// match checks one Match block against a Flow according to its Logic.
func (e *Engine) match(m proto.Match, f Flow) bool {
	if m.Empty() {
		return false
	}
	checks := buildChecks(m, f, e.geoSite, e.geoIP)
	if len(checks) == 0 {
		return false
	}
	switch m.Logic {
	case proto.LogicOr:
		for _, ok := range checks {
			if ok {
				return true
			}
		}
		return false
	default: // and (default)
		for _, ok := range checks {
			if !ok {
				return false
			}
		}
		return true
	}
}

// buildChecks turns a Match into a list of boolean results, one per
// non-empty condition group.
func buildChecks(m proto.Match, f Flow, gs GeoSiteResolver, gi GeoIPResolver) []bool {
	var checks []bool

	if len(m.DomainSuffix) > 0 {
		checks = append(checks, matchDomainSuffix(f.Domain, m.DomainSuffix))
	}
	if len(m.DomainKeyword) > 0 {
		checks = append(checks, matchDomainKeyword(f.Domain, m.DomainKeyword))
	}
	if len(m.Domain) > 0 {
		checks = append(checks, matchDomainExact(f.Domain, m.Domain))
	}
	if len(m.IPCIDR) > 0 {
		checks = append(checks, matchIPCIDR(f.IP, m.IPCIDR))
	}
	if len(m.Process) > 0 {
		checks = append(checks, matchProcess(f.Process, m.Process))
	}
	if len(m.Port) > 0 {
		checks = append(checks, matchPort(f.Port, m.Port))
	}
	if len(m.GeoSite) > 0 {
		checks = append(checks, matchGeoSite(f.Domain, m.GeoSite, gs))
	}
	if len(m.GeoIP) > 0 {
		checks = append(checks, matchGeoIP(f.IP, m.GeoIP, gi))
	}
	return checks
}

func matchDomainSuffix(domain string, suffixes []string) bool {
	d := strings.ToLower(domain)
	for _, s := range suffixes {
		s = strings.ToLower(strings.TrimPrefix(s, "."))
		if d == s || strings.HasSuffix(d, "."+s) {
			return true
		}
	}
	return false
}

func matchDomainKeyword(domain string, keywords []string) bool {
	d := strings.ToLower(domain)
	for _, k := range keywords {
		if strings.Contains(d, strings.ToLower(k)) {
			return true
		}
	}
	return false
}

func matchDomainExact(domain string, exacts []string) bool {
	d := strings.ToLower(domain)
	for _, e := range exacts {
		if strings.ToLower(e) == d {
			return true
		}
	}
	return false
}

func matchIPCIDR(ip string, cidrs []string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			continue
		}
		if n.Contains(parsed) {
			return true
		}
	}
	return false
}

func matchProcess(proc string, names []string) bool {
	p := strings.ToLower(proc)
	for _, n := range names {
		if strings.EqualFold(p, n) {
			return true
		}
	}
	return false
}

func matchPort(port int, specs []string) bool {
	for _, s := range specs {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if strings.Contains(s, "-") {
			lo, hi, ok := splitRange(s)
			if !ok {
				continue
			}
			if port >= lo && port <= hi {
				return true
			}
			continue
		}
		if v, err := strconv.Atoi(s); err == nil && v == port {
			return true
		}
	}
	return false
}

func splitRange(s string) (int, int, bool) {
	parts := strings.SplitN(s, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	lo, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return 0, 0, false
	}
	hi, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return 0, 0, false
	}
	if lo > hi {
		lo, hi = hi, lo
	}
	return lo, hi, true
}

func matchGeoSite(domain string, sites []string, gs GeoSiteResolver) bool {
	if gs == nil || domain == "" {
		return false
	}
	got := gs.Categories(domain)
	for _, want := range sites {
		for _, g := range got {
			if strings.EqualFold(g, want) {
				return true
			}
		}
	}
	return false
}

func matchGeoIP(ip string, codes []string, gi GeoIPResolver) bool {
	if gi == nil || ip == "" {
		return false
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil {
		return false
	}
	cc := gi.Country(addr)
	if cc == "" {
		return false
	}
	for _, want := range codes {
		if strings.EqualFold(cc, want) {
			return true
		}
	}
	return false
}
