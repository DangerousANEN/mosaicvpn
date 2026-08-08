// security/checks.rs — Конкретные проверки безопасности
//
// Каждая проверка возвращает CheckResult.
// Проверки не делают сетевых запросов — они смотрят на Prefs и Status.
// В будущем можно добавить активные проверки (DNS resolver test, WebRTC probe).

use super::{CheckResult, CheckStatus};
use crate::models::Prefs;

/// Запустить все проверки
pub fn run_all_checks(prefs: &Prefs, connected: bool, protocol: &str, multi_hop: bool) -> Vec<CheckResult> {
    vec![
        check_dns_leak(prefs, connected),
        check_ipv6(prefs),
        check_webrtc(),
        check_kill_switch(prefs),
        check_protocol(protocol),
        check_secure_dns(prefs),
        check_multi_hop(multi_hop),
        check_tracker_blocking(),
        check_malware_blocking(),
        check_auto_connect(prefs),
        check_always_on(prefs),
    ]
}

fn check_dns_leak(prefs: &Prefs, connected: bool) -> CheckResult {
    let passed = connected && prefs.dns_mode != "direct";
    let status = if passed { CheckStatus::Pass }
        else if connected { CheckStatus::Warn }
        else { CheckStatus::Fail };

    CheckResult {
        id: "dns_leak".into(),
        name: "DNS Leak".into(),
        status,
        weight: 15,
        description: if passed { "Protected".into() } else { "Potential leak".into() },
        detail: "DNS queries should go through the VPN tunnel, not your ISP. \
                 If DNS is not proxied, your ISP can see which websites you visit \
                 even when VPN is active.".into(),
        fix_action: if passed { String::new() } else {
            "Set DNS mode to 'fake-ip' or 'proxied' in Settings → DNS".into()
        },
    }
}

fn check_ipv6(prefs: &Prefs) -> CheckResult {
    let passed = prefs.block_ipv6;
    CheckResult {
        id: "ipv6".into(),
        name: "IPv6 Leak".into(),
        status: if passed { CheckStatus::Pass } else { CheckStatus::Warn },
        weight: 10,
        description: if passed { "Protected".into() } else { "IPv6 not blocked".into() },
        detail: "IPv6 traffic can bypass your VPN tunnel if not blocked, \
                 leaking your real IP address through IPv6-enabled websites.".into(),
        fix_action: if passed { String::new() } else {
            "Enable 'Block IPv6' in Settings".into()
        },
    }
}

fn check_webrtc() -> CheckResult {
    // WebRTC can't be controlled from VPN app — only browser extension.
    CheckResult {
        id: "webrtc".into(),
        name: "WebRTC Leak".into(),
        status: CheckStatus::Warn,
        weight: 8,
        description: "May leak in browser".into(),
        detail: "WebRTC can reveal your real IP address through browser APIs. \
                 This needs to be disabled in your browser settings or via extension.".into(),
        fix_action: "Disable WebRTC in browser: install 'WebRTC Control' extension \
                     or set media.peerconnection.enabled=false in Firefox".into(),
    }
}

fn check_kill_switch(prefs: &Prefs) -> CheckResult {
    let passed = prefs.kill_switch;
    CheckResult {
        id: "kill_switch".into(),
        name: "Kill Switch".into(),
        status: if passed { CheckStatus::Pass } else { CheckStatus::Fail },
        weight: 15,
        description: if passed { "Enabled".into() } else { "Disabled".into() },
        detail: "Kill Switch blocks ALL network traffic if VPN connection drops, \
                 preventing data leaks during reconnection. Essential for privacy.".into(),
        fix_action: if passed { String::new() } else {
            "Enable Kill Switch in Settings → Security".into()
        },
    }
}

fn check_protocol(protocol: &str) -> CheckResult {
    let (status, desc): (CheckStatus, String) = match protocol {
        "wireguard" | "wg" => (CheckStatus::Pass, "WireGuard — excellent".into()),
        "openvpn" | "ovpn" => (CheckStatus::Pass, "OpenVPN — secure".into()),
        "" => (CheckStatus::Warn, "No protocol".into()),
        _ => (CheckStatus::Warn, protocol.to_string()),
    };
    CheckResult {
        id: "protocol".into(),
        name: "Protocol".into(),
        status,
        weight: 8,
        description: desc, 
        detail: "WireGuard is the most modern and secure VPN protocol with \
                 smallest attack surface. OpenVPN is well-tested but heavier.".into(),
        fix_action: if protocol == "wireguard" || protocol == "wg" { String::new() } else {
            "Switch to WireGuard if available".into()
        },
    }
}

