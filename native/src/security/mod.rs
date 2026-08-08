// security/mod.rs — Privacy Score + Security Dashboard
//
// Privacy Score рассчитывается ТОЛЬКО в Rust.
// Slint получает только готовое значение + список проверок.
//
// Формула: sum(weight_i * passed_i) / sum(weight_i) * 100

pub mod checks;
pub mod dashboard;

use crate::models::Prefs;

/// Статус проверки
#[derive(Debug, Clone, PartialEq)]
pub enum CheckStatus {
    Pass,   // ✔ зелёный
    Warn,   // ⚠ жёлтый
    Fail,   // ✘ красный
}

/// Результат одной проверки
#[derive(Debug, Clone)]
pub struct CheckResult {
    pub id: String,           // "dns_leak", "ipv6", "kill_switch", ...
    pub name: String,         // "DNS Leak"
    pub status: CheckStatus,
    pub weight: u32,           // вес в общей оценке
    pub description: String,   // короткое описание
    pub detail: String,        // подробное объяснение
    pub fix_action: String,    // что делать для исправления
}

impl CheckResult {
    pub fn status_str(&self) -> &'static str {
        match self.status {
            CheckStatus::Pass => "pass",
            CheckStatus::Warn => "warn",
            CheckStatus::Fail => "fail",
        }
    }
}

/// Результат расчёта Privacy Score
#[derive(Debug, Clone)]
pub struct PrivacyScore {
    pub score: u32,             // 0-100
    pub checks: Vec<CheckResult>,
    pub protection_level: u32, // 0-100 (oversall protection)
}

/// Рассчитать Privacy Score на основе текущих настроек
pub fn calculate_score(prefs: &Prefs, connected: bool, protocol: &str, multi_hop: bool) -> PrivacyScore {
    let all_checks = checks::run_all_checks(prefs, connected, protocol, multi_hop);

    let total_weight: u32 = all_checks.iter().map(|c| c.weight).sum();
    let passed_weight: u32 = all_checks.iter()
        .filter(|c| c.status == CheckStatus::Pass)
        .map(|c| c.weight)
        .sum();
    let warn_weight: u32 = all_checks.iter()
        .filter(|c| c.status == CheckStatus::Warn)
        .map(|c| c.weight / 2) // warn = половина веса
        .sum();

    let raw = if total_weight > 0 {
        (passed_weight + warn_weight) * 100 / total_weight
    } else {
        100
    };

    // Protection level — отдельный показатель (зависит от connected + kill_switch + dns)
    let protection = checks::calculate_protection_level(prefs, connected);

    PrivacyScore {
        score: raw,
        checks: all_checks,
        protection_level: protection,
    }
}
