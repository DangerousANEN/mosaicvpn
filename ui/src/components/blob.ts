/**
 * blob — turn a cloud of viewBox-space points into a smooth SVG path
 * string.  Implementation:
 *
 *   1. Convex hull via a Graham scan (monotone variant).
 *   2. Expand the hull outward from its centroid by an `offset` in
 *      the same viewBox units so pins sit comfortably inside.
 *   3. Interpolate a closed Catmull-Rom spline through the expanded
 *      hull vertices so the boundary reads as an organic curve, not
 *      a polygon.
 *   4. Emit a cubic-bezier SVG `d` attribute.
 *
 * For very small groups we degrade gracefully:
 *   - 0 points → empty path "".
 *   - 1 point  → a circle of radius `minRadius` around the point.
 *   - 2 points → an ellipse-ish oval whose long axis connects them.
 */

export interface BlobPoint {
  vbX: number;
  vbY: number;
}

function cross(o: number[], a: number[], b: number[]): number {
  return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

function convexHull(pts: number[][]): number[][] {
  const sorted = pts
    .slice()
    .sort((a, b) => (a[0] === b[0] ? a[1] - b[1] : a[0] - b[0]));
  const n = sorted.length;
  if (n < 3) return sorted;
  const lower: number[][] = [];
  for (const p of sorted) {
    while (
      lower.length >= 2 &&
      cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0
    ) {
      lower.pop();
    }
    lower.push(p);
  }
  const upper: number[][] = [];
  for (let i = n - 1; i >= 0; i--) {
    const p = sorted[i];
    while (
      upper.length >= 2 &&
      cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0
    ) {
      upper.pop();
    }
    upper.push(p);
  }
  lower.pop();
  upper.pop();
  return lower.concat(upper);
}

function expandHull(hull: number[][], offset: number): number[][] {
  if (hull.length === 0) return hull;
  let cx = 0;
  let cy = 0;
  for (const [x, y] of hull) {
    cx += x;
    cy += y;
  }
  cx /= hull.length;
  cy /= hull.length;
  return hull.map(([x, y]) => {
    const dx = x - cx;
    const dy = y - cy;
    const len = Math.hypot(dx, dy) || 1;
    return [x + (dx / len) * offset, y + (dy / len) * offset];
  });
}

/**
 * Catmull-Rom through the given (closed) polyline, emitting a cubic
 * bezier SVG path.  The tension `s` = 0.5 is the canonical centripetal
 * variant — gives nice round loops without the over-shoot a uniform
 * Catmull-Rom produces on clustered vertices.
 */
function catmullRomPath(pts: number[][]): string {
  const n = pts.length;
  if (n === 0) return "";
  if (n === 1) return "";
  const s = 0.5;
  let d = `M ${pts[0][0].toFixed(2)} ${pts[0][1].toFixed(2)}`;
  for (let i = 0; i < n; i++) {
    const p0 = pts[(i - 1 + n) % n];
    const p1 = pts[i % n];
    const p2 = pts[(i + 1) % n];
    const p3 = pts[(i + 2) % n];
    const c1x = p1[0] + (p2[0] - p0[0]) * s * 0.333;
    const c1y = p1[1] + (p2[1] - p0[1]) * s * 0.333;
    const c2x = p2[0] - (p3[0] - p1[0]) * s * 0.333;
    const c2y = p2[1] - (p3[1] - p1[1]) * s * 0.333;
    d += ` C ${c1x.toFixed(2)} ${c1y.toFixed(2)} ${c2x.toFixed(2)} ${c2y.toFixed(2)} ${p2[0].toFixed(2)} ${p2[1].toFixed(2)}`;
  }
  d += " Z";
  return d;
}

/**
 * Given a set of pin positions, return the SVG path describing their
 * smoothed bounding blob.  `offset` controls how much padding the
 * blob has around the outermost pins (in viewBox units).  `minRadius`
 * is used as a fallback circle radius when there's only one point.
 */
export function blobPath(
  points: BlobPoint[],
  offset: number,
  minRadius: number = 4,
): string {
  if (points.length === 0) return "";
  const raw = points.map((p) => [p.vbX, p.vbY]);
  if (raw.length === 1) {
    const [x, y] = raw[0];
    const r = Math.max(minRadius, offset);
    // Two-arc circle path (SVG has no native circle inside <path>).
    return `M ${x - r} ${y} a ${r} ${r} 0 1 0 ${r * 2} 0 a ${r} ${r} 0 1 0 ${-r * 2} 0 Z`;
  }
  if (raw.length === 2) {
    // Padded oval: take the line segment, expand perpendicular by
    // offset, emit a 4-point rounded rectangle around it.
    const [a, b] = raw;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = Math.hypot(dx, dy) || 1;
    const nx = -dy / len;
    const ny = dx / len;
    const pad = Math.max(minRadius, offset);
    const ring = [
      [a[0] + nx * pad - (dx / len) * pad, a[1] + ny * pad - (dy / len) * pad],
      [a[0] - nx * pad - (dx / len) * pad, a[1] - ny * pad - (dy / len) * pad],
      [b[0] - nx * pad + (dx / len) * pad, b[1] - ny * pad + (dy / len) * pad],
      [b[0] + nx * pad + (dx / len) * pad, b[1] + ny * pad + (dy / len) * pad],
    ];
    return catmullRomPath(ring);
  }
  const hull = convexHull(raw);
  if (hull.length < 3) return "";
  const expanded = expandHull(hull, offset);
  return catmullRomPath(expanded);
}
