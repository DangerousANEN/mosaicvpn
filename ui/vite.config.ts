import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import pkg from "./package.json" with { type: "json" };

// Resolve the version baked into the renderer bundle.  Priority:
//   1. APP_VERSION env (release.yml passes the v0.1.0-rcN git tag).
//   2. GITHUB_REF_NAME if it looks like a v* tag (CI fallback).
//   3. package.json "version" (local dev).
// UpdateBanner reads __APP_VERSION__ via Vite define instead of a
// hard-coded literal so the banner doesn't perma-trigger after each
// rc tag is cut.
function resolveAppVersion(): string {
  const explicit = process.env.APP_VERSION;
  if (explicit && explicit.trim() !== "") return explicit.trim();
  const ref = process.env.GITHUB_REF_NAME;
  if (ref && ref.startsWith("v")) return ref;
  return `v${pkg.version}-dev`;
}

// Tauri expects a fixed dev port and the renderer's assets at a fixed
// path. This config matches src-tauri/tauri.conf.json.
// https://v2.tauri.app/start/frontend/vite/
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
  },
  envPrefix: ["VITE_", "TAURI_"],
  define: {
    __APP_VERSION__: JSON.stringify(resolveAppVersion()),
  },
  build: {
    target: "es2022",
    sourcemap: true,
  },
});
