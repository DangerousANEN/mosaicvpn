/**
 * zoomBands — discrete zoom-level table for the region strategy.
 *
 * The region strategy collapses servers into one of three semantic
 * scales:
 *
 *   continent  scale  < 1.8   →  one cluster per continent (NA/EU/AS/...)
 *   country    1.8 ≤ s < 5.5  →  one cluster per country (ISO-2)
 *   server     scale ≥ 5.5    →  one cluster per ServerGroup
 *
 * Bands are a pure function of the current TransformWrapper scale.
 * Cluster IDs change between bands by design — but the WorldMap
 * tracks open popovers by `seedServerId`, not by cluster ID, so
 * the popover follows the same group across the band transition.
 *
 * SOLID-wise: the table lives behind `resolveBand()`. Swapping in a
 * different strategy (hex, QuadTree, supercluster) only needs its
 * own band table — nothing else in the renderer cares about how
 * the bands are computed.
 */

export type BandKind = "continent" | "country" | "server";

export interface ZoomBand {
  /** Stable identifier — part of every cluster ID so React keys
   *  flip cleanly on band change. */
  id: string;
  kind: BandKind;
  /** Lower bound (inclusive). */
  minScale: number;
  /** Upper bound (exclusive). */
  maxScale: number;
  /** Diamond pin scale at this band — combined with the
   *  counter-scale 1/scale in the renderer. */
  pinScale: number;
  /** Atlas-style plate label shown in the HUD. */
  plateLabel: string;
}

const BANDS: ZoomBand[] = [
  {
    id: "continent",
    kind: "continent",
    minScale: 0,
    maxScale: 1.8,
    pinScale: 0.85,
    plateLabel: "Plate I · Continental view",
  },
  {
    id: "country",
    kind: "country",
    minScale: 1.8,
    maxScale: 5.5,
    pinScale: 1.0,
    plateLabel: "Plate II · Countries and unions",
  },
  {
    id: "server",
    kind: "server",
    minScale: 5.5,
    maxScale: Infinity,
    pinScale: 1.1,
    plateLabel: "Plate III · Individual stations",
  },
];

export function resolveBand(scale: number): ZoomBand {
  for (const band of BANDS) {
    if (scale >= band.minScale && scale < band.maxScale) return band;
  }
  return BANDS[BANDS.length - 1];
}

export function allBands(): ReadonlyArray<ZoomBand> {
  return BANDS;
}
