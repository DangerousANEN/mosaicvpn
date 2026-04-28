/**
 * OfflineBanner — top-of-app strip shown whenever the daemon
 * becomes unreachable. The status hook keeps polling on a 3s
 * cadence; the banner disappears on its own once the daemon is
 * back. F5 / Ctrl+R forces an immediate retry by reloading the
 * webview.
 */

interface OfflineBannerProps {
  retryNow: () => void;
}

export function OfflineBanner({ retryNow }: OfflineBannerProps): JSX.Element {
  return (
    <div className="offline-banner" role="status" aria-live="polite">
      <span className="offline-dot" aria-hidden="true" />
      <span className="offline-text">
        Mosaicd unreachable — auto-retrying every 3s · press F5 for recheck now
      </span>
      <button
        className="offline-retry"
        onClick={retryNow}
        title="Retry now (Ctrl+R also reloads the webview)"
      >
        retry
      </button>
    </div>
  );
}
