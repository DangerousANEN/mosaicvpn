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

/**
 * Server-band clustering: greedy proximity merge so any two
 * ServerGroups whose pin centroids project within the same on-
 * screen "diamond footprint" are collapsed into one cluster —
 * regardless of city / country boundary.
 *
 * rc40: the previous pixel-bucket grid (cellVB = 14/scale) had
 * two failure modes that produced visible overlap:
 *   1. Two pins straddling a bucket boundary (e.g. cx=4 vs cx=5)
 *      were never merged even when only ~1 vb apart.
 *   2. Two pins in different cities that happened to project to
 *      nearby pixels (e.g. small islands, dense metros across
 *      city limits) were not merged because the strategy was
 *      keyed on city.  The new merge is geometric only: any two
 *      pins within `mergeRadius` vb units fold into one cluster
 *      whose label keeps the seed city if uniform, else lists
 *      "<city> + N more".
 *
 * mergeRadius matches the rendered diamond width at this zoom so
 * adjacent diamonds always touch but never overlap.
 */
function clusterByServer(
  resolved: ResolvedGroup[],
  ctx: ClusterContext,
): Cluster[] {
  // Diamond half-width is ~7 vb at native; band.pinScale at the
  // server band is 1.1, divided by camera scale.  We merge any
  // two pins whose centroids are within ~1.7× that radius so
  // diamonds never visually overlap.
  const band = resolveBand(ctx.scale);
  const halfDiamondVB = (7 * band.pinScale) / Math.max(ctx.scale, 0.5);
  const mergeRadius = halfDiamondVB * 2.0;
  const r2 = mergeRadius * mergeRadius;

  // Greedy merge: walk the resolved list, for each unconsumed pin
  // pull every other pin within `mergeRadius` into a new bucket
  // and mark them consumed.  O(n^2) on the worst case but n is
  // already capped to whatever fits the band (typical ~few hundred).
  const consumed = new Array<boolean>(resolved.length).fill(false);
  const buckets: ResolvedGroup[][] = [];
  for (let i = 0; i < resolved.length; i++) {
    if (consumed[i]) continue;
    const seed = resolved[i];
    const bucket: ResolvedGroup[] = [seed];
    consumed[i] = true;
    for (let j = i + 1; j < resolved.length; j++) {
      if (consumed[j]) continue;
      const o = resolved[j];
      const dx = o.vbX - seed.vbX;
      const dy = o.vbY - seed.vbY;
      if (dx * dx + dy * dy <= r2) {
        bucket.push(o);
        consumed[j] = true;
      }
    }
    buckets.push(bucket);
  }

  const out: Cluster[] = [];
  for (let bi = 0; bi < buckets.length; bi++) {
    const members = buckets[bi];
    const bbox = emptyBBox();
    let sumX = 0;
    let sumY = 0;
    for (const m of members) {
      expandBBox(bbox, m.vbX, m.vbY);
      sumX += m.vbX;
      sumY += m.vbY;
    }
    const vbX = sumX / members.length;
    const vbY = sumY / members.length;

    // Label: prefer city of the seed; if all members share a
    // city, just use that; if mixed, fall back to a "metro" label
    // so the user understands they got merged across boundaries.
    const seed = members[0];
    const cities = new Set<string>();
    for (const m of members) {
      const c = m.city || m.country || "";
      if (c) cities.add(c);
    }
    const uniformCity = cities.size === 1 ? Array.from(cities)[0] : null;
    const label =
      members.length === 1
        ? seed.city || seed.country || seed.group.primary.name || "station"
        : uniformCity
          ? `${uniformCity} \u00b7 ${members.length} groups`
          : `${members.length} nearby groups`;

    // Cluster id is keyed on the seed group so React can keep
    // state across small pan jitters.  Seed identity is what the
    // WorldMap tracks for popover survival anyway.
    out.push({
      id: `region:server:${seed.group.key}-${bi}`,
      vbX,
      vbY,
      bbox,
      shapePath: "",
      members,
      totalServers: totalServers(members),
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
