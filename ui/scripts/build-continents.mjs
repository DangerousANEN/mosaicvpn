#!/usr/bin/env node
/**
 * build-continents — derive continents-110m.json from countries-110m.json.
 *
 * Reads the bundled Natural Earth 110m country dataset, groups
 * features by their `continent` property, and runs a real polygon
 * union (mfogel/polygon-clipping) per group.  Writes a tiny GeoJSON
 * FeatureCollection where each feature is one continent polygon
 * (or MultiPolygon for archipelagos).  Committed to the repo and
 * loaded by `shapeStore.ts` at runtime — no client-side union, no
 * hairline country borders bleeding through the continent silhouette.
 *
 * Antimeridian:  countries that wrap (Russia / Fiji / USA-Aleutians)
 * keep their multi-polygon split as it appears in the source — the
 * runtime `splitAntimeridian` in shapeStore.ts handles per-ring wrap
 * before projection, so we don't need to do anything special here.
 *
 * Run from `ui/`:
 *
 *     node scripts/build-continents.mjs
 *
 * Output: ui/src/data/continents-110m.json (~30 KB raw / ~10 KB gzipped).
 */

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import polygonClipping from "polygon-clipping";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");
const SRC = join(ROOT, "src/data/countries-110m.json");
const OUT = join(ROOT, "src/data/continents-110m.json");

const NE_TO_CODE = {
  "North America": "NA",
  "South America": "SA",
  Europe: "EU",
  Asia: "AS",
  Africa: "AF",
  Oceania: "OC",
  Antarctica: "AN",
};

const raw = JSON.parse(readFileSync(SRC, "utf8"));

/** Normalise a Polygon / MultiPolygon to MultiPolygon coords for polygon-clipping. */
function toMulti(geom) {
  if (geom.type === "Polygon") return [geom.coordinates];
  if (geom.type === "MultiPolygon") return geom.coordinates;
  return [];
}

const buckets = new Map();
for (const f of raw.features) {
  const code = NE_TO_CODE[f.p.continent];
  if (!code) continue;
  const arr = buckets.get(code);
  const multi = toMulti(f.g);
  if (arr) arr.push(...multi);
  else buckets.set(code, [...multi]);
}

const round = (n) => Math.round(n * 1000) / 1000;
const roundRing = (ring) => ring.map(([x, y]) => [round(x), round(y)]);
const roundPoly = (poly) => poly.map(roundRing);

const features = [];
for (const [code, polys] of buckets) {
  // polygon-clipping expects an array of MultiPolygons.  Each input
  // MultiPolygon is itself an array of Polygons (each Polygon is
  // [outerRing, ...holes]).  We treat every country polygon as a
  // separate input MultiPolygon and union them all.
  const inputs = polys.map((p) => [p]);
  const union = polygonClipping.union(...inputs);
  // Round to 0.001° to keep the file small without introducing
  // visible gaps at our render scales.
  const coords = union.map(roundPoly);
  features.push({
    p: { code, name: code },
    g: { type: "MultiPolygon", coordinates: coords },
  });
}

const out = { type: "FeatureCollection", features };
const json = JSON.stringify(out);
writeFileSync(OUT, json);

const sizeKB = (json.length / 1024).toFixed(1);
console.log(
  `wrote ${OUT} — ${features.length} continents, ${sizeKB} KB`,
);
