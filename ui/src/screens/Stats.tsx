import { useEffect, useRef, useState } from "react";
import { api } from "../api/client";
import type { TrafficStats } from "../api/types";

/**
 * Stats — traffic statistics dashboard.
 *
 * Shows total upload/download, current speeds, connection counts, and
 * a simple SVG bar chart of the traffic series. Polls every 5s when
 * auto-refresh is on.
 */
export function Stats(): JSX.Element {
  const [stats, setStats] = useState<TrafficStats | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [auto, setAuto] = useState(true);
  const timer = useRef<number | null>(null);

  const reload = async () => {
    try {
      const s = await api.getStats();
      setStats(s);
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  useEffect(() => {
    void reload();
    if (auto) {
      timer.current = window.setInterval(() => void reload(), 5000);
    }
    return () => {
      if (timer.current) window.clearInterval(timer.current);
    };
  }, [auto]);

  const onReset = async () => {
    setBusy(true);
    try {
      await api.resetStats();
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const series = stats?.series ?? [];
  const maxBar = Math.max(1, ...series.map((p) => Math.max(p.up ?? 0, p.down ?? 0)));

  return (
    <div className="stats-frame">
      {err ? <div className="conn-dim">⚠ {err}</div> : null}

      <div className="stats-grid">
        <div className="stat-card">
          <div className="lab">↓ Total In</div>
          <div className="val">{stats ? fmtBytes(stats.total_bytes_in) : "—"}</div>
        </div>
        <div className="stat-card">
          <div className="lab">↑ Total Out</div>
          <div className="val">{stats ? fmtBytes(stats.total_bytes_out) : "—"}</div>
        </div>
        <div className="stat-card">
          <div className="lab">Speed ↓</div>
          <div className="val">
            {stats?.down_speed ? fmtSpeed(stats.down_speed) : "—"}
          </div>
          <div className="sub">
            ↑ {stats?.up_speed ? fmtSpeed(stats.up_speed) : "—"}
          </div>
        </div>
        <div className="stat-card">
          <div className="lab">Connections</div>
          <div className="val">{stats?.conn_count ?? "—"}</div>
          <div className="sub">
            peak {stats?.peak_conn_count ?? "—"}
          </div>
        </div>
      </div>

      {series.length > 0 ? (
        <div className="stats-chart">
          <div className="lab">Traffic (last {series.length} samples)</div>
          <svg viewBox={`0 0 ${series.length * 12} 120`} preserveAspectRatio="none">
            {series.map((p, i) => {
              const up = ((p.up ?? 0) / maxBar) * 100;
              const down = ((p.down ?? p.bout ?? 0) / maxBar) * 100;
              return (
                <g key={i}>
                  <rect
                    className="stats-bar up"
                    x={i * 12 + 1}
                    y={120 - up}
                    width="4"
                    height={up}
                  />
                  <rect
                    className="stats-bar"
                    x={i * 12 + 6}
                    y={120 - down}
                    width="4"
                    height={down}
                  />
                </g>
              );
            })}
          </svg>
        </div>
      ) : (
        <div className="conn-empty">No traffic data yet</div>
      )}

      <div className="stats-actions">
        <label className="conn-toggle">
          <input
            type="checkbox"
            checked={auto}
            onChange={(e) => setAuto(e.target.checked)}
          />
          Auto-refresh
        </label>
        <div className="spacer" />
        <button
          className="conn-close-btn"
          onClick={() => void onReset()}
          disabled={busy}
        >
          {busy ? "Resetting…" : "Reset Stats"}
        </button>
      </div>
    </div>
  );
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

function fmtSpeed(bps: number): string {
  return `${fmtBytes(bps)}/s`;
}
