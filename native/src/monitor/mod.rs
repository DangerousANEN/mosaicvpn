// monitor/mod.rs — Real-time Network Monitor
//
// Собирает метрики сети в реальном времени: ping, jitter, packet loss,
// download/upload speed, traffic total.
// Хранит историю для графиков (last N points).

use std::collections::VecDeque;

const HISTORY_SIZE: usize = 30; // 30 точек = ~30 сек при 1s update

/// Точка истории метрик
#[derive(Debug, Clone, Default)]
pub struct MetricPoint {
    pub timestamp: u64,     // unix seconds
    pub ping: f64,          // ms
    pub jitter: f64,       // ms
    pub packet_loss: f64,   // percent
    pub download_mbps: f64,
    pub upload_mbps: f64,
}

/// Real-time монитор
pub struct NetworkMonitor {
    pub history: VecDeque<MetricPoint>,
    pub last_ping: f64,
    pub last_jitter: f64,
    pub last_packet_loss: f64,
    pub last_download: f64,
    pub last_upload: f64,
    pub total_bytes_in: u64,
    pub total_bytes_out: u64,
    pub session_start: u64,
}

impl NetworkMonitor {
    pub fn new() -> Self {
        Self {
            history: VecDeque::with_capacity(HISTORY_SIZE),
            last_ping: 0.0,
            last_jitter: 0.0,
            last_packet_loss: 0.0,
            last_download: 0.0,
            last_upload: 0.0,
            total_bytes_in: 0,
            total_bytes_out: 0,
            session_start: current_timestamp(),
        }
    }

    /// Добавить новую точку метрик
    pub fn update(&mut self, ping: f64, jitter: f64, packet_loss: f64,
                  download_mbps: f64, upload_mbps: f64) {
        let point = MetricPoint {
            timestamp: current_timestamp(),
            ping, jitter, packet_loss, download_mbps, upload_mbps,
        };
        self.last_ping = ping;
        self.last_jitter = jitter;
        self.last_packet_loss = packet_loss;
        self.last_download = download_mbps;
        self.last_upload = upload_mbps;

        if self.history.len() >= HISTORY_SIZE {
            self.history.pop_front();
        }
        self.history.push_back(point);
    }

    /// Обновить трафик
    pub fn update_traffic(&mut self, bytes_in: u64, bytes_out: u64) {
        self.total_bytes_in = bytes_in;
        self.total_bytes_out = bytes_out;
    }

    /// Получить историю для графика (ping values)
    pub fn ping_history(&self) -> Vec<f64> {
        self.history.iter().map(|p| p.ping).collect()
    }

    /// Получить историю для графика (download values)
    pub fn download_history(&self) -> Vec<f64> {
        self.history.iter().map(|p| p.download_mbps).collect()
    }

    /// Получить историю для графика (upload values)
    pub fn upload_history(&self) -> Vec<f64> {
        self.history.iter().map(|p| p.upload_mbps).collect()
    }

    /// Длительность сессии в секундах
    pub fn session_duration(&self) -> u64 {
        current_timestamp().saturating_sub(self.session_start)
    }

    /// Средний пинг за историю
    pub fn avg_ping(&self) -> f64 {
        if self.history.is_empty() { return 0.0; }
        let sum: f64 = self.history.iter().map(|p| p.ping).sum();
        sum / self.history.len() as f64
    }

    /// Health score (0-100) — вычисляется из метрик
    pub fn health_score(&self) -> u32 {
        if self.history.is_empty() { return 100; }
        let mut score = 100u32;

        // Ping penalty
        if self.last_ping > 200.0 { score -= 20; }
        else if self.last_ping > 100.0 { score -= 10; }
        else if self.last_ping > 50.0 { score -= 5; }

        // Jitter penalty
        if self.last_jitter > 20.0 { score -= 15; }
        else if self.last_jitter > 10.0 { score -= 5; }

        // Packet loss penalty
        if self.last_packet_loss > 5.0 { score -= 30; }
        else if self.last_packet_loss > 1.0 { score -= 15; }
        else if self.last_packet_loss > 0.5 { score -= 5; }

        score
    }
}

fn current_timestamp() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
