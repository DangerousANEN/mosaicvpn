/**
 * StartupAdminGate — modal shown at app launch when the persisted
 * tunnel_mode is "tun" but the daemon is running unelevated. Forces
 * the user to either (a) relaunch as administrator so TUN can install
 * its Wintun adapter, or (b) downgrade to proxy mode so the unelevated
 * daemon can start at all. There is no "ignore" path because the rc28
 * regression report was specifically that an unelevated tun-mode boot
 * silently failed.
 *
 * Distinct from Folio's existing AdminGateModal — this one runs
 * before the user has navigated anywhere, has a third "Switch to
 * proxy" action that mutates Prefs server-side, and never auto-
 * dismisses on background click.
 */

interface StartupAdminGateProps {
  onElevate: () => void | Promise<void>;
  onSwitchToProxy: () => void | Promise<void>;
  busy?: boolean;
  err?: string | null;
}

export function StartupAdminGate({
  onElevate,
  onSwitchToProxy,
  busy,
  err,
}: StartupAdminGateProps): JSX.Element {
  return (
    <div
      className="modal-scrim"
      // Background click is a no-op — the user must explicitly pick a
      // path. Otherwise a stray click could silently dismiss the gate
      // and leave them with a half-broken tun-mode session.
      onClick={(e) => e.stopPropagation()}
    >
      <div
        className="modal admin-gate"
        role="dialog"
        aria-modal="true"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="modal-eyebrow">Plate i · launch · admin gate</div>
        <div className="modal-title">
          TUN mode is enabled but Mosaic is <i>not</i> running as administrator
        </div>
        <p className="modal-body">
          Wintun (the system-wide tunnel adapter) requires elevation. Either
          relaunch Mosaic as administrator, or switch to SOCKS / HTTP proxy
          mode — proxy mode runs unelevated but only routes traffic from apps
          you point at the local proxy.
        </p>
        {err ? <div className="modal-err">{err}</div> : null}
        <div className="modal-actions">
          <button
            type="button"
            className="btn ghost"
            disabled={!!busy}
            onClick={() => void onSwitchToProxy()}
          >
            Switch to proxy mode
          </button>
          <button
            type="button"
            className="btn primary"
            disabled={!!busy}
            onClick={() => void onElevate()}
          >
            Restart as administrator
          </button>
        </div>
      </div>
    </div>
  );
}
