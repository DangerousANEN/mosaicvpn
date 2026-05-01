import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";
import { api } from "../api/client";
import type { Server, Subscription } from "../api/types";
import { romanLower as toRomanLower } from "../components/numerals";


/**
 * Pool — the gazetteer of subscriptions. Mirrors docs/mockups/subs.html.
 *
 * Lists every subscription as a numbered card with stats derived from
 * its servers (live / median / best). Footer adds a new subscription;
 * each card can refresh / delete itself or expand to show its stations.
 */
export function Pool({
  activeServerId,
}: {
  activeServerId?: string;
}): JSX.Element {
  const [subs, setSubs] = useState<Subscription[]>([]);
  const [servers, setServers] = useState<Server[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [url, setUrl] = useState("");

  const reload = async () => {
    try {
      const [s, srv] = await Promise.all([
        api.listSubscriptions(),
        api.listServers(),
      ]);
      setSubs(s);
      setServers(srv);
    } catch (e) {
      setErr((e as Error).message);
    }
  };

  useEffect(() => {
    void reload();
    // Poll every 5 s so latency cells and Test-all progress refresh
    // without the user having to navigate away and back. The reload
    // call is idempotent and cheap (two GETs); we skip while the
    // window is hidden to avoid burning bandwidth in the background.
    const id = window.setInterval(() => {
      if (typeof document !== "undefined" && document.hidden) return;
      void reload();
    }, 5000);
    return () => window.clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const onAdd = async (e: FormEvent) => {
    e.preventDefault();
    if (!url.trim()) return;
    setBusy("add");
    setErr(null);
    try {
      const sub = await api.addSubscription(url.trim());
      setUrl("");
      await reload();
      // rc28 — auto Test all on add. The user reported that the
      // probe step was easy to forget after pasting a fresh
      // subscription, leaving the world map populated with greyed-
      // out pins. Fire-and-forget: errors surface in the per-row
      // state, the Pool listing refreshes via its own poll.
      void api.testAllServers(sub.id).catch(() => {
        /* per-server errors land on the Server.last_test_error field */
      });
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  // rc45 — file-based import path for AmneziaWG `.conf`,
  // AmneziaVPN `vpn://` exports, sing-box JSON, Clash YAML, etc.
  // We use a plain <input type=file> hidden behind a button label
  // because the Tauri webview runs the same FileReader API as any
  // browser — no native dialog plugin needed.  The hidden input is
  // re-keyed via the ref reset trick so picking the same file twice
  // in a row still fires `change`.
  const fileInputRef = useRef<HTMLInputElement | null>(null);
  const onImportClick = () => {
    fileInputRef.current?.click();
  };
  const onImportFile = async (e: FormEvent<HTMLInputElement>) => {
    const input = e.currentTarget;
    const file = input.files?.[0];
    // Reset immediately so the same file can be re-imported later.
    input.value = "";
    if (!file) return;
    setBusy("add");
    setErr(null);
    try {
      const content = await file.text();
      const sub = await api.importSubscription(content, undefined, file.name);
      await reload();
      void api.testAllServers(sub.id).catch(() => {
        /* see onAdd */
      });
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onRefresh = async (id: string) => {
    setBusy(`refresh:${id}`);
    setErr(null);
    try {
      await api.refreshSubscription(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onDelete = async (id: string, name: string) => {
    if (!confirm(`Delete subscription "${name}" and all its stations?`)) return;
    setBusy(`del:${id}`);
    setErr(null);
    try {
      await api.deleteSubscription(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  // editingSub drives the in-app Edit modal. rc25 used window.prompt
  // for editing, which the user dismissed as "не в стиле приложения,
  // а в стиле браузера"; the modal below sits inside the Pool frame
  // and reuses .btn / .add-input typography so the visual identity
  // matches the rest of Atlas.
  const [editingSub, setEditingSub] = useState<Subscription | null>(null);
  const onEdit = (sub: Subscription) => {
    setEditingSub(sub);
  };
  const onEditSave = async (
    sub: Subscription,
    nextName: string,
    nextURL: string,
  ) => {
    const nameChanged = nextName !== (sub.name ?? "");
    const urlChanged = nextURL !== sub.url && nextURL !== "";
    if (!nameChanged && !urlChanged) {
      setEditingSub(null);
      return;
    }
    setBusy(`edit:${sub.id}`);
    setErr(null);
    try {
      await api.updateSubscription(
        sub.id,
        nameChanged ? nextName : undefined,
        urlChanged ? nextURL : undefined,
      );
      await reload();
      setEditingSub(null);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const totals = useMemo(() => {
    const live = servers.filter(
      (s) => (s.last_test_ms ?? 0) > 0 && !s.last_test_error,
    );
    const med = median(live.map((s) => s.last_test_ms!));
    return { stations: servers.length, median: med };
  }, [servers]);

  return (
    <div className="pool-frame">
      <header className="pool-mast">
        <div>
          <div className="pool-name">
            Pool <i>—</i> gazetteer
          </div>
          <div className="pool-mast-sub">
            {subs.length}{" "}
            {subs.length === 1 ? "subscription" : "subscriptions"}
            {" · "}
            {totals.stations}{" "}
            {totals.stations === 1 ? "station" : "stations"}
          </div>
        </div>
        <div className="pool-mast-right">
          <span className="serif italic">
            Median latency across pools:{" "}
            <em className="copper">{fmtMs(totals.median)}</em>
          </span>
        </div>
      </header>

      {err ? <div className="pool-error">{err}</div> : null}

      <section className="gazetteer">
        {subs.map((sub, i) => (
          <PoolCard
            key={sub.id}
            num={toRomanLower(i + 1)}
            sub={sub}
            servers={servers.filter((s) => s.subscription_id === sub.id)}
            activeServerId={activeServerId}
            onRefresh={() => onRefresh(sub.id)}
            onDelete={() => onDelete(sub.id, sub.name)}
            onEdit={() => onEdit(sub)}
            refreshing={busy === `refresh:${sub.id}`}
            deleting={busy === `del:${sub.id}`}
            editing={busy === `edit:${sub.id}`}
          />
        ))}
        {subs.length === 0 ? (
          <article className="pool empty">
            <div className="num">i</div>
            <div>
              <div className="pool-card-name italic-mute">
                — no subscriptions yet —
              </div>
              <div className="pool-verse">
                <em>«</em> Paste a subscription URL below. Mosaic auto-detects
                format (sing-box · clash · v2ray base64 · sip008) on first
                fetch. <em>»</em>
              </div>
            </div>
          </article>
        ) : null}
      </section>

      {editingSub ? (
        <SubscriptionEditModal
          sub={editingSub}
          onCancel={() => setEditingSub(null)}
          onSave={(name, url) => onEditSave(editingSub, name, url)}
          busy={busy === `edit:${editingSub.id}`}
        />
      ) : null}

      <form className="add-row" onSubmit={onAdd}>
        <span className="add-lab">
          <i>+</i> Add subscription
        </span>
        <span className="add-input">
          <span className="add-pre">URL</span>
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://… or vless://, ss://, hysteria2://"
            disabled={busy === "add"}
          />
          <span className="add-formats">
            sing-box · clash · v2ray base64 · sip008 · wg-quick · vpn://
          </span>
        </span>
        <button
          type="submit"
          className="btn primary"
          disabled={busy === "add" || !url.trim()}
        >
          {busy === "add" ? "Fetching…" : "Fetch"}
        </button>
        <button
          type="button"
          className="btn"
          onClick={onImportClick}
          disabled={busy === "add"}
          title="Import from .conf / vpn:// / .json / .yaml file"
        >
          {busy === "add" ? "Importing…" : "Import file…"}
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept=".conf,.json,.yaml,.yml,.txt,application/json,application/x-yaml,text/plain"
          style={{ display: "none" }}
          onChange={onImportFile}
        />
      </form>
    </div>
  );
}

function PoolCard({
  num,
  sub,
  servers,
  activeServerId,
  onRefresh,
  onDelete,
  onEdit,
  refreshing,
  deleting,
  editing,
}: {
  num: string;
  sub: Subscription;
  servers: Server[];
  activeServerId?: string;
  onRefresh: () => void;
  onDelete: () => void;
  onEdit: () => void;
  refreshing: boolean;
  deleting: boolean;
  editing: boolean;
}): JSX.Element {
  const isCur = servers.some((s) => s.id === activeServerId);
  const live = servers.filter(
    (s) => (s.last_test_ms ?? 0) > 0 && !s.last_test_error,
  );
  const dead = servers.filter((s) => (s.last_test_ms ?? 0) < 0).length;
  const med = median(live.map((s) => s.last_test_ms!));
  const best =
    live.length === 0
      ? null
      : live.reduce(
          (a, b) =>
            (a.last_test_ms ?? Infinity) < (b.last_test_ms ?? Infinity) ? a : b,
        );
  const protoMix = computeProtoMix(servers);

  const status = subStatus(sub);

  return (
    <article className={`pool ${isCur ? "cur" : ""}`}>
      <div className="num">{num}</div>
      <div>
        <div className="pool-head">
          <div>
            <div className="pool-card-name">
              {sub.name || hostFrom(sub.url)}
              {isCur ? <em> — in service</em> : null}
            </div>
            <div className="pool-src">
              ⌖ <b>{redactedURL(sub.url)}</b> · {fmtFormat(sub.format)}
            </div>
          </div>
          <span className={`pool-badge ${status.tone}`}>{status.text}</span>
        </div>

        <div className="pool-stats">
          <Cell lab="Stations" val={String(servers.length)} />
          <Cell
            lab="Live"
            val={String(live.length)}
            small={dead > 0 ? `· ${dead} dead` : "· all up"}
          />
          <Cell
            lab="Median"
            val={med === null ? "—" : String(med)}
            small={med === null ? "" : "ms"}
          />
          <Cell
            lab="Best"
            val={best ? String(best.last_test_ms ?? "—") : "—"}
            small={best ? `ms · ${best.name}` : ""}
            emphasized={!!best}
          />
        </div>

        <SubscriptionQuota sub={sub} />

        {protoMix.bar.length > 0 ? (
          <div className="pool-protos">
            PROTOCOLS
            <div className="pool-bar">
              {protoMix.bar.map((seg) => (
                <span
                  key={seg.proto}
                  className={`seg ${seg.proto}`}
                  style={{ width: `${seg.pct.toFixed(1)}%` }}
                />
              ))}
            </div>
            <span className="pool-mix">{protoMix.label}</span>
          </div>
        ) : null}

        <div className="pool-actions">
          <button
            className="btn ghost"
            onClick={() => {
              // Drill-down route: Pool's old inline expand collapsed
              // an entire 600-server subscription into a cramped list
              // inside the card. Hand off to SubscriptionDetail via
              // hash so the user gets a dedicated table view with
              // pagination-free real estate (rc24 user request).
              // rc25: renamed "Browse stations" → "Servers" per user
              // ask; Test-all now lives on the detail screen alongside
              // a separate Test all (URL) variant.
              window.location.hash = `sub=${encodeURIComponent(sub.id)}`;
            }}
            disabled={refreshing || deleting}
          >
            Servers
          </button>
          <button
            className="btn ghost"
            onClick={onRefresh}
            disabled={refreshing || deleting || editing}
          >
            {refreshing ? "Refreshing…" : "Refresh now"}
          </button>
          <button
            className="btn ghost"
            onClick={onEdit}
            disabled={refreshing || deleting || editing}
            title="Rename or repoint this subscription at a different URL"
          >
            {editing ? "Saving…" : "Edit"}
          </button>
          <button
            className="btn ghost danger"
            onClick={onDelete}
            disabled={refreshing || deleting || editing}
          >
            {deleting ? "Removing…" : "Delete"}
          </button>
          <span className="pool-foot italic">
            {fmtRefreshHint(sub)}
          </span>
        </div>
      </div>
    </article>
  );
}

function Cell({
  lab,
  val,
  small,
  emphasized,
}: {
  lab: string;
  val: string;
  small?: string;
  emphasized?: boolean;
}): JSX.Element {
  return (
    <div className="pool-cell">
      <div className="lab">{lab}</div>
      <div className="v">
        {emphasized ? <em>{val}</em> : val}
        {small ? <small>{small}</small> : null}
      </div>
    </div>
  );
}

/**
 * SubscriptionQuota renders the `Subscription-Userinfo` panel header
 * as a compact row under the stats cells: used / total traffic bar
 * plus an expiry chip. Renders nothing when neither field is set so
 * subscriptions without a panel reporting this stay clean.
 *
 * Tones mirror `subStatus`:
 *   ok   — default graphite
 *   warn — yellow: ≥ 80% traffic used OR < 7 days to expiry
 *   err  — red:    ≥ 100% traffic used OR already expired
 */
function SubscriptionQuota({ sub }: { sub: Subscription }): JSX.Element | null {
  const used = sub.traffic_used ?? 0;
  const total = sub.traffic_total ?? 0;
  // Go's `omitempty` doesn't drop a zero `time.Time`, so subscriptions
  // without an expiry get serialised as `"0001-01-01T00:00:00Z"` —
  // which the renderer would otherwise treat as a date in year 1
  // (long since "expired").  Filter that explicitly so providers that
  // don't surface a Subscription-Userinfo header don't show a red
  // "expired" chip on every server card.
  const rawExp = sub.expires_at;
  const expIso =
    rawExp && !rawExp.startsWith("0001-01-01") ? rawExp : undefined;
  if (total === 0 && used === 0 && !expIso) return null;

  const pct = total > 0 ? Math.min(100, (used / total) * 100) : 0;

  let tone: "ok" | "warn" | "err" = "ok";
  if (total > 0 && used >= total) tone = "err";
  else if (total > 0 && pct >= 80) tone = "warn";

  let expChip: string | null = null;
  if (expIso) {
    const expMs = new Date(expIso).getTime();
    if (!Number.isNaN(expMs)) {
      const now = Date.now();
      if (expMs <= now) {
        tone = "err";
        expChip = "expired";
      } else {
        const days = Math.ceil((expMs - now) / 86_400_000);
        if (days <= 7 && tone === "ok") tone = "warn";
        if (days <= 30) {
          expChip = `${days} d left`;
        } else {
          expChip = new Date(expIso).toISOString().slice(0, 10);
        }
      }
    }
  }

  return (
    <div className={`pool-quota ${tone}`}>
      {total > 0 ? (
        <>
          <div className="pool-quota-label">
            <span>QUOTA</span>
            <span className="pool-quota-num">
              {fmtBytes(used)} / {fmtBytes(total)}
              <small> · {pct.toFixed(0)}%</small>
            </span>
          </div>
          <div className="pool-quota-bar">
            <span
              className="pool-quota-fill"
              style={{ width: `${pct.toFixed(1)}%` }}
            />
          </div>
        </>
      ) : used > 0 ? (
        <div className="pool-quota-label">
          <span>USED</span>
          <span className="pool-quota-num">{fmtBytes(used)}</span>
        </div>
      ) : null}
      {expChip ? (
        <span className="pool-quota-chip">◷ {expChip}</span>
      ) : null}
    </div>
  );
}

/** fmtBytes formats bytes with 3-significant-digit precision. */
function fmtBytes(n: number): string {
  if (n <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  const digits = v >= 100 ? 0 : v >= 10 ? 1 : 2;
  return `${v.toFixed(digits)} ${units[i]}`;
}

/* ---------- helpers ---------- */

function median(nums: number[]): number | null {
  if (nums.length === 0) return null;
  const sorted = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? Math.round((sorted[mid - 1] + sorted[mid]) / 2)
    : sorted[mid];
}

function fmtMs(ms: number | null): string {
  return ms === null ? "—" : `${ms} ms`;
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

function fmtFormat(f: string): string {
  switch (f) {
    case "singbox":
      return "sing-box format";
    case "clash":
      return "clash YAML format";
    case "v2ray-base64":
      return "v2ray base64 format";
    case "sip008":
      return "sip008 format";
    default:
      return "auto-detect";
  }
}

function fmtRefreshHint(s: Subscription): string {
  if (!s.auto_refresh || !s.refresh_interval_seconds) return "manual refresh";
  const h = Math.round(s.refresh_interval_seconds / 3600);
  if (h <= 1) return "refreshes hourly";
  return `refreshes every ${h} h`;
}

function subStatus(s: Subscription): { text: string; tone: string } {
  if (s.last_error) return { text: `× ${s.last_error}`, tone: "err" };
  if (!s.last_fetched) return { text: "⏳ never fetched", tone: "warn" };
  const age = Date.now() - new Date(s.last_fetched).getTime();
  return { text: `◆ ${fmtAge(age)} ago`, tone: "ok" };
}

function fmtAge(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} m`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h`;
  const d = Math.round(h / 24);
  return `${d} d`;
}

function computeProtoMix(servers: Server[]): {
  bar: { proto: string; pct: number }[];
  label: string;
} {
  if (servers.length === 0) return { bar: [], label: "" };
  const counts = new Map<string, number>();
  for (const s of servers) {
    counts.set(s.protocol, (counts.get(s.protocol) ?? 0) + 1);
  }
  const total = servers.length;
  const bar = [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([proto, n]) => ({ proto: protoClass(proto), pct: (n / total) * 100 }));
  const label = [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([p, n]) => `${protoLabel(p)} ${n}`)
    .join(" · ");
  return { bar, label };
}

function protoClass(p: string): string {
  switch (p) {
    case "hysteria2":
      return "hy";
    case "vless":
      return "vl";
    case "vmess":
      return "vl";
    case "naive":
      return "nv";
    case "shadowsocks":
      return "ss";
    case "amneziawg":
      return "wg";
    case "trojan":
      return "tj";
    default:
      return "ot";
  }
}

function protoLabel(p: string): string {
  switch (p) {
    case "hysteria2":
      return "HY²";
    case "vless":
      return "VLESS";
    case "vmess":
      return "VMess";
    case "naive":
      return "NAIVE";
    case "shadowsocks":
      return "SS";
    case "amneziawg":
      return "AWG";
    case "trojan":
      return "TROJ";
    default:
      return p.toUpperCase();
  }
}

/**
 * SubscriptionEditModal — in-app modal for renaming / repointing a
 * subscription. Replaces rc25's pair of window.prompt() dialogs
 * which the user reported as "в стиле браузера, а не приложения".
 *
 * The modal is intentionally lightweight: a centred panel with two
 * inputs, Cancel / Save buttons and an Esc-to-dismiss / Enter-to-
 * submit binding. Repointing the URL triggers an auto-refetch on the
 * backend (PATCH /v1/subscriptions/{id}); renaming alone does not.
 */
function SubscriptionEditModal({
  sub,
  onCancel,
  onSave,
  busy,
}: {
  sub: Subscription;
  onCancel: () => void;
  onSave: (name: string, url: string) => void;
  busy: boolean;
}): JSX.Element {
  const [name, setName] = useState<string>(sub.name ?? "");
  const [url, setUrl] = useState<string>(sub.url);
  const trimmedName = name.trim();
  const trimmedURL = url.trim();
  const dirty =
    trimmedName !== (sub.name ?? "") ||
    (trimmedURL !== sub.url && trimmedURL !== "");
  const submit = (e?: FormEvent) => {
    e?.preventDefault();
    if (!dirty || busy) return;
    onSave(trimmedName, trimmedURL);
  };
  return (
    <div className="modal-scrim" onClick={onCancel}>
      <form
        className="modal-panel"
        onClick={(e) => e.stopPropagation()}
        onSubmit={submit}
      >
        <div className="modal-title">
          Edit subscription <i>—</i>{" "}
          <span className="mono">{sub.id.slice(0, 8)}</span>
        </div>
        <label className="modal-field">
          <span className="modal-lab">Name</span>
          <input
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="(optional)"
            autoFocus
          />
        </label>
        <label className="modal-field">
          <span className="modal-lab">URL</span>
          <input
            type="text"
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://…"
          />
        </label>
        <div className="modal-hint italic-mute">
          Changing the URL will refetch the subscription. Renaming
          alone keeps the existing server list and probe history.
        </div>
        <div className="modal-actions">
          <button type="button" className="btn ghost" onClick={onCancel}>
            Cancel
          </button>
          <button
            type="submit"
            className="btn primary"
            disabled={!dirty || busy}
          >
            {busy ? "Saving…" : "Save changes"}
          </button>
        </div>
      </form>
    </div>
  );
}

