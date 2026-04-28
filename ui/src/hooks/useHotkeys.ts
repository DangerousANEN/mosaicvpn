/**
 * useHotkeys wires global keyboard shortcuts. Bindings:
 *
 *   Space        — toggle Engage tunnel / Disconnect
 *   Ctrl+F       — open the server search overlay
 *   Ctrl+,       — navigate to Folio (preferences)
 *   Ctrl+K       — open quick connect (search overlay alias)
 *   1..9         — connect to the Nth fastest station
 *   Esc          — close any open overlay (search, onboarding tour)
 *
 * Bindings ignore key events whose target is an editable element so
 * the user can still type spaces / digits inside <input> / <textarea>
 * without triggering the global handlers.
 */

import { useEffect } from "react";

export interface HotkeyHandlers {
  onToggleConnect?: () => void;
  onOpenSearch?: () => void;
  onOpenFolio?: () => void;
  onCloseOverlay?: () => void;
  onConnectFastest?: (rank: number) => void;
}

function isEditable(t: EventTarget | null): boolean {
  if (!(t instanceof HTMLElement)) return false;
  const tag = t.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
  return t.isContentEditable;
}

export function useHotkeys(h: HotkeyHandlers): void {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      // Esc closes overlays even from inside an input.
      if (e.key === "Escape") {
        h.onCloseOverlay?.();
        return;
      }
      if (isEditable(e.target)) return;
      const ctrl = e.ctrlKey || e.metaKey;
      if (ctrl && (e.key === "f" || e.key === "F")) {
        e.preventDefault();
        h.onOpenSearch?.();
        return;
      }
      if (ctrl && (e.key === "k" || e.key === "K")) {
        e.preventDefault();
        h.onOpenSearch?.();
        return;
      }
      if (ctrl && e.key === ",") {
        e.preventDefault();
        h.onOpenFolio?.();
        return;
      }
      if (!ctrl && e.key === " ") {
        e.preventDefault();
        h.onToggleConnect?.();
        return;
      }
      if (!ctrl && /^[1-9]$/.test(e.key)) {
        const n = Number(e.key);
        h.onConnectFastest?.(n);
        return;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [h]);
}
