package netmemory

import (
	"crypto/sha256"
	"encoding/hex"
	"math"
	"net"
	"sort"
	"strings"
	"sync"
	"time"
)

// Package netmemory remembers which routes actually worked, per network.
//
// WHY
// ---
// Blocking in Russia is per-operator and per-region, and it changes during the
// day: a node that works on home broadband can be dead on a mobile carrier and
// alive again on a different Wi-Fi. Scoring routes by latency alone (what a
// plain urltest does) throws away the single most valuable signal we have —
// whether this route carried real traffic on THIS network last time.
//
// So we keep a small EWMA per (network, route) pair, fed by the runtime
// truth-check: it already proves whether a tunnel moves bytes, which is a far
// stronger signal than a handshake or a ping.
//
// PRIVACY
// -------
// The network identity is stored as a salted hash, never as a raw SSID or
// gateway MAC. We only ever need equality ("is this the same network as last
// time?"), never the value itself, so there is no reason to keep the plaintext
// on disk where a backup or a support log could leak it.

// Outcome is what the truth-check observed for one connection attempt.
type Outcome struct {
	// Verified is true when real traffic passed through the tunnel.
	Verified bool
	// LatencyMS is the observed probe latency; ignored when Verified is false.
	LatencyMS int
	// At is the observation time; zero means "now".
	At time.Time
}

// RouteStat is the accumulated knowledge about one route on one network.
type RouteStat struct {
	// SuccessRate is an EWMA in [0,1]: 1 means every recent attempt carried
	// traffic, 0 means none did.
	SuccessRate float64 `json:"success_rate"`
	// LatencyMS is an EWMA of verified probe latencies. Zero means unknown.
	LatencyMS float64 `json:"latency_ms,omitempty"`
	// Attempts counts observations, used to distinguish "known bad" from
	// "never tried".
	Attempts int `json:"attempts"`
	// LastSeen is when this pair was last observed.
	LastSeen time.Time `json:"last_seen"`
}

// Memory is a per-network route ledger. It is safe for concurrent use.
type Memory struct {
	mu sync.RWMutex
	// stats is keyed by network fingerprint, then by route ID.
	stats map[string]map[string]*RouteStat
	// alpha is the EWMA smoothing factor. Higher reacts faster to change.
	alpha float64
	// halfLife decays confidence in stale observations; networks change and
	// yesterday's verdict should not outweigh today's evidence forever.
	halfLife time.Duration
	now      func() time.Time
}

// New returns an empty Memory with sane defaults.
//
// alpha=0.4 reaches ~87% of a step change within 4 observations, which matches
// how quickly a route realistically flips between working and blocked.
func New() *Memory {
	return &Memory{
		stats:    make(map[string]map[string]*RouteStat),
		alpha:    0.4,
		halfLife: 72 * time.Hour,
		now:      time.Now,
	}
}

