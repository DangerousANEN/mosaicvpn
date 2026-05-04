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
  /** rc44 — timestamp of the most recent successful Connect to this
   *  server (ISO-8601).  Drives the Recent-5 picker in the tray and
   *  the multi-egress server-select dropdown. */
  last_connected_at?: string;
  /** Protocol-specific fields carried from the subscription parse
   *  (see internal/subs/*.go). `raw.uri` is the original `vless://`
   *  / `trojan://` / `ss://` / `hy2://` / `naive+https://` URI
   *  preserved so the UI can round-trip it with Copy URI. */
  raw?: Record<string, unknown>;
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
  /** Subscription-Userinfo (v2board / marzban / 3x-ui): bytes. 0 = not reported. */
  traffic_used?: number;
  /** Subscription-Userinfo total bytes. 0 = unlimited / unknown. */
  traffic_total?: number;
  /** Subscription-Userinfo expire, ISO-8601. Omitted = no expiry reported. */
  expires_at?: string;
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
  /** SOCKS5 inbound listen port.  0 / undefined keeps the historical
   *  "try 2080, fall back to ephemeral if taken" behaviour.  A
   *  non-zero value pins the port — connect fails loudly when it's
   *  already in use instead of moving to a random ephemeral. */
  socks_port?: number;
  /** HTTP proxy inbound listen port.  Same semantics as socks_port;
   *  0 / undefined = auto (try 2081, fall back). */
  http_port?: number;
  /** Speedtest target URL.  Empty falls back to the default
   *  Cloudflare 10 MB → 5 MB → 1 MB ladder. */
  speedtest_url?: string;
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

/* rc44 — auxiliary egress lifecycle. -------------------------------- */

/** EgressConfig describes a long-lived auxiliary proxy listener: a
 *  SOCKS5 or HTTP inbound pinned to a single server, independent of
 *  the main Connect/Disconnect tunnel.  Useful for routing specific
 *  apps through a different geo without touching the main VPN.        */
export interface EgressConfig {
  id: string;
  name: string;
  server_id: string;
  /** "socks5" (default) or "http". */
  protocol: string;
  /** Local TCP port the inbound binds to (1..65535). */
  port: number;
  /** Bind on 0.0.0.0 instead of 127.0.0.1 so other LAN devices can
   *  use this egress as their proxy. */
  share_lan: boolean;
  /** When non-empty, the inbound requires basic auth from clients on
   *  the LAN.  Both empty = anonymous. */
  share_user?: string;
  share_pass?: string;
  /** Bring this egress up automatically at daemon launch. */
  auto_start: boolean;
}

/** EgressStatus is the live runtime state of one egress's sing-box
 *  subprocess.  Exposed by GET /v1/egresses alongside the config so
 *  the renderer can paint a row in one round-trip. */
export interface EgressStatus {
  running: boolean;
  pid?: number;
  started_at?: string;
  last_error?: string;
}

/** EgressDTO bundles the persisted config with the live status, as
 *  returned by GET /v1/egresses. */
export type EgressDTO = EgressConfig & { status: EgressStatus };
