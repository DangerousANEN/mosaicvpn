/**
 * useStatus subscribes to the daemon's /v1/events SSE stream and
 * exposes the latest status snapshot to React. It is the single
 * source of truth for the toggle state, the header dot, the tray
 * icon — i.e. the Atlas single-status-surface principle in code
 * form.
 *
 * rc28 additions:
 *   - Auto-retry on daemon-offline. Whenever /v1/status fails or
 *     the SSE stream errors out, we flip the hook into a "polling"
 *     mode that GETs /v1/status every RETRY_MS until we succeed,
 *     at which point we re-subscribe to /v1/events. This is what
 *     drives the OfflineBanner and lets the UI auto-recover when
 *     mosaicd is killed and re-launched without forcing the user
 *     to F5.
 *   - retryNow() lets callers force an immediate retry (the banner
 *     uses this so the user gets feedback on click).
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { api, resolveEndpoint, subscribeStatus } from "../api/client";
import type { Status } from "../api/types";

export type LoadState = "loading" | "ready" | "no-daemon";

export interface StatusHook {
  status: Status | null;
  load: LoadState;
  /** True whenever we've lost the daemon and are auto-retrying.
   *  When ready === true and offline === true, the last cached
   *  status is still rendered — the daemon went away mid-session.
   *  When ready === false and offline === true, the daemon never
   *  came up to begin with. Either way the OfflineBanner is the
   *  single visible cue. */
  offline: boolean;
  error: string | null;
  retryNow: () => void;
}

const RETRY_MS = 3000;

export function useStatus(): StatusHook {
  const [status, setStatus] = useState<Status | null>(null);
  const [load, setLoad] = useState<LoadState>("loading");
  const [offline, setOffline] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const detachRef = useRef<(() => void) | null>(null);
  const cancelledRef = useRef(false);
  const retryTimerRef = useRef<number | null>(null);

  const clearRetry = () => {
    if (retryTimerRef.current !== null) {
      window.clearInterval(retryTimerRef.current);
      retryTimerRef.current = null;
    }
  };

  const teardownStream = () => {
    detachRef.current?.();
    detachRef.current = null;
  };

  const tryConnect = useCallback(async () => {
    if (cancelledRef.current) return;
    try {
      // Force a fresh endpoint resolve so a daemon that came back
      // on a different port (after a restart) is re-discovered.
      await resolveEndpoint(true);
      const initial = await api.status();
      if (cancelledRef.current) return;
      setStatus(initial);
      setLoad("ready");
      setOffline(false);
      setError(null);
      clearRetry();
      teardownStream();
      detachRef.current = await subscribeStatus(
        (s) => {
          if (!cancelledRef.current) {
            setStatus(s);
            setOffline(false);
          }
        },
        () => {
          // SSE dropped — fall back into the retry loop. We keep
          // the last-known Status so the UI doesn't blank out.
          if (!cancelledRef.current) {
            setOffline(true);
            startRetryLoop();
          }
        },
      );
    } catch (err) {
      if (cancelledRef.current) return;
      setError((err as Error).message);
      setOffline(true);
      // Keep load=ready if we ever succeeded; only first-boot
      // failures land in no-daemon territory.
      setLoad((prev) => (prev === "ready" ? "ready" : "no-daemon"));
      startRetryLoop();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const startRetryLoop = useCallback(() => {
    if (retryTimerRef.current !== null) return;
    retryTimerRef.current = window.setInterval(() => {
      void tryConnect();
    }, RETRY_MS);
  }, [tryConnect]);

  useEffect(() => {
    cancelledRef.current = false;
    void tryConnect();
    return () => {
      cancelledRef.current = true;
      clearRetry();
      teardownStream();
    };
  }, [tryConnect]);

  const retryNow = useCallback(() => {
    void tryConnect();
  }, [tryConnect]);

  return { status, load, offline, error, retryNow };
}
