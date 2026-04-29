/**
 * HexClusterStrategy — pointy-top hex-bin clustering in viewBox
 * space.  Each server group is bucketed into a hexagonal cell by
 * its projected position.  Cells never overlap by construction, so
 * the renderer doesn't need a pixel-merge pass and clusters never
 * "naezzhayut" on each other.
 *
 * Multi-resolution is handled by ZoomBands (see ./zoomBands.ts):
 * the strategy picks a hex edge length R based on the current
 * scale.  Within a band the cell ID is fully deterministic from
 * (q, r, bandIndex) so popover state survives re-renders, filter
 * changes, and live updates.
 *
 * Atlas note: pointy-top hexes read as topographic cells on a
 * cream-paper map and tile cleanly with the equirectangular
 * graticule.  Polygon path emitted by `cellPolygon` traces the six
 * vertices in user-space units; the renderer applies stroke as a
 * non-scaling-stroke so line weight stays constant under zoom.
 */

import type {
  Cluster,
  ClusterContext,
  IClusterStrategy,
  ResolvedGroup,
} from "./types";
import { emptyBBox, expandBBox } from "./types";
import { resolveBand, type ZoomBand } from "./zoomBands";

const SQRT3 = Math.sqrt(3);

interface AxialCell {
  q: number;
  r: number;
}

/** Convert viewBox (x, y) to axial hex coords for a pointy-top hex
 *  of edge length R.  Inverts the formula in `axialToVb`. */
function vbToAxial(x: number, y: number, R: number): { q: number; r: number } {
  const q = (SQRT3 / 3 * x - 1 / 3 * y) / R;
  const r = (2 / 3 * y) / R;
  return roundAxial(q, r);
}

/** Round fractional axial coords to the nearest hex via cube
 *  coordinates.  Standard hex-grid algorithm. */
function roundAxial(q: number, r: number): AxialCell {
  let x = q;
  let z = r;
  let y = -x - z;
  let rx = Math.round(x);
  let ry = Math.round(y);
  let rz = Math.round(z);
  const dx = Math.abs(rx - x);
  const dy = Math.abs(ry - y);
  const dz = Math.abs(rz - z);
  if (dx > dy && dx > dz) rx = -ry - rz;
  else if (dy > dz) ry = -rx - rz;
  else rz = -rx - ry;
  void ry;
  return { q: rx, r: rz };
}

/** Hex centre (in viewBox coords) for the given axial cell. */
function axialToVb(
  q: number,
  r: number,
  R: number,
): { x: number; y: number } {
  const x = R * (SQRT3 * q + (SQRT3 / 2) * r);
  const y = R * (3 / 2) * r;
  return { x, y };
}

/** Six-vertex polygon path string for a pointy-top hex centred on
 *  (cx, cy) with edge length R.  Closed with Z so SVG can fill. */
function cellPolygon(cx: number, cy: number, R: number): string {
  let d = "";
  for (let i = 0; i < 6; i++) {
    const a = (Math.PI / 180) * (60 * i - 30);
    const x = cx + R * Math.cos(a);
    const y = cy + R * Math.sin(a);
    d += i === 0 ? `M ${x.toFixed(2)} ${y.toFixed(2)}` : ` L ${x.toFixed(2)} ${y.toFixed(2)}`;
  }
  return d + " Z";
}

/** Bucket label — best-effort country / city / continent based on
 *  cell members so the popover head reads as English instead of
 *  raw axial coords. */
