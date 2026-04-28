/**
 * UpdateBanner — fetches the GitHub Releases API once at app
 * startup and surfaces a small dismissible strip when a newer
 * tag than the bundled CURRENT_VERSION is available. The user can
 * dismiss per-version (the dismissal is keyed on the version
 * string so a *later* release will resurface the banner).
 *
 * The fetch runs through the renderer's network stack — Tauri's
 * webview allows arbitrary HTTPS by default. Failures are silent.
 */

import { useEffect, useState } from "react";
import {
  getDismissedUpdate,
  setDismissedUpdate,
} from "../utils/localStore";

const CURRENT_VERSION = "v0.1.0-rc28";
const RELEASES_URL =
  "https://api.github.com/repos/DangerousANEN/mosaicvpn/releases/latest";

interface ReleaseInfo {
  tag_name?: string;
  html_url?: string;
}

/** Compare two semver-ish tags. Returns true if `a` is newer than
 *  `b`. Both are assumed to follow `v0.1.0-rc<N>` so we strip
 *  prefixes and lex-compare numerically on the last segment when
 *  both are RCs. Falls back to string comparison otherwise. */
function isNewer(a: string, b: string): boolean {
  if (a === b) return false;
  const reRC = /v?(\d+)\.(\d+)\.(\d+)-rc(\d+)/i;
  const ma = reRC.exec(a);
  const mb = reRC.exec(b);
  if (ma && mb) {
    const cmp = (i: number): number => Number(ma[i]) - Number(mb[i]);
    if (cmp(1) !== 0) return cmp(1) > 0;
    if (cmp(2) !== 0) return cmp(2) > 0;
    if (cmp(3) !== 0) return cmp(3) > 0;
    return cmp(4) > 0;
  }
  return a > b;
}

export function UpdateBanner(): JSX.Element | null {
  const [latest, setLatest] = useState<ReleaseInfo | null>(null);
  const [dismissed, setDismissed] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(RELEASES_URL, {
          headers: { accept: "application/vnd.github+json" },
        });
        if (!res.ok) return;
        const j = (await res.json()) as ReleaseInfo;
        if (!cancelled) setLatest(j);
      } catch {
        /* silent */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const tag = latest?.tag_name;
  if (!tag || dismissed) return null;
  if (!isNewer(tag, CURRENT_VERSION)) return null;
  if (getDismissedUpdate() === tag) return null;

  const url = latest?.html_url ?? "https://github.com/DangerousANEN/mosaicvpn/releases";

  return (
    <div className="update-banner">
      <span className="update-text">
        New release <b>{tag}</b> available — currently on {CURRENT_VERSION}.
      </span>
      <a
        className="update-link"
        href={url}
        target="_blank"
        rel="noreferrer"
      >
        view release →
      </a>
      <button
        className="update-dismiss"
        onClick={() => {
          setDismissedUpdate(tag);
          setDismissed(true);
        }}
        title="Hide until a newer release is published"
      >
        dismiss
      </button>
    </div>
  );
}
