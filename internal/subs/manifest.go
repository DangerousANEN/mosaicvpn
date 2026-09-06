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
			if group.ID == "max-speed" {
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
	// Smart Groups select only daemon-side client candidates. The ordinary
	// subscription profile is reserved for the explicit direct route and must
	// never be included in a client-side selection pool.
	if group.Category == "smart" && !boolRaw(srv, "mosaic_client_candidate") {
		return false
	}
	// Mosaic's direct pool optionally includes opaque, aggregate selection hints.
	// Their presence takes precedence; ordinary third-party subscriptions retain
	// the legacy heuristic below for backwards compatibility.
	switch group.ID {
	case "auto-stable", "stable":
		if stable, present := boolHint(srv, "mosaic_stable"); present {
			return stable
		}
		return true
	case "auto-speed", "max-speed":
		if eligible, present := boolHint(srv, "mosaic_speed_eligible"); present {
			return eligible
		}
		return true
	case "auto-allowlist":
		if allowed, present := boolHint(srv, "mosaic_allowlist"); present {
			return allowed
		}
	}
	// Provider-annotated membership (mosaic_group_ids / mosaic_candidate_groups)
	// wins for every named smart group before heuristics are consulted. The
	// collector publishes ids like "germany", "canada", "netherlands" and the
	// local manifest uses the same names, so an exact match is sufficient.
	if ids := candidateGroupMemberships(srv); ids != nil {
		if _, ok := ids[group.ID]; ok {
			return true
		}
	}

	// Category-based matching as fallback.
	switch group.Category {
	case "direct":
		// A public direct route must be explicit. Do not fall back to all
		// subscription nodes: that could silently turn a direct row into a view
		// of the daemon-only candidate pool.
		if group.DirectPath != "" {
			path, _ := srv.Raw["path"].(string)
			return path == group.DirectPath && !boolRaw(srv, "mosaic_client_candidate")
		}
		country := group.CountryCode
		if country == "" {
			country = groupCountryFromID(group.ID)
		}
		return country != "" && strings.EqualFold(srv.Country, country)
	case "whitelist":
		nameLower := strings.ToLower(srv.Name + " " + srv.Tag)
		return strings.Contains(nameLower, "whitelist") || strings.Contains(nameLower, "4g") || strings.Contains(nameLower, "tspu") || srv.Protocol == "vless"
	case "smart":
		// Country metadata takes precedence. ID suffix is a compatibility
		// fallback for already issued third-party manifests.
		cc := group.CountryCode
		if cc == "" {
			cc = groupCountryFromID(group.ID)
		}
		if cc == "" {
			return true
		} // rg-all → all nodes
		return strings.EqualFold(srv.Country, cc)
	}
	return true
}

func boolRaw(srv proto.Server, key string) bool {
	value, _ := srv.Raw[key].(bool)
	return value
}

