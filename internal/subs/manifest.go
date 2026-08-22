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

// NodeFilter matches servers based on tag pattern or country.
type NodeFilter struct {
	TagContains []string `json:"tag_contains,omitempty"` // match if server tag/name contains any of these
	Country     string   `json:"country,omitempty"`
	AllNodes    bool     `json:"all_nodes,omitempty"`
}

// resolveGroupNodes resolves a manifest group's node references to actual servers.
func resolveGroupNodes(group proto.ManifestGroup, rawServers []proto.Server) []proto.ManifestNode {
	if len(group.Nodes) > 0 {
		return group.Nodes // explicit node refs
	}
	// If group has a filter, apply it
	var nodes []proto.ManifestNode
	for _, srv := range rawServers {
		if matchGroupFilter(group, srv) {
			nodes = append(nodes, proto.ManifestNode{ID: srv.ID})
		}
	}
	return nodes
}

func matchGroupFilter(group proto.ManifestGroup, srv proto.Server) bool {
	// Explicit membership wins first: candidate nodes carry their group ids
	// in Raw (mosaic_candidate_groups) resolved at merge time into GroupTag.
	if srv.Category == "candidate" {
		groups := CandidateGroups(srv.Raw)
		if len(groups) > 0 {
			for _, g := range groups {
				if strings.EqualFold(g, group.ID) {
					return true
				}
			}
			// rg-all / auto groups with no country still take every candidate
			// whose membership list is non-empty.
			switch group.ID {
			case "rg-all":
				return true
			case "auto-stable", "auto-speed", "auto-lte", "auto-whitelist":
				return containsFold(groups, group.ID) || candidateFlagMatches(group.ID, srv.Raw)
			}
			// Named country groups (germany, canada, ...) match the
			// candidate's mosaic_country annotation.
			if cc := groupCountryFromID(group.ID); cc != "" {
				if mcc, _ := srv.Raw["mosaic_country"].(string); strings.EqualFold(mcc, cc) {
					return true
				}
			}
		}
	}

	// Category-based matching as fallback
	switch group.Category {
	case "whitelist":
		nameLower := strings.ToLower(srv.Name + " " + srv.Tag)
		return strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") || strings.Contains(nameLower, "tspu") || srv.Protocol == "vless"
	case "smart":
		// Country-based matching from group ID suffix
		cc := groupCountryFromID(group.ID)
		if cc == "" {
			return true
		} // rg-all → all nodes
		return strings.EqualFold(srv.Country, cc) || matchServerCountryTag(srv, cc)
	}
	return true
}

// containsFold reports whether list contains s, case-insensitive.
func containsFold(list []string, s string) bool {
	for _, v := range list {
		if strings.EqualFold(v, s) {
			return true
		}
	}
	return false
}

// boolFlag reads a boolean annotation from a candidate's Raw outbound map.
func boolFlag(raw map[string]any, key string) bool {
	if raw == nil {
		return false
	}
	b, _ := raw[key].(bool)
	return b
}

// BoolFlag is the exported form of boolFlag for backends that need to read
// candidate annotations without reaching into internals.
func BoolFlag(raw map[string]any, key string) bool { return boolFlag(raw, key) }

// MatchWhitelistHeuristic reports whether a server qualifies for the
// whitelist/ТСПУ bypass group: Reality VLESS, or explicit whitelist/4g/tspu
// markers in its name or tag.
func MatchWhitelistHeuristic(srv proto.Server) bool {
	nameLower := strings.ToLower(srv.Name + " " + srv.Tag)
	return strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") ||
		strings.Contains(nameLower, "tspu") || srv.Protocol == proto.ProtoVLESS
}

// MatchLTEHeuristic reports whether a server fits the Free LTE (mobile
// carrier whitelist bypass) group.
func MatchLTEHeuristic(srv proto.Server) bool {
	if boolFlag(srv.Raw, "mosaic_lte") {
		return true
	}
	return containsAnyFold(srv.Name+" "+srv.Tag+" "+srv.GroupTag, "lte", "4g", "mobile", "tspu")
}

// containsAnyFold reports whether s contains any of the tokens.
func containsAnyFold(s string, tokens ...string) bool {
	lower := strings.ToLower(s)
	for _, t := range tokens {
		if strings.Contains(lower, t) {
			return true
		}
	}
	return false
}

