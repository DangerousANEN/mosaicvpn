/**
 * useLiveServers polls /v1/servers every 5 s while the page is
 * visible. The daemon's /v1/events stream only carries Status — not
 * the server list — so the cleanest path to "live" Folio / Atlas /
 * Tray is a shared poll hook that every screen consumes instead of
 * hand-rolling its own setInterval.
 *
 * The hook pauses while document.hidden so background tabs don't
 * burn bandwidth. Errors surface as `error` for callers that want
 * to render a banner; the previous server list is preserved on
 * failure so the UI doesn't blank out on a transient hiccup.
 */

import { useEffect, useState } from "react";
import { api } from "../api/client";
import type { Server } from "../api/types";

export interface LiveServersHook {
  servers: Server[];
  error: string | null;
  /** Force an immediate refetch — useful right after mutating the
   *  server list (refresh subscription, delete subscription, etc.)
   *  so the UI doesn't wait up to 5 s for the next tick. */
  reload: () => Promise<void>;
}

const POLL_INTERVAL_MS = 5000;

export function useLiveServers(): LiveServersHook {
  const [servers, setServers] = useState<Server[]>([]);
  const [error, setError] = useState<string | null>(null);

  const reload = async (): Promise<void> => {
    try {
      const s = await api.listServers();
      setServers(s);
      setError(null);
    } catch (e) {
      setError((e as Error).message);
    }
  };

  useEffect(() => {
    let cancelled = false;
    const tick = () => {
      if (cancelled) return;
      if (typeof document !== "undefined" && document.hidden) return;
      void reload();
    };
    tick();
    const id = window.setInterval(tick, POLL_INTERVAL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return { servers, error, reload };
}
