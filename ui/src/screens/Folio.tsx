import { useEffect, useMemo, useState, type ReactNode } from "react";
import { api } from "../api/client";
import type { Prefs } from "../api/types";
import { isAdmin, restartAsAdmin } from "../api/tauri";

/**
 * Folio — the book of preferences. Mirrors docs/mockups/settings.html.
 *
 * Chapters with a sticky table-of-contents on the left. Edits are local
 * until "Save changes" — discard reverts. Only fields present on the
 * Prefs type (proto.Prefs) are exposed; the mockup also shows MTU,
 * SOCKS/HTTP listener bindings, LAN sharing options etc. that the
 * daemon doesn't yet have — those will land when proto.Prefs grows.
 */

type ChapterId = "network" | "privacy" | "dns" | "autostart" | "mcp";

const CHAPTERS: { id: ChapterId; num: string; title: string; sub: string }[] = [
  { id: "network", num: "i", title: "Network", sub: "tunnel mode & stack" },
  {
    id: "privacy",
    num: "ii",
    title: "Privacy & kill-switch",
    sub: "if the tunnel drops",
  },
  { id: "dns", num: "iii", title: "DNS", sub: "name resolution" },
  { id: "autostart", num: "iv", title: "Auto-start", sub: "how Mosaic launches" },
  {
    id: "mcp",
    num: "v",
    title: "Agent & MCP",
    sub: "letting an AI control Mosaic",
  },
];

