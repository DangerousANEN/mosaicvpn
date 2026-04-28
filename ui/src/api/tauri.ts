// Thin wrapper around Tauri's `window.__TAURI__` invoke bridge.
//
// The renderer can be loaded by Tauri (production build, Tauri dev)
// or by plain `vite dev` for fast iteration. We never want a missing
// `window.__TAURI__` to crash the UI, so all helpers degrade
// gracefully in browser-only contexts (admin gate becomes a no-op,
// restart returns Err, etc.).

type TauriInvokeFn = (cmd: string, args?: Record<string, unknown>) => Promise<unknown>;

interface TauriGlobals {
  invoke?: TauriInvokeFn;
  core?: { invoke?: TauriInvokeFn };
}

function tauri(): TauriGlobals | null {
  if (typeof window === "undefined") return null;
  // Tauri 2 attaches under window.__TAURI_INTERNALS__.invoke and
  // window.__TAURI__.core.invoke depending on version. Prefer the
  // public surface where available.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const w = window as unknown as { __TAURI__?: TauriGlobals; __TAURI_INTERNALS__?: TauriGlobals };
  return w.__TAURI__ ?? w.__TAURI_INTERNALS__ ?? null;
}

function invoke(): TauriInvokeFn | null {
  const t = tauri();
  if (!t) return null;
  return t.invoke ?? t.core?.invoke ?? null;
}

export async function isAdmin(): Promise<boolean> {
  const inv = invoke();
  if (!inv) return true; // browser dev — assume privileged
  try {
    const v = await inv("is_admin");
    return Boolean(v);
  } catch {
    return false;
  }
}

export async function restartAsAdmin(): Promise<void> {
  const inv = invoke();
  if (!inv) throw new Error("restart_as_admin: not running under Tauri");
  await inv("restart_as_admin");
}

export async function trayPopupToggle(): Promise<void> {
  const inv = invoke();
  if (!inv) return;
  await inv("tray_popup_toggle").catch(() => {
    /* best-effort */
  });
}
