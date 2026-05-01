// Package proto contains the shared data types used across the daemon, CLI,
// and API client. Types are JSON-serializable and represent the canonical
// state of the system as exposed by the daemon API.
package proto

import "time"

// Protocol identifies a VPN/proxy protocol supported by Mosaic.
type Protocol string

const (
	ProtoVLESS       Protocol = "vless"
	ProtoHysteria2   Protocol = "hysteria2"
	ProtoNaive       Protocol = "naive"
	ProtoShadowsocks Protocol = "shadowsocks"
	ProtoAmneziaWG   Protocol = "amneziawg"
)

// AllProtocols returns every protocol Mosaic understands.
func AllProtocols() []Protocol {
	return []Protocol{ProtoVLESS, ProtoHysteria2, ProtoNaive, ProtoShadowsocks, ProtoAmneziaWG}
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
	ID             string         `json:"id"`
	Name           string         `json:"name"`
	Protocol       Protocol       `json:"protocol"`
	Address        string         `json:"address"`
	Port           int            `json:"port"`
	City           string         `json:"city,omitempty"`
	Country        string         `json:"country,omitempty"`
	Tag            string         `json:"tag,omitempty"`
	SubscriptionID string         `json:"subscription_id"`
	// LastTestMS is the round-trip time of the most recent probe, in
	// milliseconds. A negative value means the probe failed; LastTestError
	// then carries the reason. Zero means the server has never been probed.
	LastTestMS    int            `json:"last_test_ms,omitempty"`
	LastTestError string         `json:"last_test_error,omitempty"`
	LastTestAt    time.Time      `json:"last_test_at,omitempty"`
	// LastURLTestMS / Status / Error / At persist the last result of
	// a Verify (URL test) probe through this server.  Surfaced in the
	// SubscriptionDetail Verify column so the user can see what the
	// last gstatic-204 fetch actually returned without re-running it.
	LastURLTestMS     int       `json:"last_url_test_ms,omitempty"`
	LastURLTestStatus int       `json:"last_url_test_status,omitempty"`
	LastURLTestError  string    `json:"last_url_test_error,omitempty"`
	LastURLTestAt     time.Time `json:"last_url_test_at,omitempty"`
	// LastConnectedAt is the timestamp of the most recent successful
	// Connect to this server (rc44). Used by the Recent-5 picker in
	// the tray and the multi-egress server-select to surface what the
	// user has actually used, rather than dumping the entire pool.
	LastConnectedAt time.Time `json:"last_connected_at,omitempty"`
	// Lat/Lon are decimal degrees (WGS84). Populated from a GeoIP
	// lookup against Address; zero means "not resolved yet".
	Lat float64 `json:"lat,omitempty"`
	Lon float64 `json:"lon,omitempty"`
	// ResolvedIP is the IP that Address resolved to during the most
	// recent probe. For Address values that are already IPs it equals
	// Address; for hostnames it is the first A/AAAA record seen.
	// Used by the UI to group multiple protocol entries that point at
	// the same physical host.
	ResolvedIP string `json:"resolved_ip,omitempty"`
	Raw map[string]any `json:"raw,omitempty"`
}

// Format identifies a subscription payload format.
type Format string

const (
	FormatSingbox        Format = "singbox"
	FormatClash          Format = "clash"
	FormatV2RayB64       Format = "v2ray-base64"
	FormatSIP008         Format = "sip008"
	FormatWireGuardConf  Format = "wireguard-conf"
	FormatAmneziaVPN     Format = "amnezia-vpn"
	FormatUnknown        Format = "unknown"
)

// Subscription is a remote source of Servers, periodically fetched and
// re-parsed.
type Subscription struct {
	ID                     string    `json:"id"`
	Name                   string    `json:"name"`
	URL                    string    `json:"url"`
	Format                 Format    `json:"format"`
	LastFetched            time.Time `json:"last_fetched,omitempty"`
	LastError              string    `json:"last_error,omitempty"`
	AutoRefresh            bool      `json:"auto_refresh"`
	RefreshIntervalSeconds int       `json:"refresh_interval_seconds"`
	ServerCount            int       `json:"server_count"`
	// Subscription-Userinfo (v2board / marzban / 3x-ui / xui convention):
	// bytes used/total and ISO-8601 expiry. Zero = unknown / not reported.
	// Populated from the `Subscription-Userinfo` response header on fetch.
	TrafficUsed  uint64    `json:"traffic_used,omitempty"`
	TrafficTotal uint64    `json:"traffic_total,omitempty"`
	ExpiresAt    time.Time `json:"expires_at,omitempty"`
}

// EgressConfig describes a long-lived auxiliary proxy listener (rc44).
// The main Connect / Disconnect flow stays on a single user-selected
// server; egresses are independent SOCKS/HTTP proxies a user can stand
// up in addition, each pinned to its own server.  Useful for routing
// specific apps through a different geo without flipping the main
// tunnel.  Configured per-egress and persisted in store.State.
type EgressConfig struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	ServerID string `json:"server_id"`
	// Protocol is "socks5" or "http" — determines what kind of inbound
	// the per-egress sing-box exposes.  Defaults to socks5 when empty.
	Protocol string `json:"protocol"`
	// Port is the local TCP port the inbound listens on.  Bound to
	// 127.0.0.1 by default; 0.0.0.0 when ShareLAN is true.
	Port int `json:"port"`
	// ShareLAN flips the listen address to 0.0.0.0 so other devices
	// on the same network can use this egress as their proxy.
	ShareLAN bool `json:"share_lan"`
	// ShareUser / SharePass gate the inbound when exposed on the LAN.
	// Both empty = anonymous listener (loopback historic behaviour).
	ShareUser string `json:"share_user,omitempty"`
	SharePass string `json:"share_pass,omitempty"`
	// AutoStart asks the daemon to bring this egress up at launch
	// without an explicit /v1/egresses/:id/start call.  Set when the
	// user wants the egress to behave like a system service.
	AutoStart bool `json:"auto_start"`
}

// EgressStatus is the runtime state of a single egress, surfaced via
// the /v1/egresses endpoint and the MCP egress tools.
type EgressStatus struct {
	Running   bool      `json:"running"`
	StartedAt time.Time `json:"started_at,omitempty"`
	LastError string    `json:"last_error,omitempty"`
	PID       int       `json:"pid,omitempty"`
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

	// MyLocation is the user's approximate geo position, resolved
	// once at daemon startup via ip-api.com on the user's public IP.
	// Used by the renderer to plant the "vous" pin at a sensible
	// place on the world map instead of a hardcoded fallback near
	// the West African coast (rc26 dropped one there which the user
	// flagged as "vous отмечает неправильно моё местоположение").
	// Nil while the lookup is still in flight or if it failed
	// (no internet at boot, ip-api rate limit, etc.).
	MyLocation *GeoLocation `json:"my_location,omitempty"`
}

// GeoLocation is a coarse public-IP-to-coordinates mapping. Source:
// ip-api.com's free /json endpoint, called once at daemon startup.
type GeoLocation struct {
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	City    string  `json:"city,omitempty"`
	Country string  `json:"country,omitempty"`
	IP      string  `json:"ip,omitempty"`
}

// ConnectRequest tells the daemon to bring up a server.
type ConnectRequest struct {
	ServerID string `json:"server_id"`
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
