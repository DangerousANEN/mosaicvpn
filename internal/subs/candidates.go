package subs

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/pupspochta-cpu/mosaicvpn/internal/proto"
)

// CandidateFeed is the daemon-only physical-node feed served by the provider
// at /api/client-candidates/<opaque_id>. It carries sing-box outbound maps
// annotated with mosaic_* metadata that assign each node to smart groups.
type CandidateFeed struct {
	Outbounds []map[string]any `json:"outbounds"`
}

// deriveCandidatesURL converts a subscription URL to its candidate feed
// endpoint. The opaque subscription id is the last path segment of the sub
// URL (e.g. https://sub.zxc1x1.ru/<short_uuid>).
func deriveCandidatesURL(subURL string) string {
	u, err := url.Parse(subURL)
	if err != nil {
		return ""
	}
	segs := strings.Split(strings.Trim(u.Path, "/"), "/")
	opaque := ""
	if len(segs) > 0 {
		opaque = segs[len(segs)-1]
	}
	if opaque == "" || !isOpaqueCandidateID(opaque) {
		return ""
	}
	u.Path = "/api/client-candidates/" + url.PathEscape(opaque)
	u.RawQuery = ""
	return u.String()
}

// isOpaqueCandidateID mirrors the server-side guard: 8..256 chars of
// [A-Za-z0-9_-].
func isOpaqueCandidateID(s string) bool {
	if len(s) < 8 || len(s) > 256 {
		return false
	}
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '_' || r == '-':
		default:
			return false
		}
	}
	return true
}

// FetchCandidateFeed downloads the provider's daemon-only candidate feed.
// A missing feed (404, network error, non-JSON body) yields a nil feed and a
// nil error — candidates are an enhancement, never a hard requirement.
func FetchCandidateFeed(ctx context.Context, subURL string) (*CandidateFeed, error) {
	feedURL := deriveCandidatesURL(subURL)
	if feedURL == "" {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return nil, nil
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "MosaicVPN-Daemon/0.3")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, nil // silent fallback
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, nil
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20)) // 8 MiB cap
	if err != nil {
		return nil, nil
	}
	var feed CandidateFeed
	if json.Unmarshal(body, &feed) != nil || len(feed.Outbounds) == 0 {
		return nil, nil
	}
	return &feed, nil
}

// candidateGroupAliases maps provider smart-group ids to the canonical local
// group ids used by the manifest/synthesizer. Both spellings resolve to the
// same virtual group so old and new manifests interoperate.
var candidateGroupAliases = map[string]string{
	"min-latency":  "rg-all",
	"min_latency":  "rg-all",
	"all":          "rg-all",
	"stable":       "auto-stable",
	"max-speed":    "auto-speed",
	"max_speed":    "auto-speed",
	"germany":      "auto-de",
	"canada":       "auto-ca",
	"netherlands":  "auto-nl",
	"holland":      "auto-nl",
	"usa":          "auto-us",
	"united-states": "auto-us",
	"great-britain": "auto-gb",
	"uk":           "auto-gb",
	"france":       "auto-fr",
	"russia":       "auto-ru",
	"allowlist":    "auto-whitelist",
	"whitelist":    "auto-whitelist",
	"free-lte":     "auto-lte",
	"lte":          "auto-lte",
	"owned":        "", // owned nodes are not part of the free pool
}

// CandidateGroups returns the canonical local group ids a candidate belongs
// to, based on its mosaic_* annotations and GeoIP metadata.
func CandidateGroups(ob map[string]any) []string {
	seen := map[string]bool{}
	var out []string
	add := func(g string) {
		if g == "" || seen[g] {
			return
		}
		seen[g] = true
		out = append(out, g)
	}
	if ids, ok := ob["mosaic_group_ids"].([]any); ok {
		for _, raw := range ids {
			s, _ := raw.(string)
			add(candidateGroupAliases[s])
			// Unknown group id: keep it as-is so future provider groups work.
			if s != "" && candidateGroupAliases[s] == "" && !strings.HasPrefix(s, "client-") {
				add(s)
			}
		}
	}
	if cc, ok := ob["mosaic_country"].(string); ok && cc != "" {
		cc = strings.ToUpper(cc)
		switch cc {
		case "DE", "NL", "US", "RU", "CA", "FR", "SG", "GB", "FI":
			add("auto-" + strings.ToLower(cc))
		}
	}
	return out
}

// CandidateInGroup reports whether a candidate server's provider annotations
// (Raw.mosaic_group_ids) list the given local group id. Aliases are applied
// both ways: provider ids like "min_latency" map to local "rg-all", and local
// tags like "auto-whitelist"/"auto-lte" match provider "allowlist"/"free-lte".
func CandidateInGroup(sv proto.Server, groupID string) bool {
	if groupID == "" || sv.Category != "candidate" {
		return false
	}
	ids, ok := sv.Raw["mosaic_group_ids"].([]any)
	if !ok {
		return false
	}
	for _, raw := range ids {
		s, _ := raw.(string)
		if s == "" {
			continue
		}
		if s == groupID {
			return true
		}
		if candidateGroupAliases[s] == groupID {
			return true
		}
		switch s {
		case "allowlist":
			if groupID == "auto-whitelist" || groupID == "free-lte" {
				return true
			}
		case "free-lte":
			if groupID == "auto-whitelist" || groupID == "free-lte" {
				return true
			}
		}
	}
	return false
}

// CandidatesToServers converts a candidate feed into proto.Server entries.
// Every candidate gets Category="candidate" plus GroupTag set to the first
// matching group; Raw keeps the full outbound map for config generation.
// The returned servers are NOT persisted as a subscription — callers merge
// them into the store's server list under a synthetic subscription id.
func CandidatesToServers(feed *CandidateFeed) []proto.Server {
	var out []proto.Server
	for i, ob := range feed.Outbounds {
		t, _ := ob["type"].(string)
		var p proto.Protocol
		switch strings.ToLower(t) {
		case "vless":
			p = proto.ProtoVLESS
		case "hysteria2":
			p = proto.ProtoHysteria2
		case "shadowsocks":
			p = proto.ProtoShadowsocks
		case "naive":
			p = proto.ProtoNaive
		case "wireguard":
			p = proto.ProtoAmneziaWG
		default:
			continue
		}
		groups := CandidateGroups(ob)
		if len(groups) == 0 {
			continue // no membership → unusable by any smart group
		}
		tag, _ := ob["tag"].(string)
		server, _ := ob["server"].(string)
		port := portFromString(ob["server_port"])
		if port == 0 {
			port = portFromString(ob["port"])
		}
		name := tag
		if name == "" {
			name = fmt.Sprintf("%s://%s:%d", p, server, port)
		}
		fp := fmt.Sprint(i, server, port, name)
		s := proto.Server{
			ID:             serverID("candidates", strings.ToLower(t), server, fp),
			Name:           name,
			Protocol:       p,
			Address:        server,
			Port:           port,
			Tag:            tag,
			SubscriptionID: CandidateSubID,
			Category:       "candidate",
			GroupTag:       groups[0],
			Raw:            ob,
		}
		out = append(out, s)
	}
	return out
}

// CandidateSubID is the synthetic subscription id all provider candidates are
// stored under. It never appears in the subscriptions list.
const CandidateSubID = "provider-candidates"
