/**
 * levelCluster — zoom-level-driven clustering for the world map.
 *
 * rc30 replaces the rc28 pixel-distance merge (adaptiveCluster.ts)
 * with a discrete four-level hierarchy:
 *
 *   continent → country → city → server
 *
 * The level is a pure function of the current TransformWrapper scale
 * (see `levelForScale`). At every level, all resolved server groups
 * are bucketed by a level-appropriate key (continent code / ISO2
 * country / city / host), and each bucket becomes a single cluster
 * pin. Clusters whose bucket ended up containing exactly one server
 * group collapse to an individual diamond marker, so a country with
 * one server shows the server directly rather than a circle-with-1
 * badge.
 *
 * Clicking a multi-member cluster zooms the wrapper to that cluster's
 * axis-aligned bbox — computed from the PROJECTED vbX/vbY of its
 * members, not from lat/lon — and the next re-cluster falls out of
 * the scale-dependent useMemo one level deeper.
 */

import type { Server } from "../api/types";
import { groupServers, type ServerGroup } from "./serverGroup";
import { cityToLatLon } from "./cityCoords";
import continentMap from "../data/continent_map.json";

// Mirror of WorldMap.project(). Kept here so the clusterer is
// independent of the renderer module.
const LON_OFFSET = 409.7;
const LON_SCALE = 2.414;
const LAT_OFFSET = 530.8;
const LAT_SCALE = 2.787;

export function projectVB(lat: number, lon: number): { x: number; y: number } {
  return { x: LON_OFFSET + LON_SCALE * lon, y: LAT_OFFSET - LAT_SCALE * lat };
}

export type MapLevel = "continent" | "country" | "city" | "server";

/** Scale thresholds match the rc30 spec — continent view at 1×,
 *  countries emerge at ~1.5×, cities at ~3×, individual servers at
 *  ~6× where server labels also become visible by default. */
export function levelForScale(s: number): MapLevel {
  if (s < 1.5) return "continent";
  if (s < 3) return "country";
  if (s < 6) return "city";
  return "server";
}

const CONTINENT_TO_COUNTRIES = continentMap as unknown as {
  countryToContinent: Record<string, string>;
  continentBBox: Record<string, [number, number, number, number]>;
};

const CONTINENT_NAMES: Record<string, string> = {
  NA: "North America",
  SA: "South America",
  EU: "Europe",
  AS: "Asia",
  AF: "Africa",
  OC: "Oceania",
  AN: "Antarctica",
};

export interface ResolvedGroup {
  group: ServerGroup;
  vbX: number;
  vbY: number;
  country: string;
  city: string;
  continent: string;
}

export interface LevelCluster {
  key: string;
  level: MapLevel;
  vbX: number;
  vbY: number;
  bbox: { minX: number; maxX: number; minY: number; maxY: number };
  members: ResolvedGroup[];
  totalServers: number;
  bestMs: number | null;
  active: boolean;
  /** Human-readable label: continent name / ISO2 country / city. */
  label: string;
}

/** Project each host group to viewBox coords and tag country / city /
 *  continent. Groups with no resolvable geo are dropped so we don't
 *  paint a pin at (0,0) off the coast of West Africa. */
export function resolveGroups(
  servers: Server[],
  activeServerId?: string,
): { resolved: ResolvedGroup[]; activeKey: string | null } {
  const groups = groupServers(servers);
  const out: ResolvedGroup[] = [];
  let activeKey: string | null = null;
  for (const g of groups) {
    let lat: number | undefined;
    let lon: number | undefined;
    for (const srv of [g.primary, ...g.members]) {
      if (
        typeof srv.lat === "number" &&
        typeof srv.lon === "number" &&
        (srv.lat !== 0 || srv.lon !== 0)
      ) {
        lat = srv.lat;
        lon = srv.lon;
        break;
      }
      const c = cityToLatLon(srv.city, srv.country, srv.address);
      if (c) {
        lat = c.lat;
        lon = c.lon;
        break;
      }
    }
    if (lat === undefined || lon === undefined) continue;
    const country = (g.primary.country || "").toUpperCase();
    const city = (g.primary.city || "").trim();
    const continent = CONTINENT_TO_COUNTRIES.countryToContinent[country] || "??";
    const { x, y } = projectVB(lat, lon);
    out.push({ group: g, vbX: x, vbY: y, country, city, continent });
    if (
      activeServerId !== undefined &&
      g.members.some((m) => m.id === activeServerId)
    ) {
      activeKey = g.key;
    }
  }
  return { resolved: out, activeKey };
}

