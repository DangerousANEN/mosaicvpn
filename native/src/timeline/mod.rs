// timeline/mod.rs — Session Timeline
//
// Хранит историю подключений: время, сервер, трафик, пинг, IP смены, реконнекты.
// Сохраняется в JSON файл между запусками.

use std::collections::VecDeque;
use std::path::PathBuf;

const MAX_TIMELINE_ITEMS: usize = 200;

/// Тип записи в timeline
#[derive(Debug, Clone)]
pub enum TimelineEventType {
    Connect,
    Disconnect,
    Reconnect,
    ServerSwitch,
    IpChange,
    TrafficReport,
    Error,
}

impl TimelineEventType {
    pub fn as_str(&self) -> &str {
        match self {
            TimelineEventType::Connect => "connect",
            TimelineEventType::Disconnect => "disconnect",
            TimelineEventType::Reconnect => "reconnect",
            TimelineEventType::ServerSwitch => "server_switch",
            TimelineEventType::IpChange => "ip_change",
            TimelineEventType::TrafficReport => "traffic",
            TimelineEventType::Error => "error",
        }
    }

    pub fn icon(&self) -> &str {
        match self {
            TimelineEventType::Connect => "🔗",
            TimelineEventType::Disconnect => "⚡",
            TimelineEventType::Reconnect => "🔄",
            TimelineEventType::ServerSwitch => "🔀",
            TimelineEventType::IpChange => "🔄",
            TimelineEventType::TrafficReport => "📊",
            TimelineEventType::Error => "❌",
        }
    }
}

/// Запись в timeline
#[derive(Debug, Clone)]
pub struct TimelineEntry {
    pub timestamp: u64,
    pub event_type: TimelineEventType,
    pub server_name: String,
    pub server_city: String,
    pub server_country: String,
    pub bytes_in: u64,
    pub bytes_out: u64,
    pub avg_ping: u32,
    pub duration_secs: u64,
    pub ip_address: String,
    pub description: String,
}

/// Session Timeline
pub struct SessionTimeline {
    entries: VecDeque<TimelineEntry>,
    storage_path: Option<PathBuf>,
}

impl SessionTimeline {
    pub fn new() -> Self {
        Self {
            entries: VecDeque::with_capacity(MAX_TIMELINE_ITEMS),
            storage_path: None,
        }
    }

    /// Установить путь для сохранения
    pub fn with_storage(mut self, path: PathBuf) -> Self {
        self.storage_path = Some(path.clone());
        // Try to load existing
        if let Ok(data) = std::fs::read_to_string(&path) {
            // TODO: deserialize from JSON when serde derive added
            // For now, start fresh
            let _ = data;
        }
        self
    }

    /// Добавить запись
    pub fn add(&mut self, entry: TimelineEntry) {
        if self.entries.len() >= MAX_TIMELINE_ITEMS {
            self.entries.pop_front();
        }
        self.entries.push_back(entry);
        self.save();
    }

    /// Получить последние записи
    pub fn recent(&self, count: usize) -> Vec<&TimelineEntry> {
        self.entries.iter().rev().take(count).collect()
    }

    /// Получить все записи
    pub fn all(&self) -> Vec<&TimelineEntry> {
        self.entries.iter().rev().collect()
    }

    /// Очистить
    pub fn clear(&mut self) {
        self.entries.clear();
        self.save();
    }

    fn save(&self) {
        if let Some(ref path) = self.storage_path {
            // TODO: serialize to JSON
            let _ = path;
        }
    }
}
