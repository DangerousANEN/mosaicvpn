// Package proto contains the shared data types used across the daemon, CLI,
// and API client. Types are JSON-serializable and represent the canonical
// state of the system as exposed by the daemon API.
package proto

import "time"

// Protocol identifies a VPN/proxy protocol supported by Mosaic.
type Protocol string

const (
	ProtoVLESS       Protocol = "vless"
	ProtoVMess       Protocol = "vmess"
	ProtoTrojan      Protocol = "trojan"
	ProtoHysteria2   Protocol = "hysteria2"
	ProtoNaive       Protocol = "naive"
	ProtoShadowsocks Protocol = "shadowsocks"
	ProtoAmneziaWG   Protocol = "amneziawg"
)

// AllProtocols returns every protocol Mosaic understands.
func AllProtocols() []Protocol {
	return []Protocol{
		ProtoVLESS, ProtoVMess, ProtoTrojan, ProtoHysteria2,
		ProtoNaive, ProtoShadowsocks, ProtoAmneziaWG,
	}
}

// IsKnown reports whether p is a recognised protocol.
func (p Protocol) IsKnown() bool {
	for _, k := range AllProtocols() {
		if k == p {
			return true
		}
	}
	return false
}

// Server represents a single VPN/proxy endpoint that the daemon can connect
// to. Servers live inside Subscriptions.
type Server struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Protocol       Protocol `json:"protocol"`
	Address        string   `json:"address"`
	Port           int      `json:"port"`
	City           string   `json:"city,omitempty"`
	Country        string   `json:"country,omitempty"`
	Tag            string   `json:"tag,omitempty"`
	SubscriptionID string   `json:"subscription_id"`
	IsVirtualGroup bool     `json:"is_virtual_group,omitempty"`
	Category       string   `json:"category,omitempty"` // "smart", "whitelist", "raw"
	GroupTag       string   `json:"group_tag,omitempty"`
	OutboundTag    string   `json:"outbound_tag,omitempty"`
	// LastTestMS is the round-trip time of the most recent probe, in
	// milliseconds. A negative value means the probe failed; LastTestError
	// then carries the reason. Zero means the server has never been probed.
	LastTestMS    int       `json:"last_test_ms,omitempty"`
	LastTestError string    `json:"last_test_error,omitempty"`
	LastTestAt    time.Time `json:"last_test_at,omitempty"`
	// Lat/Lon are decimal degrees (WGS84). Populated from a GeoIP
	// lookup against Address; zero means "not resolved yet".
	Lat float64        `json:"lat,omitempty"`
	Lon float64        `json:"lon,omitempty"`
	Raw map[string]any `json:"raw,omitempty"`
}

// UserTier describes user access privileges.
type UserTier string

const (
	TierFree UserTier = "free"
	TierPro  UserTier = "pro"
	TierVIP  UserTier = "vip"
)

// GroupSource defines the origin of server group nodes.
type GroupSource string

const (
	GroupSourcePool      GroupSource = "pool"
	GroupSourceUser      GroupSource = "user"
	GroupSourceEmergency GroupSource = "emergency"
)

// GroupStrategy defines how a group selects nodes.
type GroupStrategy string

const (
	GroupStrategyURLTest            GroupStrategy = "urltest"
	GroupStrategyWeightedRoundRobin GroupStrategy = "weighted_round_robin"
	GroupStrategyFallback           GroupStrategy = "fallback"
	GroupStrategyDirectNode         GroupStrategy = "direct_node"
)

// GroupCriterion defines the filter/selection criterion for group nodes.
type GroupCriterion string

const (
	GroupCriterionAuto     GroupCriterion = "auto"
	GroupCriterionMinPing  GroupCriterion = "min_ping"
	GroupCriterionLocation GroupCriterion = "location"
	GroupCriterionMinLoad  GroupCriterion = "min_load"
	GroupCriterionMaxSpeed GroupCriterion = "max_speed"
)

// NodeRef references a physical node within a ServerGroup along with load and health telemetry.
type NodeRef struct {
	ServerID  string  `json:"server_id"`
	Weight    int     `json:"weight"`     // 1..100, static weight
	Load      float64 `json:"load"`       // 0..1, current load
	LatencyMs int     `json:"latency_ms"` // last latency probe
	Alive     bool    `json:"alive"`
	LastSeen  int64   `json:"last_seen"` // unix timestamp
	Country   string  `json:"country,omitempty"`
	City      string  `json:"city,omitempty"`
}

