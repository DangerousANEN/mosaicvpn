// feed/mod.rs — Live Protection Feed
//
// Поток событий безопасности на главном экране.
// Хранит последние N событий, отдает их в UI.

use std::collections::VecDeque;

const MAX_FEED_ITEMS: usize = 50;

/// Событие для Live Feed
#[derive(Debug, Clone)]
pub struct FeedItem {
    pub id: u64,
    pub timestamp: u64,     // unix seconds
    pub severity: String,   // "info" | "success" | "warning" | "error"
    pub icon: String,       // emoji или символ
    pub message: String,
}

/// Live Protection Feed
pub struct ProtectionFeed {
    items: VecDeque<FeedItem>,
    next_id: u64,
}

impl ProtectionFeed {
    pub fn new() -> Self {
        Self {
            items: VecDeque::with_capacity(MAX_FEED_ITEMS),
            next_id: 1,
        }
    }

    /// Добавить событие
    pub fn add(&mut self, severity: &str, icon: &str, message: &str) -> &FeedItem {
        let item = FeedItem {
            id: self.next_id,
            timestamp: current_timestamp(),
            severity: severity.into(),
            icon: icon.into(),
            message: message.into(),
        };
        self.next_id += 1;

        if self.items.len() >= MAX_FEED_ITEMS {
            self.items.pop_front();
        }
        self.items.push_back(item);
        self.items.back().unwrap()
    }

    /// Получить последние N событий (в порядке новых → старых)
    pub fn recent(&self, count: usize) -> Vec<FeedItem> {
        self.items.iter().rev().take(count).cloned().collect()
    }

    /// Получить все события
    pub fn all(&self) -> Vec<FeedItem> {
        self.items.iter().rev().cloned().collect()
    }

    /// Очистить
    pub fn clear(&mut self) {
        self.items.clear();
    }
}

fn current_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
