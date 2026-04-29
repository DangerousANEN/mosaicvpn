/**
 * Sparkline — minimal SVG line chart for per-server latency history.
 * Renders the most recent N probe samples as a thin polyline plus a
 * dot on the last sample. Failed probes are stored as NaN by
 * recordLatency() and drawn as gaps so the user can see "this
 * server flapped" at a glance.
 */

interface SparklineProps {
  data: number[];
  width?: number;
  height?: number;
  /** Optional fixed maximum used to align scales across rows (e.g.
   *  the median across the table). Defaults to series max. */
  maxOverride?: number;
  /** Highlight the last sample as the active probe. */
  emphasizeLast?: boolean;
}

export function Sparkline({
  data,
  width = 64,
  height = 18,
  maxOverride,
  emphasizeLast = true,
}: SparklineProps): JSX.Element | null {
  if (data.length < 2) return null;
  const finite = data.filter((v) => Number.isFinite(v));
  if (finite.length === 0) return null;
  const max = maxOverride && maxOverride > 0 ? maxOverride : Math.max(...finite);
  const min = Math.min(...finite);
  const range = Math.max(1, max - min);

  // Build segments separated by NaN gaps — react/svg renders one
  // <polyline> per contiguous run of finite values.
  const segments: { x: number; y: number }[][] = [];
  let cur: { x: number; y: number }[] = [];
  for (let i = 0; i < data.length; i++) {
    const v = data[i];
    if (!Number.isFinite(v)) {
      if (cur.length > 1) segments.push(cur);
      cur = [];
      continue;
    }
    const x = (i / Math.max(1, data.length - 1)) * (width - 4) + 2;
    const y = height - 2 - ((v - min) / range) * (height - 6);
    cur.push({ x, y });
  }
  if (cur.length > 1) segments.push(cur);
  if (segments.length === 0) return null;

  const last = cur.length > 0 ? cur[cur.length - 1] : null;

  return (
    <svg
      className="sparkline"
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      aria-hidden="true"
    >
      {segments.map((seg, i) => (
        <polyline
          key={i}
          points={seg.map((p) => `${p.x.toFixed(1)},${p.y.toFixed(1)}`).join(" ")}
          fill="none"
          stroke="currentColor"
          strokeWidth={1}
          strokeLinejoin="round"
          strokeLinecap="round"
        />
      ))}
      {emphasizeLast &&
      last &&
      Number.isFinite(last.x) &&
      Number.isFinite(last.y) ? (
        <circle cx={last.x} cy={last.y} r={1.6} fill="currentColor" />
      ) : null}
    </svg>
  );
}
