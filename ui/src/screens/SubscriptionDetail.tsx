import { useMemo, useState } from "react";
import { api } from "../api/client";
import type { Subscription } from "../api/types";
import { useLiveServers } from "../hooks/useLiveServers";
import { locText } from "../components/locText";

/**
 * SubscriptionDetail — full-screen drill-down for a single
 * subscription. Reachable via the URL hash `#sub=<id>`. Pool's
 * "Browse stations" button now navigates here instead of inline-
 * expanding, so the user gets a dedicated page with the entire
 * server table (name / city / country / protocol / RTT / Connect)
 * instead of a cramped inline list.
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

  const own = useMemo(
    () => servers.filter((s) => s.subscription_id === subscription.id),
    [servers, subscription.id],
  );

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

  // onTestAllURL spins an ephemeral sing-box per server (serialised on
  // the daemon side via urlTestMu) and walks the entire subscription.
  // Each pass takes ~3-5 s; we surface progress ("Verifying X / N…")
  // in the button so a 1 000-server feed doesn't look hung. Errors
  // collected per server land in the banner as a short summary; the
  // full per-server result still shows next to the row Verify button
  // when the user runs it individually.
  const onTestAllURL = async () => {
    if (own.length === 0) return;
    setBusy("url-all:0");
    setErr(null);
    let ok = 0;
    let bad = 0;
    for (let i = 0; i < own.length; i++) {
      setBusy(`url-all:${i + 1}`);
      try {
        const r = await api.urlTestServer(own[i].id);
        if (r.error) bad++;
        else ok++;
      } catch {
        bad++;
      }
    }
    setBusy(null);
    setErr(`Verify all: ${ok} ok, ${bad} failed (of ${own.length})`);
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
          <div className="pool-mast-sub mono">
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
          <button
            className="btn ghost"
            onClick={onTestAllURL}
            disabled={busy !== null || own.length === 0}
            title="Spin up sing-box for each station and fetch generate_204 (slow — ~3-5 s per server, serialised)"
          >
            {busy?.startsWith("url-all:")
              ? `Verifying ${busy.slice("url-all:".length)} / ${own.length}…`
              : "Test all (URL)"}
          </button>
        </div>
      </header>

      {banner ? <div className="pool-error">{banner}</div> : null}

      <table className="sub-detail-table">
        <thead>
          <tr>
            <th>Name</th>
            <th>City</th>
            <th>Country</th>
            <th>Proto</th>
            <th className="num">Port</th>
            <th className="num">RTT</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {own.length === 0 ? (
            <tr>
              <td colSpan={7} className="empty italic-mute">
                — no servers yet, refresh the subscription —
              </td>
            </tr>
          ) : null}
          {own.map((s) => {
            const ms = s.last_test_ms;
            const dead = (ms ?? 0) < 0;
            const live = (ms ?? 0) > 0 && !s.last_test_error;
            const isActive = s.id === activeServerId;
            return (
              <tr key={s.id} className={isActive ? "cur" : ""}>
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