// Record folds one observation into the ledger.
func (m *Memory) Record(network, routeID string, out Outcome) {
	if network == "" || routeID == "" {
		return
	}
	at := out.At
	if at.IsZero() {
		at = m.now()
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	byRoute, ok := m.stats[network]
	if !ok {
		byRoute = make(map[string]*RouteStat)
		m.stats[network] = byRoute
	}
	st, ok := byRoute[routeID]
	if !ok {
		st = &RouteStat{}
		byRoute[routeID] = st
	}

	observed := 0.0
	if out.Verified {
		observed = 1.0
	}

	if st.Attempts == 0 {
		// Seed with the first observation instead of dragging it up from zero,
		// otherwise a route needs several successes before it stops looking bad.
		st.SuccessRate = observed
		if out.Verified && out.LatencyMS > 0 {
			st.LatencyMS = float64(out.LatencyMS)
		}
	} else {
		st.SuccessRate = m.alpha*observed + (1-m.alpha)*st.SuccessRate
		if out.Verified && out.LatencyMS > 0 {
			if st.LatencyMS == 0 {
				st.LatencyMS = float64(out.LatencyMS)
			} else {
				st.LatencyMS = m.alpha*float64(out.LatencyMS) + (1-m.alpha)*st.LatencyMS
			}
		}
	}
	st.Attempts++
	st.LastSeen = at
}

// Score returns a route's remembered quality on a network, in [0,1], and
// whether anything is known at all.
//
// Confidence decays with age: an observation older than the half-life is pulled
// back toward the neutral 0.5 so stale knowledge cannot veto a fresh attempt.
func (m *Memory) Score(network, routeID string) (float64, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	byRoute, ok := m.stats[network]
	if !ok {
		return 0, false
	}
	st, ok := byRoute[routeID]
	if !ok || st.Attempts == 0 {
		return 0, false
	}
	return m.decayedLocked(st), true
}

func (m *Memory) decayedLocked(st *RouteStat) float64 {
	age := m.now().Sub(st.LastSeen)
	if age <= 0 {
		return st.SuccessRate
	}
	// weight halves every halfLife; at weight w the score blends toward 0.5.
	w := math.Pow(0.5, age.Seconds()/m.halfLife.Seconds())
	return st.SuccessRate*w + 0.5*(1-w)
}

// Reorder returns candidates sorted by what we remember about this network,
// best first. Order is stable for equally-known routes, so a network we have
// never seen keeps the caller's original ranking untouched.
//
// Routes with no history sort at the neutral 0.5 rather than last: an unknown
// route deserves a try ahead of one we know is broken, but should not displace
// a route with a proven record.
func (m *Memory) Reorder(network string, candidates []string) []string {
	if network == "" || len(candidates) < 2 {
		return candidates
	}

	type scored struct {
		id    string
		score float64
		order int
	}
	items := make([]scored, 0, len(candidates))
	for i, id := range candidates {
		score, known := m.Score(network, id)
		if !known {
			score = 0.5
		}
		items = append(items, scored{id: id, score: score, order: i})
	}

	sort.SliceStable(items, func(i, j int) bool {
		if items[i].score != items[j].score {
			return items[i].score > items[j].score
		}
		// Ties keep the caller's ranking (latency/load ordering).
		return items[i].order < items[j].order
	})

	out := make([]string, 0, len(items))
	for _, it := range items {
		out = append(out, it.id)
	}
	return out
}

// Snapshot exports the ledger for persistence.
func (m *Memory) Snapshot() map[string]map[string]RouteStat {
	m.mu.RLock()
	defer m.mu.RUnlock()

	out := make(map[string]map[string]RouteStat, len(m.stats))
	for network, byRoute := range m.stats {
		copied := make(map[string]RouteStat, len(byRoute))
		for id, st := range byRoute {
			copied[id] = *st
		}
		out[network] = copied
	}
	return out
}

// Load restores a previously exported ledger, replacing current contents.
func (m *Memory) Load(data map[string]map[string]RouteStat) {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.stats = make(map[string]map[string]*RouteStat, len(data))
	for network, byRoute := range data {
		copied := make(map[string]*RouteStat, len(byRoute))
		for id, st := range byRoute {
			s := st
			copied[id] = &s
		}
		m.stats[network] = copied
	}
}

// Prune drops networks whose entries are all older than maxAge, keeping the
// ledger small on a device that roams a lot.
func (m *Memory) Prune(maxAge time.Duration) int {
	m.mu.Lock()
	defer m.mu.Unlock()

	cutoff := m.now().Add(-maxAge)
	removed := 0
	for network, byRoute := range m.stats {
		for id, st := range byRoute {
			if st.LastSeen.Before(cutoff) {
				delete(byRoute, id)
				removed++
			}
		}
		if len(byRoute) == 0 {
			delete(m.stats, network)
		}
	}
	return removed
}

// Fingerprint derives a stable, privacy-preserving identifier for the network
// the device is currently attached to.
//
// The inputs are things that change when the network changes but stay constant
// while on it: the default gateway and the local subnet. They are hashed with a
// fixed salt so the stored value cannot be reversed into a home address or an
// employer's network layout.
func Fingerprint(parts ...string) string {
	cleaned := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(strings.ToLower(p))
		if p != "" {
			cleaned = append(cleaned, p)
		}
	}
	if len(cleaned) == 0 {
		return ""
	}
	sort.Strings(cleaned)
	sum := sha256.Sum256([]byte("mosaicvpn-netfp-v1|" + strings.Join(cleaned, "|")))
	return hex.EncodeToString(sum[:8])
}

// LocalFingerprint builds a fingerprint from the host's active interfaces.
//
// It uses interface names plus their IPv4 subnet (not the full address): the
// subnet identifies the network, while the host part can change on every DHCP
// lease and would otherwise split one network into many remembered identities.
func LocalFingerprint() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	var parts []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok || ipnet.IP.To4() == nil {
				continue
			}
			// Skip our own tunnel addresses: they are identical on every
			// network and would make all networks look the same.
			if isTunnelSubnet(ipnet.IP) {
				continue
			}
			parts = append(parts, iface.Name+"/"+ipnet.IP.Mask(ipnet.Mask).String())
		}
	}
	return Fingerprint(parts...)
}

// isTunnelSubnet reports whether an address belongs to the ranges our own TUN
// interface uses, so the fingerprint reflects the underlying network.
func isTunnelSubnet(ip net.IP) bool {
	for _, cidr := range []string{"172.19.0.0/16", "198.18.0.0/15", "10.255.0.0/16"} {
		_, block, err := net.ParseCIDR(cidr)
		if err == nil && block.Contains(ip) {
			return true
		}
	}
	return false
}