// candidateGroupMemberships returns the provider-published group id set for a
// candidate node (Raw.mosaic_group_ids or the legacy mosaic_candidate_groups).
// Returns nil when the node carries no membership annotations.
func candidateGroupMemberships(srv proto.Server) map[string]struct{} {
	for _, key := range []string{"mosaic_group_ids", "mosaic_candidate_groups"} {
		list, ok := srv.Raw[key].([]any)
		if !ok || len(list) == 0 {
			continue
		}
		ids := make(map[string]struct{}, len(list))
		for _, raw := range list {
			s, _ := raw.(string)
			if s != "" {
				ids[s] = struct{}{}
			}
		}
		if len(ids) > 0 {
			return ids
		}
	}
	return nil
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
	case "auto-stable", "stable":
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

// deriveCandidateFeedURL derives the daemon-only candidate endpoint from one
// Mosaic subscription URL. The opaque subscription token stays in the path so
// the provider can validate the same capability as the ordinary feed.
func deriveCandidateFeedURL(subURL string) string {
	u, err := url.Parse(subURL)
	if err != nil || u.Host == "" {
		return ""
	}
	token := strings.Trim(strings.TrimSpace(u.Path), "/")
	if token == "" || strings.Contains(token, "/") {
		return ""
	}
	u.Path = "/api/client-candidates/" + url.PathEscape(token)
	u.RawQuery = ""
	return u.String()
}

// FetchClientCandidates downloads a bounded sing-box feed used only by the
// local Mosaic daemon for Smart Group ranking and failover. Its physical
// profiles never become ordinary UI route rows.
func FetchClientCandidates(ctx context.Context, subURL, subID string) ([]proto.Server, error) {
	feedURL := deriveCandidateFeedURL(subURL)
	if feedURL == "" {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "MosaicVPN-daemon/1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("candidate feed: unexpected HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if err != nil {
		return nil, err
	}
	parsed, err := ParseAs(subID, body, proto.FormatSingbox)
	if err != nil {
		return nil, fmt.Errorf("candidate feed: %w", err)
	}
	// Mark every physical profile from the hidden candidate feed so the store
	// counter and the UI route lists can exclude them from user-visible
	// counts. Smart Group resolution still reads them via Raw.
	for i := range parsed.Servers {
		if parsed.Servers[i].Raw == nil {
			parsed.Servers[i].Raw = map[string]any{}
		}
		parsed.Servers[i].Raw["mosaic_client_candidate"] = true
	}
	return parsed.Servers, nil
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

// ParseManifestOrSynthesize parses an explicit provider manifest. A regular
// imported feed remains a collection of its own raw nodes: it must never be
// decorated with Mosaic-specific smart groups, labels or routing semantics.
func ParseManifestOrSynthesize(content []byte, subID string, rawServers []proto.Server) (proto.SubscriptionManifest, []proto.Server) {
	var manifest proto.SubscriptionManifest

	// Attempt JSON manifest parse
	if len(content) > 0 && json.Unmarshal(content, &manifest) == nil && manifest.HasRoutes() {
		for i := range manifest.Groups {
			if manifest.Groups[i].PoolID == "" {
				manifest.Groups[i].PoolID = subID
			}
			manifest.Groups[i].Nodes = resolveGroupNodes(manifest.Groups[i], rawServers)
			manifest.Groups[i].SetDefaults()
		}
		for i := range manifest.DirectRoutes {
			if manifest.DirectRoutes[i].PoolID == "" {
				manifest.DirectRoutes[i].PoolID = subID
			}
			manifest.DirectRoutes[i].Nodes = resolveGroupNodes(manifest.DirectRoutes[i], rawServers)
			manifest.DirectRoutes[i].SetDefaults()
		}
		virtualServers := BuildVirtualServersFromManifest(manifest, subID)
		allServers := append(virtualServers, rawServers...)
		return manifest, allServers
	}

	// An arbitrary compatible subscription is not a Mosaic service profile.
	// Returning its raw nodes unchanged avoids injecting Mosaic-branded virtual
	// groups into another provider's source and prevents those groups being
	// rendered as misleading VLESS nodes in the client.
	manifest = proto.SubscriptionManifest{
		ProviderName: "Imported subscription",
		UserTier:     proto.TierFree,
		Groups:       []proto.ManifestGroup{},
	}
	return manifest, rawServers
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

	// The server owns all concrete group metadata and client probing policy.
	// Generic clients render these values as supplied; they do not embed a list
	// of Mosaic group IDs or geo-specific selection rules.
	for i := range groups {
		groups[i].PoolID = subID
		groups[i].SetDefaults()
	}
	// TODO(authorized-lte-compat): This is deliberately disabled until a
	// separately reviewed, owner-authorized profile feed is integrated. Do not
	// add network-evasion logic here; the generic client will render the server
	// metadata and keep disabled groups non-selectable.
	reservedLTE := proto.ManifestGroup{
		ID:             "reserved-lte-compat",
		Title:          "Свободный LTE",
		Type:           "urltest",
		PoolID:         "reserved-lte-compat",
		UserTier:       proto.TierFree,
		Badge:          "Скоро",
		Category:       "compatibility",
		Icon:           "cellular",
		Description:    "Категория зарезервирована для авторизованных профилей совместимости сети.",
		Disabled:       true,
		DisabledReason: "Требуется подключение авторизованного источника профилей.",
		ClientPolicy: proto.ClientSelectionPolicy{
			Mode: "stability",
		},
	}
	reservedLTE.SetDefaults()
	groups = append(groups, reservedLTE)

	return proto.SubscriptionManifest{
		ProviderName: "Mosaic Direct Node Routing Engine",
		UserTier:     proto.TierFree,
		Groups:       groups,
	}
}

// BuildVirtualServersFromManifest converts manifest groups to proto.Server virtual group entries.
func BuildVirtualServersFromManifest(manifest proto.SubscriptionManifest, subID string) []proto.Server {
	var list []proto.Server
	for _, g := range manifest.Routes() {
		protocol := g.Protocol
		if protocol == "" {
			protocol = "vless"
		}
		srv := proto.Server{
			ID:             fmt.Sprintf("group-%s", g.ID),
			Name:           g.Title,
			Protocol:       proto.Protocol(protocol),
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
				"mosaic_route_type":     g.RouteType,
				"mosaic_country_code":   g.CountryCode,
				"mosaic_protocol":       protocol,
				"mosaic_ping_interval":  g.PingInterval,
				"mosaic_max_retries":    g.MaxRetries,
				"mosaic_failover_delay": g.FailoverDelay,
			},
		}
		switch {
		case g.CountryCode != "":
			srv.Country = strings.ToUpper(g.CountryCode)
		default:
			baseID := g.ID
			if idx := strings.LastIndex(baseID, ":"); idx >= 0 {
				baseID = baseID[idx+1:]
			}
			if cc := groupCountryFromID(baseID); cc != "" {
				srv.Country = cc
			}
		}
		list = append(list, srv)
	}
	return list
}