// candidateFlagMatches honours the provider's boolean annotations for the
// quality-based smart groups.
func candidateFlagMatches(groupID string, raw map[string]any) bool {
	switch groupID {
	case "auto-stable":
		b, _ := raw["mosaic_stable"].(bool)
		return b
	case "auto-speed":
		b, _ := raw["mosaic_speed_eligible"].(bool)
		return b
	case "auto-lte":
		s, _ := raw["mosaic_lte"].(bool)
		return s
	case "auto-whitelist":
		_, ok := raw["mosaic_whitelist"]
		if !ok {
			return false
		}
		b, _ := raw["mosaic_whitelist"].(bool)
		return b
	}
	return false
}

// matchServerCountryTag checks a server's name/tag for an explicit country
// token like [DE] or de- so candidates without GeoIP still land correctly.
func matchServerCountryTag(srv proto.Server, cc string) bool {
	nameLower := strings.ToLower(srv.Name + " " + srv.Tag + " " + srv.GroupTag)
	tok := strings.ToLower(cc)
	for _, part := range strings.FieldsFunc(nameLower, func(r rune) bool {
		return r == ' ' || r == '-' || r == '_' || r == '[' || r == ']' || r == '|' || r == ':'
	}) {
		if part == tok {
			return true
		}
	}
	return false
}

func groupCountryFromID(id string) string {
	lower := strings.ToLower(id)
	// Named country groups from the provider manifest (germany, canada, ...)
	for name, cc := range namedCountryGroups {
		if strings.Contains(lower, name) {
			return cc
		}
	}
	// extract 2-letter country from group ID like "auto-de", "auto-nl"
	if len(id) >= 2 {
		suffix := id[len(id)-2:]
		switch strings.ToUpper(suffix) {
		case "DE", "NL", "US", "RU", "CA", "FR", "SG", "GB", "FI":
			return strings.ToUpper(suffix)
		}
	}
	return ""
}

// namedCountryGroups maps provider group-id fragments to ISO countries.
var namedCountryGroups = map[string]string{
	"germany":     "DE",
	"deutschland": "DE",
	"netherlands": "NL",
	"holland":     "NL",
	"usa":         "US",
	"united-states": "US",
	"america":     "US",
	"canada":      "CA",
	"france":      "FR",
	"britain":     "GB",
	"uk-":         "GB",
	"england":     "GB",
	"russia":      "RU",
	"singapore":   "SG",
	"finland":     "FI",
}

// GroupCountry is the exported form of groupCountryFromID for backends that
// resolve a manifest group's target country without reaching into internals.
func GroupCountry(id string) string { return groupCountryFromID(id) }

// deriveManifestURL converts a subscription URL to its manifest endpoint.
// e.g. https://sub.zxc1x1.ru/api/sub/{token} → https://sub.zxc1x1.ru/api/manifest.json
func deriveManifestURL(subURL string) string {
	u, err := url.Parse(subURL)
	if err != nil {
		return ""
	}
	u.Path = "/api/manifest.json"
	u.RawQuery = ""
	return u.String()
}

// FetchProviderManifest attempts to download the provider's JSON manifest.
// Returns nil manifest and nil error if not available (caller falls back to synth).
func FetchProviderManifest(ctx context.Context, subURL string) (*proto.SubscriptionManifest, error) {
	manifestURL := deriveManifestURL(subURL)
	if manifestURL == "" {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, "GET", manifestURL, nil)
	if err != nil {
		return nil, nil
	}
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, nil // silent fallback
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, nil
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil
	}
	var m proto.SubscriptionManifest
	if json.Unmarshal(body, &m) == nil && len(m.Groups) > 0 {
		return &m, nil
	}
	return nil, nil
}

// ParseManifestOrSynthesize parses a JSON manifest or auto-generates Smart Virtual Groups
// for a set of raw physical servers.
func ParseManifestOrSynthesize(content []byte, subID string, rawServers []proto.Server) (proto.SubscriptionManifest, []proto.Server) {
	var manifest proto.SubscriptionManifest

	// Attempt JSON manifest parse
	if len(content) > 0 && json.Unmarshal(content, &manifest) == nil && len(manifest.Groups) > 0 {
		for i := range manifest.Groups {
			manifest.Groups[i].Nodes = resolveGroupNodes(manifest.Groups[i], rawServers)
		}
		virtualServers := BuildVirtualServersFromManifest(manifest, subID)
		allServers := append(virtualServers, rawServers...)
		return manifest, allServers
	}

	// Synthesize Smart Virtual Groups automatically
	manifest = SynthesizeManifest(subID, rawServers)
	virtualServers := BuildVirtualServersFromManifest(manifest, subID)
	allServers := append(virtualServers, rawServers...)
	return manifest, allServers
}

