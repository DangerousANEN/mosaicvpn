/**
 * zoomBands — discrete zoom-level table for the hex strategy.
 *
 * Each band picks a hex edge length `hexR` (in viewBox units).  The
 * world.svg viewBox is ~784 wide × ~459 tall, so:
 *
 *   continent  R=46   →  ~10 hexes across the equator
 *   country    R=20   →  ~22 hexes
 *   region     R=10   →  ~45 hexes
 *   city       R=5    →  ~90 hexes
 *   server     R=2.5  →  ~180 hexes
 *
 * The band is a *pure* function of the current scale: the renderer
 * is allowed to flip back and forth between bands as the user zooms,
 * but within a band the cluster IDs are stable.
 *
 * SOLID-wise: the table lives behind a function, so swapping in a
 * different strategy (Voronoi, QuadTree, supercluster) only needs
 * its own band table — no other code changes.
 */

export type BandKind = "continent" | "country" | "region" | "city" | "server";

export interface ZoomBand {
  /** Stable identifier — part of every cluster ID so React keys
   *  flip cleanly on band change. */
  id: string;
  kind: BandKind;
  /** Lower bound (inclusive). */
  minScale: number;
  /** Upper bound (exclusive). */
  maxScale: number;
  /** Hex edge length in viewBox units. */
  hexR: number;
  /** Diamond pin scale at this band — small at low zoom so
   *  continent overview reads as silhouettes; bigger at high zoom
   *  so the user can hit the click target.  Combined with the
   *  counter-scale 1/scale in the renderer. */
  pinScale: number;
  /** Atlas-style plate label shown in the HUD. */
  plateLabel: string;
}

const BANDS: ZoomBand[] = [
  {
    id: "b0",
    kind: "continent",
    minScale: 0,
    maxScale: 1.4,
    hexR: 46,
    pinScale: 0.7,
    plateLabel: "Plate I · Continental view",
  },
  {
    id: "b1",
    kind: "country",
    minScale: 1.4,
    maxScale: 2.6,
    hexR: 22,
    pinScale: 0.85,
    plateLabel: "Plate II · Countries in detail",
  },
  {
    id: "b2",
    kind: "region",
    minScale: 2.6,
    maxScale: 4.5,
    hexR: 11,
    pinScale: 0.95,
    plateLabel: "Plate III · Regional survey",
  },
  {
    id: "b3",
    kind: "city",
    minScale: 4.5,
    maxScale: 7.5,
    hexR: 5.5,
    pinScale: 1.0,
    plateLabel: "Plate IV · Cities and metros",
  },
  {
    id: "b4",
    kind: "server",
    minScale: 7.5,
    maxScale: Infinity,
    hexR: 2.6,
    pinScale: 1.05,
    plateLabel: "Plate V · Individual stations",
  },
];

export function resolveBand(scale: number): ZoomBand {
  for (const band of BANDS) {
    if (scale >= band.minScale && scale < band.maxScale) return band;
  }
  return BANDS[BANDS.length - 1];
}

/** All bands, in order — useful for legend rendering. */
export function allBands(): ReadonlyArray<ZoomBand> {
  return BANDS;
}
