/**
 * Mirror of internal/proto/types.go. The renderer consumes these types
 * verbatim from the daemon's HTTP API responses; field names match the
 * JSON tags exactly.
 */

export type Protocol =
  | "vless"
  | "vmess"
  | "shadowsocks"
  | "hysteria2"
  | "naive"
  | "amneziawg"
  | "trojan";

export type Format =
  | "singbox"
  | "clash"
  | "v2ray-base64"
  | "sip008"
  | "unknown";

export type Logic = "and" | "or";

export type Action = "proxy" | "direct" | "block";

export type State =
  | "disconnected"
  | "connecting"
  | "connected"
  | "error";

export interface Server {
  id: string;
  name: string;
  protocol: Protocol;
  address: string;
  port: number;
  city?: string;
  country?: string;
  tag?: string;
  subscription_id: string;
  last_test_ms?: number;
  last_test_error?: string;
  last_test_at?: string;
  /** rc40 — last result of a Verify (URL test) probe.  Persisted
   *  by the daemon so the SubscriptionDetail Verify column can
   *  display the most recent gstatic-204 outcome without re-
   *  running the test. */
  last_url_test_ms?: number;
  last_url_test_status?: number;
  last_url_test_error?: string;
  last_url_test_at?: string;
  lat?: number;
  lon?: number;
  /** IP that `address` resolved to during the most recent probe.
   *  Used by the UI to group multi-protocol entries pointing at the
   *  same physical host. */
  resolved_ip?: string;
}

export interface Subscription {
  id: string;
  name: string;
  url: string;
  format: Format;
  last_fetched?: string;
  last_error?: string;
  auto_refresh: boolean;
  refresh_interval_seconds: number;
  server_count: number;
}

export interface Match {
  logic: Logic;
  geosite?: string[];
  geoip?: string[];
  domain_suffix?: string[];
  domain_keyword?: string[];
  domain?: string[];
  ip_cidr?: string[];
  process?: string[];
  port?: string[];
}

export interface Rule {
  id: string;
  name: string;
  priority: number;
  enabled: boolean;
  action: Action;
  target?: string;
  match: Match;
}

export interface Status {
  state: State;
  server?: Server;
  since?: string;
  last_error?: string;
  latency_ms?: number;
  bytes_in: number;
  bytes_out: number;
  tunnel_mode: string;
  kill_switch: boolean;
  agent_connected: boolean;
  daemon_version: string;
  daemon_pid: number;
  proxy_socks?: string;
  proxy_http?: string;
  /** User's approximate location, resolved by mosaicd at startup
   *  via ip-api.com on the public IP. Drives the "vous" pin. */
  my_location?: GeoLocation;
}

export interface GeoLocation {
  lat: number;
  lon: number;
  city?: string;
  country?: string;
  ip?: string;
}

export interface Prefs {
  tunnel_mode: string;
  tun_stack: string;
  kill_switch: boolean;
  allow_lan: boolean;
  share_lan: boolean;
  share_addr: string;
  share_user?: string;
  share_pass?: string;
  dns_proxied: string;
  dns_direct: string;
  auto_connect: boolean;
  show_on_launch: boolean;
  mcp_enabled: boolean;
  mcp_addr: string;
  mcp_permission: "read" | "connect" | "full";
  mcp_confirm: boolean;
  /** Verify (URL test) target.  Empty = gstatic-204 default. */
  url_test_endpoint?: string;
  /** Anti-DPI overrides — see store.Prefs for semantics. */
  dpi_fingerprint?: string;
  dpi_fragment?: string;
  dpi_mux?: string;
  dpi_ech?: boolean;
}

export interface DaemonEndpoint {
  host: string;
  port: number;
  token: string;
  pid: number;
  version: string;
  started: string;
}
