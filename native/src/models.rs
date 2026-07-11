use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub protocol: String,
    pub address: String,
    pub port: u16,
    #[serde(default)]
    pub city: Option<String>,
    #[serde(default)]
    pub country: Option<String>,
    #[serde(default)]
    pub tag: Option<String>,
    pub subscription_id: String,
    #[serde(default)]
    pub last_test_ms: Option<i32>,
    #[serde(default)]
    pub last_test_error: Option<String>,
    #[serde(default)]
    pub last_test_at: Option<String>,
    #[serde(default)]
    pub lat: Option<f64>,
    #[serde(default)]
    pub lon: Option<f64>,
    #[serde(default)]
    pub raw: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Subscription {
    pub id: String,
    pub name: String,
    pub url: String,
    pub format: String,
    #[serde(default)]
    pub last_fetched: Option<String>,
    #[serde(default)]
    pub last_error: Option<String>,
    pub auto_refresh: bool,
    pub refresh_interval_seconds: i32,
    pub server_count: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Match {
    pub logic: String,
    #[serde(default)]
    pub geosite: Vec<String>,
    #[serde(default)]
    pub geoip: Vec<String>,
    #[serde(default)]
    pub domain_suffix: Vec<String>,
    #[serde(default)]
    pub domain_keyword: Vec<String>,
    #[serde(default)]
    pub domain: Vec<String>,
    #[serde(default)]
    pub ip_cidr: Vec<String>,
    #[serde(default)]
    pub process: Vec<String>,
    #[serde(default)]
    pub port: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Rule {
    pub id: String,
    pub name: String,
    pub priority: i32,
    pub enabled: bool,
    pub action: String,
    #[serde(default)]
    pub target: Option<String>,
    pub r#match: Match,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Status {
    pub state: String,
    #[serde(default)]
    pub server: Option<Server>,
    #[serde(default)]
    pub since: Option<String>,
    #[serde(default)]
    pub last_error: Option<String>,
    #[serde(default)]
    pub latency_ms: Option<i32>,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub tunnel_mode: String,
    pub kill_switch: bool,
    pub agent_connected: bool,
    pub daemon_version: String,
    pub daemon_pid: i32,
    #[serde(default)]
    pub proxy_socks: Option<String>,
    #[serde(default)]
    pub proxy_http: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Prefs {
    pub tunnel_mode: String,
    pub socks_addr: String,
    pub http_addr: String,
    pub mtu: i32,
    pub kill_switch: bool,
    pub allow_lan: bool,
    #[serde(default)]
    pub bypass_processes: Vec<String>,
    pub block_ipv6: bool,
    pub dns_mode: String,
    pub dns_proxied: String,
    pub dns_direct: String,
    pub share_lan: bool,
    pub share_addr: String,
    #[serde(default)]
    pub share_allow: Vec<String>,
    pub auto_start: String,
    pub auto_connect: bool,
    pub show_on_launch: bool,
    pub mcp_enabled: bool,
    pub mcp_addr: String,
    pub mcp_permission: String,
    pub mcp_confirm: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonEndpoint {
    pub token: String,
    pub host: String,
    pub port: u16,
    pub pid: i32,
}
