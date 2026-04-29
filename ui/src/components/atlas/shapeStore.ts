/**
 * shapeStore — atlas country / continent geometry, cached.
 *
 * Loads the bundled `countries-110m.json` (a minified Natural Earth
 * 110m admin-0 dataset, ~150 KB raw / ~42 KB gzipped) once on first
 * access, projects every coordinate through `projectVB(lat,lon)` —
 * the same equirectangular projection the rest of the world map
 * uses — and emits SVG path strings ready to drop into the
 * worldmap-shapes layer.
 *
 * Continents are loaded from a separate `continents-110m.json`
 * dataset that ships pre-merged: `ui/scripts/build-continents.mjs`
 * runs `polygon-clipping` (mfogel) over the country features once
 * at build time, grouping by NE's CONTINENT property and emitting
 * one MultiPolygon per continent (NA / SA / EU / AS / AF / OC / AN).
 * The runtime then projects those union polygons through `projectVB`
 * the same way as countries — so a continent silhouette is one
 * monolithic shape with no internal country borders bleeding
 * through, and pin / country / continent layers all co-register
 * by construction.
 *
 * No d3-geo dependency on purpose — the equirect projection is one
 * line of arithmetic and we save 30 KB of bundle. If we ever need
 * Robinson / Mercator we'll revisit.
 */

import { projectVB } from "../cluster/resolveGroups";
import countries110m from "../../data/countries-110m.json";
import continents110m from "../../data/continents-110m.json";

/** Two-letter continent code, matching `continent_map.json`. */
export type ContinentCode = "NA" | "SA" | "EU" | "AS" | "AF" | "OC" | "AN";

/** Natural Earth uses long names; we collapse them to ISO codes. */
const NE_TO_CONTINENT: Record<string, ContinentCode> = {
  "North America": "NA",
  "South America": "SA",
  "Europe": "EU",
  "Asia": "AS",
  "Africa": "AF",
  "Oceania": "OC",
  "Antarctica": "AN",
};

export interface CountryShape {
  /** Two-letter country code (ISO 3166-1 alpha-2). */
  iso: string;
  /** Display name from Natural Earth. */
  name: string;
  /** Mosaic continent code. */
  continent: ContinentCode | "";
  /** SVG path data, projected to viewBox space. */
  pathD: string;
  /** Bounding box in viewBox space. */
  bbox: { minX: number; minY: number; maxX: number; maxY: number };
  /** Centroid in viewBox space (bbox-centre, fast & deterministic;
   *  not the polygon-centroid — irrelevant for pin placement at
   *  this zoom level). */
  centroid: { x: number; y: number };
}

export interface ContinentShape {
  code: ContinentCode;
  name: string;
  members: CountryShape[];
  /** Real polygon-union (built once at build time, see
   *  `ui/scripts/build-continents.mjs`) projected into viewBox
   *  space — one monolithic SVG path with no internal country
   *  borders. */
  pathD: string;
  bbox: { minX: number; minY: number; maxX: number; maxY: number };
  centroid: { x: number; y: number };
}

/* ------------------------------------------------------------- */

interface RawFeature {
  p: { iso: string; name: string; continent: string; subregion: string };
  g:
    | { type: "Polygon"; coordinates: number[][][] }
    | { type: "MultiPolygon"; coordinates: number[][][][] };
}

interface RawDataset {
  type: "FeatureCollection";
  features: RawFeature[];
}

interface RawContinentFeature {
  p: { code: string; name: string };
  g:
    | { type: "Polygon"; coordinates: number[][][] }
    | { type: "MultiPolygon"; coordinates: number[][][][] };
}

interface RawContinentDataset {
  type: "FeatureCollection";
  features: RawContinentFeature[];
}

let cachedCountries: CountryShape[] | null = null;
let cachedContinents: ContinentShape[] | null = null;

/**
 * Split a polygon ring across the antimeridian (lon = ±180).
 *
 * Without splitting, a country whose polygon spans both sides of
 * the dateline (Russia / USA-Aleutians / Fiji / Antarctica) gets
 * rendered as a giant horizontal stripe across the whole map
 * because the polygon's edge connects the +179° and -179° points
 * with a straight line through the projection grid.
 *
 * The fix: walk the ring; whenever consecutive points have a
 * longitude jump > 180°, close the current sub-ring and start a
 * fresh one.  The two halves render as separate sub-polygons,
 * each within the viewBox.
 */
function splitAntimeridian(ring: number[][]): number[][][] {
  if (ring.length === 0) return [];
  const parts: number[][][] = [];
  let current: number[][] = [ring[0]];
  for (let i = 1; i < ring.length; i++) {
    const [lon, lat] = ring[i];
    const [pLon] = current[current.length - 1];
    if (Math.abs(lon - pLon) > 180) {
      if (current.length >= 2) parts.push(current);
      current = [];
    }
    current.push([lon, lat]);
  }
  if (current.length >= 2) parts.push(current);
  return parts;
}

function subringToPath(part: number[][]): string {
  let d = "";
  for (let i = 0; i < part.length; i++) {
    const [lon, lat] = part[i];
    const { x, y } = projectVB(lat, lon);
    d += i === 0 ? `M${x.toFixed(1)} ${y.toFixed(1)}` : `L${x.toFixed(1)} ${y.toFixed(1)}`;
  }
  return d + "Z";
}

