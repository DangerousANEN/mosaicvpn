import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { api } from "../api/client";
import type {
  EgressConfig,
  EgressDTO,
  Prefs,
  Server,
  Status,
  Subscription,
} from "../api/types";
import { isAdmin, restartAsAdmin } from "../api/tauri";
import { useTheme } from "../hooks/useTheme";

/**
 * Folio — the book of preferences. Mirrors docs/mockups/settings.html.
 *
 * Chapters with a sticky table-of-contents on the left. Edits are local
 * until "Save changes" — discard reverts. Only fields present on the
 * Prefs type (proto.Prefs) are exposed; the mockup also shows MTU,
 * SOCKS/HTTP listener bindings, LAN sharing options etc. that the
 * daemon doesn't yet have — those will land when proto.Prefs grows.
 */

type ChapterId =
  | "network"
  | "privacy"
  | "dns"
  | "verify"
  | "antidpi"
  | "autostart"
  | "mcp"
  | "egress"
  | "bypass"
  | "appearance";

const CHAPTERS: { id: ChapterId; num: string; title: string; sub: string }[] = [
  { id: "network", num: "i", title: "Network", sub: "tunnel mode & stack" },
  {
    id: "privacy",
    num: "ii",
    title: "Privacy & kill-switch",
    sub: "if the tunnel drops",
  },
  { id: "dns", num: "iii", title: "DNS", sub: "name resolution" },
  {
    id: "verify",
    num: "iv",
    title: "Verify",
    sub: "URL test + proxy ports",
  },
  {
    id: "antidpi",
    num: "v",
    title: "Anti-DPI",
    sub: "evade carrier-level fingerprinting",
  },
  { id: "autostart", num: "vi", title: "Auto-start", sub: "how Mosaic launches" },
  {
    id: "mcp",
    num: "vii",
    title: "Agent & MCP",
    sub: "letting an AI control Mosaic",
  },
  {
    id: "egress",
    num: "viii",
    title: "Egresses",
    sub: "auxiliary SOCKS/HTTP proxies",
  },
  {
    id: "bypass",
    num: "ix",
    title: "Bypass list",
    sub: "domains & IPs that skip the tunnel",
  },
  {
    id: "appearance",
    num: "x",
    title: "Appearance & backup",
    sub: "theme, export & import",
  },
];

