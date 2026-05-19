import { useEffect, useMemo, useRef, useState, type JSX } from "react";
import { api } from "../api/client";
import type { Server, Subscription } from "../api/types";
import { useLiveServers } from "../hooks/useLiveServers";
import { locText } from "../components/locText";
import { Sparkline } from "../components/Sparkline";
import {
  getFavorites,
  setFavorite,
  getNotes,
  setNote,
  getLatencySeries,
  recordLatency,
} from "../utils/localStore";

/**
 * SubscriptionDetail — full-screen drill-down for a single
 * subscription. Reachable via the URL hash `#sub=<id>`. Pool's
 * "Browse stations" button now navigates here instead of inline-
 * expanding, so the user gets a dedicated page with the entire
 * server table (name / city / country / protocol / RTT / Connect)
 * instead of a cramped inline list.
 *
 * rc28 — adds favorite stars (G), per-server notes (T), and a 20-
 * sample latency sparkline (H). All three live entirely in
 * localStorage; the daemon doesn't need to know about them.
 *
 * Polling lives in `useLiveServers` so RTT / dead counts refresh
 * every 5 s without the user re-navigating.
 */
export function SubscriptionDetail({
  subscription,
  activeServerId,
  onBack,
  onConnect,
}: {
  subscription: Subscription;
  activeServerId?: string;
  onBack: () => void;
  onConnect: (serverID: string) => Promise<void> | void;
}): JSX.Element {
  const { servers, error: liveErr, reload } = useLiveServers();
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [favs, setFavs] = useState<Set<string>>(() => getFavorites());
  const [notes, setNotes] = useState<Record<string, string>>(() => getNotes());
  // Sparkline history is kept in localStorage; we mirror it into
  // state so a probe-result update re-renders the cell without a
  // full table reload.
  const [seriesTick, setSeriesTick] = useState(0);
  const [copiedId, setCopiedId] = useState<string | null>(null);

  const own = useMemo(
    () => servers.filter((s) => s.subscription_id === subscription.id),
    [servers, subscription.id],
  );

  // Whenever a probe lands on a fresh last_test_ms value, fold it
  // into the per-server latency history. We track "last recorded ms"
  // per server in a ref so we don't re-record the same probe on
  // every 5 s poll cycle.
  const lastSeenMs = useRef<Record<string, number>>({});
  useEffect(() => {
    let touched = false;
    for (const s of own) {
      const ms = s.last_test_ms ?? 0;
      const seen = lastSeenMs.current[s.id];
      if (seen === ms) continue;
      lastSeenMs.current[s.id] = ms;
      // Skip 0 / undefined so we don't pollute the series with the
      // initial "never probed" sentinel.
      if (ms === 0 || s.last_test_ms === undefined) continue;
      recordLatency(s.id, ms);
      touched = true;
    }
    if (touched) setSeriesTick((t) => t + 1);
  }, [own]);

  const onPingOne = async (id: string) => {
    setBusy(`ping:${id}`);
    setErr(null);
    try {
      await api.pingServer(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onPingAll = async () => {
    setBusy("ping-all");
    setErr(null);
    try {
      await api.pingAllServers(subscription.id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onConnectClick = async (id: string) => {
    setBusy(`conn:${id}`);
    setErr(null);
    try {
      await onConnect(id);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onToggleFav = (id: string) => {
    const next = setFavorite(id, !favs.has(id));
    setFavs(new Set(next));
  };

  const onChangeNote = (id: string, text: string) => {
    const next = setNote(id, text);
    setNotes({ ...next });
  };

  // Copy the original protocol URI (vless://, ss://, hy2://, etc.)
  // preserved in server.raw.uri during subscription parsing. Falls
  // back to a reconstructed URI if raw.uri is absent (older records
  // that predate rc44 don't have it — they'll only ship the URI
  // after the next subscription refresh).
  const onCopyURI = async (srv: Server) => {
    const uri = serverCopyURI(srv);
    if (!uri) {
      setErr("Copy URI: this server has no known URI — refresh the subscription");
      return;
    }
    try {
      await navigator.clipboard.writeText(uri);
      setCopiedId(srv.id);
      window.setTimeout(() => {
        setCopiedId((cur) => (cur === srv.id ? null : cur));
      }, 1500);
    } catch (e) {
      setErr(`Copy URI: ${(e as Error).message}`);
    }
  };

  const banner = err ?? liveErr;

  return (
    <div className="pool-frame">
      <header className="pool-mast">
        <div>
          <div className="pool-name">
            <button className="btn ghost xs" onClick={onBack}>
              ← Pool
            </button>{" "}
            {subscription.name || hostFrom(subscription.url)} <i>—</i> stations
          </div>
          <div className="pool-mast-sub mono" title={subscription.url}>
            {redactedURL(subscription.url)} · {own.length} servers
          </div>
        </div>
        <div className="pool-mast-right" style={{ display: "flex", gap: 8 }}>
          <button
            className="btn ghost"
            onClick={onPingAll}
            disabled={busy !== null || own.length === 0}
            title="Ping every station in this subscription using the selected ping method"
          >
            {busy === "ping-all" ? "Pinging…" : "Ping all"}
          </button>
        </div>
      </header>

      {banner ? <div className="pool-error">{banner}</div> : null}

      <div className="sub-detail-scroll">
      <table className="sub-detail-table">
        <thead>
          <tr>
            <th aria-label="favorite" />
            <th>Name</th>
            <th>City</th>
            <th>Country</th>
            <th>Proto</th>
            <th className="num">Port</th>
            <th className="num">RTT</th>
            <th>Trend</th>
            <th>Note</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {own.length === 0 ? (
            <tr>
              <td colSpan={11} className="empty italic-mute">
                — no servers yet, refresh the subscription —
              </td>
            </tr>
          ) : null}
          {own.map((s) => {
            const ms = s.last_test_ms;
            const dead = (ms ?? 0) < 0;
            const live = (ms ?? 0) > 0 && !s.last_test_error;
            const isActive = s.id === activeServerId;
            const fav = favs.has(s.id);
            const series = getLatencySeries(s.id);
            void seriesTick; // re-render trigger
            return (
              <tr key={s.id} className={isActive ? "cur" : ""}>
                <td className="num">
                  <button
                    type="button"
                    className={`fav-btn ${fav ? "on" : ""}`}
                    onClick={() => onToggleFav(s.id)}
                    title={fav ? "Unfavorite" : "Favorite"}
                    aria-label={fav ? "Remove from favorites" : "Add to favorites"}
                  >
                    {fav ? "★" : "☆"}
                  </button>
                </td>
                <td>{s.name}</td>
                <td>{s.city || "—"}</td>
                <td>{s.country || locText(s) || "—"}</td>
                <td className="mono">{s.protocol}</td>
                <td className="num mono">{s.port}</td>
                <td className="num mono" title={s.last_test_error || undefined}>
                  {dead
                    ? "fail"
                    : live
                      ? `${ms}ms`
                      : "—"}
                </td>
                <td>
                  {series.length > 1 ? (
                    <Sparkline data={series} width={80} height={20} />
                  ) : (
                    <span className="italic-mute" style={{ fontSize: 11 }}>
                      —
                    </span>
                  )}
                </td>
                <td>
                  <input
                    type="text"
                    className="note-input"
                    value={notes[s.id] ?? ""}
                    onChange={(e) => onChangeNote(s.id, e.target.value)}
                    placeholder="…"
                    title="Personal label / note for this server"
                  />
                </td>
                <td className="actions">
                  <button
                    type="button"
                    className="btn ghost xs"
                    onClick={() => onPingOne(s.id)}
                    disabled={busy === `ping:${s.id}`}
                    title="Ping — measure latency using the selected method"
                  >
                    {busy === `ping:${s.id}` ? "…" : "Ping"}
                  </button>
                  <button
                    type="button"
                    className="btn ghost xs"
                    onClick={() => onCopyURI(s)}
                    title="Copy this server's subscription URI to the clipboard"
                  >
                    {copiedId === s.id ? "✓" : "Copy URI"}
                  </button>
                  <button
                    type="button"
                    className="btn primary xs"
                    onClick={() => onConnectClick(s.id)}
                    disabled={busy === `conn:${s.id}`}
                  >
                    {busy === `conn:${s.id}`
                      ? "…"
                      : isActive
                        ? "Active"
                        : "Connect"}
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      </div>
    </div>
  );
}

function hostFrom(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}

/**
 * serverCopyURI returns the protocol URI for this server, preferring the
 * original string preserved at parse time in `raw.uri`. For records that
 * predate rc44 (no raw.uri), fall back to reconstructing a best-effort
 * URI from the typed fields. Returns `null` if we have neither.
 */
function serverCopyURI(s: Server): string | null {
  const rawUri =
    s.raw && typeof s.raw["uri"] === "string" ? (s.raw["uri"] as string) : null;
  if (rawUri) return rawUri;

  // Best-effort reconstruction. This is lossy for VLESS (no UUID/REALITY
  // keys) but at least produces something that identifies the server.
  if (!s.address || !s.port) return null;
  const frag = encodeURIComponent(s.name || `${s.protocol}-${s.address}`);
  switch (s.protocol) {
    case "vless":
      return `vless://${s.address}:${s.port}#${frag}`;
    case "hysteria2":
      return `hy2://${s.address}:${s.port}#${frag}`;
    case "shadowsocks":
      return `ss://${s.address}:${s.port}#${frag}`;
    case "naive":
      return `naive+https://${s.address}:${s.port}#${frag}`;
    default:
      return `${s.protocol}://${s.address}:${s.port}#${frag}`;
  }
}

function redactedURL(url: string): string {
  try {
    const u = new URL(url);
    if (u.searchParams.has("token")) {
      const tok = u.searchParams.get("token") ?? "";
      const tail = tok.length > 4 ? tok.slice(-4) : tok;
      u.searchParams.set("token", `••••${tail}`);
    }
    return u.toString();
  } catch {
    return url;
  }
}