function bucketKey(r: ResolvedGroup, level: MapLevel): string {
  switch (level) {
    case "continent":
      return r.continent || "??";
    case "country":
      return r.country || "??";
    case "city":
      // Include country in the key so same-name cities (Springfield, MO
      // vs Springfield, VT) don't collapse. Fallback to host when no
      // city is known, keeping unknown-city hosts as individual pins.
      return r.country + "|" + (r.city.toLowerCase() || "~" + r.group.key);
    case "server":
      return r.group.key;
  }
}

function labelFor(level: MapLevel, members: ResolvedGroup[]): string {
  switch (level) {
    case "continent": {
      const c = members[0].continent;
      return CONTINENT_NAMES[c] || c;
    }
    case "country":
      return members[0].country || "??";
    case "city": {
      const g = members[0].group;
      return g.primary.city || g.primary.country || g.host;
    }
    case "server": {
      const g = members[0].group;
      return g.primary.city || g.host;
    }
  }
}

/**
 * Bucket resolved groups by level and return one cluster per bucket.
 * Cluster centroid = mean of member positions; bbox = union.
 */
export function clusterAtLevel(
  resolved: ResolvedGroup[],
  level: MapLevel,
  activeKey: string | null,
): LevelCluster[] {
  if (resolved.length === 0) return [];
  const buckets = new Map<string, ResolvedGroup[]>();
  for (const r of resolved) {
    const k = bucketKey(r, level);
    const arr = buckets.get(k);
    if (arr) arr.push(r);
    else buckets.set(k, [r]);
  }
  const out: LevelCluster[] = [];
  for (const [key, members] of buckets) {
    let minX = Infinity;
    let maxX = -Infinity;
    let minY = Infinity;
    let maxY = -Infinity;
    let sx = 0;
    let sy = 0;
    let bestMs: number | null = null;
    let totalServers = 0;
    let active = false;
    for (const m of members) {
      sx += m.vbX;
      sy += m.vbY;
      if (m.vbX < minX) minX = m.vbX;
      if (m.vbX > maxX) maxX = m.vbX;
      if (m.vbY < minY) minY = m.vbY;
      if (m.vbY > maxY) maxY = m.vbY;
      totalServers += m.group.members.length;
      if (
        m.group.bestMs !== null &&
        (bestMs === null || m.group.bestMs < bestMs)
      ) {
        bestMs = m.group.bestMs;
      }
      if (activeKey !== null && m.group.key === activeKey) active = true;
    }
    out.push({
      key: `${level}:${key}`,
      level,
      vbX: sx / members.length,
      vbY: sy / members.length,
      bbox: { minX, maxX, minY, maxY },
      members,
      totalServers,
      bestMs,
      active,
      label: labelFor(level, members),
    });
  }
  // Paint N → S so northern pins layer on top of southern overlaps.
  out.sort((a, b) => b.vbY - a.vbY);
  return out;
}

/** Convenience wrapper: resolve then cluster at the given scale. */
export function clusterAtScale(
  servers: Server[],
  scale: number,
  activeServerId?: string,
): { clusters: LevelCluster[]; level: MapLevel; activeKey: string | null } {
  const level = levelForScale(scale);
  const { resolved, activeKey } = resolveGroups(servers, activeServerId);
  const clusters = clusterAtLevel(resolved, level, activeKey);
  return { clusters, level, activeKey };
}