// ServerGroup is the unified group entity for user node selection.
type ServerGroup struct {
	ID             string         `json:"id"`
	Title          string         `json:"title"`
	Source         GroupSource    `json:"source"`
	Strategy       GroupStrategy  `json:"strategy"`
	Criterion      GroupCriterion `json:"criterion"`
	CriterionValue string         `json:"criterion_value,omitempty"`
	Nodes          []NodeRef      `json:"nodes"`
	RequiredTier   UserTier       `json:"required_tier,omitempty"`

	// health
	PingInterval  int `json:"ping_interval"`  // sec, default 30
	MaxRetries    int `json:"max_retries"`    // default 3
	FailoverDelay int `json:"failover_delay"` // sec, default 2

	// display
	Badge       string `json:"badge,omitempty"`
	Description string `json:"description,omitempty"`
	Icon        string `json:"icon,omitempty"`
}

// SetDefaults applies default values to ServerGroup health check parameters if unassigned.
func (g *ServerGroup) SetDefaults() {
	if g.PingInterval <= 0 {
		g.PingInterval = 30
	}
	if g.MaxRetries <= 0 {
		g.MaxRetries = 3
	}
	if g.FailoverDelay <= 0 {
		g.FailoverDelay = 2
	}
}

// NewServerGroup creates a new ServerGroup with default health check parameters set.
func NewServerGroup() *ServerGroup {
	g := &ServerGroup{}
	g.SetDefaults()
	return g
}

// ToServerGroup converts a ManifestGroup to a ServerGroup.
func (m ManifestGroup) ToServerGroup() ServerGroup {
	nodes := make([]NodeRef, 0, len(m.Nodes))
	for _, n := range m.Nodes {
		weight := n.Weight
		if weight <= 0 {
			weight = 10
		}
		nodes = append(nodes, NodeRef{
			ServerID: n.ID,
			Weight:   weight,
			Alive:    true,
		})
	}

	g := ServerGroup{
		ID:            m.ID,
		Title:         m.Title,
		Source:        GroupSourceUser,
		Strategy:      GroupStrategy(m.Type),
		Criterion:     GroupCriterionAuto,
		Nodes:         nodes,
		RequiredTier:  m.UserTier,
		PingInterval:  m.PingInterval,
		MaxRetries:    m.MaxRetries,
		FailoverDelay: m.FailoverDelay,
		Badge:         m.Badge,
		Description:   m.Description,
		Icon:          m.Icon,
	}
	g.SetDefaults()
	return g
}

// ManifestNode references a physical node within a group.
type ManifestNode struct {
	ID       string `json:"id"`
	Weight   int    `json:"weight,omitempty"`   // for weighted_round_robin
	Priority int    `json:"priority,omitempty"` // for fallback ordering
}

// SpeedProbePolicy defines bounded HTTPS throughput probes. Endpoints are
// provider-configurable, but all values are clamped before use by the daemon.
type SpeedProbePolicy struct {
	Enabled        bool     `json:"enabled,omitempty"`
	DownloadURLs   []string `json:"download_urls,omitempty"`
	UploadURL      string   `json:"upload_url,omitempty"`
	SampleBytes    int64    `json:"sample_bytes,omitempty"`
	TimeoutSeconds int      `json:"timeout_seconds,omitempty"`
	MaxCandidates  int      `json:"max_candidates,omitempty"`
	TargetMbps     float64  `json:"target_mbps,omitempty"`
}

func (p *SpeedProbePolicy) SetDefaults() {
	if p.SampleBytes <= 0 {
		p.SampleBytes = 2 * 1024 * 1024
	}
	if p.SampleBytes > 8*1024*1024 {
		p.SampleBytes = 8 * 1024 * 1024
	}
	if p.TimeoutSeconds <= 0 {
		p.TimeoutSeconds = 12
	}
	if p.TimeoutSeconds > 30 {
		p.TimeoutSeconds = 30
	}
	if p.MaxCandidates <= 0 {
		p.MaxCandidates = 2
	}
	if p.MaxCandidates > 3 {
		p.MaxCandidates = 3
	}
	if p.TargetMbps <= 0 {
		p.TargetMbps = 50
	}
	if p.TargetMbps > 1000 {
		p.TargetMbps = 1000
	}
}