// SynthesizeManifest generates default smart groups & whitelist evader route for raw servers.
func SynthesizeManifest(subID string, rawServers []proto.Server) proto.SubscriptionManifest {
	var allNodes []proto.ManifestNode
	var whitelistNodes []proto.ManifestNode
	var deNodes, nlNodes, usNodes, ruNodes, caNodes, frNodes, sgNodes, gbNodes, fiNodes []proto.ManifestNode

	for _, srv := range rawServers {
		node := proto.ManifestNode{ID: srv.ID}
		allNodes = append(allNodes, node)

		cc := strings.ToUpper(srv.Country)
		nameLower := strings.ToLower(srv.Name + " " + srv.Tag)

		// Whitelist evader heuristic (VLESS Reality / whitelist SNI / mobile tags)
		if strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") || strings.Contains(nameLower, "tspu") || srv.Protocol == "vless" {
			whitelistNodes = append(whitelistNodes, node)
		}

		switch cc {
		case "DE":
			deNodes = append(deNodes, node)
		case "NL":
			nlNodes = append(nlNodes, node)
		case "US":
			usNodes = append(usNodes, node)
		case "RU":
			ruNodes = append(ruNodes, node)
		case "CA":
			caNodes = append(caNodes, node)
		case "FR":
			frNodes = append(frNodes, node)
		case "SG":
			sgNodes = append(sgNodes, node)
		case "GB":
			gbNodes = append(gbNodes, node)
		case "FI":
			fiNodes = append(fiNodes, node)
		}
	}

	if len(whitelistNodes) == 0 {
		whitelistNodes = allNodes
	}

	// Quality-based smart groups operate on candidate nodes only: they rank
	// provider-verified free-pool entries by stability/speed/mobile traits.
	var stableNodes, speedNodes, lteNodes []proto.ManifestNode
	for _, srv := range rawServers {
		node := proto.ManifestNode{ID: srv.ID}
		switch {
		case srv.Category == "candidate" && boolFlag(srv.Raw, "mosaic_stable"):
			stableNodes = append(stableNodes, node)
		case srv.Category == "candidate" && boolFlag(srv.Raw, "mosaic_speed_eligible"):
			speedNodes = append(speedNodes, node)
		case boolFlag(srv.Raw, "mosaic_lte") || containsAnyFold(srv.Name+" "+srv.Tag, "lte", "4g", "mobile"):
			lteNodes = append(lteNodes, node)
		}
	}

	groups := []proto.ManifestGroup{
		{
			ID:          "rg-all",
			Title:       "⚡️ Минимальный пинг (Авто)",
			Type:        "urltest",
			Nodes:       allNodes,
			UserTier:    proto.TierFree,
			Badge:       "Оптимально",
			Category:    "smart",
			Icon:        "lightning",
			Description: "Автоматический выбор наибыстрейшего сервера с наименьшей задержкой",
		},
		{
			ID:          "auto-whitelist",
			Title:       "🛡 Обход белых списков (РФ 4G / ТСПУ)",
			Type:        "urltest",
			Nodes:       whitelistNodes,
			UserTier:    proto.TierFree,
			Badge:       "Защита 4G",
			Category:    "whitelist",
			Icon:        "shield",
			Description: "Специальный маршрут VLESS Reality через SNI разрешённых гос-сервисов и банков РФ",
		},
	}
	if len(stableNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:          "auto-stable",
			Title:       "🛡 Стабильность",
			Type:        "urltest",
			Nodes:       stableNodes,
			UserTier:    proto.TierFree,
			Badge:       "Рекомендуется",
			Category:    "smart",
			Icon:        "verified",
			Description: "Узлы с высоким показателем успешных подключений",
		})
	}
	if len(speedNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:          "auto-speed",
			Title:       "🚀 Максимальная скорость",
			Type:        "urltest",
			Nodes:       speedNodes,
			UserTier:    proto.TierFree,
			Badge:       "Турбо",
			Category:    "smart",
			Icon:        "speed",
			Description: "Узлы с измеренной высокой пропускной способностью",
		})
	}
	if len(lteNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:          "auto-lte",
			Title:       "📱 Free LTE (обход цензуры)",
			Type:        "urltest",
			Nodes:       lteNodes,
			UserTier:    proto.TierFree,
			Badge:       "4G",
			Category:    "whitelist",
			Icon:        "signal_cellular_alt",
			Description: "Маршруты для мобильных операторов с белыми списками",
		})
	}

	if len(deNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-de",
			Title:    "🇩🇪 Германия",
			Type:     "urltest",
			Nodes:    deNodes,
			UserTier: proto.TierFree,
			Badge:    "EU Fast",
			Category: "smart",
			Icon:     "flag_de",
		})
	}
	if len(nlNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-nl",
			Title:    "🇳🇱 Нидерланды",
			Type:     "urltest",
			Nodes:    nlNodes,
			UserTier: proto.TierFree,
			Badge:    "P2P / Torrent",
			Category: "smart",
			Icon:     "flag_nl",
		})
	}
	if len(usNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-us",
			Title:    "🇺🇸 США",
			Type:     "urltest",
			Nodes:    usNodes,
			UserTier: proto.TierPro,
			Badge:    "PRO Stream",
			Category: "smart",
			Icon:     "flag_us",
		})
	}
	if len(caNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-ca",
			Title:    "🇨🇦 Канада",
			Type:     "urltest",
			Nodes:    caNodes,
			UserTier: proto.TierFree,
			Badge:    "NA Fast",
			Category: "smart",
			Icon:     "flag_ca",
		})
	}
	if len(frNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-fr",
			Title:    "🇫🇷 Франция",
			Type:     "urltest",
			Nodes:    frNodes,
			UserTier: proto.TierFree,
			Badge:    "EU Low Ping",
			Category: "smart",
			Icon:     "flag_fr",
		})
	}
	if len(sgNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-sg",
			Title:    "🇸🇬 Сингапур",
			Type:     "urltest",
			Nodes:    sgNodes,
			UserTier: proto.TierPro,
			Badge:    "Asia Fast",
			Category: "smart",
			Icon:     "flag_sg",
		})
	}
	if len(gbNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-gb",
			Title:    "🇬🇧 Великобритания",
			Type:     "urltest",
			Nodes:    gbNodes,
			UserTier: proto.TierFree,
			Badge:    "UK Fast",
			Category: "smart",
			Icon:     "flag_gb",
		})
	}
	if len(fiNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-fi",
			Title:    "🇫🇮 Финляндия",
			Type:     "urltest",
			Nodes:    fiNodes,
			UserTier: proto.TierFree,
			Badge:    "Nordic Fast",
			Category: "smart",
			Icon:     "flag_fi",
		})
	}
	if len(ruNodes) > 0 {
		groups = append(groups, proto.ManifestGroup{
			ID:       "auto-ru",
			Title:    "🇷🇺 Россия",
			Type:     "urltest",
			Nodes:    ruNodes,
			UserTier: proto.TierFree,
			Badge:    "Local Low Ping",
			Category: "smart",
			Icon:     "flag_ru",
		})
	}

	return proto.SubscriptionManifest{
		ProviderName: "Mosaic Direct Node Routing Engine",
		UserTier:     proto.TierFree,
		Groups:       groups,
	}
}

// BuildVirtualServersFromManifest converts manifest groups to proto.Server virtual group entries.
func BuildVirtualServersFromManifest(manifest proto.SubscriptionManifest, subID string) []proto.Server {
	var list []proto.Server
	for _, g := range manifest.Groups {
		srv := proto.Server{
			ID:             fmt.Sprintf("group-%s", g.ID),
			Name:           g.Title,
			Protocol:       "vless",
			Address:        "127.0.0.1",
			Port:           443,
			SubscriptionID: subID,
			IsVirtualGroup: true,
			Category:       g.Category,
			GroupTag:       g.ID,
			OutboundTag:    g.ID,
			Tag:            g.Badge,
		}
		if cc := groupCountryFromID(g.ID); cc != "" {
			srv.Country = cc
		}
		list = append(list, srv)
	}
	return list
}
