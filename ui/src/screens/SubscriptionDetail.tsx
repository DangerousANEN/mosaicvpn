import { useEffect, useMemo, useRef, useState, type JSX } from "react";
import { api } from "../api/client";
import type { Subscription } from "../api/types";
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

  const onTestOne = async (id: string) => {
    setBusy(`test:${id}`);
    setErr(null);
    try {
      await api.testServer(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onUrlTest = async (id: string) => {
    setBusy(`url:${id}`);
    setErr(null);
    try {
      const r = await api.urlTestServer(id);
      if (r.error) {
        setErr(`Verify: ${r.error}`);
      } else {
        setErr(`Verify: HTTP ${r.status} in ${r.rtt_ms}ms`);
      }
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onTestAllTCP = async () => {
    setBusy("test-all");
    setErr(null);
    try {
      await api.testAllServers(subscription.id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  // rc40 — Test all (URL) is cancellable.  Clicking the button
  // again while it is running flips `cancelRef` to true; the
  // worker loop notices on the next iteration and returns early,
  // and the in-flight HTTP request gets aborted via the
  // controller below so we don't wait an extra ~12 s for the
  // current sing-box probe to finish before stopping.
  const cancelRef = useRef(false);
  const inflightCtl = useRef<AbortController | null>(null);

  const onTestAllURLStop = () => {
    cancelRef.current = true;
    inflightCtl.current?.abort();
  };

  const onTestAllURL = async () => {
    if (own.length === 0) return;
    cancelRef.current = false;
    setBusy("url-all:0");
    setErr(null);
    let ok = 0;
    let bad = 0;
    let stopped = false;
    for (let i = 0; i < own.length; i++) {
      if (cancelRef.current) {
        stopped = true;
        break;
      }
      setBusy(`url-all:${i + 1}`);
      const ctl = new AbortController();
      inflightCtl.current = ctl;
      try {
        const r = await api.urlTestServer(own[i].id, ctl.signal);
        if (r.error) bad++;
        else ok++;
      } catch (e) {
        // AbortError counts as cancelled; everything else as a
        // failure of this individual server.
        if ((e as Error).name === "AbortError") {
          stopped = true;
          break;
        }
        bad++;
      } finally {
        inflightCtl.current = null;
      }
    }
    setBusy(null);
    setErr(
      stopped
        ? `Verify all: stopped after ${ok + bad} of ${own.length} (${ok} ok, ${bad} failed)`
        : `Verify all: ${ok} ok, ${bad} failed (of ${own.length})`,
    );
    await reload();
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
            onClick={onTestAllTCP}
            disabled={busy !== null || own.length === 0}
            title="TCP-probe every station in this subscription (fast — a few seconds)"
          >
            {busy === "test-all" ? "Testing…" : "Test all (TCP)"}
          </button>
          {/* rc40 — Test all (URL) becomes a Stop button while it
              is running so the user can interrupt without waiting
              for the remaining ~12 s × N timeout. */}
          {busy?.startsWith("url-all:") ? (
            <button
              className="btn ghost"
              onClick={onTestAllURLStop}
              title="Stop the running Verify-all loop"
            >
              Stop ({busy.slice("url-all:".length)} / {own.length})
            </button>
          ) : (
            <button
              className="btn ghost"
              onClick={onTestAllURL}
              disabled={busy !== null || own.length === 0}
              title="Spin up sing-box for each station and fetch generate_204 (slow — ~3-5 s per server, serialised). Click again to stop."
            >
              Test all (URL)
            </button>
          )}
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
            <th className="num">Verify</th>
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
            // rc40/rc41 — Verify column.  Cell text is one of:
            //   ✓ <ms>     last URL test succeeded with HTTP 204
            //   <status>   last URL test got an unexpected status
            //   fail       last URL test errored (hover for detail)
            //   —          never run
            //
            // We gate on `last_url_test_at` (timestamp set only on
            // a real probe) so a stale/empty `last_url_test_error`
            // string from older builds doesn't display as "fail" —
            // a row that has *never* been url-tested must show "—".
            const urlMs = s.last_url_test_ms ?? 0;
            const urlStatus = s.last_url_test_status ?? 0;
            const urlErr = s.last_url_test_error;
            const urlAt = s.last_url_test_at;
            const everTested = !!urlAt && urlAt !== "0001-01-01T00:00:00Z";
            let verifyCell: JSX.Element;
            let verifyTitle: string | undefined;
            if (!everTested) {
              verifyCell = <span className="italic-mute">—</span>;
            } else if (urlErr) {
              verifyCell = <span className="verify-cell verify-fail">fail</span>;
              verifyTitle = urlErr;
            } else if (urlStatus === 204 || urlStatus === 200) {
              verifyCell = (
                <span className="verify-cell verify-ok">{`✓ ${urlMs}ms`}</span>
              );
            } else if (urlStatus > 0) {
              verifyCell = (
                <span className="verify-cell verify-warn">{urlStatus}</span>
              );
            } else {
              verifyCell = <span className="italic-mute">—</span>;
            }
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
                <td
                  className="num mono"
                  title={s.last_test_error || undefined}
                >
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
                <td className="num mono" title={verifyTitle}>
                  {verifyCell}
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
                    onClick={() => onTestOne(s.id)}
                    disabled={busy === `test:${s.id}`}
                    title="TCP probe — confirms remote port answers"
                  >
                    {busy === `test:${s.id}` ? "…" : "Test"}
                  </button>
                  <button
                    type="button"
                    className="btn ghost xs"
                    onClick={() => onUrlTest(s.id)}
                    disabled={busy === `url:${s.id}`}
                    title="URL test — fetches generate_204 through this proxy to prove real internet access"
                  >
                    {busy === `url:${s.id}` ? "…" : "Verify"}
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