// SpeedTestRequest is accepted by POST /v1/test/speed. Empty fields use
// daemon defaults, allowing older clients to keep using the endpoint.
type SpeedTestRequest struct {
	Policy *SpeedProbePolicy `json:"policy,omitempty"`
}

// ClientSelectionPolicy is a provider-defined, bounded policy executed by the
// local client runtime. The policy contains no endpoint data: it tells the
// client how to probe and rank the opaque candidate shard for this group.
type ClientSelectionPolicy struct {
	Mode              string           `json:"mode,omitempty"` // latency, stability, speed, weighted, fallback
	ShardSize         int              `json:"shard_size,omitempty"`
	MaxParallelProbes int              `json:"max_parallel_probes,omitempty"`
	ProbeTTLSeconds   int              `json:"probe_ttl_seconds,omitempty"`
	MaxFailoverTries  int              `json:"max_failover_tries,omitempty"`
	LatencyWeight     float64          `json:"latency_weight,omitempty"`
	LossWeight        float64          `json:"loss_weight,omitempty"`
	StabilityWeight   float64          `json:"stability_weight,omitempty"`
	SpeedWeight       float64          `json:"speed_weight,omitempty"`
	SpeedProbe        SpeedProbePolicy `json:"speed_probe,omitempty"`
}

func (p *ClientSelectionPolicy) SetDefaults() {
	if p.Mode == "" {
		p.Mode = "latency"
	}
	if p.ShardSize <= 0 {
		p.ShardSize = 16
	}
	if p.ShardSize > 32 {
		p.ShardSize = 32
	}
	if p.MaxParallelProbes <= 0 {
		p.MaxParallelProbes = 4
	}
	if p.MaxParallelProbes > 8 {
		p.MaxParallelProbes = 8
	}
	if p.ProbeTTLSeconds <= 0 {
		p.ProbeTTLSeconds = 600
	}
	if p.MaxFailoverTries <= 0 {
		p.MaxFailoverTries = 3
	}
	if p.LatencyWeight == 0 && p.LossWeight == 0 && p.StabilityWeight == 0 && p.SpeedWeight == 0 {
		p.LatencyWeight = 0.45
		p.LossWeight = 0.30
		p.StabilityWeight = 0.25
	}
	p.SpeedProbe.SetDefaults()
}

// ManifestGroup defines an admin-managed route/group in the subscription manifest.
type ManifestGroup struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	// RouteType is the generic UI/API type (normally "smart_group"). Strategy
	// remains a separate implementation detail so the client never presents
	// urltest/fallback as a user-visible protocol.
	RouteType      string                `json:"route_type,omitempty"`
	Type           string                `json:"type"` // runtime strategy: urltest, fallback, weighted_round_robin, direct_node
	PoolID         string                `json:"pool_id,omitempty"`
	Nodes          []ManifestNode        `json:"nodes"`
	UserTier       UserTier              `json:"user_tier,omitempty"`
	Badge          string                `json:"badge,omitempty"`
	Category       string                `json:"category,omitempty"`
	Icon           string                `json:"icon,omitempty"`
	Description    string                `json:"description,omitempty"`
	Disabled       bool                  `json:"disabled,omitempty"`
	DisabledReason string                `json:"disabled_reason,omitempty"`
	ClientPolicy   ClientSelectionPolicy `json:"client_policy,omitempty"`
	PingInterval   int                   `json:"ping_interval,omitempty"`
	MaxRetries     int                   `json:"max_retries,omitempty"`
	FailoverDelay  int                   `json:"failover_delay,omitempty"`
}

// SetDefaults bounds policy settings coming from any provider manifest so an
// arbitrary remote feed cannot turn the client into an unbounded prober.
func (m *ManifestGroup) SetDefaults() {
	if m.RouteType == "" {
		m.RouteType = "smart_group"
	}
	m.ClientPolicy.SetDefaults()
	if m.PingInterval <= 0 {
		m.PingInterval = 30
	}
	if m.MaxRetries <= 0 {
		m.MaxRetries = 3
	}
	if m.FailoverDelay <= 0 {
		m.FailoverDelay = 2
	}
}