export function Folio({ status }: { status?: Status | null }): JSX.Element {
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
              {/* Live LAN address — sing-box's listen_port may fall back
                  to an ephemeral port when the configured 2080/2081 is
                  busy, which made the rc24 "raздача в LAN либо не работает,
                  либо не на порту 2080" complaint hard to debug. We
                  surface the actual listener address here so the user
                  knows exactly what to point a phone at. */}
              {draft.share_lan && status?.proxy_socks ? (
                <Opt
                  name="LAN listener — actual"
                  desc="What sing-box is currently listening on. Copy this into the proxy field of any LAN device."
                >
                  <div className="mono" style={{ fontSize: 12 }}>
                    SOCKS · {status.proxy_socks}
                    {status.proxy_http ? `   ·   HTTP · ${status.proxy_http}` : ""}
                  </div>
                </Opt>
              ) : null}
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

          {chapter === "verify" ? (
            <Chapter
              num="iv"
              title="Verify & proxy ports"
              desc="what the per-server Verify probe fetches through the proxy, plus the SOCKS / HTTP listen ports sing-box exposes on 127.0.0.1"
            >
              <Opt
                name="Target URL"
                desc="A 2xx/3xx response is treated as success.  Pick a captive-portal endpoint (gstatic-204), a normal page (google.com), Cloudflare's diagnostic, or any URL.  Empty = gstatic default."
              >
                <Seg
                  value={(() => {
                    const v = draft.url_test_endpoint ?? "";
                    if (v === "" || v === "https://www.gstatic.com/generate_204")
                      return "gstatic";
                    if (v === "https://www.google.com/") return "google";
                    if (v === "https://www.cloudflare.com/cdn-cgi/trace")
                      return "cf";
                    return "custom";
                  })()}
                  options={[
                    { v: "gstatic", lab: "GSTATIC 204" },
                    { v: "google", lab: "GOOGLE" },
                    { v: "cf", lab: "CLOUDFLARE" },
                    { v: "custom", lab: "CUSTOM…" },
                  ]}
                  onChange={(v) => {
                    if (v === "gstatic")
                      update("url_test_endpoint", "");
                    else if (v === "google")
                      update("url_test_endpoint", "https://www.google.com/");
                    else if (v === "cf")
                      update(
                        "url_test_endpoint",
                        "https://www.cloudflare.com/cdn-cgi/trace",
                      );
                    else if (v === "custom")
                      // Pre-fill the input so the user has something to edit.
                      update(
                        "url_test_endpoint",
                        draft.url_test_endpoint &&
                          draft.url_test_endpoint !==
                            "https://www.gstatic.com/generate_204" &&
                          draft.url_test_endpoint !== "https://www.google.com/" &&
                          draft.url_test_endpoint !==
                            "https://www.cloudflare.com/cdn-cgi/trace"
                          ? draft.url_test_endpoint
                          : "https://example.com/",
                      );
                  }}
                />
              </Opt>
              <Opt
                name="Custom URL"
                desc="Used when the selector is on CUSTOM. Must start with http:// or https://."
              >
                <Text
                  value={draft.url_test_endpoint ?? ""}
                  onChange={(v) => update("url_test_endpoint", v)}
                  placeholder="https://example.com/"
                />
              </Opt>
              <Opt
                name="Speedtest URL override"
                desc="Replaces the default Cloudflare ladder (10 MB → 5 MB → 1 MB) used by the Main-screen Speedtest button. Empty = ladder. Set to any __down-style endpoint when your ISP throttles or resets speed.cloudflare.com mid-download."
              >
                <Text
                  value={draft.speedtest_url ?? ""}
                  onChange={(v) => update("speedtest_url", v)}
                  placeholder="https://speed.cloudflare.com/__down?bytes=5242880"
                />
              </Opt>
              <Opt
                name="SOCKS port"
                desc="Pins the SOCKS5 inbound that sing-box exposes on 127.0.0.1.  Empty / 0 = auto (try 2080, fall back to a random port if it's already taken).  A pinned value forces sing-box to bind exactly that port — Connect fails with an error when it's busy, instead of silently moving to a random port your apps don't know about."
              >
                <Text
                  value={
                    draft.socks_port && draft.socks_port > 0
                      ? String(draft.socks_port)
                      : ""
                  }
                  onChange={(v) => {
                    const n = parseInt(v.trim(), 10);
                    update(
                      "socks_port",
                      Number.isFinite(n) && n > 0 && n < 65536 ? n : 0,
                    );
                  }}
                  placeholder="2080"
                />
              </Opt>
              <Opt
                name="HTTP port"
                desc="Pins the HTTP proxy inbound on 127.0.0.1.  Same semantics as the SOCKS port: empty = auto (try 2081, fall back), pinned = bind exactly that or fail loudly."
              >
                <Text
                  value={
                    draft.http_port && draft.http_port > 0
                      ? String(draft.http_port)
                      : ""
                  }
                  onChange={(v) => {
                    const n = parseInt(v.trim(), 10);
                    update(
                      "http_port",
                      Number.isFinite(n) && n > 0 && n < 65536 ? n : 0,
                    );
                  }}
                  placeholder="2081"
                />
              </Opt>
              <Opt
                name="Ping method"
                desc="How Mosaic measures server latency. TCP = raw TCP connect (fastest). URL = HEAD request via proxy. ICMP = native ping (requires admin on Windows). Via-proxy modes test through the active tunnel."
              >
                <Seg
                  value={(draft.ping_method || "tcp") as
                    | "tcp"
                    | "url"
                    | "icmp"
                    | "via_proxy_head"
                    | "via_proxy_get"}
                  options={[
                    { v: "tcp", lab: "TCP" },
                    { v: "url", lab: "URL" },
                    { v: "icmp", lab: "ICMP" },
                    { v: "via_proxy_head", lab: "VIA PROXY HEAD" },
                    { v: "via_proxy_get", lab: "VIA PROXY GET" },
                  ]}
                  onChange={(v) => update("ping_method", v)}
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "antidpi" ? (
            <Chapter
              num="v"
              title="Anti-DPI"
              desc="evade carrier-level fingerprinting; only enable what you actually need"
            >
              <Opt
                name="TLS fingerprint override"
                desc="Forces the outbound to mimic a real browser's TLS handshake.  Auto = use whatever the subscription declared.  Try CHROME or FIREFOX if your ISP is fingerprinting non-browser TLS."
              >
                <Seg
                  value={
                    (draft.dpi_fingerprint || "auto") as
                      | "auto"
                      | "chrome"
                      | "firefox"
                      | "safari"
                      | "ios"
                      | "android"
                      | "edge"
                      | "random"
                  }
                  options={[
                    { v: "auto", lab: "AUTO" },
                    { v: "chrome", lab: "CHROME" },
                    { v: "firefox", lab: "FIREFOX" },
                    { v: "safari", lab: "SAFARI" },
                    { v: "ios", lab: "iOS" },
                    { v: "android", lab: "ANDROID" },
                    { v: "edge", lab: "EDGE" },
                    { v: "random", lab: "RANDOM" },
                  ]}
                  onChange={(v) =>
                    update("dpi_fingerprint", v === "auto" ? "" : v)
                  }
                />
              </Opt>
              <Opt
                name="TLS fragment"
                desc="Splits the TLS ClientHello across multiple TCP segments so SNI-keyword DPI loses the keyword.  Useful in Iran / Russia where SNI is filtered.  OFF if your ISP doesn't do SNI filtering."
              >
                <Seg
                  value={
                    (draft.dpi_fragment || "off") as
                      | "off"
                      | "1-3"
                      | "2-5"
                      | "5-10"
                  }
                  options={[
                    { v: "off", lab: "OFF" },
                    { v: "1-3", lab: "1-3 B" },
                    { v: "2-5", lab: "2-5 B" },
                    { v: "5-10", lab: "5-10 B" },
                  ]}
                  onChange={(v) =>
                    update("dpi_fragment", v === "off" ? "" : v)
                  }
                />
              </Opt>
              <Opt
                name="Multiplexing (mux.cool)"
                desc="Multiplex traffic over a single outbound connection so DPI can't isolate flows.  Effective for VLESS / Trojan; ignored by Hysteria2."
              >
                <Seg
                  value={
                    (draft.dpi_mux || "off") as "off" | "auto" | "4" | "8"
                  }
                  options={[
                    { v: "off", lab: "OFF" },
                    { v: "auto", lab: "AUTO" },
                    { v: "4", lab: "MAX 4" },
                    { v: "8", lab: "MAX 8" },
                  ]}
                  onChange={(v) =>
                    update("dpi_mux", v === "off" ? "" : v)
                  }
                />
              </Opt>
              <Opt
                name="Encrypted Client Hello (ECH)"
                desc="Encrypts the SNI inside TLS so middleboxes can't see which host you're connecting to.  Requires the upstream server to publish an ECHConfigList; if it doesn't, this is a no-op."
              >
                <Switch
                  value={!!draft.dpi_ech}
                  onChange={(v) => update("dpi_ech", v)}
                />
              </Opt>
            </Chapter>
          ) : null}

          {chapter === "mcp" ? (
            <Chapter
              num="vii"
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

          {chapter === "egress" ? <EgressChapter /> : null}

          {chapter === "bypass" ? <BypassChapter /> : null}

          {chapter === "appearance" ? (
            <AppearanceChapter />
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

/* ---------- rc28 — Appearance & backup chapter ---------- */

/** BypassChapter — split-tunneling editor. Manages a single named
 *  routing rule "Bypass list" with action=direct that the user can
 *  populate with one domain or IP/CIDR per line. Saving deletes any
 *  previous "Bypass list" rule and creates a fresh one at priority 1
 *  (top of the rule chain) so it takes precedence over the catch-
 *  all proxy rule. We keep the management entirely on the client
 *  side (no new daemon endpoint) by composing existing Rules CRUD
 *  calls. */
const BYPASS_RULE_NAME = "Bypass list";

function BypassChapter(): JSX.Element {
  const [domains, setDomains] = useState("");
  const [ips, setIps] = useState("");
  const [busy, setBusy] = useState<"load" | "save" | null>("load");
  const [err, setErr] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);

  const reload = async () => {
    setBusy("load");
    setErr(null);
    try {
      const rules = await api.listRules();
      const existing = rules.find((r) => r.name === BYPASS_RULE_NAME);
      if (existing) {
        setDomains((existing.match.domain_suffix ?? []).join("\n"));
        setIps((existing.match.ip_cidr ?? []).join("\n"));
      } else {
        setDomains("");
        setIps("");
      }
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const parse = (raw: string): string[] =>
    raw
      .split(/[\n,]/)
      .map((s) => s.trim())
      .filter((s) => s.length > 0 && !s.startsWith("#"));

  const onSave = async () => {
    setBusy("save");
    setErr(null);
    setInfo(null);
    try {
      const domList = parse(domains);
      const ipList = parse(ips);
      const rules = await api.listRules();
      const existing = rules.find((r) => r.name === BYPASS_RULE_NAME);
      if (existing) {
        await api.deleteRule(existing.id);
      }
      if (domList.length === 0 && ipList.length === 0) {
        setInfo("Bypass list cleared.");
        return;
      }
      await api.addRule({
        name: BYPASS_RULE_NAME,
        action: "direct",
        enabled: true,
        match: {
          logic: "or",
          domain_suffix: domList,
          ip_cidr: ipList,
        },
      });
      // Bump the new rule to priority 1 so it wins over the proxy
      // catch-all. We rebuild the priority order by listing again
      // and pushing our rule's id to the front.
      const after = await api.listRules();
      const ours = after.find((r) => r.name === BYPASS_RULE_NAME);
      if (ours) {
        const reordered = [
          ours.id,
          ...after.filter((r) => r.id !== ours.id).map((r) => r.id),
        ];
        await api.reorderRules(reordered);
      }
      setInfo(
        `Saved · ${domList.length} domain${domList.length === 1 ? "" : "s"}, ${ipList.length} IP entr${ipList.length === 1 ? "y" : "ies"}.`,
      );
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  return (
    <Chapter
      num="vi"
      title="Bypass list"
      desc="Domains & IPs that skip the tunnel"
    >
      <p className="folio-prose">
        Traffic matching any entry below goes <i>direct</i> instead of through
        the active server. One per line. Domains match by suffix:
        <code> youtube.com </code>also matches<code> www.youtube.com</code>.
        IP entries accept CIDR (e.g.<code> 192.168.0.0/16</code>). Lines
        starting with <code>#</code> are treated as comments and ignored.
      </p>
      <p className="folio-prose italic-mute">
        Mosaic already bypasses the public IP-detection hosts it uses to
        place your <i>vous</i> pin — <code>ip-api.com</code>,{" "}
        <code>ipapi.co</code>, <code>ipinfo.io</code>, <code>2ip.ru</code>,{" "}
        <code>2ip.io</code>, <code>ifconfig.me</code> and a few more — at the
        sing-box level, so you don't need to add them here. This list is for
        your own splits (corporate VPN, banking, region-locked apps, etc.).
      </p>

      <div className="bypass-grid">
        <label className="bypass-col">
          <span className="bypass-col-label">Domain suffixes</span>
          <textarea
            className="bypass-area"
            value={domains}
            onChange={(e) => setDomains(e.target.value)}
            spellCheck={false}
            placeholder={"# one host per line\nyoutube.com\n*.local"}
            rows={10}
            disabled={busy === "load"}
          />
        </label>
        <label className="bypass-col">
          <span className="bypass-col-label">IPs / CIDRs</span>
          <textarea
            className="bypass-area"
            value={ips}
            onChange={(e) => setIps(e.target.value)}
            spellCheck={false}
            placeholder={"192.168.0.0/16\n10.0.0.0/8\n100.64.0.0/10"}
            rows={10}
            disabled={busy === "load"}
          />
        </label>
      </div>

      {err ? <div className="folio-err">{err}</div> : null}
      {info ? <div className="folio-info">{info}</div> : null}

      <div className="bypass-actions">
        <button
          type="button"
          className="btn ghost"
          onClick={() => void reload()}
          disabled={!!busy}
        >
          Reload
        </button>
        <button
          type="button"
          className="btn primary"
          onClick={() => void onSave()}
          disabled={!!busy}
        >
          {busy === "save" ? "Saving…" : "Save bypass list"}
        </button>
      </div>
    </Chapter>
  );
}

/* ---------- rc44 — Egresses chapter ---------- */

/** EgressChapter — CRUD over auxiliary SOCKS5/HTTP egresses.  Each
 *  row is one long-lived sing-box subprocess pinned to a single
 *  server, exposing a local proxy port independent of the main
 *  Connect/Disconnect tunnel.  Common use: route Telegram via a DE
 *  server while watching Russian streaming on the main tunnel.       */
function EgressChapter(): JSX.Element {
  const [items, setItems] = useState<EgressDTO[]>([]);
  const [servers, setServers] = useState<Server[]>([]);
  const [busy, setBusy] = useState<"load" | "act" | null>("load");
  const [err, setErr] = useState<string | null>(null);
  const [draft, setDraft] = useState<EgressConfig | null>(null);

  const reload = async () => {
    setBusy("load");
    setErr(null);
    try {
      const [list, srv] = await Promise.all([
        api.listEgresses(),
        api.listServers(),
      ]);
      setItems(list);
      setServers(srv);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  useEffect(() => {
    void reload();
  }, []);

  const startNew = () => {
    setDraft({
      id: "",
      name: "",
      server_id: servers[0]?.id ?? "",
      protocol: "socks5",
      port: 10808,
      share_lan: false,
      share_user: "",
      share_pass: "",
      auto_start: false,
    });
  };

  const onSave = async () => {
    if (!draft) return;
    setBusy("act");
    setErr(null);
    try {
      if (draft.id) {
        await api.updateEgress(draft.id, draft);
      } else {
        await api.addEgress(draft);
      }
      setDraft(null);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onDelete = async (id: string) => {
    setBusy("act");
    setErr(null);
    try {
      await api.deleteEgress(id);
      await reload();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onToggle = async (e: EgressDTO) => {
    setBusy("act");
    setErr(null);
    try {
      if (e.status?.running) {
        await api.stopEgress(e.id);
      } else {
        await api.startEgress(e.id);
      }
      await reload();
    } catch (ex) {
      setErr((ex as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const serverName = (id: string): string => {
    const s = servers.find((sv) => sv.id === id);
    if (!s) return id;
    const where = [s.country, s.city].filter(Boolean).join(" · ");
    return where ? `${s.name} (${where})` : s.name;
  };

  return (
    <Chapter
      num="viii"
      title="Egresses"
      desc="auxiliary SOCKS/HTTP proxies running alongside the main tunnel"
    >
      {err ? <div className="folio-err">{err}</div> : null}

      <div className="folio-egresses">
        {items.length === 0 ? (
          <div className="folio-empty">
            No egresses configured. Create one to expose a local proxy
            port pinned to a specific server, independent of the main
            Connect/Disconnect flow.
          </div>
        ) : (
          <table className="folio-egress-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Server</th>
                <th>Protocol</th>
                <th>Listen</th>
                <th>State</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {items.map((e) => (
                <tr key={e.id}>
                  <td>{e.name || "—"}</td>
                  <td className="folio-egress-srv">
                    {serverName(e.server_id)}
                  </td>
                  <td>{(e.protocol || "socks5").toUpperCase()}</td>
                  <td className="mono">
                    {e.share_lan ? "0.0.0.0" : "127.0.0.1"}:{e.port}
                  </td>
                  <td>
                    {e.status?.running ? (
                      <span className="folio-egress-on">● running</span>
                    ) : e.status?.last_error ? (
                      <span className="folio-egress-err">
                        × {e.status.last_error}
                      </span>
                    ) : (
                      <span className="folio-egress-off">○ stopped</span>
                    )}
                  </td>
                  <td className="folio-egress-actions">
                    <button
                      type="button"
                      className="folio-btn"
                      onClick={() => void onToggle(e)}
                      disabled={busy !== null}
                    >
                      {e.status?.running ? "Stop" : "Start"}
                    </button>
                    <button
                      type="button"
                      className="folio-btn"
                      onClick={() => setDraft(e)}
                      disabled={busy !== null}
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      className="folio-btn folio-btn-danger"
                      onClick={() => void onDelete(e.id)}
                      disabled={busy !== null}
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {!draft ? (
          <button
            type="button"
            className="folio-btn folio-btn-primary"
            onClick={startNew}
            disabled={busy !== null || servers.length === 0}
          >
            + New egress
          </button>
        ) : (
          <div className="folio-egress-form">
            <div className="folio-egress-row">
              <label>Name</label>
              <input
                type="text"
                value={draft.name}
                onChange={(ev) =>
                  setDraft({ ...draft, name: ev.target.value })
                }
                placeholder="Telegram-DE"
              />
            </div>
            <div className="folio-egress-row">
              <label>Server</label>
              <select
                value={draft.server_id}
                onChange={(ev) =>
                  setDraft({ ...draft, server_id: ev.target.value })
                }
              >
                {servers.map((s) => (
                  <option key={s.id} value={s.id}>
                    {serverName(s.id)}
                  </option>
                ))}
              </select>
            </div>
            <div className="folio-egress-row">
              <label>Protocol</label>
              <select
                value={draft.protocol || "socks5"}
                onChange={(ev) =>
                  setDraft({ ...draft, protocol: ev.target.value })
                }
              >
                <option value="socks5">SOCKS5</option>
                <option value="http">HTTP</option>
              </select>
            </div>
            <div className="folio-egress-row">
              <label>Port</label>
              <input
                type="number"
                min={1}
                max={65535}
                value={draft.port}
                onChange={(ev) =>
                  setDraft({
                    ...draft,
                    port: Math.max(1, Math.min(65535, +ev.target.value || 0)),
                  })
                }
              />
            </div>
            <div className="folio-egress-row">
              <label>
                <input
                  type="checkbox"
                  checked={draft.share_lan}
                  onChange={(ev) =>
                    setDraft({ ...draft, share_lan: ev.target.checked })
                  }
                />{" "}
                Share on LAN (bind 0.0.0.0)
              </label>
            </div>
            {draft.share_lan ? (
              <>
                <div className="folio-egress-row">
                  <label>LAN user</label>
                  <input
                    type="text"
                    value={draft.share_user ?? ""}
                    onChange={(ev) =>
                      setDraft({ ...draft, share_user: ev.target.value })
                    }
                    placeholder="optional"
                  />
                </div>
                <div className="folio-egress-row">
                  <label>LAN password</label>
                  <input
                    type="password"
                    value={draft.share_pass ?? ""}
                    onChange={(ev) =>
                      setDraft({ ...draft, share_pass: ev.target.value })
                    }
                    placeholder="optional"
                  />
                </div>
              </>
            ) : null}
            <div className="folio-egress-row">
              <label>
                <input
                  type="checkbox"
                  checked={draft.auto_start}
                  onChange={(ev) =>
                    setDraft({ ...draft, auto_start: ev.target.checked })
                  }
                />{" "}
                Start automatically at daemon launch
              </label>
            </div>
            <div className="folio-egress-actions">
              <button
                type="button"
                className="folio-btn folio-btn-primary"
                onClick={() => void onSave()}
                disabled={busy !== null || !draft.server_id || draft.port <= 0}
              >
                {draft.id ? "Save" : "Create"}
              </button>
              <button
                type="button"
                className="folio-btn"
                onClick={() => setDraft(null)}
                disabled={busy !== null}
              >
                Cancel
              </button>
            </div>
          </div>
        )}
      </div>
    </Chapter>
  );
}

/** AppearanceChapter — light/dark toggle plus export/import of the
 *  user's full Mosaic config (subscriptions, rules, prefs) as a
 *  single JSON file. The export is a hand-written shape rather than
 *  a passthrough of any single API call so we can version it
 *  independently of the daemon's wire format. */
function AppearanceChapter(): JSX.Element {
  const theme = useTheme();
  const [busy, setBusy] = useState<"export" | "import" | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement | null>(null);

  const onExport = async () => {
    setBusy("export");
    setErr(null);
    setInfo(null);
    try {
      const [subs, rules, prefs] = await Promise.all([
        api.listSubscriptions(),
        api.listRules(),
        api.getPrefs(),
      ]);
      const blob = new Blob(
        [
          JSON.stringify(
            {
              kind: "mosaic-export",
              version: 1,
              exported_at: new Date().toISOString(),
              subscriptions: subs,
              rules,
              prefs,
            },
            null,
            2,
          ),
        ],
        { type: "application/json" },
      );
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `mosaic-config-${new Date()
        .toISOString()
        .slice(0, 10)}.json`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      setInfo(`Exported ${subs.length} subscription(s), ${rules.length} rule(s).`);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
    }
  };

  const onImportFile = async (file: File) => {
    setBusy("import");
    setErr(null);
    setInfo(null);
    try {
      const text = await file.text();
      const j = JSON.parse(text) as {
        kind?: string;
        version?: number;
        subscriptions?: Subscription[];
        prefs?: Prefs;
      };
      if (j.kind !== "mosaic-export") {
        throw new Error("not a mosaic-export file");
      }
      let added = 0;
      for (const s of j.subscriptions ?? []) {
        if (!s.url) continue;
        try {
          await api.addSubscription(s.url, s.name);
          added++;
        } catch {
          /* duplicate URLs / malformed entries — keep going */
        }
      }
      if (j.prefs) {
        try {
          await api.setPrefs(j.prefs);
        } catch {
          /* daemon Prefs shape may have evolved — non-fatal */
        }
      }
      setInfo(`Imported ${added} subscription(s).`);
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(null);
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  return (
    <Chapter
      num="vi"
      title="Appearance & backup"
      desc="theme + JSON export / import of your full Mosaic config"
    >
      <Opt
        name="Theme"
        desc="Dark theme inverts paper / ink while keeping the copper accent."
      >
        <Seg
          value={theme.mode}
          options={[
            { v: "light", lab: "LIGHT" },
            { v: "dark", lab: "DARK" },
          ]}
          onChange={(v) => theme.set(v === "dark" ? "dark" : "light")}
        />
      </Opt>
      <Opt
        name="Export config"
        desc="Saves subscriptions, rules and preferences as a single JSON file you can stash next to your other backups."
      >
        <button
          type="button"
          className="btn primary"
          onClick={() => void onExport()}
          disabled={busy !== null}
        >
          {busy === "export" ? "Exporting…" : "Export JSON"}
        </button>
      </Opt>
      <Opt
        name="Import config"
        desc="Loads a previous export. Subscriptions are added (duplicates skipped). Prefs overwrite the current values; rules are kept."
      >
        <input
          ref={fileRef}
          type="file"
          accept="application/json,.json"
          style={{ display: "none" }}
          onChange={(e) => {
            const f = e.target.files?.[0];
            if (f) void onImportFile(f);
          }}
        />
        <button
          type="button"
          className="btn ghost"
          onClick={() => fileRef.current?.click()}
          disabled={busy !== null}
        >
          {busy === "import" ? "Importing…" : "Import JSON"}
        </button>
      </Opt>
      {err ? <div className="modal-err">{err}</div> : null}
      {info ? (
        <div
          className="mono"
          style={{ color: "var(--copper)", fontSize: 11, marginTop: 6 }}
        >
          {info}
        </div>
      ) : null}
    </Chapter>
  );
}
