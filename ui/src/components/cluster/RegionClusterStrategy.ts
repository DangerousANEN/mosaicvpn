/**
 * RegionClusterStrategy — geo-administrative clustering.
 *
 * Three semantic bands (see zoomBands.ts):
 *
 *   continent  →  group ResolvedGroup by ISO continent code; one
 *                 cluster per continent. Shape = continent path
 *                 (union of country paths) from `shapeStore`.
 *   country    →  group by ISO-2 country code. Shape = country
 *                 path. One cluster per country.
 *   server     →  no grouping; one cluster per ServerGroup.
 *                 Shape = empty (renderer paints a diamond pin).
 *
 * Cluster ids encode (band, scope-key) so they remain stable while
 * the user pans / hovers within a band. Crossing a band boundary
 * intentionally rebuilds clusters — but the WorldMap tracks open
 * popovers by `seedServerId`, not cluster id, so the popover
 * survives the transition.
 *
 * Pure function of (resolved, ctx). No internal state.
 */

import { resolveBand } from "./zoomBands";
import {
  type Cluster,
  type ClusterContext,
  type IClusterStrategy,
  type ResolvedGroup,
  emptyBBox,
  expandBBox,
} from "./types";
import {
  getCountryByIso,
  getContinentByCode,
  type ContinentCode,
} from "../atlas/shapeStore";

const CONTINENT_LABELS: Record<string, string> = {
  NA: "North America",
  SA: "South America",
  EU: "Europe",
  AS: "Asia",
  AF: "Africa",
  OC: "Oceania",
  AN: "Antarctica",
};

function bestMs(members: ResolvedGroup[]): number | null {
  let best: number | null = null;
  for (const m of members) {
    const ms = m.group.bestMs;
    if (typeof ms !== "number" || ms <= 0) continue;
    if (best === null || ms < best) best = ms;
  }
  return best;
}

function totalServers(members: ResolvedGroup[]): number {
  let n = 0;
  for (const m of members) n += m.group.members.length;
  return n;
}

function isActive(members: ResolvedGroup[], activeKey: string | null): boolean {
  if (activeKey === null) return false;
  for (const m of members) if (m.group.key === activeKey) return true;
  return false;
}

function clusterByContinent(
  resolved: ResolvedGroup[],
  ctx: ClusterContext,
): Cluster[] {
  const buckets = new Map<string, ResolvedGroup[]>();
  for (const rg of resolved) {
    const code = rg.continent || "??";
    const arr = buckets.get(code);
    if (arr) arr.push(rg);
    else buckets.set(code, [rg]);
  }
  const out: Cluster[] = [];
  for (const [code, members] of buckets) {
    const shape = getContinentByCode(code as ContinentCode);
    let vbX: number;
    let vbY: number;
    let pathD = "";
    const bbox = emptyBBox();
    if (shape) {
      vbX = shape.centroid.x;
      vbY = shape.centroid.y;
      pathD = shape.pathD;
      bbox.minX = shape.bbox.minX;
      bbox.minY = shape.bbox.minY;
      bbox.maxX = shape.bbox.maxX;
      bbox.maxY = shape.bbox.maxY;
    } else {
      // Unknown continent — fall back to bbox of members.
      vbX = 0;
      vbY = 0;
      let sumX = 0;
      let sumY = 0;
      for (const m of members) {
        expandBBox(bbox, m.vbX, m.vbY);
        sumX += m.vbX;
        sumY += m.vbY;
      }
      vbX = sumX / members.length;
      vbY = sumY / members.length;
    }
    out.push({
      id: `region:continent:${code}`,
      vbX,
      vbY,
      bbox,
      shapePath: pathD,
      members,
      totalServers: totalServers(members),
      bestMs: bestMs(members),
      active: isActive(members, ctx.activeKey),
      label: CONTINENT_LABELS[code] || code,
      level: "continent",
    });
  }
  return out;
}

function clusterByCountry(
  resolved: ResolvedGroup[],
  ctx: ClusterContext,
): Cluster[] {
  const buckets = new Map<string, ResolvedGroup[]>();
  for (const rg of resolved) {
    const code = rg.country || "??";
    const arr = buckets.get(code);
    if (arr) arr.push(rg);
    else buckets.set(code, [rg]);
  }
  const out: Cluster[] = [];
  for (const [code, members] of buckets) {
    const shape = getCountryByIso(code);
    let vbX: number;
    let vbY: number;
    let pathD = "";
    const bbox = emptyBBox();
    let label = code;
    if (shape) {
      vbX = shape.centroid.x;
      vbY = shape.centroid.y;
      pathD = shape.pathD;
      bbox.minX = shape.bbox.minX;
      bbox.minY = shape.bbox.minY;
      bbox.maxX = shape.bbox.maxX;
      bbox.maxY = shape.bbox.maxY;
      label = shape.name || code;
    } else {
      let sumX = 0;
      let sumY = 0;
      for (const m of members) {
        expandBBox(bbox, m.vbX, m.vbY);
        sumX += m.vbX;
        sumY += m.vbY;
      }
      vbX = sumX / members.length;
      vbY = sumY / members.length;
    }
    out.push({
      id: `region:country:${code}`,
      vbX,
      vbY,
      bbox,
      shapePath: pathD,
      members,
      totalServers: totalServers(members),
      bestMs: bestMs(members),
      active: isActive(members, ctx.activeKey),
      label,
      level: "country",
    });
  }
  return out;
}

function clusterByServer(
  resolved: ResolvedGroup[],
  ctx: ClusterContext,
): Cluster[] {
  const out: Cluster[] = [];
  for (const rg of resolved) {
    const bbox = emptyBBox();
    expandBBox(bbox, rg.vbX, rg.vbY);
    const members = [rg];
    const label = rg.city || rg.country || rg.group.primary.name || "station";
    out.push({
      id: `region:server:${rg.group.key}`,
      vbX: rg.vbX,
      vbY: rg.vbY,
      bbox,
      shapePath: "",
      members,
      totalServers: rg.group.members.length,
      bestMs: bestMs(members),
      active: isActive(members, ctx.activeKey),
      label,
      level: "server",
    });
  }
  return out;
}

class Region implements IClusterStrategy {
  readonly name = "region";

  cluster(resolved: ResolvedGroup[], ctx: ClusterContext): Cluster[] {
    const band = resolveBand(ctx.scale);
    if (band.kind === "continent") return clusterByContinent(resolved, ctx);
    if (band.kind === "country") return clusterByCountry(resolved, ctx);
    return clusterByServer(resolved, ctx);
  }

  bandLabel(ctx: ClusterContext): string {
    const band = resolveBand(ctx.scale);
    return `${band.kind} · ${ctx.scale.toFixed(1)}×`;
  }
}

export const RegionClusterStrategy: IClusterStrategy = new Region();