// SubscriptionManifest is the provider-controlled routing & load-balancing manifest.
// CandidateShard is a bounded, deterministic subset of a smart group's
// eligible candidates. It is served only by the user's local daemon: Flutter
// receives opaque IDs and never needs pool endpoint details to rank them.
type CandidateShard struct {
	GroupID      string    `json:"group_id"`
	Version      string    `json:"version"`
	ExpiresAt    time.Time `json:"expires_at"`
	CandidateIDs []string  `json:"candidate_ids"`
}

// CandidateProbeRequest asks the local daemon to make a small transport-level
// probe from the user's real network. It deliberately accepts an opaque ID,
// so pool profiles do not enter the UI state tree.
type CandidateProbeRequest struct {
	CandidateID string `json:"candidate_id"`
}

// CandidateProbeResult is local quality evidence used by the desktop/mobile
// client to rank one candidate. Protocol-level probes may extend this model in
// a later runtime version; the initial implementation is transport liveness.
type CandidateProbeResult struct {
	GroupID         string    `json:"group_id"`
	CandidateID     string    `json:"candidate_id"`
	Successful      bool      `json:"successful"`
	Samples         int       `json:"samples"`
	Successes       int       `json:"successes"`
	LossPercent     float64   `json:"loss_percent"`
	MedianLatencyMs int       `json:"median_latency_ms"`
	P95LatencyMs    int       `json:"p95_latency_ms"`
	JitterMs        int       `json:"jitter_ms"`
	CheckedAt       time.Time `json:"checked_at"`
	ProbeKind       string    `json:"probe_kind"`
}

// SubscriptionManifest is the provider-controlled routing & load-balancing manifest.
type SubscriptionManifest struct {
	ProviderName string           `json:"provider_name,omitempty"`
	UserTier     UserTier         `json:"user_tier,omitempty"`
	TelemetryURL string           `json:"telemetry_url,omitempty"`
	Groups       []ManifestGroup  `json:"groups"`
	Rules        []Rule           `json:"routing_rules,omitempty"`
	Profile      *ProviderProfile `json:"profile,omitempty"`
}

// SubscriptionSource distinguishes provider-owned route catalogs from an
// ordinary user-imported source. The distinction controls visibility and
// account capabilities; it must never be inferred from a display name.
type SubscriptionSource string

const (
	SubscriptionSourceLocal    SubscriptionSource = "local"
	SubscriptionSourceProvider SubscriptionSource = "provider"
)

// ProviderAccount is a non-secret account descriptor. Credentials are kept by
// each platform's secure storage; this record only connects an account to its
// provider-owned subscriptions and capability manifest.
type ProviderAccount struct {
	ID           string          `json:"id"`
	ProviderID   string          `json:"provider_id"`
	DisplayName  string          `json:"display_name"`
	IssuerURL    string          `json:"issuer_url,omitempty"`
	Username     string          `json:"username,omitempty"`
	Capabilities map[string]bool `json:"capabilities,omitempty"`
	LastSync     time.Time       `json:"last_sync,omitempty"`
	LastError    string          `json:"last_error,omitempty"`
}

// ProviderProfile is the provider-defined UI/branding/billing/services manifest section.
type ProviderProfile struct {
	Branding ProviderBranding  `json:"branding"`
	Billing  *ProviderBilling  `json:"billing,omitempty"`
	Services []ProviderService `json:"services,omitempty"`
	Widgets  []ProviderWidget  `json:"widgets,omitempty"`
}

type ProviderBranding struct {
	LogoURL             string `json:"logo_url,omitempty"`
	AccentColor         string `json:"accent_color,omitempty"`
	SupportURL          string `json:"support_url,omitempty"`
	ProviderDescription string `json:"provider_description,omitempty"`
}

type ProviderBilling struct {
	Type           string             `json:"type"` // "telegram_bot"
	BotUsername    string             `json:"bot_username,omitempty"`
	PricingModel   string             `json:"pricing_model"`
	PricePerDay    map[string]float64 `json:"price_per_day,omitempty"`
	TrialDays      int                `json:"trial_days,omitempty"`
	PaymentMethods []string           `json:"payment_methods"`
	Endpoints      map[string]string  `json:"endpoints"`
}