export function Folio(): JSX.Element {
  const [loaded, setLoaded] = useState<Prefs | null>(null);
  const [draft, setDraft] = useState<Prefs | null>(null);
  const [busy, setBusy] = useState<"load" | "save" | null>("load");
  const [err, setErr] = useState<string | null>(null);
  const [chapter, setChapter] = useState<ChapterId>("network");

  const reload = async () => {
    setBusy("load");
    setErr(null);
    try {
      const p = await api.getPrefs();
      setLoaded(p);
      setDraft(p);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const dirty = useMemo(() => {
    if (!loaded || !draft) return false;
    return JSON.stringify(loaded) !== JSON.stringify(draft);
  }, [loaded, draft]);

  const onSave = async () => {
    if (!draft) return;
    setBusy("save");
    setErr(null);
    try {
      const saved = await api.setPrefs(draft);
      setLoaded(saved);
      setDraft(saved);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onDiscard = () => {
    if (loaded) setDraft(loaded);
  };

  const update = <K extends keyof Prefs>(k: K, v: Prefs[K]) => {
    if (!draft) return;
    setDraft({ ...draft, [k]: v });
  };

  // Admin gate: if the user flips tunnel_mode → "tun" while running
  // unelevated, ask before applying. The probe is async so we keep
  // the click handler local; if the user backs out we revert the
  // local draft (no daemon round-trip yet because Save hasn't run).
  const [adminModal, setAdminModal] = useState(false);
  const onChangeTunnelMode = async (v: string) => {
    if (!draft) return;
    if (v === "tun" && draft.tunnel_mode !== "tun") {
      const elevated = await isAdmin();
      if (!elevated) {
        // Don't apply the change. The draft stays on whatever the
        // current mode is (proxy by default), and the admin gate
        // modal explains what the user has to do.
        setAdminModal(true);
        return;
      }
    }
    update("tunnel_mode", v);
  };

  if (!draft || !loaded) {
    return (
      <div className="folio-frame">
        <header className="pool-mast">
          <div>
            <div className="pool-name">
              Folio <i>—</i> preferences
            </div>
            <div className="pool-mast-sub">loading…</div>
          </div>
        </header>
        {err ? <div className="pool-error">{err}</div> : null}
      </div>
    );
  }

  return (
    <div className="folio-frame">
      <header className="pool-mast">
        <div>
          <div className="pool-name">
            Folio <i>—</i> preferences
          </div>
          <div className="pool-mast-sub">
            {dirty ? "unsaved changes" : "all settings saved"}
          </div>
        </div>
        <div className="folio-mast-actions">
          <button
            className="btn ghost"
            onClick={onDiscard}
            disabled={!dirty || busy === "save"}
          >
            Discard
          </button>
          <button
            className="btn primary"
            onClick={onSave}
            disabled={!dirty || busy === "save"}
          >
            {busy === "save" ? "Saving…" : "Save changes"}
          </button>
        </div>
      </header>

      {err ? <div className="pool-error">{err}</div> : null}

      <section className="folio-main">
        <aside className="folio-toc">
          <div className="folio-toc-lab">Table of contents</div>
          {CHAPTERS.map((c) => (
            <div
              key={c.id}
              className={`folio-toc-row ${chapter === c.id ? "cur" : ""}`}
              onClick={() => setChapter(c.id)}
            >
              <span className="n">{c.num}</span>
              <span className="t">{c.title}</span>
              <span className="pg">↓</span>
            </div>
          ))}
        </aside>

        <div className="folio-pages">
          {chapter === "network" ? (
            <Chapter num="i" title="Network — tunnel" desc="how Mosaic captures traffic">
              <Opt
                name="Tunnel mode"
                desc="TUN intercepts all system traffic via Wintun. Proxy-only listens on a local port."
              >
                <Seg
                  value={draft.tunnel_mode}
                  options={[
                    { v: "tun", lab: "TUN · system-wide" },
                    { v: "proxy", lab: "SOCKS / HTTP only" },
                  ]}
                  onChange={(v) => void onChangeTunnelMode(v)}
                />
              </Opt>
              <Opt
                name="TUN stack"
                desc="System uses Wintun device directly (Windows). gVisor is a userland networking stack — no driver, slower. Mixed selectively delegates."
              >
                <Seg
                  value={draft.tun_stack}
                  options={[
                    { v: "system", lab: "SYSTEM" },
                    { v: "gvisor", lab: "GVISOR" },
                    { v: "mixed", lab: "MIXED" },
                  ]}
                  onChange={(v) => update("tun_stack", v)}
                />
              </Opt>
              <Opt
                name="Share proxy on LAN"
                desc="Bind SOCKS / HTTP inbounds on 0.0.0.0 so other devices on the same network can route through Mosaic. Off → loopback only."
              >
                <Switch
                  value={draft.share_lan}
                  onChange={(v) => update("share_lan", v)}
                />
              </Opt>
              <Opt
                name="LAN share — username"
                desc="Optional username for the shared SOCKS / HTTP proxies. Leave blank to keep the listeners anonymous (still bound on 0.0.0.0). Both username and password must be set to enable auth."
              >
                <Text
                  value={draft.share_user ?? ""}
                  onChange={(v) => update("share_user", v)}
                  placeholder="mosaic"
                  disabled={!draft.share_lan}
                />
              </Opt>
              <Opt
                name="LAN share — password"
                desc="Optional password paired with the username above. Stored in store.json (loopback-only file with 0700 dir perms); rotate as you would any other shared credential."
              >
                <Text
                  value={draft.share_pass ?? ""}
                  onChange={(v) => update("share_pass", v)}
                  placeholder="••••••"
                  disabled={!draft.share_lan}
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "privacy" ? (
            <Chapter
              num="ii"
              title="Privacy & kill-switch"
              desc="if the tunnel drops"
            >
              <Opt
                name="Kill-switch"
                desc="Block all internet if the tunnel drops. Stronger than DNS-only protection."
              >
                <Switch
                  value={draft.kill_switch}
                  onChange={(v) => update("kill_switch", v)}
                />
              </Opt>
              <Opt
                name="Allow LAN during outage"
                desc="Keep 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12 reachable while the kill-switch is up."
              >
                <Switch
                  value={draft.allow_lan}
                  onChange={(v) => update("allow_lan", v)}
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "dns" ? (
            <Chapter num="iii" title="DNS" desc="name resolution">
              <Opt
                name="Upstream — proxied"
                desc="Used for matched-via-proxy domains. DoH recommended, e.g. https://1.1.1.1/dns-query"
              >
                <Text
                  value={draft.dns_proxied}
                  onChange={(v) => update("dns_proxied", v)}
                  placeholder="https://1.1.1.1/dns-query"
                />
              </Opt>
              <Opt
                name="Upstream — direct"
                desc="Used for DIRECT-ruled domains. Fast, local resolver, e.g. udp://1.1.1.1"
              >
                <Text
                  value={draft.dns_direct}
                  onChange={(v) => update("dns_direct", v)}
                  placeholder="udp://1.1.1.1"
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "autostart" ? (
            <Chapter
              num="iv"
              title="Auto-start"
              desc="how Mosaic launches"
            >
              <Opt
                name="Auto-connect on start"
                desc="Connect to the last used station immediately when the daemon comes up. Pairs naturally with kill-switch on."
              >
                <Switch
                  value={draft.auto_connect}
                  onChange={(v) => update("auto_connect", v)}
                />
              </Opt>
              <Opt
                name="Show window at launch"
                desc="If off, Mosaic only sits in the tray until you click it."
              >
                <Switch
                  value={draft.show_on_launch}
                  onChange={(v) => update("show_on_launch", v)}
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "mcp" ? (
            <Chapter
              num="v"
              title="Agent & MCP"
              desc="letting an AI control Mosaic"
            >
              <Opt
                name="MCP server"
                desc="Exposes Mosaic as an MCP endpoint over loopback so an AI agent can read state and (optionally) drive connections."
              >
                <Switch
                  value={draft.mcp_enabled}
                  onChange={(v) => update("mcp_enabled", v)}
                />
              </Opt>
              <Opt
                name="Listen address"
                desc="Loopback only. Default 127.0.0.1:8731."
              >
                <Text
                  value={draft.mcp_addr}
                  onChange={(v) => update("mcp_addr", v)}
                  placeholder="127.0.0.1:8731"
                  disabled={!draft.mcp_enabled}
                />
              </Opt>
              <Opt
                name="Permission"
                desc="Read = status & lists. Connect = also engage/disengage. Full = everything (subscriptions, rules, prefs)."
              >
                <Seg
                  value={draft.mcp_permission}
                  options={[
                    { v: "read", lab: "READ" },
                    { v: "connect", lab: "CONNECT" },
                    { v: "full", lab: "FULL" },
                  ]}
                  onChange={(v) =>
                    update("mcp_permission", v as Prefs["mcp_permission"])
                  }
                  disabled={!draft.mcp_enabled}
                />
              </Opt>
              <Opt
                name="Confirm destructive actions"
                desc="When the agent calls connect/set_prefs/etc., raise a confirm dialog before executing."
              >
                <Switch
                  value={draft.mcp_confirm}
                  onChange={(v) => update("mcp_confirm", v)}
                  disabled={!draft.mcp_enabled}
                />
              </Opt>
            </Chapter>
          ) : null}
        </div>
      </section>

      {adminModal ? (
        <AdminGateModal
          onCancel={() => setAdminModal(false)}
          onElevate={async () => {
            try {
              await restartAsAdmin();
              // restart_as_admin asks Tauri to exit; if that returned
              // synchronously the UAC prompt was likely denied, so
              // we just close the modal — the draft remains "proxy".
              setAdminModal(false);
            } catch (e) {
              setErr((e as Error).message);
              setAdminModal(false);
            }
          }}
        />
      ) : null}
    </div>
  );
}

function AdminGateModal({
  onCancel,
  onElevate,
}: {
  onCancel: () => void;
  onElevate: () => void;
}): JSX.Element {
  return (
    <div className="modal-scrim" onClick={onCancel}>
      <div
        className="modal admin-gate"
        onClick={(e) => e.stopPropagation()}
        role="dialog"
        aria-modal="true"
      >
        <div className="modal-eyebrow">Folio · plate i · sub-section</div>
        <div className="modal-title">
          TUN mode requires <i>administrator privileges</i>
        </div>
        <p className="modal-body">
          Mosaic must run elevated to install the Wintun virtual adapter
          and intercept system-wide traffic. SOCKS / HTTP proxy mode does
          not require elevation and remains available without restart.
        </p>
        <div className="modal-actions">
          <button type="button" className="btn ghost" onClick={onCancel}>
            Cancel
          </button>
          <button type="button" className="btn primary" onClick={onElevate}>
            Restart as administrator
          </button>
        </div>
      </div>
    </div>
  );
}

/* ---------- chapter / option layouts ---------- */

function Chapter({
  num,
  title,
  desc,
  children,
}: {
  num: string;
  title: string;
  desc: string;
  children: ReactNode;
}): JSX.Element {
  return (
    <section className="ch-page">
      <div className="ch-mast">
        <span className="ch-num">{num}</span>
        <span className="ch-title">{title}</span>
        <span className="ch-desc">{desc}</span>
      </div>
      {children}
    </section>
  );
}

function Opt({
  name,
  desc,
  children,
}: {
  name: string;
  desc: string;
  children: ReactNode;
}): JSX.Element {
  return (
    <div className="opt">
      <div className="info">
        <div className="name">{name}</div>
        <div className="desc">{desc}</div>
      </div>
      <div className="ctl">{children}</div>
    </div>
  );
}

/* ---------- controls ---------- */

function Switch({
  value,
  onChange,
  disabled,
}: {
  value: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}): JSX.Element {
  return (
    <span className={`swc ${disabled ? "muted" : ""}`}>
      <button
        type="button"
        className={value ? "on" : ""}
        onClick={() => !disabled && onChange(true)}
        disabled={disabled}
      >
        ON
      </button>
      <button
        type="button"
        className={!value ? "off" : ""}
        onClick={() => !disabled && onChange(false)}
        disabled={disabled}
      >
        OFF
      </button>
    </span>
  );
}

function Seg<T extends string>({
  value,
  options,
  onChange,
  disabled,
}: {
  value: T;
  options: { v: T; lab: string }[];
  onChange: (v: T) => void;
  disabled?: boolean;
}): JSX.Element {
  return (
    <span className={`seg ${disabled ? "muted" : ""}`}>
      {options.map((o) => (
        <button
          key={o.v}
          type="button"
          className={value === o.v ? "copper on" : ""}
          onClick={() => !disabled && onChange(o.v)}
          disabled={disabled}
        >
          {o.lab}
        </button>
      ))}
    </span>
  );
}

function Text({
  value,
  onChange,
  placeholder,
  disabled,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  disabled?: boolean;
}): JSX.Element {
  return (
    <input
      type="text"
      className="text-input"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      disabled={disabled}
    />
  );
}
