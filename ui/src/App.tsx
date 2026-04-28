import { useState } from "react";
import { Marginalia } from "./components/Marginalia";
import { useStatus } from "./hooks/useStatus";
import { Main } from "./screens/Main";
import { Pool } from "./screens/Pool";
import { Routing } from "./screens/Routing";
import { Folio } from "./screens/Folio";
import { Tray } from "./screens/Tray";

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

export function App(): JSX.Element {
  const trayPopup = isTrayPopup();
  const { status, load, error } = useStatus();
  const [screen, setScreen] = useState<Screen>("main");

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
            onClick={() => setScreen(s.id)}
          >
            {s.label}
          </button>
        ))}
      </nav>

      {screen === "main" ? <Main status={status} /> : null}
      {screen === "pool" ? <Pool activeServerId={status.server?.id} /> : null}
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