type ProviderService struct {
	ID          string         `json:"id"`
	Type        string         `json:"type"` // proxy_picker, value_display, action, web_view, link
	Title       string         `json:"title"`
	Description string         `json:"description,omitempty"`
	Icon        string         `json:"icon,omitempty"`
	Config      map[string]any `json:"config"`
}

type ProviderWidget struct {
	ID         string   `json:"id"`
	Type       string   `json:"type"` // stats_card, progress_bar
	Title      string   `json:"title"`
	DataSource string   `json:"data_source"`
	Fields     []string `json:"fields"`
}

// Format identifies a subscription payload format.
type Format string

const (
	FormatSingbox  Format = "singbox"
	FormatClash    Format = "clash"
	FormatV2RayB64 Format = "v2ray-base64"
	FormatSIP008   Format = "sip008"
	FormatUnknown  Format = "unknown"
)

// Subscription is a remote source of Servers, periodically fetched and
// re-parsed.
type Subscription struct {
	ID                     string             `json:"id"`
	Name                   string             `json:"name"`
	URL                    string             `json:"url"`
	Format                 Format             `json:"format"`
	LastFetched            time.Time          `json:"last_fetched,omitempty"`
	LastError              string             `json:"last_error,omitempty"`
	AutoRefresh            bool               `json:"auto_refresh"`
	RefreshIntervalSeconds int                `json:"refresh_interval_seconds"`
	ServerCount            int                `json:"server_count"`
	Source                 SubscriptionSource `json:"source,omitempty"`
	ProviderID             string             `json:"provider_id,omitempty"`
	ProviderAccountID      string             `json:"provider_account_id,omitempty"`
	// HidePhysicalNodes prevents a provider's protected pool from being
	// rendered as ordinary user-selectable rows. Manifest Smart Groups remain
	// visible because they are virtual route entries with explicit policy.
	HidePhysicalNodes bool `json:"hide_physical_nodes,omitempty"`
}

// Action is the verdict a routing rule produces when it matches a flow.
type Action string

const (
	ActionProxy  Action = "proxy"
	ActionDirect Action = "direct"
	ActionBlock  Action = "block"
)

// Logic combines multiple match conditions in a Rule.
type Logic string

const (
	LogicAnd Logic = "and"
	LogicOr  Logic = "or"
)

// Match describes the conditions that select traffic for a Rule.
type Match struct {
	Logic         Logic    `json:"logic"`
	GeoSite       []string `json:"geosite,omitempty"`
	GeoIP         []string `json:"geoip,omitempty"`
	DomainSuffix  []string `json:"domain_suffix,omitempty"`
	DomainKeyword []string `json:"domain_keyword,omitempty"`
	Domain        []string `json:"domain,omitempty"`
	IPCIDR        []string `json:"ip_cidr,omitempty"`
	Process       []string `json:"process,omitempty"`
	Port          []string `json:"port,omitempty"`
}

// Empty reports whether the match has no conditions configured.
func (m Match) Empty() bool {
	return len(m.GeoSite) == 0 && len(m.GeoIP) == 0 && len(m.DomainSuffix) == 0 &&
		len(m.DomainKeyword) == 0 && len(m.Domain) == 0 && len(m.IPCIDR) == 0 &&
		len(m.Process) == 0 && len(m.Port) == 0
}

// Rule is a routing rule entry. Rules are evaluated in priority order; the
// first match wins.
type Rule struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Priority int    `json:"priority"`
	Enabled  bool   `json:"enabled"`
	Action   Action `json:"action"`
	Target   string `json:"target,omitempty"`
	Match    Match  `json:"match"`
}

// State is the current daemon connection state.
type State string

const (
	StateDisconnected State = "disconnected"
	StateConnecting   State = "connecting"
	StateConnected    State = "connected"
	StateError        State = "error"
)

// Status is the aggregate runtime state exposed by the daemon API.
type Status struct {
	State          State     `json:"state"`
	Server         *Server   `json:"server,omitempty"`
	Since          time.Time `json:"since,omitempty"`
	LastError      string    `json:"last_error,omitempty"`
	LatencyMS      int       `json:"latency_ms,omitempty"`
	BytesIn        uint64    `json:"bytes_in"`
	BytesOut       uint64    `json:"bytes_out"`
	TunnelMode     string    `json:"tunnel_mode"`
	KillSwitch     bool      `json:"kill_switch"`
	AgentConnected bool      `json:"agent_connected"`
	DaemonVersion  string    `json:"daemon_version"`
	DaemonPID      int       `json:"daemon_pid"`
	// ProxySOCKS / ProxyHTTP are the loopback listeners exposed by the
	// active backend (e.g. "127.0.0.1:2080" / "127.0.0.1:2081"). Empty
	// when the backend is the mock or no proxy listener is active.
	ProxySOCKS string `json:"proxy_socks,omitempty"`
	ProxyHTTP  string `json:"proxy_http,omitempty"`
}

