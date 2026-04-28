/**
 * useTheme persists the user's light / dark preference in
 * localStorage and toggles `data-theme="dark"` on the document
 * root so CSS-variable swaps take effect globally. The dark
 * palette inverts the Atlas paper/ink contrast while keeping the
 * copper accent identical so the page identity stays recognisable.
 */

import { useEffect, useState } from "react";
import { getTheme, setTheme, type ThemeMode } from "../utils/localStore";

export interface ThemeHook {
  mode: ThemeMode;
  toggle: () => void;
  set: (mode: ThemeMode) => void;
}

export function useTheme(): ThemeHook {
  const [mode, setMode] = useState<ThemeMode>(() => getTheme());

  useEffect(() => {
    const root = document.documentElement;
    if (mode === "dark") root.setAttribute("data-theme", "dark");
    else root.removeAttribute("data-theme");
    setTheme(mode);
  }, [mode]);

  return {
    mode,
    toggle: () => setMode((m) => (m === "dark" ? "light" : "dark")),
    set: setMode,
  };
}
