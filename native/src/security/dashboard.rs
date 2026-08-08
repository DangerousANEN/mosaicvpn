// security/dashboard.rs — Security Dashboard state
//
// Объединяет все проверки в единую приборную панель.
// Slint получает готовый DashboardState.

use super::{CheckResult, CheckStatus};
use crate::models::Prefs;

/// Полное состояние Security Dashboard
#[derive(Debug, Clone)]
pub struct DashboardState {
    pub protection_level: u32,   // 0-100
    pub privacy_score: u32,      // 0-100
    pub items: Vec<DashboardItem>,
}

/// Один пункт на приборной панели
#[derive(Debug, Clone)]
pub struct DashboardItem {
    pub id: String,
    pub name: String,
    pub status: String,   // "pass" | "warn" | "fail"
    pub value: String,    // "WireGuard", "Enabled", "Protected", etc.
    pub category: DashboardCategory,
}

#[derive(Debug, Clone, PartialEq)]
pub enum DashboardCategory {
    Encryption,     // protocol, cipher, handshake, session key
    Protection,     // kill switch, dns, ipv6, webrtc
    Blocking,       // tracker, malware, secure dns
    Automation,     // auto connect, always-on
}

/// Построить DashboardState из CheckResult'ов
pub fn build_dashboard(checks: &[CheckResult], protection: u32, score: u32) -> DashboardState {
    let items = checks.iter().map(|c| {
        let category = match c.id.as_str() {
            "protocol" => DashboardCategory::Encryption,
            "dns_leak" | "secure_dns" => DashboardCategory::Protection,
            "ipv6" | "kill_switch" | "webrtc" => DashboardCategory::Protection,
            "tracker_blocking" | "malware_blocking" => DashboardCategory::Blocking,
            "multi_hop" => DashboardCategory::Protection,
            "auto_connect" | "always_on" => DashboardCategory::Automation,
            _ => DashboardCategory::Protection,
        };
        DashboardItem {
            id: c.id.clone(),
            name: c.name.clone(),
            status: c.status_str().into(),
            value: c.description.clone(),
            category,
        }
    }).collect();

    DashboardState {
        protection_level: protection,
        privacy_score: score,
        items,
    }
}

/// Группировать элементы по категории
pub fn group_by_category(items: &[DashboardItem]) -> Vec<(DashboardCategory, Vec<&DashboardItem>)> {
    let mut groups: Vec<(DashboardCategory, Vec<&DashboardItem>)> = Vec::new();
    for cat in &[DashboardCategory::Encryption, DashboardCategory::Protection, DashboardCategory::Blocking, DashboardCategory::Automation] {
        let group: Vec<&DashboardItem> = items.iter().filter(|i| i.category == *cat).collect();
        if !group.is_empty() {
            groups.push((cat.clone(), group));
        }
    }
    groups
}
