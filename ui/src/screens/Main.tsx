import { useEffect, useMemo, useState } from "react";
import { api } from "../api/client";
import type { Server, Status, Profile } from "../api/types";
import { StatusSquare } from "../components/StatusSquare";
import { WorldMap } from "../components/WorldMap";
import { locText } from "../components/locText";
import { ProfileEditor } from "./ProfileEditor";

/**
 * Main — the home screen, equivalent to docs/mockups/main.html.
 * Three columns: status panel · world map · routing register excerpt.
 */
export function Main({ status }: { status: Status }): JSX.Element {
  const [servers, setServers] = useState<Server[]>([]);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [editing, setEditing] = useState<Profile | null>(null);
  const [showEditor, setShowEditor] = useState(false);

  const reloadProfiles = () =>
    api.listProfiles().then(setProfiles).catch(() => {});

  useEffect(() => {
    let cancelled = false;
    api
      .listServers()
      .then((s) => {
        if (!cancelled) setServers(s);
      })
      .catch((e: Error) => {
        if (!cancelled) setErr(e.message);
      });
    reloadProfiles();
    return () => {
      cancelled = true;
    };
  }, []);

  const fastest = useMemo(() => {
    return [...servers]
      .filter((s) => (s.last_test_ms ?? 0) > 0)
      .sort((a, b) => (a.last_test_ms ?? 0) - (b.last_test_ms ?? 0))
      .slice(0, 6);
  }, [servers]);

  const onToggle = async () => {
    setBusy(true);
    setErr(null);
    try {
      if (status.state === "connected" || status.state === "connecting") {
        await api.disconnect();
      } else if (status.server) {
        await api.connect(status.server.id);
      } else if (servers[0]) {
        await api.connect(servers[0].id);
      } else {
        setErr("no servers configured");
      }
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
            val={status.kill_switch ? "on" : "off"}
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

        {/* Profile quick-switcher */}
        {profiles.length > 0 ? (
          <div className="mono" style={{ marginTop: 12, fontSize: 11.5 }}>
            <div style={{ color: "var(--ink-mute)", letterSpacing: "0.1em", textTransform: "uppercase", fontSize: 10, marginBottom: 4 }}>
              Profiles
            </div>
            {profiles.map((p) => (
              <button
                key={p.id}
                type="button"
                className="row"
                style={{ display: "flex", width: "100%", alignItems: "center", gap: 6, padding: "4px 8px" }}
                onClick={() => setEditing(p)}
                title="Edit profile"
              >
                <span style={{ fontSize: 14 }}>{p.icon ?? "🌐"}</span>
                <span>{p.name}</span>
              </button>
            ))}
          </div>
        ) : null}

        <button
          className="btn ghost"
          style={{ marginTop: 8, fontSize: 11, width: "100%" }}
          onClick={() => { setEditing(null); setShowEditor(true); }}
        >
          + New Profile
        </button>

        {showEditor || editing ? (
          <ProfileEditor
            profile={editing ?? undefined}
            onClose={() => { setShowEditor(false); setEditing(null); }}
            onSaved={() => void reloadProfiles()}
          />
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

      <section className="map-wrap">
        <div className="map-eyebrow">
          <span>
            Plate IV · Routes in service · {servers.length} stations
          </span>
          <span style={{ color: "var(--copper)" }}>
            {status.server ? `${status.server.name} · current bearing` : ""}
          </span>
        </div>
        <div className="map">
          <WorldMap
            servers={servers}
            activeServerId={status.server?.id}
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
            <button
              type="button"
              key={s.id}
              className={`row ${status.server?.id === s.id ? "cur" : ""}`}
              onClick={async () => {
                if (busy) return;
                setBusy(true);
                setErr(null);
                try {
                  await api.connect(s.id);
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
                </div>
              </div>
              <span className="ms">
                {s.last_test_ms && s.last_test_ms > 0
                  ? `${s.last_test_ms} ms`
                  : "—"}
              </span>
            </button>
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
}: {
  lab: string;
  val: string | number;
  unit?: string;
}): JSX.Element {
  return (
    <div className="metric">
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

function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  if (n < 1024 * 1024 * 1024) return `${(n / 1024 / 1024).toFixed(2)} MB`;
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function toRoman(n: number): string {
  const map: [number, string][] = [
    [10, "X"],
    [9, "IX"],
    [5, "V"],
    [4, "IV"],
    [1, "I"],
  ];
  let out = "";
  for (const [v, sym] of map) {
    while (n >= v) {
      out += sym;
      n -= v;
    }
  }
  return out;
}
