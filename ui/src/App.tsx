import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Marginalia } from "./components/Marginalia";
import { useStatus } from "./hooks/useStatus";
import { useTheme } from "./hooks/useTheme";
import { useHotkeys } from "./hooks/useHotkeys";
import { Main } from "./screens/Main";
import { Pool } from "./screens/Pool";
import { Routing } from "./screens/Routing";
import { Folio } from "./screens/Folio";
import { Tray } from "./screens/Tray";
import { SubscriptionDetail } from "./screens/SubscriptionDetail";
import { OfflineBanner } from "./components/OfflineBanner";
import { UpdateBanner } from "./components/UpdateBanner";
import { OnboardingTour } from "./components/OnboardingTour";
import { SearchOverlay } from "./components/SearchOverlay";
import { StartupAdminGate } from "./components/StartupAdminGate";
import { api } from "./api/client";
import { isAdmin, restartAsAdmin } from "./api/tauri";
import { isOnboarded, recordConnect } from "./utils/localStore";
import type { Server, Subscription } from "./api/types";

type Screen = "main" | "routing" | "pool" | "folio";

const SCREENS: { id: Screen; label: string }[] = [
  { id: "main", label: "Atlas" },
  { id: "pool", label: "Pool" },
  { id: "routing", label: "Routing" },
  { id: "folio", label: "Folio" },
];

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
  const { status, load, offline, error, retryNow } = useStatus();
  const [screen, setScreen] = useState<Screen>("main");
  const [subId, setSubId] = useState<string | null>(() => readSubFromHash());
  const [subs, setSubs] = useState<Subscription[]>([]);
  const [allServers, setAllServers] = useState<Server[]>([]);
  const [searchOpen, setSearchOpen] = useState(false);
  const [showOnboarding, setShowOnboarding] = useState(false);
  // Startup admin gate (rc28 AA): persists tunnel_mode=tun across
  // launches and prompts on next boot if Mosaic isn't elevated.
  const [adminGate, setAdminGate] = useState(false);
  const [adminGateBusy, setAdminGateBusy] = useState(false);
  const [adminGateErr, setAdminGateErr] = useState<string | null>(null);
  const adminGateChecked = useRef(false);

  useTheme();

  // Listen for hash changes (back / forward buttons, manual edits)
  // so the drill-down route stays in sync with the URL.
  useEffect(() => {
    const onHash = () => setSubId(readSubFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  // First-launch onboarding tour. Gated by localStorage so a power
  // user who reinstalls Mosaic doesn't get bounced through it again.
  useEffect(() => {
    if (load !== "ready" || trayPopup) return;
    if (!isOnboarded()) setShowOnboarding(true);
  }, [load, trayPopup]);

  // rc28 — drag-and-drop import. Accept .json / .yaml / .txt files
  // dropped anywhere on the window and feed them to api.addSubscription
  // as a data: URL. The daemon's parser already auto-detects sing-box,
  // Clash, v2ray, SIP008 etc. so we don't need format-specific
  // routing here.
  useEffect(() => {
    if (load !== "ready" || trayPopup) return;
    const onDragOver = (e: DragEvent) => {
      if (e.dataTransfer?.types?.includes("Files")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
      }
    };
    const onDrop = (e: DragEvent) => {
      const files = e.dataTransfer?.files;
      if (!files || files.length === 0) return;
      e.preventDefault();
      void (async () => {
        for (const f of Array.from(files)) {
          if (!/\.(ya?ml|json|txt)$/i.test(f.name)) continue;
          try {
            const txt = await f.text();
            const dataUrl = `data:text/plain;base64,${btoa(
              unescape(encodeURIComponent(txt)),
            )}`;
            await api.addSubscription(dataUrl, f.name);
          } catch {
            /* per-file errors are silent — Pool's listing will refresh */
          }
        }
      })();
    };
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("drop", onDrop);
    return () => {
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("drop", onDrop);
    };
  }, [load, trayPopup]);

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

  // Roster used by the Ctrl+F overlay + 1..9 hotkeys. Cheap poll on
  // top of Main's existing 5s ticker — the search overlay itself
  // memos on this so re-renders are cheap.
  useEffect(() => {
    if (load !== "ready") return;
    let cancelled = false;
    const tick = () => {
      api
        .listServers()
        .then((s) => {
          if (!cancelled) setAllServers(s);
        })
        .catch(() => {
          /* offline banner already covers the messaging */
        });
    };
    tick();
    const id = window.setInterval(tick, 8000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [load]);

  // rc28 — startup admin gate. Run once on first ready snapshot. If
  // the persisted tunnel_mode is tun but the daemon is unelevated,
  // pop the modal so the user can either relaunch elevated or fall
  // back to proxy mode. Suppressed in the tray-popup window because
  // it's a frameless companion and any modal would be cropped.
  useEffect(() => {
    if (adminGateChecked.current) return;
    if (load !== "ready" || !status || trayPopup) return;
    adminGateChecked.current = true;
    if ((status.tunnel_mode || "") !== "tun") return;
    void (async () => {
      const elevated = await isAdmin();
      if (!elevated) setAdminGate(true);
    })();
  }, [load, status, trayPopup]);

  const fastest = useMemo(
    () =>
      [...allServers]
        .filter((s) => (s.last_test_ms ?? 0) > 0)
        .sort((a, b) => (a.last_test_ms ?? 0) - (b.last_test_ms ?? 0)),
    [allServers],
  );

  const onConnectId = useCallback(async (id: string) => {
    try {
      await api.connect(id);
      recordConnect(id);
    } catch {
      /* errors surface inside the originating screen */
    }
  }, []);

  const onToggleConnect = useCallback(async () => {
    if (!status) return;
    try {
      if (status.state === "connected" || status.state === "connecting") {
        await api.disconnect();
      } else {
        await api.connect("");
      }
    } catch {
      /* surface elsewhere */
    }
  }, [status]);

  // Hotkeys. Sit at the App layer so they fire across every screen
  // — including from inside Pool / SubscriptionDetail / Folio.
  useHotkeys({
    onToggleConnect,
    onOpenSearch: () => setSearchOpen(true),
    onOpenFolio: () => setScreen("folio"),
    onCloseOverlay: () => {
      if (searchOpen) setSearchOpen(false);
      else if (showOnboarding) setShowOnboarding(false);
    },
    onConnectFastest: (rank: number) => {
      const target = fastest[rank - 1];
      if (target) void onConnectId(target.id);
    },
  });

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

  // Never blank the app once we've ever connected. The OfflineBanner
  // covers daemon-down state without nuking the last-known status.
  if ((load === "no-daemon" || !status) && !offline) {
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
    return (
      <div className="app-shell tray-popup-shell">
        {status ? <Tray status={status} /> : null}
      </div>
    );
  }

  if (!status) {
    // offline=true but no cached status — first-boot daemon failure.
    return (
      <div className="app-shell">
        <OfflineBanner retryNow={retryNow} />
        <div className="splash">
          <div className="badge">daemon offline</div>
          <div className="hint">
            {error ?? "Start mosaicd and Mosaic will reconnect automatically."}
          </div>
        </div>
      </div>
    );
  }

  const drillSub = subId ? subs.find((s) => s.id === subId) : null;
  const showDrill = screen === "pool" && drillSub != null;

  return (
    <div className="app-shell">
      {offline ? <OfflineBanner retryNow={retryNow} /> : null}
      <UpdateBanner />
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

      {screen === "main" ? (
        <Main
          status={status}
          onConnectId={onConnectId}
        />
      ) : null}
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
            recordConnect(id);
          }}
        />
      ) : null}
      {screen === "routing" ? <Routing /> : null}
      {screen === "folio" ? <Folio status={status} /> : null}

      {searchOpen ? (
        <SearchOverlay
          servers={allServers}
          onConnect={(id) => void onConnectId(id)}
          onClose={() => setSearchOpen(false)}
        />
      ) : null}

      {showOnboarding ? (
        <OnboardingTour onClose={() => setShowOnboarding(false)} />
      ) : null}

      {adminGate ? (
        <StartupAdminGate
          busy={adminGateBusy}
          err={adminGateErr}
          onElevate={async () => {
            setAdminGateBusy(true);
            setAdminGateErr(null);
            try {
              await restartAsAdmin();
              // restartAsAdmin asks Tauri to exit; if we're still here
              // the UAC was denied. Leave the gate up so the user can
              // pick the proxy fallback.
            } catch (e) {
              setAdminGateErr((e as Error).message);
            } finally {
              setAdminGateBusy(false);
            }
          }}
          onSwitchToProxy={async () => {
            setAdminGateBusy(true);
            setAdminGateErr(null);
            try {
              const cur = await api.getPrefs();
              await api.setPrefs({ ...cur, tunnel_mode: "proxy" });
              setAdminGate(false);
            } catch (e) {
              setAdminGateErr((e as Error).message);
            } finally {
              setAdminGateBusy(false);
            }
          }}
        />
      ) : null}
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