// ConnectRequest tells the daemon to bring up a server.
type ConnectRequest struct {
	// ServerID pins one specific node. Takes precedence over GroupID.
	ServerID string `json:"server_id"`
	// GroupID asks the daemon to pick the best node inside that group. When
	// both fields are empty the daemon walks the full priority chain.
	GroupID string `json:"group_id,omitempty"`
}

// ConnectResponse is the /v1/connect body: the resulting status with the
// resolver's decision embedded.
//
// Status is embedded rather than nested under a "status" key because existing
// clients (CLI, Flutter, Tauri) decode this response straight into Status.
// Nesting it would silently break every one of them.
type ConnectResponse struct {
	Status
	// ResolvedVia names the priority-chain step that produced the node.
	ResolvedVia string `json:"resolved_via,omitempty"`
	// GroupID is the group the node came from.
	GroupID string `json:"group_id,omitempty"`
	// Degraded is true when a more preferred option was unavailable, so the UI
	// can show a fall back to the emergency group instead of presenting it as
	// a normal connection.
	Degraded bool `json:"degraded,omitempty"`
	// Notes explain any downgrade in user-facing language.
	Notes []string `json:"notes,omitempty"`
}

// AddSubscriptionRequest adds a new subscription.
type AddSubscriptionRequest struct {
	URL    string `json:"url"`
	Name   string `json:"name,omitempty"`
	Format Format `json:"format,omitempty"` // optional override; auto-detected if empty
}

// DiagReport is the structured output of `mosaic diag`.
type DiagReport struct {
	GeneratedAt   time.Time      `json:"generated_at"`
	DaemonVersion string         `json:"daemon_version"`
	OS            string         `json:"os"`
	Arch          string         `json:"arch"`
	Status        Status         `json:"status"`
	Subscriptions []Subscription `json:"subscriptions"`
	ServerCount   int            `json:"server_count"`
	RuleCount     int            `json:"rule_count"`
	RecentLogs    []string       `json:"recent_logs"`
	Notes         []string       `json:"notes,omitempty"`
}

// Daemon listen info, surfaced to clients via the lockfile.
type DaemonEndpoint struct {
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Token   string `json:"token"`
	PID     int    `json:"pid"`
	Started string `json:"started"`
	Version string `json:"version"`
}

// ---------- Profile & RouteProfile ----------------------------------------

// Profile bundles user preferences, selected subscription/server, routing
// ruleset, and DNS config into a named preset. Users can have multiple
// profiles (e.g. "Home", "Work", "Gaming") and switch between them.
type Profile struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Icon           string    `json:"icon,omitempty"`  // emoji or icon name
	Color          string    `json:"color,omitempty"` // hex color for avatar
	ServerID       string    `json:"server_id,omitempty"`
	SubscriptionID string    `json:"subscription_id,omitempty"`
	TunnelMode     string    `json:"tunnel_mode"` // "tun" | "proxy"
	KillSwitch     bool      `json:"kill_switch"`
	AllowLAN       bool      `json:"allow_lan"`
	DNS            DNSConfig `json:"dns"`
	RuleIDs        []string  `json:"rule_ids,omitempty"` // ordered list of rule IDs enabled in this profile
	AutoConnect    bool      `json:"auto_connect"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// RouteProfile is a named bundle of routing rules that can be shared
// across profiles. Each profile references rule IDs; a route profile
// groups those rules into a reusable preset.
type RouteProfile struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	RuleIDs     []string  `json:"rule_ids"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// ---------- DNS -----------------------------------------------------------

