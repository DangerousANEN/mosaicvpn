/**
 * serverGroup — collapse a flat list of servers into "host" groups.
 *
 * A host group is a set of Server entries that the UI should render as
 * a single row in the Pool list and a single pin on the world map. The
 * grouping key is best-effort:
 *
 *   1. Servers with the same `resolved_ip` (set by the daemon's Test
 *      handler after a DNS lookup) collapse into one group. This is the
 *      "real" host identity and cleanly handles the case where one
 *      physical server exposes multiple ports / protocols, even if the
 *      subscription advertises some entries by IP and others by domain
 *      (e.g. `bondgacha.com` and `206.251.50.217` resolving to the
 *      same A-record).
 *
 *   2. If `resolved_ip` is empty (server hasn't been probed yet, or
 *      the address didn't resolve), fall back to `address` verbatim.
 *      That keeps fresh subscriptions usable before Test all has run.
 *
 *   3. As a last-resort affinity, two groups whose pins land within
 *      ~0.05° of each other on the world map are visually merged in
 *      the WorldMap component, but kept distinct in the Pool list.
 *      That last step is implemented in WorldMap, not here.
 *
 * Within a group, members are sorted by best (lowest, positive)
 * latency first so the "primary" pick for one-click Connect is at
 * index 0.
 */

import type { Server } from "../api/types";

export interface ServerGroup {
  /** Stable identifier for the group; equals the grouping key. */
  key: string;
  /** Resolved IP (or address fallback). Useful for display. */
  host: string;
  /** All servers belonging to this host. */
  members: Server[];
  /** Convenience: lowest positive latency across members, or null. */
  bestMs: number | null;
  /** Member that exposed the lowest latency, or members[0]. */
  primary: Server;
}

export function groupServers(servers: Server[]): ServerGroup[] {
  const buckets = new Map<string, Server[]>();
  for (const s of servers) {
    const key = (s.resolved_ip || s.address || s.id).toLowerCase();
    const arr = buckets.get(key);
    if (arr) arr.push(s);
    else buckets.set(key, [s]);
  }
  const out: ServerGroup[] = [];
  for (const [key, members] of buckets) {
    members.sort((a, b) => byLatency(a) - byLatency(b));
    const best = members.find(
      (m) => typeof m.last_test_ms === "number" && m.last_test_ms > 0,
    );
    out.push({
      key,
      host: members[0].resolved_ip || members[0].address,
      members,
      bestMs: best?.last_test_ms ?? null,
      primary: best ?? members[0],
    });
  }
  // Stable, deterministic order: groups with measured latency first
  // (lowest at the top), then unmeasured groups by host.
  out.sort((a, b) => {
    const aHas = a.bestMs !== null;
    const bHas = b.bestMs !== null;
    if (aHas && bHas) return (a.bestMs as number) - (b.bestMs as number);
    if (aHas) return -1;
    if (bHas) return 1;
    return a.host.localeCompare(b.host);
  });
  return out;
}

function byLatency(s: Server): number {
  const ms = s.last_test_ms ?? 0;
  if (ms > 0) return ms;
  if (ms < 0) return 9_000_000; // failed → bottom
  return 9_999_999; // never tested → very bottom
}
