import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles/atlas.css";
import "./styles/app.css";
import "./styles/pool.css";
import "./styles/routing.css";
import "./styles/folio.css";
import "./styles/tray.css";
import { App } from "./App";
import { ErrorBoundary } from "./ErrorBoundary";

// Surface uncaught async errors so a release build doesn't silently
// blank the webview when, e.g., a fetch rejection or SSE handler
// throws. Without this you only see them in devtools.
window.addEventListener("error", (e) => {
  console.error("window.error:", e.error ?? e.message);
});
window.addEventListener("unhandledrejection", (e) => {
  console.error("window.unhandledrejection:", e.reason);
});

const root = document.getElementById("root");
if (!root) throw new Error("missing #root");
createRoot(root).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
);