// DNSConfig describes the DNS resolution strategy for the tunnel and
// direct paths. Mirrors sing-box's DNS section.
type DNSConfig struct {
	// Mode: "fake-ip" | "real-ip" | "disabled"
	Mode string `json:"mode"`

	// Proxied is the upstream DNS used for traffic that goes through the
	// proxy. Accepts plain DNS (udp://1.1.1.1), DoH (https://1.1.1.1/dns-query),
	// or DoT (tls://1.1.1.1).
	Proxied string `json:"proxied,omitempty"`

	// Direct is the upstream DNS used for traffic that goes direct.
	Direct string `json:"direct,omitempty"`

	// FakeIPRange is the IPv4 CIDR for fake-ip allocation.
	// Default: "198.18.0.0/15".
	FakeIPRange string `json:"fake_ip_range,omitempty"`

	// FakeIPExclude are domain patterns excluded from fake-ip (resolved
	// with real upstream).
	FakeIPExclude []string `json:"fake_ip_exclude,omitempty"`

	// Hosts is an optional static domain→IP override map.
	Hosts map[string]string `json:"hosts,omitempty"`

	// DisableCache disables DNS caching.
	DisableCache bool `json:"disable_cache,omitempty"`

	// DisableFallback disables the fallback DNS path.
	DisableFallback bool `json:"disable_fallback,omitempty"`
}

// DefaultDNSConfig returns the DNS config Mosaic ships with.
func DefaultDNSConfig() DNSConfig {
	return DNSConfig{
		Mode:        "fake-ip",
		Proxied:     "https://1.1.1.1/dns-query",
		Direct:      "udp://77.88.8.8",
		FakeIPRange: "198.18.0.0/15",
	}
}

// ---------- Connections & Stats (Throne-parity) ---------------------------

// Connection is a live TCP/UDP flow observed by the VPN engine (sing-box
// Clash API). Uses a mix of the fields sing-box exposes via its
// connections endpoint.
type Connection struct {
	ID         string    `json:"id"`
	Network    string    `json:"network"`  // "tcp" | "udp"
	Outbound   string    `json:"outbound"` // outbound tag: "proxy", "direct", "block"
	Domain     string    `json:"domain,omitempty"`
	IP         string    `json:"ip,omitempty"`
	Port       int       `json:"port,omitempty"`
	SourceIP   string    `json:"source_ip,omitempty"`
	SourcePort int       `json:"source_port,omitempty"`
	Process    string    `json:"process,omitempty"`
	Upload     uint64    `json:"upload"`
	Download   uint64    `json:"download"`
	StartAt    time.Time `json:"start_at"`
	Chain      string    `json:"chain,omitempty"` // e.g. "proxy → vless"
	Rule       string    `json:"rule,omitempty"`  // matching rule name
}

// TrafficStats aggregates bytes uploaded/downloaded over a time window.
// Used for the Stats screen to render charts and sparklines.
type TrafficStats struct {
	// TotalBytesIn / TotalBytesOut are the cumulative byte counts since
	// the current session began.
	TotalBytesIn  uint64 `json:"total_bytes_in"`
	TotalBytesOut uint64 `json:"total_bytes_out"`

	// Series is a set of timestamped data points for charting, each
	// containing the delta since the previous point.
	Series []TrafficPoint `json:"series,omitempty"`

	// ConnCount is the current number of live connections.
	ConnCount int `json:"conn_count"`

	// PeakConnCount is the observed max concurrent connections.
	PeakConnCount int `json:"peak_conn_count,omitempty"`

	// UpSpeed / DownSpeed are bytes/second computed from the most
	// recent interval.
	UpSpeed   uint64 `json:"up_speed,omitempty"`
	DownSpeed uint64 `json:"down_speed,omitempty"`
}

// TrafficPoint is a single timestamped measurement for charting traffic.
type TrafficPoint struct {
	Timestamp time.Time `json:"ts"`
	BytesIn   uint64    `json:"bin"`
	BytesOut  uint64    `json:"bout"`
	UpSpeed   uint64    `json:"up,omitempty"`
	DownSpeed uint64    `json:"down,omitempty"`
}

// ---------- Test results --------------------------------------------------

// TestResult is the outcome of a URL-test (latency probe) or IP-test
// against a single server. Mirror of Throne's query test results.
type TestResult struct {
	ServerID   string    `json:"server_id"`
	ServerName string    `json:"server_name,omitempty"`
	LatencyMS  int       `json:"latency_ms"` // -1 on failure
	Error      string    `json:"error,omitempty"`
	TestedAt   time.Time `json:"tested_at"`
	// IPInfo is populated during an IP test (the apparent egress IP).
	IPInfo *IPInfo `json:"ip_info,omitempty"`
}

