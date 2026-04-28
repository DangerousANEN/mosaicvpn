/**
 * adaptiveCluster — pixel-distance clustering for the world map.
 *
 * The user's spec: at the current map zoom, any pins whose on-screen
 * distance is below a threshold collapse into a single cluster pin.
 * Zoom in → clusters dissolve emergently into smaller clusters or
 * single pins; zoom out → adjacent pins merge.
 *
 * This replaces the rc26 hard-coded `scale < 1.8 ? country : host`
 * toggle, which hid all city detail until the user crossed a magic
 * threshold and never accounted for a single isolated server vs a
 * lump of 50 servers in the same metro area.
 *
 * Algorithm: greedy nearest-neighbour merge. We project every pin
 * to viewport pixels (linear in scale, since the map projection is
 * itself linear), then repeatedly absorb the closest pair within
 * MERGE_PX into one cluster. The bbox of each cluster is the union
 * of its members' positions — used by drill-down click to animate
 * zoomToElement onto the cluster's footprint.
 */

import type { Server } from "../api/types";
import { groupServers, type ServerGroup } from "./serverGroup";
import { cityToLatLon } from "./cityCoords";

/** Linear projection from (lat,lon) → world.svg viewBox coords.
 *  Mirrors WorldMap.project(); kept here as a copy so the
 *  clusterer is independent of the renderer module. */
const LON_OFFSET = 409.7;
const LON_SCALE = 2.414;
const LAT_OFFSET = 530.8;
const LAT_SCALE = 2.787;

function projectVB(lat: number, lon: number): { x: number; y: number } {
  return { x: LON_OFFSET + LON_SCALE * lon, y: LAT_OFFSET - LAT_SCALE * lat };
}

/** world.svg viewBox dimensions, used to translate viewBox-space
 *  coordinates into on-screen pixel distance at a given zoom. */
const VB_W = 784.077;
const VB_H = 458.627;

/** Pixel distance below which two pins merge into one cluster. The
 *  user explicitly asked for "if many servers and they overlap,
 *  cluster them"; 36 px keeps adjacent country labels from touching
 *  on a 1080p stage at 1× zoom and dissolves into individual pins by
 *  ~3× zoom. */
export const MERGE_PX = 36;

export interface ResolvedGroup {
  group: ServerGroup;
  /** projected coords in world.svg viewBox units */
  vbX: number;
  vbY: number;
}

export interface AdaptiveCluster {
  /** projected position (centroid) in world.svg viewBox units */
  vbX: number;
  vbY: number;
  members: ResolvedGroup[];
  /** axis-aligned bbox in viewBox units, used for drill-down zoom. */
  bbox: { minX: number; maxX: number; minY: number; maxY: number };
  /** Lowest measured latency across the cluster; null when no member
   *  has been probed yet. */
  bestMs: number | null;
  /** Underlying server count for the cluster badge. */
  totalServers: number;
  /** Stable React key — the lowest member group key, prefixed. */
  key: string;
  /** Active server is somewhere inside this cluster. */
  active: boolean;
}

/** Project every group to viewBox coords; drop groups that lack any
 *  geo information so we don't render a pin at (0,0). */
export function resolveGroups(servers: Server[], activeServerId?: string): {
  resolved: ResolvedGroup[];
  activeKey: string | null;
} {
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
    const { x, y } = projectVB(lat, lon);
    out.push({ group: g, vbX: x, vbY: y });
    if (
      activeServerId !== undefined &&
      g.members.some((m) => m.id === activeServerId)
    ) {
      activeKey = g.key;
    }
  }
  return { resolved: out, activeKey };
}

/**
 * Merge pins whose viewport distance falls below `mergePx` at the
 * current `scale`. `stageW`/`stageH` are the on-screen pixel size of
 * the map stage (not the viewBox). Returns the cluster set sorted by
 * latitude descending (so northern pins paint last and stay on top
 * over southern overlaps for nicer label layering).
 */
export function clusterAtScale(
  resolved: ResolvedGroup[],
  scale: number,
  stageW: number,
  stageH: number,
  activeKey: string | null,
  mergePx: number = MERGE_PX,
): AdaptiveCluster[] {
  if (resolved.length === 0) return [];
  // 1 viewBox unit = (stageW/VB_W) * scale pixels (X axis), similarly
  // for Y. We invert to get the merge threshold in viewBox units.
  const pxPerVbX = (stageW / VB_W) * scale;
  const pxPerVbY = (stageH / VB_H) * scale;
  // Use the *smaller* axis so we don't over-cluster on tall narrow
  // stages where Y compresses faster than X. Avoids "all of Europe
  // becomes one mega-cluster on portrait viewports".
  const pxPer = Math.min(pxPerVbX, pxPerVbY) || 1;
  const mergeVb = mergePx / pxPer;

  // Initialise: every group is its own singleton cluster.
  const clusters: AdaptiveCluster[] = resolved.map((r) => ({
    vbX: r.vbX,
    vbY: r.vbY,
    members: [r],
    bbox: { minX: r.vbX, maxX: r.vbX, minY: r.vbY, maxY: r.vbY },
    bestMs: r.group.bestMs,
    totalServers: r.group.members.length,
    key: r.group.key,
    active: activeKey !== null && r.group.key === activeKey,
  }));

  // Greedy merge: scan each cluster against every later cluster, fold
  // when within mergeVb. Re-scan after each fold to catch chains.
  // O(N²) is fine for N ≤ a few thousand; world.svg projections are
  // single-precision linear so we don't accumulate drift.
  let merged = true;
  while (merged) {
    merged = false;
    outer: for (let i = 0; i < clusters.length; i++) {
      for (let j = i + 1; j < clusters.length; j++) {
        const a = clusters[i];
        const b = clusters[j];
        const dx = a.vbX - b.vbX;
        const dy = a.vbY - b.vbY;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist > mergeVb) continue;
        // Fold b into a: union bbox + members; recompute centroid +
        // best ms; clear b.
        a.members.push(...b.members);
        a.bbox = {
          minX: Math.min(a.bbox.minX, b.bbox.minX),
          maxX: Math.max(a.bbox.maxX, b.bbox.maxX),
          minY: Math.min(a.bbox.minY, b.bbox.minY),
          maxY: Math.max(a.bbox.maxY, b.bbox.maxY),
        };
        a.totalServers += b.totalServers;
        if (
          b.bestMs !== null &&
          (a.bestMs === null || b.bestMs < a.bestMs)
        ) {
          a.bestMs = b.bestMs;
        }
        if (b.active) a.active = true;
        // Centroid: weighted average by member count keeps a single
        // 1-server pin from snapping the centre of a 50-server lump
        // toward itself.
        const totalA = a.members.length;
        a.vbX =
          (a.vbX * (totalA - b.members.length) + b.vbX * b.members.length) /
          totalA;
        a.vbY =
          (a.vbY * (totalA - b.members.length) + b.vbY * b.members.length) /
          totalA;
        clusters.splice(j, 1);
        merged = true;
        break outer;
      }
    }
  }

  clusters.sort((a, b) => b.vbY - a.vbY);
  return clusters;
}
