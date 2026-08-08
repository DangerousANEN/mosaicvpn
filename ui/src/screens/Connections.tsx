import { useEffect, useRef, useState } from "react";
import { api } from "../api/client";
import type { Connection } from "../api/types";

/**
 * Connections — live connection table. Mirrors the Throne connections view.
 *
 * Polls /v1/connections every 3s (toggleable). Each row shows the
 * network, destination, outbound tag, process, traffic counters, and
 * chain. Individual connections can be closed, or all at once.
 */
export function Connections(): JSX.Element {
  const [conns, setConns] = useState<Connection[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [auto, setAuto] = useState(true);
  const timer = useRef<number | null>(null);

  const reload = async () => {
    try {
      const list = await api.listConnections();
      setConns(list);
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  useEffect(() => {
    void reload();
    if (auto) {
      timer.current = window.setInterval(() => void reload(), 3000);
    }
    return () => {
      if (timer.current) window.clearInterval(timer.current);
    };
  }, [auto]);

  const onClose = async (id: string) => {
    setBusy(id);
    try {
      await api.closeConnection(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onCloseAll = async () => {
    setBusy("all");
    try {
      await api.closeAllConnections();
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  return (
    <div className="conn-frame">
      <div className="conn-toolbar">
        <label className="conn-toggle">
          <input
            type="checkbox"
            checked={auto}
            onChange={(e) => setAuto(e.target.checked)}
          />
          Auto-refresh
        </label>
        <div className="spacer" />
        <span className="conn-dim">{conns.length} active</span>
        <button
          className="conn-close-btn"
          onClick={() => void onCloseAll()}
          disabled={busy === "all" || conns.length === 0}
        >
          {busy === "all" ? "…" : "Close All"}
        </button>
      </div>

      {err ? <div className="conn-dim">⚠ {err}</div> : null}

      {conns.length === 0 ? (
        <div className="conn-empty">No active connections</div>
      ) : (
        <table className="conn-table">
          <thead>
            <tr>
              <th>Net</th>
              <th>Destination</th>
              <th>Outbound</th>
              <th>Process</th>
              <th>↑ Upload</th>
              <th>↓ Download</th>
              <th>Chain</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {conns.map((c) => (
              <tr key={c.id}>
                <td>
                  <span className={`conn-badge ${c.network}`}>
                    {c.network.toUpperCase()}
                  </span>
                </td>
                <td>
                  {c.domain ? (
                    c.domain
                  ) : (
                    <span className="conn-dim">
                      {c.ip}:{c.port}
                    </span>
                  )}
                </td>
                <td>
                  <span
                    className={`conn-outbound ${outboundClass(c.outbound)}`}
                  >
                    {c.outbound}
                  </span>
                </td>
                <td className="conn-dim">{c.process ?? "—"}</td>
                <td>{fmtBytes(c.upload)}</td>
                <td>{fmtBytes(c.download)}</td>
                <td className="conn-dim">{c.chain ?? "—"}</td>
                <td>
                  <button
                    className="conn-close-btn"
                    onClick={() => void onClose(c.id)}
                    disabled={busy === c.id}
                  >
                    {busy === c.id ? "…" : "✕"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

function outboundClass(tag: string): string {
  if (tag === "direct") return "direct";
  if (tag === "block") return "block";
  return "proxy";
}

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / (1024 * 1024)).toFixed(1)} MB`;
  return `${(n / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}