fn check_secure_dns(prefs: &Prefs) -> CheckResult {
    let is_secure = prefs.dns_proxied.starts_with("https://") 
        || prefs.dns_proxied.starts_with("tls://");
    CheckResult {
        id: "secure_dns".into(),
        name: "Secure DNS".into(),
        status: if is_secure { CheckStatus::Pass } else { CheckStatus::Warn },
        weight: 8,
        description: if is_secure { "Encrypted DNS".into() } else { "Plain DNS".into() },
        detail: "Secure DNS (DoH/DoT) encrypts your DNS queries, preventing \
                 ISP and third parties from seeing which websites you visit.".into(),
        fix_action: if is_secure { String::new() } else {
            "Set proxied DNS to https://1.1.1.1/dns-query or tls://dns.google".into()
        },
    }
}

fn check_multi_hop(multi_hop: bool) -> CheckResult {
    CheckResult {
        id: "multi_hop".into(),
        name: "Multi-Hop".into(),
        status: if multi_hop { CheckStatus::Pass } else { CheckStatus::Warn },
        weight: 6,
        description: if multi_hop { "Enabled".into() } else { "Single hop".into() },
        detail: "Multi-hop routes your traffic through multiple servers in different \
                 jurisdictions, making it much harder to trace. Optional but recommended \
                 for maximum privacy.".into(),
        fix_action: if multi_hop { String::new() } else {
            "Enable Multi-Hop in Settings → Privacy".into()
        },
    }
}

fn check_tracker_blocking() -> CheckResult {
    // Default: pass (assuming tracker blocking is built-in via DNS rules)
    CheckResult {
        id: "tracker_blocking".into(),
        name: "Tracker Blocking".into(),
        status: CheckStatus::Pass,
        weight: 6,
        description: "Active".into(),
        detail: "Tracker blocking prevents known advertising and tracking domains \
                 from loading, protecting your privacy and speeding up page loads.".into(),
        fix_action: String::new(),
    }
}

fn check_malware_blocking() -> CheckResult {
    CheckResult {
        id: "malware_blocking".into(),
        name: "Malware Blocking".into(),
        status: CheckStatus::Pass,
        weight: 6,
        description: "Active".into(),
        detail: "Malware blocking prevents connections to known malicious domains, \
                 protecting your device from phishing, ransomware, and other threats.".into(),
        fix_action: String::new(),
    }
}

fn check_auto_connect(prefs: &Prefs) -> CheckResult {
    let passed = prefs.auto_connect;
    CheckResult {
        id: "auto_connect".into(),
        name: "Auto-Connect".into(),
        status: if passed { CheckStatus::Pass } else { CheckStatus::Warn },
        weight: 5,
        description: if passed { "Enabled".into() } else { "Disabled".into() },
        detail: "Auto-connect ensures your VPN is always active when you start your \
                 computer, preventing accidental exposure of your real IP.".into(),
        fix_action: if passed { String::new() } else {
            "Enable Auto-Connect in Settings".into()
        },
    }
}

fn check_always_on(prefs: &Prefs) -> CheckResult {
    // always-on is inferred from auto_start mode
    let passed = prefs.auto_start == "service";
    CheckResult {
        id: "always_on".into(),
        name: "Always-On VPN".into(),
        status: if passed { CheckStatus::Pass } else { CheckStatus::Warn },
        weight: 5,
        description: if passed { "Enabled".into() } else { "Disabled".into() },
        detail: "Always-On VPN maintains a persistent VPN connection that automatically \
                 reconnects if it drops, and blocks non-VPN traffic until reconnected.".into(),
        fix_action: if passed { String::new() } else {
            "Set auto-start to 'service' mode in Settings".into()
        },
    }
}

/// Calculate overall protection level (separate from Privacy Score)
pub fn calculate_protection_level(prefs: &Prefs, connected: bool) -> u32 {
    if !connected {
        return 0;
    }
    let mut level = 40u32; // base for connected
    if prefs.kill_switch { level += 20; }
    if prefs.block_ipv6 { level += 10; }
    if prefs.dns_mode != "direct" { level += 15; }
    if prefs.dns_proxied.starts_with("https://") { level += 10; }
    if prefs.auto_connect { level += 5; }
    level.min(100)
}
