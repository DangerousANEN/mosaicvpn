import { useEffect, useMemo, useState } from "react";
import { api } from "../api/client";
import type { Server, Status, Subscription } from "../api/types";
import { StatusSquare } from "../components/StatusSquare";
import { WorldMap } from "../components/WorldMap";
import { locText } from "../components/locText";
import {
  roman as toRoman,
  romanLower as toRomanLower,
} from "../components/numerals";
import {
  getFavorites,
  getHistory,
  getNotes,
  recordConnect,
  setFavorite,
} from "../utils/localStore";

/**
 * Main — the home screen, equivalent to docs/mockups/main.html.
 * Three columns: status panel · world map · routing register excerpt.
 *
 * rc28 — adds:
 *   - subscription filter chips above the map (4.5)
 *   - auto-pick fastest one-click button (C)
 *   - kill-switch visual indicator (R) folded into the metric
 */
interface MainProps {
  status: Status;
  /** Optional connect handler from App so the global Space/1-9
   *  hotkeys share the same flow as in-screen clicks (history is
   *  recorded in one place). When omitted the screen falls back to
   *  api.connect directly. */
  onConnectId?: (id: string) => Promise<void> | void;
}

export function Main({ status, onConnectId }: MainProps): JSX.Element {
  const [servers, setServers] = useState<Server[]>([]);
  const [subs, setSubs] = useState<Subscription[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [subFilter, setSubFilter] = useState<string | null>(null);
  // Speedtest one-shot state. setSpeedResult holds the latest run's
  // throughput numbers so the inline result strip survives a status
  // SSE re-render. setSpeedErr surfaces transport / proxy errors.
  const [speedBusy, setSpeedBusy] = useState(false);
  const [speedResult, setSpeedResult] = useState<{
    bytes: number;
    duration_ms: number;
    mbit_per_sec: number;
    http_status: number;
    note?: string;
  } | null>(null);
  const [speedErr, setSpeedErr] = useState<string | null>(null);
  // Favorites + history live in localStorage; we mirror them in
  // state so the register re-orders without forcing a remount.
  const [favs, setFavs] = useState<Set<string>>(() => getFavorites());
  const history = useMemo(() => getHistory(), [favs]); // re-read on toggle
  const notes = useMemo(() => getNotes(), [favs]);

  useEffect(() => {
    let cancelled = false;
    // Initial fetch + 5 s poll so the world-map pin set, latency
    // labels and "fastest" sidebar refresh without forcing the user
    // to navigate away and back. Cheap (one GET per cycle) and the
    // poll pauses while the tab is hidden via document.hidden gating.
    const tick = () => {
      if (typeof document !== "undefined" && document.hidden) return;
      api
        .listServers()
        .then((s) => {
          if (!cancelled) setServers(s);
        })
        .catch((e: Error) => {
          if (!cancelled) setErr(e.message);
        });
    };
    tick();
    const id = window.setInterval(tick, 5000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, []);

  // Subscription roster powers the filter chips above the map.
  // Refreshed on mount; rare-enough that polling isn't worth it.
  useEffect(() => {
    let cancelled = false;
    api
      .listSubscriptions()
      .then((s) => {
        if (!cancelled) setSubs(s);
      })
      .catch(() => {
        /* errors surfaced via the existing err channel */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const filtered = useMemo(() => {
    if (!subFilter) return servers;
    return servers.filter((s) => s.subscription_id === subFilter);
  }, [servers, subFilter]);

  // The Routing register sort folds in (a) starred favorites first,
  // (b) recently-connected stations next, (c) fastest probed last —
  // so the list reads as "your usual stations, then the rest". Each
  // bucket is internally sorted by latency. Servers with no probe
  // and no history fall off the end (slice(0, 6)) so the register
  // doesn't overflow the 3-column frame.
  const fastest = useMemo(() => {
    const now = Date.now();
    const score = (s: Server): number => {
      const ms = (s.last_test_ms ?? 0) > 0 ? s.last_test_ms ?? 9999 : 9999;
      const last = history[s.id] ?? 0;
      // Favorites and recent connects pull a server toward the top.
      // Bucket gaps are larger than any latency contribution so the
      // ordering is stable: fav > recent > everything else.
      let bucket = 200_000;
      if (favs.has(s.id)) bucket = 0;
      else if (last > 0) bucket = 100_000 - Math.min(99_000, (now - last) / 1000);
      return bucket + ms;
    };
    return [...filtered]
      .filter((s) => (s.last_test_ms ?? 0) > 0 || favs.has(s.id) || (history[s.id] ?? 0) > 0)
      .sort((a, b) => score(a) - score(b))
      .slice(0, 6);
  }, [filtered, favs, history]);

  const fastestAll = useMemo(() => {
    return [...filtered]
      .filter((s) => (s.last_test_ms ?? 0) > 0)
      .sort((a, b) => (a.last_test_ms ?? 0) - (b.last_test_ms ?? 0));
  }, [filtered]);

  const callConnect = async (id: string) => {
    if (onConnectId) {
      await onConnectId(id);
    } else {
      await api.connect(id);
      recordConnect(id);
    }
  };

  const onToggle = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (status.state === "connected" || status.state === "connecting") {
        await api.disconnect();
      } else if (status.server) {
        await callConnect(status.server.id);
      } else if (servers.length > 0) {
        // Empty string asks the daemon to reuse LastServerID (persisted
        // across restarts). Falls back to the first available server
        // only when the user has never connected before.
        await callConnect("");
      } else {
        setErr("no servers configured");
      }
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  const onSpeedtest = async () => {
    setSpeedBusy(true);
    setSpeedErr(null);
    setSpeedResult(null);
    try {
      const r = await api.speedtest();
      setSpeedResult(r);
    } catch (e) {
      setSpeedErr((e as Error).message);
    } finally {
      setSpeedBusy(false);
    }
  };

  const onAutoFastest = async () => {
    if (fastestAll.length === 0) {
      setErr("no probed servers — Test all in Pool first");
      return;
    }
    setBusy(true);
    setErr(null);
    try {
      await callConnect(fastestAll[0].id);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="frame">
      <section className="col-left">
        <div className="masthead">
          Mosaic
          <br />
          <span className="italic-copper">vpn</span>
          <span style={{ fontStyle: "normal" }}>.</span>
          <div className="sub">Atlas of routes · Edition I</div>
        </div>

        <div className="h-rule" />

        <div className="status-eyebrow">
          <StatusSquare state={status.state} /> Connection ·{" "}
          {labelFor(status.state)}
        </div>
        <div className="station-name">
          {status.server ? status.server.name : "—"}
        </div>
        {status.server && locText(status.server) ? (
          <div
            className="mono"
            style={{
              marginTop: -4,
              marginBottom: 4,
              fontSize: 11,
              color: "var(--copper)",
              fontStyle: "italic",
              letterSpacing: "0.04em",
            }}
          >
            ⤷ {locText(status.server)}
          </div>
        ) : null}
        <div className="mono" style={{ marginBottom: 4 }}>
          {status.server
            ? `${status.server.address}:${status.server.port}`
            : "no station selected"}
        </div>

        <div className="metrics">
          <Metric
            lab="Latency"
            val={status.latency_ms ?? "—"}
            unit={status.latency_ms ? "ms" : ""}
          />
          <Metric
            lab="Protocol"
            val={status.server?.protocol?.toUpperCase() ?? "—"}
          />
          <Metric
            lab="Down"
            val={fmtBytes(status.bytes_in)}
            unit=""
          />
          <Metric
            lab="Up"
            val={fmtBytes(status.bytes_out)}
            unit=""
          />
          <Metric lab="Mode" val={status.tunnel_mode || "proxy"} />
          <Metric
            lab="Kill-switch"
            val={status.kill_switch ? "armed" : "off"}
            armed={status.kill_switch}
          />
        </div>

        <button
          className={`toggle ${
            status.state === "connected" ? "disconnect" : ""
          }`}
          onClick={onToggle}
          disabled={busy}
        >
          {busy
            ? "…"
            : status.state === "connected"
              ? "« Disconnect"
              : status.state === "connecting"
                ? "Cancel"
                : "Engage tunnel »"}
        </button>
        <button
          type="button"
          className="auto-fastest"
          onClick={onAutoFastest}
          disabled={busy || fastestAll.length === 0 || status.state === "connected"}
          title="Connect to the lowest-latency station from your latest probe results"
        >
          ⚡ Auto-pick fastest
          {fastestAll.length > 0 && fastestAll[0].last_test_ms ? (
            <span className="mono"> · {fastestAll[0].last_test_ms}ms</span>
          ) : null}
        </button>
        <button
          type="button"
          className="auto-fastest"
          onClick={onSpeedtest}
          disabled={speedBusy || status.state !== "connected"}
          title="Pull a 10 MB payload through the active proxy and report Mbps"
          style={{ marginTop: 6 }}
        >
          {speedBusy ? "↓ Speedtest …" : "↓ Speedtest (10 MB)"}
        </button>
        {speedResult ? (
          <div
            className="mono"
            style={{
              marginTop: 6,
              fontSize: 11.5,
              color: "var(--ink-2)",
              letterSpacing: "0.04em",
            }}
          >
            {speedResult.mbit_per_sec.toFixed(2)} Mbit/s · {(speedResult.bytes / 1_048_576).toFixed(1)} MB in {(speedResult.duration_ms / 1000).toFixed(1)}s · HTTP {speedResult.http_status}
            {speedResult.note ? (
              <div
                style={{
                  fontSize: 10.5,
                  color: "var(--ink-mute)",
                  marginTop: 2,
                }}
                title={speedResult.note}
              >
                rough estimate — edge closed connection early
              </div>
            ) : null}
          </div>
        ) : null}
        {speedErr ? (
          <div
            className="mono"
            style={{
              color: "var(--copper)",
              marginTop: 6,
              fontSize: 11,
              wordBreak: "break-word",
              overflowWrap: "anywhere",
              maxHeight: 80,
              overflow: "hidden",
            }}
            title={`speedtest: ${speedErr}`}
          >
            {`speedtest: ${speedErr.replace(/^speedtest:\s*/i, "")}`}
          </div>
        ) : null}
        {err ? (
          <div
            className="mono"
            style={{ color: "var(--copper)", marginTop: 8 }}
          >
            {err}
          </div>
        ) : null}
        {status.state === "connected" && status.proxy_socks ? (
          <div
            className="mono"
            style={{
              marginTop: 10,
              fontSize: 11.5,
              color: "var(--ink-2)",
              letterSpacing: "0.04em",
            }}
            title="Point your system / browser proxy at one of these"
          >
            SOCKS · {status.proxy_socks}
            {status.proxy_http ? `   ·   HTTP · ${status.proxy_http}` : ""}
          </div>
        ) : null}
      </section>

      <section className={`map-wrap ${status.kill_switch ? "armed" : ""}`}>
        <div className="map-eyebrow">
          <span>
            Plate IV · Routes in service · {filtered.length} stations
            {subFilter && subs.find((s) => s.id === subFilter)
              ? ` · ${subs.find((s) => s.id === subFilter)?.name ?? ""}`
              : ""}
          </span>
          <span style={{ color: "var(--copper)" }}>
            {status.server ? `${status.server.name} · current bearing` : ""}
          </span>
        </div>
        {subs.length > 0 ? (
          <div className="sub-chips" role="tablist" aria-label="Subscription filter">
            <button
              type="button"
              className={`sub-chip ${subFilter === null ? "cur" : ""}`}
              onClick={() => setSubFilter(null)}
              title="Show every subscription"
            >
              All
            </button>
            {subs.map((s, i) => (
              <button
                key={s.id}
                type="button"
                className={`sub-chip ${subFilter === s.id ? "cur" : ""}`}
                onClick={() => setSubFilter(s.id)}
                title={s.name || s.url || s.id}
              >
                {toRomanLower(i + 1)}
              </button>
            ))}
          </div>
        ) : null}
        <div className="map">
          <WorldMap
            servers={filtered}
            activeServerId={status.server?.id}
            myLocation={status.my_location}
            onPinClick={async (id) => {
              if (busy) return;
              setBusy(true);
              setErr(null);
              try {
                await callConnect(id);
              } catch (e) {
                setErr((e as Error).message);
              } finally {
                setBusy(false);
              }
            }}
          />
        </div>
      </section>

      <section className="col-right">
        <h4>Routing register</h4>
        {fastest.length === 0 ? (
          <p className="mono" style={{ color: "var(--ink-mute)" }}>
            No latency data yet. Open <em>Pool</em> and click <b>Test all</b>
            {" "}to probe stations.
          </p>
        ) : (
          fastest.map((s, i) => (
            <div
              key={s.id}
              className={`row ${status.server?.id === s.id ? "cur" : ""}`}
            >
              <button
                type="button"
                className={`fav-btn ${favs.has(s.id) ? "on" : ""}`}
                onClick={(e) => {
                  e.stopPropagation();
                  const next = setFavorite(s.id, !favs.has(s.id));
                  setFavs(new Set(next));
                }}
                title={favs.has(s.id) ? "Unstar" : "Star · pins to top of register"}
                aria-label="Toggle favorite"
              >
                {favs.has(s.id) ? "★" : "☆"}
              </button>
              <button
                type="button"
                className="row-body"
                onClick={async () => {
                  if (busy) return;
                  setBusy(true);
                  setErr(null);
                  try {
                    await callConnect(s.id);
                  } catch (e) {
                    setErr((e as Error).message);
                  } finally {
                    setBusy(false);
                  }
                }}
                disabled={busy}
                title="Connect to this station"
              >
                <span className="num">{toRoman(i + 1)}</span>
                <div>
                  <div className="city">{s.name}</div>
                  <div className="proto">
                    {s.protocol}
                    {locText(s) ? (
                      <span className="loc-inline"> · {locText(s)}</span>
                    ) : null}
                    {notes[s.id] ? (
                      <span className="loc-inline italic-mute">
                        {" "}· {notes[s.id]}
                      </span>
                    ) : null}
                  </div>
                </div>
                <span className="ms">
                  {s.last_test_ms && s.last_test_ms > 0
                    ? `${s.last_test_ms} ms`
                    : "—"}
                </span>
              </button>
            </div>
          ))
        )}
      </section>
    </div>
  );
}

function Metric({
  lab,
  val,
  unit,
  armed,
}: {
  lab: string;
  val: string | number;
  unit?: string;
  armed?: boolean;
}): JSX.Element {
  return (
    <div className={`metric ${armed ? "armed" : ""}`}>
      <div className="lab">{lab}</div>
      <div className="val">
        {val}
        {unit ? <span className="unit">{unit}</span> : null}
      </div>
    </div>
  );
}

function labelFor(state: Status["state"]): string {
  switch (state) {
    case "connected":
      return "Active";
    case "connecting":
      return "Connecting";
    case "error":
      return "Error";
    default:
      return "Standby";
  }
}

// fmtBytes renders a byte count with a unit, or an em dash when there's
// no traffic yet — distinguishes "not implemented / not connected" from
// "0 B sent so far". The clash-api poller fills these in once the user
// actually connects.
function fmtBytes(n: number): string {
  if (!n || n <= 0) return "—";
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(2)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}


