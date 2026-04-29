/**
 * cluster/types — domain types for the map clustering pipeline.
 *
 * Kept dependency-free so the strategy implementations
 * (HexClusterStrategy, future Voronoi/QuadTree) can be unit tested
 * without React or SVG in scope.
 */

import type { Server } from "../../api/types";
import type { ServerGroup } from "../serverGroup";

/** A point in the world map's viewBox space (post-projection). */
export interface ViewPoint {
  vbX: number;
  vbY: number;
}

export interface BBox {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
}

/** Latency bucket used for colouring pins / hex fills. */
export type LatencyBucket = "fast" | "med" | "slow" | "fail" | "untested";

export function latencyBucket(ms: number | null | undefined): LatencyBucket {
  if (ms === undefined || ms === null) return "untested";
  if (ms < 0) return "fail";
  if (ms === 0) return "untested";
  if (ms < 80) return "fast";
  if (ms < 200) return "med";
  return "slow";
}

/** A server group with resolved geo, ready for clustering. */
export interface ResolvedGroup {
  group: ServerGroup;
  vbX: number;
  vbY: number;
  /** ISO-2 country code, uppercase, "" if unknown. */
  country: string;
  /** City name as reported by the daemon, "" if unknown. */
  city: string;
  /** Continent code (NA/SA/EU/AS/AF/OC/AN), "" if unknown. */
  continent: string;
}

/** A cluster produced by a IClusterStrategy.
 *
 *  `id` MUST be stable across re-renders for the same logical
 *  cluster — the WorldMap stores hover/open state by `id`, never by
 *  array index, so re-clustering (filter change, live update) does
 *  not flip the user's currently-open popover onto a different
 *  bucket. */
export interface Cluster {
  /** Stable across re-renders: deterministic from the strategy and
   *  its input bucket key. */
  id: string;
  /** Centroid in viewBox space — anchor for pins / labels. */
  vbX: number;
  vbY: number;
  /** Axis-aligned bbox of all members in viewBox space. */
  bbox: BBox;
  /** Polygon path for the cluster shape (hex / blob / cell), in the
   *  same viewBox space.  Empty string if there is no shape (e.g. a
   *  bare diamond pin). */
  shapePath: string;
  /** Members in this cluster. */
  members: ResolvedGroup[];
  /** Sum across all member groups (one ServerGroup may aggregate
   *  several Server entries). */
  totalServers: number;
  /** Lowest positive latency across members, or null. */
  bestMs: number | null;
  /** True when the active server is inside this cluster. */
  active: boolean;
  /** Human-readable label for tooltips / popover heads. */
  label: string;
  /** Optional level tag for renderer styling ("continent" / "city"
   *  / "server" / strategy-specific). */
  level: string;
}

export interface ClusterContext {
  /** Current TransformWrapper scale (1.0 = fit, 12 = max zoom). */
  scale: number;
  /** Stage size in CSS pixels. */
  stageW: number;
  stageH: number;
  /** Stable key of the active server-group, or null. */
  activeKey: string | null;
}

/** Strategy that turns a flat list of resolved groups into clusters
 *  for the current view state.  Implementations MUST be pure
 *  functions of (resolved, ctx) — no internal state, no side
 *  effects — so the WorldMap can call them on every render
 *  without surprises. */
export interface IClusterStrategy {
  /** Strategy identifier — surfaced in the HUD legend. */
  readonly name: string;
  cluster(resolved: ResolvedGroup[], ctx: ClusterContext): Cluster[];
  /** Human-friendly band label for the current scale, used in the
   *  Plate readout in the HUD ("continent · 1.0×" / "city · 4.2×"). */
  bandLabel(ctx: ClusterContext): string;
}

/** Helper used by both the resolver and any pixel-distance strategy. */
export function emptyBBox(): BBox {
  return { minX: Infinity, maxX: -Infinity, minY: Infinity, maxY: -Infinity };
}

export function expandBBox(bbox: BBox, x: number, y: number): void {
  if (x < bbox.minX) bbox.minX = x;
  if (x > bbox.maxX) bbox.maxX = x;
  if (y < bbox.minY) bbox.minY = y;
  if (y > bbox.maxY) bbox.maxY = y;
}

/** Convenience re-export so renderers don't need to import api types. */
export type { Server, ServerGroup };
