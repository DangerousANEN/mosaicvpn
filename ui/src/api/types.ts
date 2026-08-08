/**
 * Mirror of internal/proto/types.go. The renderer consumes these types
 * verbatim from the daemon's HTTP API responses; field names match the
 * JSON tags exactly.
 */

export type Protocol = "vless" | "vmess" | "trojan" | "shadowsocks" | "hysteria2" | "naive" | "amneziawg";

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
  lat?: number;
  lon?: number;
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
}

export interface Prefs {
  tunnel_mode: string;
  tun_stack: string;
  kill_switch: boolean;
  allow_lan: boolean;
  dns_proxied: string;
  dns_direct: string;
  auto_connect: boolean;
  show_on_launch: boolean;
  mcp_enabled: boolean;
  mcp_addr: string;
  mcp_permission: "read" | "connect" | "full";
  mcp_confirm: boolean;
}

export interface DaemonEndpoint {
  host: string;
  port: number;
  token: string;
  pid: number;
  version: string;
  started: string;
}

export interface DNSConfig {
  mode: "fake-ip" | "real-ip" | "disabled";
  proxied?: string;
  direct?: string;
  fake_ip_range?: string;
  fake_ip_exclude?: string[];
  hosts?: Record<string, string>;
  disable_cache?: boolean;
  disable_fallback?: boolean;
}

export interface Profile {
  id: string;
  name: string;
  icon?: string;
  color?: string;
  server_id?: string;
  subscription_id?: string;
  tunnel_mode: string;
  kill_switch: boolean;
  allow_lan: boolean;
  dns: DNSConfig;
  rule_ids?: string[];
  auto_connect: boolean;
  created_at: string;
  updated_at: string;
}

export interface RouteProfile {
  id: string;
  name: string;
  description?: string;
  rule_ids: string[];
  created_at: string;
  updated_at: string;
}

export interface Connection {
  id: string;
  network: "tcp" | "udp";
  outbound: string;
  domain?: string;
  ip?: string;
  port?: number;
  source_ip?: string;
  source_port?: number;
  process?: string;
  upload: number;
  download: number;
  start_at: string;
  chain?: string;
  rule?: string;
}

export interface TrafficPoint {
  ts: string;
  bin: number;
  bout: number;
  up?: number;
  down?: number;
}

export interface TrafficStats {
  total_bytes_in: number;
  total_bytes_out: number;
  series?: TrafficPoint[];
  conn_count: number;
  peak_conn_count?: number;
  up_speed?: number;
  down_speed?: number;
}

export interface TestResult {
  server_id: string;
  server_name?: string;
  latency_ms: number;
  error?: string;
  tested_at: string;
  ip_info?: IPInfo;
}

export interface IPInfo {
  ip: string;
  country?: string;
  city?: string;
  isp?: string;
  asn?: string;
}

export interface SpeedTestResult {
  download_bps: number;
  upload_bps: number;
  download_mbps: number;
  upload_mbps: number;
  latency_ms?: number;
  tested_at: string;
  error?: string;
}

export interface WARPConfig {
  enabled: boolean;
  mode?: string;
  license_key?: string;
  team_token?: string;
  bind_addr?: string;
}

export interface ClipboardImport {
  raw: string;
  protocol?: Protocol;
  format?: Format;
  parsed: boolean;
  error?: string;
}