function buildPathFromRing(ring: number[][]): string {
  const parts = splitAntimeridian(ring);
  return parts.map(subringToPath).join("");
}

function buildPathFromPolygon(polygon: number[][][]): string {
  // Outer ring + holes — we emit each ring as its own subpath; the
  // SVG nonzero/evenodd fill rule handles the rest.
  return polygon.map(buildPathFromRing).join("");
}

function buildPathFromMultiPolygon(multi: number[][][][]): string {
  return multi.map(buildPathFromPolygon).join("");
}

function bboxOfRing(
  ring: number[][],
  acc: { minX: number; minY: number; maxX: number; maxY: number },
): void {
  // Use only the antimeridian-split sub-rings so a wrap-around
  // ring doesn't yank the bbox across the entire map.
  const parts = splitAntimeridian(ring);
  let bestPart = parts[0];
  let bestSize = 0;
  // Pick the largest sub-ring's bbox as the country's bbox.
  for (const part of parts) {
    let mnx = Infinity;
    let mxx = -Infinity;
    let mny = Infinity;
    let mxy = -Infinity;
    for (const [lon, lat] of part) {
      const { x, y } = projectVB(lat, lon);
      if (x < mnx) mnx = x;
      if (x > mxx) mxx = x;
      if (y < mny) mny = y;
      if (y > mxy) mxy = y;
    }
    const size = (mxx - mnx) * (mxy - mny);
    if (size > bestSize) {
      bestSize = size;
      bestPart = part;
    }
  }
  if (!bestPart) return;
  for (const [lon, lat] of bestPart) {
    const { x, y } = projectVB(lat, lon);
    if (x < acc.minX) acc.minX = x;
    if (x > acc.maxX) acc.maxX = x;
    if (y < acc.minY) acc.minY = y;
    if (y > acc.maxY) acc.maxY = y;
  }
}

function bboxOf(feature: RawFeature): {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
} {
  const acc = {
    minX: Infinity,
    minY: Infinity,
    maxX: -Infinity,
    maxY: -Infinity,
  };
  if (feature.g.type === "Polygon") {
    for (const ring of feature.g.coordinates) bboxOfRing(ring, acc);
  } else {
    for (const poly of feature.g.coordinates)
      for (const ring of poly) bboxOfRing(ring, acc);
  }
  return acc;
}

function buildCountries(): CountryShape[] {
  const data = countries110m as unknown as RawDataset;
  const out: CountryShape[] = [];
  for (const f of data.features) {
    if (!f.p.iso) continue;
    const pathD =
      f.g.type === "Polygon"
        ? buildPathFromPolygon(f.g.coordinates)
        : buildPathFromMultiPolygon(f.g.coordinates);
    if (!pathD) continue;
    const bbox = bboxOf(f);
    out.push({
      iso: f.p.iso.toUpperCase(),
      name: f.p.name,
      continent: NE_TO_CONTINENT[f.p.continent] || "",
      pathD,
      bbox,
      centroid: {
        x: (bbox.minX + bbox.maxX) / 2,
        y: (bbox.minY + bbox.maxY) / 2,
      },
    });
  }
  return out;
}

const CONTINENT_LABELS: Record<ContinentCode, string> = {
  NA: "North America",
  SA: "South America",
  EU: "Europe",
  AS: "Asia",
  AF: "Africa",
  OC: "Oceania",
  AN: "Antarctica",
};

function buildContinents(
  countries: CountryShape[],
  raw: RawContinentDataset,
): ContinentShape[] {
  const byCode = new Map<ContinentCode, CountryShape[]>();
  for (const c of countries) {
    if (c.continent === "") continue;
    const arr = byCode.get(c.continent);
    if (arr) arr.push(c);
    else byCode.set(c.continent, [c]);
  }
  const out: ContinentShape[] = [];
  for (const f of raw.features) {
    const code = (f.p.code || "").toUpperCase() as ContinentCode;
    if (!CONTINENT_LABELS[code]) continue;
    const pathD =
      f.g.type === "Polygon"
        ? buildPathFromPolygon(f.g.coordinates)
        : buildPathFromMultiPolygon(f.g.coordinates);
    if (!pathD) continue;
    const bbox = bboxOf(f as unknown as RawFeature);
    out.push({
      code,
      name: CONTINENT_LABELS[code],
      members: byCode.get(code) ?? [],
      pathD,
      bbox,
      centroid: {
        x: (bbox.minX + bbox.maxX) / 2,
        y: (bbox.minY + bbox.maxY) / 2,
      },
    });
  }
  return out;
}

export function getCountryShapes(): CountryShape[] {
  if (!cachedCountries) cachedCountries = buildCountries();
  return cachedCountries;
}

export function getContinentShapes(): ContinentShape[] {
  if (!cachedContinents) {
    cachedContinents = buildContinents(
      getCountryShapes(),
      continents110m as unknown as RawContinentDataset,
    );
  }
  return cachedContinents;
}

/** Lookup helpers. */
export function getCountryByIso(iso: string): CountryShape | undefined {
  const code = iso.toUpperCase();
  return getCountryShapes().find((c) => c.iso === code);
}

export function getContinentByCode(
  code: ContinentCode,
): ContinentShape | undefined {
  return getContinentShapes().find((c) => c.code === code);
}
