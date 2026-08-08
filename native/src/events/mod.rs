// events/mod.rs — Event Bus (pub/sub) между Rust ядром и UI
//
// Архитектура:
// - EventBus хранит список подписчиков (callback'ов)
// - Любой модуль может publish(event) → все подписчики получат
// - UI подписывается через slint::invoke_from_event_loop
// - Полностью thread-safe (Arc<RwLock<Vec<...>>>)

use std::sync::{Arc, RwLock};

/// Тип события в системе
#[derive(Debug, Clone)]
pub enum AppEvent {
    /// VPN статус изменился (connected/disconnected/connecting)
    StatusChanged(String),

    /// Privacy Score пересчитан
    PrivacyScoreUpdated { score: u32, checks: Vec<crate::security::CheckResult> },

    /// Сетевой монитор обновился (ping/traffic)
    MonitorUpdated {
        ping: u32,
        jitter: u32,
        download_mbps: f64,
        upload_mbps: f64,
        packet_loss: f64,
    },

    /// Новый сервер выбран
    ServerSelected { id: String, city: String, country: String },

    /// Server Health обновлён
    ServerHealthUpdated { server_id: String, health: u32 },

    /// Событие защиты (для Live Feed)
    ProtectionEvent { severity: String, message: String, icon: String },

    /// Профиль изменён
    ProfileChanged { name: String },

    /// Состояние подключения (анимированные этапы)
    ConnectionStage { stage: String, progress: u32 },

    /// Timeline событие
    TimelineEvent { timestamp: String, event_type: String, description: String },
}

/// Подписчик — функция которая вызывается при событии
type Subscriber = Box<dyn Fn(&AppEvent) + Send + Sync>;

/// Event Bus — singleton, shared across threads
pub struct EventBus {
    subscribers: RwLock<Vec<Subscriber>>,
}

impl EventBus {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            subscribers: RwLock::new(Vec::new()),
        })
    }

    /// Подписаться на события. Возвращает ID для отписки.
    pub fn subscribe(&self, callback: Subscriber) -> usize {
        let mut subs = self.subscribers.write().unwrap();
        subs.push(callback);
        subs.len() - 1
    }

    /// Опубликовать событие → все подписчики получат
    pub fn publish(&self, event: &AppEvent) {
        let subs = self.subscribers.read().unwrap();
        for sub in subs.iter() {
            (sub)(event);
        }
    }
}

/// Helper: проверяет, есть ли подписчики
impl EventBus {
    pub fn has_subscribers(&self) -> bool {
        self.subscribers.read().map_or(0, |s| s.len()) > 0
    }
}