// IPInfo is the apparent egress IP metadata, determined by querying
// an IP-echo service through the proxy tunnel.
type IPInfo struct {
	IP      string `json:"ip"`
	Country string `json:"country,omitempty"`
	City    string `json:"city,omitempty"`
	ISP     string `json:"isp,omitempty"`
	ASN     string `json:"asn,omitempty"`
}

// SpeedTestResult is the outcome of a download/upload speed test
// through the active tunnel.
type SpeedTestResult struct {
	DownloadBps  uint64    `json:"download_bps"` // bytes/sec
	UploadBps    uint64    `json:"upload_bps"`
	DownloadMbps float64   `json:"download_mbps"`
	UploadMbps   float64   `json:"upload_mbps"`
	LatencyMS    int       `json:"latency_ms,omitempty"`
	TestedAt     time.Time `json:"tested_at"`
	Error        string    `json:"error,omitempty"`
}

// ---------- WARP / Cloudflare ---------------------------------------------

// WARPConfig holds Cloudflare WARP connection parameters. When enabled,
// the daemon prepends a WARP outbound to the chain.
type WARPConfig struct {
	Enabled    bool   `json:"enabled"`
	Mode       string `json:"mode,omitempty"`        // "warp" | "warp+"
	LicenseKey string `json:"license_key,omitempty"` // WARP+ key
	TeamToken  string `json:"team_token,omitempty"`  // Zero Trust team token
	BindAddr   string `json:"bind_addr,omitempty"`   // local:port for the warp outbound
}

// ---------- Clipboard import & deep-link ----------------------------------

// ClipboardImport is a structure representing a shared server link
// pasted from the clipboard or received via the mosaic:// deep-link.
type ClipboardImport struct {
	Raw      string   `json:"raw"`
	Protocol Protocol `json:"protocol,omitempty"`
	Format   Format   `json:"format,omitempty"`
	Parsed   bool     `json:"parsed"`
	Error    string   `json:"error,omitempty"`
}

// ---------- Egress listeners ----------------------------------------------

// Egress represents a local proxy listener that forwards traffic through
// the VPN tunnel. Each egress can be independently enabled/disabled and
// configured with its own protocol settings.
type Egress struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Protocol string `json:"protocol"` // "socks5", "http", "mixed"
	Listen   string `json:"listen"`   // "127.0.0.1:10808"
	Active   bool   `json:"active"`
	// Chain specifies an optional outbound chain (e.g. "warp→vless") for
	// this listener. Empty means use the default proxy outbound.
	Chain string `json:"chain,omitempty"`
	// GroupID, if set, means this egress auto-selects the best node from
	// the specified manifest group pool instead of a fixed server.
	GroupID     string `json:"group_id,omitempty"`
	ServerID    string `json:"server_id,omitempty"`
	ServerName  string `json:"server_name,omitempty"`
	Port        int    `json:"port"`
	Type        string `json:"type,omitempty"` // "mixed", "socks", "http"
	AutoConnect bool   `json:"auto_connect,omitempty"`
}

// ---------- Anti-DPI settings ---------------------------------------------

// AntiDPIConfig holds parameters for transport-layer obfuscation to evade
// deep packet inspection and circumvent blocking.
type AntiDPIConfig struct {
	Enabled      bool   `json:"enabled"`
	Mode         string `json:"mode,omitempty"`          // "utls", "shadowtls", " reality"
	Fingerprint  string `json:"fingerprint,omitempty"`   // uTLS fingerprint name
	FragmentSize int    `json:"fragment_size,omitempty"` // TCP fragment size (0 = disabled)
	FragmentTTL  int    `json:"fragment_ttl,omitempty"`  // IP TTL for fragments
}

// ---------- Import / Export -----------------------------------------------

// ExportRequest carries export options from the client.
type ExportRequest struct {
	IncludeSubscriptions bool `json:"include_subscriptions"`
}

// ImportRequest carries a previously-exported config blob and a merge mode.
type ImportRequest struct {
	Config map[string]any `json:"config"`
	Mode   string         `json:"mode"` // "merge" | "replace"
}
