import { useEffect, useState } from "react";
import { Marginalia } from "./components/Marginalia";
import { useStatus } from "./hooks/useStatus";
import { Main } from "./screens/Main";
import { Pool } from "./screens/Pool";
import { Routing } from "./screens/Routing";
import { Folio } from "./screens/Folio";
import { Tray } from "./screens/Tray";
import { SubscriptionDetail } from "./screens/SubscriptionDetail";
import { api } from "./api/client";
import type { Subscription } from "./api/types";

type Screen = "main" | "routing" | "pool" | "folio";

const SCREENS: { id: Screen; label: string }[] = [
  { id: "main", label: "Atlas" },
  { id: "pool", label: "Pool" },
  { id: "routing", label: "Routing" },
  { id: "folio", label: "Folio" },
];

// isTrayPopup detects whether the renderer is being loaded into the
// dedicated tray-popup window (label "tray-popup", URL "#/tray"). When
// true the App returns a slim, frame-friendly Tray screen instead of
// the full Atlas shell with its TOC nav.
function isTrayPopup(): boolean {
  return (
    typeof window !== "undefined" &&
    (window.location.hash === "#/tray" || window.location.hash === "#tray")
  );
}

// Pool drill-down is encoded as `#sub=<id>` in the URL hash. We watch
// `hashchange` so back-button navigation flips Pool ↔ SubscriptionDetail
// without any router dependency. Returns the matching subscription id
// or null when no drill-down is requested.
function readSubFromHash(): string | null {
  if (typeof window === "undefined") return null;
  const h = window.location.hash || "";
  const m = /^#?sub=([^&]+)/.exec(h.startsWith("#") ? h.slice(1) : h);
  return m ? decodeURIComponent(m[1]) : null;
}

export function App(): JSX.Element {
  const trayPopup = isTrayPopup();
  const { status, load, error } = useStatus();
  const [screen, setScreen] = useState<Screen>("main");
  const [subId, setSubId] = useState<string | null>(() => readSubFromHash());
  const [subs, setSubs] = useState<Subscription[]>([]);

  // Listen for hash changes (back / forward buttons, manual edits)
  // so the drill-down route stays in sync with the URL.
  useEffect(() => {
    const onHash = () => setSubId(readSubFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  // Subscription metadata is fetched once and refreshed whenever the
  // user enters Pool or a drill-down — the detail screen needs the
  // full Subscription object (name, url, format) which the server
  // list alone doesn't carry.
  useEffect(() => {
    if (load !== "ready") return;
    let cancelled = false;
    api
      .listSubscriptions()
      .then((s) => {
        if (!cancelled) setSubs(s);
      })
      .catch(() => {
        /* surfaced inside Pool / Detail's own error channels */
      });
    return () => {
      cancelled = true;
    };
  }, [load, screen, subId]);

  if (load === "loading") {
    return (
      <div className="app-shell">
        <div className="splash">
          <div className="badge">resolving…</div>
          <div className="hint">Reading the daemon lockfile</div>
        </div>
      </div>
    );
  }

  if (load === "no-daemon" || !status) {
    return (
      <div className="app-shell">
        <div className="splash">
          <div className="badge">daemon offline</div>
          <div className="hint">{error ?? "Start mosaicd and reload"}</div>
        </div>
      </div>
    );
  }

  if (trayPopup) {
    // Standalone tray window — no Marginalia, no TOC nav, just the
    // Tray screen. The window itself is frameless / always-on-top
    // (configured in tauri.conf.json), so the renderer just renders
    // the contents.
    return (
      <div className="app-shell tray-popup-shell">
        <Tray status={status} />
      </div>
    );
  }

  const drillSub = subId ? subs.find((s) => s.id === subId) : null;
  const showDrill = screen === "pool" && drillSub != null;

  return (
    <div className="app-shell">
      <Marginalia
        status={status}
        plate={plateFor(screen)}
        plateSubtitle={plateSubtitleFor(screen)}
      />
      <nav className="toc">
        {SCREENS.map((s) => (
          <button
            key={s.id}
            className={screen === s.id ? "active" : ""}
            onClick={() => {
              setScreen(s.id);
              if (s.id !== "pool") {
                // Clear any drill-down hash on nav-out so we don't
                // resurface it later when the user comes back to Pool.
                if (window.location.hash.startsWith("#sub=")) {
                  history.replaceState(null, "", "#");
                  setSubId(null);
                }
              }
            }}
          >
            {s.label}
          </button>
        ))}
      </nav>

      {screen === "main" ? <Main status={status} /> : null}
      {screen === "pool" && !showDrill ? (
        <Pool activeServerId={status.server?.id} />
      ) : null}
      {screen === "pool" && showDrill && drillSub ? (
        <SubscriptionDetail
          subscription={drillSub}
          activeServerId={status.server?.id}
          onBack={() => {
            history.replaceState(null, "", "#");
            setSubId(null);
          }}
          onConnect={async (id) => {
            await api.connect(id);
          }}
        />
      ) : null}
      {screen === "routing" ? <Routing /> : null}
      {screen === "folio" ? <Folio /> : null}
    </div>
  );
}

function plateFor(s: Screen): string {
  return { main: "IV", pool: "II", routing: "III", folio: "V" }[s];
}

function plateSubtitleFor(s: Screen): string {
  return {
    main: "The world, projected",
    pool: "Stations & subscriptions",
    routing: "Rules & priorities",
    folio: "Preferences",
  }[s];
}
