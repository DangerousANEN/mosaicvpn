/// <reference types="vite/client" />

// Injected by Vite at build-time from APP_VERSION env (or a fallback
// chain — see vite.config.ts).  Read by UpdateBanner so the banner
// compares against the actual installed version instead of a literal
// that goes stale every rc.
declare const __APP_VERSION__: string;
