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
			node := proto.ManifestNode{ID: srv.ID}
			// The optional auto-speed group is a client-side weighted choice.
			// The provider supplies only a recent bounded probe result; the
			// client still performs its own health checks before connecting.
			if group.ID == "auto-speed" {
				if speed, ok := srv.Raw["mosaic_speed_mbps"].(float64); ok && speed > 0 {
					weight := int(speed * 10)
					if weight < 1 {
						weight = 1
					}
					if weight > 100 {
						weight = 100
					}
					node.Weight = weight
				}
			}
			if priority := failoverPriority(group.ID, srv); priority > 0 {
				node.Priority = priority
			}
			nodes = append(nodes, node)
		}
	}
	return nodes
}

func matchGroupFilter(group proto.ManifestGroup, srv proto.Server) bool {
	// Mosaic's direct pool optionally includes opaque, aggregate selection hints.
	// Their presence takes precedence; ordinary third-party subscriptions retain
	// the legacy heuristic below for backwards compatibility.
	switch group.ID {
	case "auto-stable":
		if stable, present := boolHint(srv, "mosaic_stable"); present {
			return stable
		}
		return true
	case "auto-speed":
		if eligible, present := boolHint(srv, "mosaic_speed_eligible"); present {
			return eligible
		}
		return true
	case "auto-allowlist":
		if allowed, present := boolHint(srv, "mosaic_allowlist"); present {
			return allowed
		}
	}

	// Category-based matching as fallback.
	switch group.Category {
	case "whitelist":
		nameLower := strings.ToLower(srv.Name + " " + srv.Tag)
		return strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") || strings.Contains(nameLower, "tspu") || srv.Protocol == "vless"
	case "smart":
		// Country-based matching from group ID suffix.
		cc := groupCountryFromID(group.ID)
		if cc == "" {
			return true
		} // rg-all → all nodes
		return strings.EqualFold(srv.Country, cc)
	}
	return true
}

func boolHint(srv proto.Server, key string) (bool, bool) {
	value, present := srv.Raw[key]
	flag, ok := value.(bool)
	return flag, present && ok
}

func numericHint(srv proto.Server, key string) int {
	value, present := srv.Raw[key]
	if !present {
		return 0
	}
	switch number := value.(type) {
	case float64:
		return int(number)
	case float32:
		return int(number)
	case int:
		return number
	case int64:
		return int(number)
	}
	return 0
}

func failoverPriority(groupID string, srv proto.Server) int {
	switch groupID {
	case "auto-stable":
		return numericHint(srv, "mosaic_stable_priority")
	case "auto-allowlist":
		return numericHint(srv, "mosaic_allowlist_priority")
	default:
		return numericHint(srv, "mosaic_failover_priority")
	}
}

func groupCountryFromID(id string) string {
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
			Raw: map[string]any{
				"mosaic_group_type":     g.Type,
				"mosaic_ping_interval":  g.PingInterval,
				"mosaic_max_retries":    g.MaxRetries,
				"mosaic_failover_delay": g.FailoverDelay,
			},
		}
		switch {
		case strings.Contains(g.ID, "de"):
			srv.Country = "DE"
		case strings.Contains(g.ID, "nl"):
			srv.Country = "NL"
		case strings.Contains(g.ID, "us"):
			srv.Country = "US"
		case strings.Contains(g.ID, "ca"):
			srv.Country = "CA"
		case strings.Contains(g.ID, "fr"):
			srv.Country = "FR"
		case strings.Contains(g.ID, "sg"):
			srv.Country = "SG"
		case strings.Contains(g.ID, "gb"):
			srv.Country = "GB"
		case strings.Contains(g.ID, "fi"):
			srv.Country = "FI"
		case strings.Contains(g.ID, "ru"):
			srv.Country = "RU"
		}
		list = append(list, srv)
	}
	return list
}
