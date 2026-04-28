/**
 * countryCluster — second-pass clustering for the world map.
 *
 * groupServers() in serverGroup.ts collapses duplicate-host entries
 * into one ServerGroup per (resolved IP / address). For a small pool
 * that's enough — the map shows one teardrop per datacenter.
 *
 * For a 1 000-server subscription the pool spreads across 30+ cities
 * inside the same country and React melts under the weight of all the
 * SVG nodes, plus the labels overlap into mush. This file folds
 * groups belonging to the same ISO-country into a single
 * `CountryCluster` once a per-country threshold is exceeded.
 *
 * The shape mirrors `ServerGroup` enough that WorldMap can render
 * both in the same loop:
 *
 *   - `kind === "host"` → render the original teardrop (unchanged).
 *   - `kind === "country"` → render a country-style pin labelled
 *     `<ISO> · <N servers> · <best ms>` at the average lat/lon of its
 *     members; clicking opens a popover with the underlying
 *     ServerGroups so the user can drill down.
 *
 * The threshold is intentionally low (3 distinct cities) because the
 * user explicitly asked: "if too many in one country in different
 * cities, merge the whole country into one pin". 3 is the minimum
 * value of "too many" that still keeps single-city countries intact.
 */

import type { Server } from "../api/types";
import { cityToLatLon } from "./cityCoords";
import type { ServerGroup } from "./serverGroup";

/** Minimum distinct cities/host-groups in the same country before
 * the cluster collapses to a single country pin. */
export const COUNTRY_CLUSTER_THRESHOLD = 3;

export interface CountryCluster {
  kind: "country";
  /** ISO 3166-1 alpha-2 code (uppercased). Used as the React key
   *  and as the visible label. */
  iso: string;
  /** Pretty country name from the first member that supplied one,
   *  for the popover header. */
  name: string;
  /** Centroid (mean of member lat/lon) for the pin. */
  lat: number;
  lon: number;
  /** Member host-groups inside this country, sorted by best latency. */
  members: ServerGroup[];
  /** Best (lowest positive) latency across all servers in the cluster. */
  bestMs: number | null;
  /** Server with the best latency — what one-click Connect targets. */
  primary: Server;
  /** Total number of underlying Server entries (across all members). */
  totalServers: number;
}

export interface HostPin {
  kind: "host";
  group: ServerGroup;
}

export type WorldPin = HostPin | CountryCluster;

/**
 * Split groups into per-country buckets. Groups whose primary server
 * has no `country` field (geo lookup failed / never ran) end up in
 * the special bucket "?" and are returned as host pins regardless of
 * count, so we don't conjure a "?" mega-pin in the middle of the
 * Atlantic.
 */
function bucketByCountry(groups: ServerGroup[]): Map<string, ServerGroup[]> {
  const buckets = new Map<string, ServerGroup[]>();
  for (const g of groups) {
    const iso = (g.primary.country || "").trim().toUpperCase() || "?";
    const arr = buckets.get(iso);
    if (arr) arr.push(g);
    else buckets.set(iso, [g]);
  }
  return buckets;
}

/**
 * Returns the lat/lon to use for `g`. Falls back to cityToLatLon when
 * the daemon hasn't filled lat/lon yet — same logic WorldMap.tsx uses
 * for individual host pins, just lifted here so we can compute
 * centroids without re-projecting.
 */
function groupCoords(g: ServerGroup): { lat: number; lon: number } | null {
  for (const srv of [g.primary, ...g.members]) {
    if (
      typeof srv.lat === "number" &&
      typeof srv.lon === "number" &&
      (srv.lat !== 0 || srv.lon !== 0)
    ) {
      return { lat: srv.lat, lon: srv.lon };
    }
    const coords = cityToLatLon(srv.city, srv.country, srv.address);
    if (coords) return coords;
  }
  return null;
}

/**
 * Cluster `groups` by country. Countries with fewer than
 * `threshold` distinct host-groups are passed through as individual
 * host pins; countries above the threshold collapse into a single
 * `CountryCluster` whose lat/lon is the centroid of its members.
 *
 * Output order: country pins (sorted by best latency, ascending),
 * then host pins (already sorted by serverGroup).
 */
export function clusterByCountry(
  groups: ServerGroup[],
  threshold: number = COUNTRY_CLUSTER_THRESHOLD,
): WorldPin[] {
  const buckets = bucketByCountry(groups);
  const out: WorldPin[] = [];
  const clusters: CountryCluster[] = [];
  for (const [iso, members] of buckets) {
    if (iso === "?" || members.length < threshold) {
      for (const g of members) out.push({ kind: "host", group: g });
      continue;
    }
    let sumLat = 0;
    let sumLon = 0;
    let n = 0;
    let bestMs: number | null = null;
    let primary: Server = members[0].primary;
    let totalServers = 0;
    let name = "";
    for (const g of members) {
      const c = groupCoords(g);
      if (c) {
        sumLat += c.lat;
        sumLon += c.lon;
        n++;
      }
      totalServers += g.members.length;
      if (g.bestMs !== null && g.bestMs > 0) {
        if (bestMs === null || g.bestMs < bestMs) {
          bestMs = g.bestMs;
          primary = g.primary;
        }
      }
      if (!name) {
        const sample = g.primary.country;
        if (sample) name = sample;
      }
    }
    if (n === 0) {
      // No member had usable coords — fall back to host pins so we
      // don't draw a pin at (0,0).
      for (const g of members) out.push({ kind: "host", group: g });
      continue;
    }
    members.sort((a, b) => {
      const aMs = a.bestMs ?? Number.POSITIVE_INFINITY;
      const bMs = b.bestMs ?? Number.POSITIVE_INFINITY;
      return aMs - bMs;
    });
    clusters.push({
      kind: "country",
      iso,
      name: name || iso,
      lat: sumLat / n,
      lon: sumLon / n,
      members,
      bestMs,
      primary,
      totalServers,
    });
  }
  clusters.sort((a, b) => {
    const aMs = a.bestMs ?? Number.POSITIVE_INFINITY;
    const bMs = b.bestMs ?? Number.POSITIVE_INFINITY;
    return aMs - bMs;
  });
  return [...clusters, ...out];
}