function labelForCell(members: ResolvedGroup[], band: ZoomBand): string {
  const continents = new Set<string>();
  const countries = new Set<string>();
  const cities = new Set<string>();
  for (const m of members) {
    if (m.continent) continents.add(m.continent);
    if (m.country) countries.add(m.country);
    if (m.city) cities.add(m.city);
  }
  if (band.kind === "continent" && continents.size === 1) {
    return continentName([...continents][0]);
  }
  if (band.kind === "country" || band.kind === "continent") {
    if (countries.size === 1) return [...countries][0];
    if (countries.size > 1)
      return `${[...countries].slice(0, 2).join("/")}${
        countries.size > 2 ? ` +${countries.size - 2}` : ""
      }`;
  }
  if (cities.size === 1) {
    const city = [...cities][0];
    if (countries.size === 1) return `${city}, ${[...countries][0]}`;
    return city;
  }
  if (cities.size > 1) {
    const list = [...cities].slice(0, 2).join(" / ");
    return cities.size > 2 ? `${list} +${cities.size - 2}` : list;
  }
  if (countries.size === 1) return [...countries][0];
  return members[0]?.group.host ?? "—";
}

const CONTINENT_NAMES: Record<string, string> = {
  NA: "North America",
  SA: "South America",
  EU: "Europe",
  AS: "Asia",
  AF: "Africa",
  OC: "Oceania",
  AN: "Antarctica",
};

function continentName(code: string): string {
  return CONTINENT_NAMES[code] ?? code;
}

export class HexClusterStrategy implements IClusterStrategy {
  readonly name = "hex";

  cluster(resolved: ResolvedGroup[], ctx: ClusterContext): Cluster[] {
    if (resolved.length === 0) return [];
    const band = resolveBand(ctx.scale);
    const R = band.hexR;
    // bucket members by axial cell key
    const buckets = new Map<string, ResolvedGroup[]>();
    for (const rg of resolved) {
      const cell = vbToAxial(rg.vbX, rg.vbY, R);
      const key = `${cell.q},${cell.r}`;
      const arr = buckets.get(key);
      if (arr) arr.push(rg);
      else buckets.set(key, [rg]);
    }

    const out: Cluster[] = [];
    for (const [cellKey, members] of buckets) {
      const [q, r] = cellKey.split(",").map(Number);
      const { x: cx, y: cy } = axialToVb(q, r, R);
      const bbox = emptyBBox();
      let bestMs: number | null = null;
      let totalServers = 0;
      let active = false;
      for (const m of members) {
        expandBBox(bbox, m.vbX, m.vbY);
        totalServers += m.group.members.length;
        if (
          m.group.bestMs !== null &&
          (bestMs === null || m.group.bestMs < bestMs)
        ) {
          bestMs = m.group.bestMs;
        }
        if (ctx.activeKey !== null && m.group.key === ctx.activeKey) {
          active = true;
        }
      }
      out.push({
        // Stable across re-renders (filter / live update do not
        // change band id or hex coords for a server at the same
        // lat/lon).  Renderer uses this as the React key AND the
        // hover/open registry key.
        id: `hex:${band.id}:${cellKey}`,
        vbX: cx,
        vbY: cy,
        bbox,
        shapePath: cellPolygon(cx, cy, R),
        members,
        totalServers,
        bestMs,
        active,
        label: labelForCell(members, band),
        level: band.kind,
      });
    }
    // Paint north → south: northern hexes layer over southern ones
    // so the user-perceived stack matches how labels read.
    out.sort((a, b) => b.vbY - a.vbY);
    return out;
  }

  bandLabel(ctx: ClusterContext): string {
    const band = resolveBand(ctx.scale);
    return `${band.kind} · ${ctx.scale.toFixed(1)}×`;
  }
}

/** Public utility: hex bbox for a given cell, used by the
 *  WorldMap to drill-zoom to the just-clicked cell.  We use the
 *  cell's geometric bbox (the inscribed bbox of the hex) rather
 *  than its members' bbox so empty-but-clicked cells still zoom
 *  reasonably.  R is the strategy's edge length at the current
 *  band; the renderer computes it from `resolveBand(scale)`. */
export function hexCellBBox(cluster: Cluster, R: number): {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
} {
  return {
    minX: cluster.vbX - SQRT3 * R,
    maxX: cluster.vbX + SQRT3 * R,
    minY: cluster.vbY - R,
    maxY: cluster.vbY + R,
  };
}
