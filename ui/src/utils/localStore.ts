/**
 * localStore — thin typed wrappers around localStorage for every
 * client-only piece of state we keep between Mosaic sessions:
 *
 *   - favorites: server IDs the user has starred.
 *   - notes: per-server free-form text labels.
 *   - history: timestamped (id → ms-since-epoch) of last connect.
 *   - theme: "light" | "dark" preference.
 *   - latencyHistory: per-server rolling window of probe RTTs.
 *   - dismissedOnboarding / dismissedUpdate: boolean flags for the
 *     first-run tour and the "new release available" banner so we
 *     don't re-show them every launch once the user has dismissed.
 *
 * The daemon doesn't yet have endpoints for any of this and the
 * data is fundamentally per-machine UX state, not VPN config — so
 * keeping it in localStorage is the right call.
 */

const PREFIX = "mosaic.v1.";
const FAVS = `${PREFIX}favorites`;
const NOTES = `${PREFIX}notes`;
const HISTORY = `${PREFIX}history`;
const THEME = `${PREFIX}theme`;
const LATENCY = `${PREFIX}latency`;
const ONBOARDED = `${PREFIX}onboarded`;
const DISMISSED_UPDATE = `${PREFIX}dismissed_update`;

function read<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function write<T>(key: string, value: T): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* quota / disabled — silently ignore */
  }
}

/* ---------- favorites ---------- */

export function getFavorites(): Set<string> {
  return new Set(read<string[]>(FAVS, []));
}

export function setFavorite(id: string, fav: boolean): Set<string> {
  const s = getFavorites();
  if (fav) s.add(id);
  else s.delete(id);
  write(FAVS, [...s]);
  return s;
}

/* ---------- notes ---------- */

export function getNotes(): Record<string, string> {
  return read<Record<string, string>>(NOTES, {});
}

export function setNote(id: string, text: string): Record<string, string> {
  const m = getNotes();
  if (text.trim() === "") delete m[id];
  else m[id] = text;
  write(NOTES, m);
  return m;
}

/* ---------- connect history ---------- */

export function getHistory(): Record<string, number> {
  return read<Record<string, number>>(HISTORY, {});
}

export function recordConnect(id: string): void {
  const m = getHistory();
  m[id] = Date.now();
  // Cap at 200 entries — drop the oldest.
  const entries = Object.entries(m);
  if (entries.length > 200) {
    entries.sort((a, b) => a[1] - b[1]);
    const dropN = entries.length - 200;
    for (let i = 0; i < dropN; i++) delete m[entries[i][0]];
  }
  write(HISTORY, m);
}

/* ---------- theme ---------- */

export type ThemeMode = "light" | "dark";

export function getTheme(): ThemeMode {
  const v = read<ThemeMode>(THEME, "light");
  return v === "dark" ? "dark" : "light";
}

export function setTheme(t: ThemeMode): void {
  write(THEME, t);
}

/* ---------- per-server latency history (sparkline) ---------- */

const LATENCY_WINDOW = 20;

export function getLatencySeries(id: string): number[] {
  const m = read<Record<string, number[]>>(LATENCY, {});
  return m[id] ?? [];
}

export function recordLatency(id: string, ms: number): void {
  if (!Number.isFinite(ms)) return;
  const m = read<Record<string, number[]>>(LATENCY, {});
  const arr = m[id] ?? [];
  // Treat negative / zero as a failed probe — store as NaN so the
  // sparkline can render a gap.
  const value = ms > 0 ? ms : NaN;
  arr.push(value);
  while (arr.length > LATENCY_WINDOW) arr.shift();
  m[id] = arr;
  write(LATENCY, m);
}

/* ---------- onboarding / update banners ---------- */

export function isOnboarded(): boolean {
  return read<boolean>(ONBOARDED, false);
}

export function markOnboarded(): void {
  write(ONBOARDED, true);
}

export function getDismissedUpdate(): string {
  return read<string>(DISMISSED_UPDATE, "");
}

export function setDismissedUpdate(version: string): void {
  write(DISMISSED_UPDATE, version);
}
