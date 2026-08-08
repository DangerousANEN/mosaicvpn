// profiles/mod.rs — Smart Profiles
//
// Каждый профиль — набор настроек, применяемых автоматически.
// Gaming: минимальный ping, ближайший сервер
// Streaming: сервер по региону, Smart DNS
// Work: Always-On, Kill Switch, корпоративный DNS
// Privacy: Multi-hop, максимальная защита, Secure DNS

use crate::models::Prefs;

/// Тип профиля
#[derive(Debug, Clone, PartialEq)]
pub enum ProfileType {
    Gaming,
    Streaming,
    Work,
    Privacy,
    Custom(String),
}

impl ProfileType {
    pub fn name(&self) -> &str {
        match self {
            ProfileType::Gaming => "Gaming",
            ProfileType::Streaming => "Streaming",
            ProfileType::Work => "Work",
            ProfileType::Privacy => "Privacy",
            ProfileType::Custom(n) => n.as_str(),
        }
    }

    pub fn id(&self) -> &str {
        match self {
            ProfileType::Gaming => "gaming",
            ProfileType::Streaming => "streaming",
            ProfileType::Work => "work",
            ProfileType::Privacy => "privacy",
            ProfileType::Custom(n) => n.as_str(),
        }
    }

    pub fn icon(&self) -> &str {
        match self {
            ProfileType::Gaming => "🎮",
            ProfileType::Streaming => "▶",
            ProfileType::Work => "💼",
            ProfileType::Privacy => "🛡",
            ProfileType::Custom(_) => "⚙",
        }
    }

    pub fn description(&self) -> &str {
        match self {
            ProfileType::Gaming => "Minimum ping · Nearest server · Max speed",
            ProfileType::Streaming => "Region-locked servers · Smart DNS · Speed optimised",
            ProfileType::Work => "Always-On · Kill Switch · Corporate DNS · LAN block",
            ProfileType::Privacy => "Multi-hop · Maximum protection · Secure DNS · Auto IP change",
            ProfileType::Custom(_) => "Custom configuration",
        }
    }
}

/// Настройки профиля
#[derive(Debug, Clone)]
pub struct ProfileConfig {
    pub profile_type: ProfileType,
    pub prefs: Prefs,
    pub prefer_nearest: bool,       // Gaming: выбирать ближайший сервер
    pub multi_hop: bool,            // Privacy: multi-hop
    pub block_lan: bool,            // Work: блокировка LAN
    pub auto_rotate_ip: bool,       // Privacy: автоматическая смена IP
    pub aggressive_tracker_blocking: bool, // Privacy: усиленная блокировка
}

/// Применить профиль к Prefs
pub fn apply_profile(profile: &ProfileType, current_prefs: &Prefs) -> ProfileConfig {
    let mut prefs = current_prefs.clone();

    match profile {
        ProfileType::Gaming => {
            // Минимальный ping, ближайший сервер, максимальная скорость
            prefs.kill_switch = false;        // KS добавляет задержку
            prefs.dns_mode = "fake-ip".into(); // Быстрый DNS
            prefs.block_ipv6 = false;          // Не блокировать IPv6 (может быть быстрее)
            ProfileConfig {
                profile_type: profile.clone(),
                prefs,
                prefer_nearest: true,
                multi_hop: false,
                block_lan: false,
                auto_rotate_ip: false,
                aggressive_tracker_blocking: false,
            }
        }
        ProfileType::Streaming => {
            // Сервер по региону, Smart DNS, оптимизация скорости
            prefs.dns_mode = "fake-ip".into();
            prefs.kill_switch = true;
            prefs.block_ipv6 = true;
            ProfileConfig {
                profile_type: profile.clone(),
                prefs,
                prefer_nearest: false,
                multi_hop: false,
                block_lan: false,
                auto_rotate_ip: false,
                aggressive_tracker_blocking: false,
            }
        }
        ProfileType::Work => {
            // Always-On, Kill Switch, корпоративный DNS, блокировка LAN
            prefs.kill_switch = true;
            prefs.block_ipv6 = true;
            prefs.dns_mode = "proxied".into();
            prefs.auto_connect = true;
            prefs.auto_start = "service".into();
            prefs.allow_lan = false;
            ProfileConfig {
                profile_type: profile.clone(),
                prefs,
                prefer_nearest: false,
                multi_hop: false,
                block_lan: true,
                auto_rotate_ip: false,
                aggressive_tracker_blocking: false,
            }
        }
        ProfileType::Privacy => {
            // Multi-hop, максимальная защита, Secure DNS, авто смена IP
            prefs.kill_switch = true;
            prefs.block_ipv6 = true;
            prefs.dns_mode = "proxied".into();
            prefs.dns_proxied = "https://1.1.1.1/dns-query".into();
            prefs.auto_connect = true;
            prefs.auto_start = "service".into();
            ProfileConfig {
                profile_type: profile.clone(),
                prefs,
                prefer_nearest: false,
                multi_hop: true,
                block_lan: false,
                auto_rotate_ip: true,
                aggressive_tracker_blocking: true,
            }
        }
        ProfileType::Custom(_) => {
            ProfileConfig {
                profile_type: profile.clone(),
                prefs: prefs.clone(),
                prefer_nearest: false,
                multi_hop: false,
                block_lan: false,
                auto_rotate_ip: false,
                aggressive_tracker_blocking: false,
            }
        }
    }
}

/// Список всех доступных профилей
pub fn list_profiles() -> Vec<ProfileType> {
    vec![
        ProfileType::Gaming,
        ProfileType::Streaming,
        ProfileType::Work,
        ProfileType::Privacy,
    ]
}
