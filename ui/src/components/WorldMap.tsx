/**
 * WorldMap renders the world outline (flekschas/simple-world-map,
 * MIT, mirrored under ui/src/assets/world.svg) plus a graticule and
 * per-host pins. The map's native viewBox is
 * `30.767 241.591 784.077 458.627` and its projection is approximately
 * — but not exactly — equirectangular. We fit the projection
 * empirically against ~6 country centroids (see project()), which
 * lines up Brazil, Egypt, India, Iceland, Madagascar and South Africa
 * to within a few pixels of their actual mainland.
 *
 * Both the world image and the pin layer share that viewBox and use
 * `preserveAspectRatio="none"` so they stretch identically across the
 * container — ditto for the graticule. Stretching breaks geographic
 * accuracy slightly when the container aspect drifts from 1.71:1, but
 * keeps every pin glued to its country.
 *
 * Pins are *host* pins — multiple servers sharing the same resolved
 * IP (or the same lat/lon to ~0.5°) collapse into a single dot so a
 * datacenter exposing three protocols doesn't draw three overlapping
 * pins. Hovering a pin reveals a tooltip with the host, location and
 * member protocols; clicking it connects to the fastest member.
 */

import { useState } from "react";
import worldUrl from "../assets/world.svg";
import type { Server } from "../api/types";
import { cityToLatLon } from "./cityCoords";
import { groupServers, type ServerGroup } from "./serverGroup";
import { locText } from "./locText";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  /** Optional caption shown in the top-right corner (e.g. current bearing). */
  bearing?: string;
  /** Click handler invoked with the server id of a pin's primary
   *  member. Omit to render non-clickable pins (hover still works). */
  onPinClick?: (serverId: string) => void;
}

interface PinPos {
  x: number;
  y: number;
  group: ServerGroup;
  active: boolean;
  primaryMs?: number;
}

// world.svg's native viewBox. Both the world image and the pin layer
// use it so coordinates are directly comparable.
const MAP_VB = { x: 30.767, y: 241.591, w: 784.077, h: 458.627 } as const;

// Empirical fit of the simple-world-map projection: linear in lon/lat
// with constants regressed against the bbox centroids of 6 country
// paths in the source SVG (br, eg, in, is, mg, za). Residuals stay
// under ~10 px on a 784×459 canvas, well under one pin diameter.
const LON_OFFSET = 409.7;
const LON_SCALE = 2.414;
const LAT_OFFSET = 530.8;
const LAT_SCALE = 2.787;

function project(lat: number, lon: number): { x: number; y: number } {
  return {
    x: LON_OFFSET + LON_SCALE * lon,
    y: LAT_OFFSET - LAT_SCALE * lat,
  };
}

// "You" pin sits roughly where Earth's median land mass lives — lon=0,
// lat=20°N, the same bias the previous (500, 290) hardcode aimed at on
// the old 1000×500 grid. Stays inside the new viewBox.
const YOU = project(20, 0);

/**
 * Merge two groups whose pins land within ~0.5° of each other. This
 * is mostly cosmetic — when ip-api.com returns slightly different
 * lat/lon for two different IPs in the same datacenter we still want
 * one dot, not two stacked. Members of merged groups are concatenated
 * and the merged group inherits the better latency.
 */
function mergeNearbyPins(pins: PinPos[]): PinPos[] {
  if (pins.length < 2) return pins;
  const out: PinPos[] = [];
  for (const p of pins) {
    const near = out.find(
      (o) => Math.abs(o.x - p.x) < 5 && Math.abs(o.y - p.y) < 5,
    );
    if (!near) {
      out.push({ ...p, group: { ...p.group, members: [...p.group.members] } });
      continue;
    }
    near.group.members.push(...p.group.members);
    if (p.active) near.active = true;
    if (
      p.primaryMs !== undefined &&
      (near.primaryMs === undefined || p.primaryMs < near.primaryMs)
    ) {
      near.primaryMs = p.primaryMs;
      near.group.primary = p.group.primary;
    }
  }
  return out;
}

function pinForGroup(g: ServerGroup, activeServerId?: string): PinPos | null {
  // Try the primary member first, then any member with coordinates.
  for (const srv of [g.primary, ...g.members]) {
    let lat: number | undefined;
    let lon: number | undefined;
    if (
      typeof srv.lat === "number" &&
      typeof srv.lon === "number" &&
      (srv.lat !== 0 || srv.lon !== 0)
    ) {
      lat = srv.lat;
      lon = srv.lon;
    } else {
      const coords = cityToLatLon(srv.city, srv.country, srv.address);
      if (coords) {
        lat = coords.lat;
        lon = coords.lon;
      }
    }
    if (lat === undefined || lon === undefined) continue;
    const { x, y } = project(lat, lon);
    return {
      x,
      y,
      group: g,
      active: g.members.some((m) => m.id === activeServerId),
      primaryMs:
        g.bestMs !== null && g.bestMs > 0 ? g.bestMs : undefined,
    };
  }
  return null;
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
  onPinClick,
}: WorldMapProps): JSX.Element {
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);
  const groups = groupServers(servers);
  const raw: PinPos[] = [];
  for (const g of groups) {
    const p = pinForGroup(g, activeServerId);
    if (p) raw.push(p);
  }
  const pins = mergeNearbyPins(raw);
  const activePin = pins.find((p) => p.active);
  const hover = hoverIdx !== null ? pins[hoverIdx] : null;

  // Graticule lines in the same map coordinates: equator, tropics &
  // arctic/antarctic circles for horizontals; longitude steps every
  // 30° for verticals. We clip to the visible viewBox so high-latitude
  // verticals don't paint outside the world outline.
  const clipL = MAP_VB.x;
  const clipR = MAP_VB.x + MAP_VB.w;
  const clipT = MAP_VB.y;
  const clipB = MAP_VB.y + MAP_VB.h;
  const horizontals = [-66.5, -45, -23.5, 23.5, 45, 66.5]
    .map((lat) => project(lat, 0).y)
    .filter((y) => y > clipT && y < clipB);
  const equatorY = project(0, 0).y;
  const verticals = [-150, -120, -90, -60, -30, 30, 60, 90, 120, 150]
    .map((lon) => project(0, lon).x)
    .filter((x) => x > clipL && x < clipR);
  const meridianX = project(0, 0).x;

  return (
    <div className="worldmap">
      <svg
        className="worldmap-img"
        viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
        preserveAspectRatio="none"
        aria-hidden="true"
      >
        <image
          href={worldUrl}
          x={MAP_VB.x}
          y={MAP_VB.y}
          width={MAP_VB.w}
          height={MAP_VB.h}
          preserveAspectRatio="none"
        />
      </svg>
      <svg
        className="worldmap-grat"
        viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
        preserveAspectRatio="none"
      >
        <line className="eq" x1={clipL} y1={equatorY} x2={clipR} y2={equatorY} />
        <line className="eq" x1={meridianX} y1={clipT} x2={meridianX} y2={clipB} />
        {horizontals.map((y) => (
          <line key={`h${y.toFixed(1)}`} x1={clipL} y1={y} x2={clipR} y2={y} />
        ))}
        {verticals.map((x) => (
          <line key={`v${x.toFixed(1)}`} x1={x} y1={clipT} x2={x} y2={clipB} />
        ))}
      </svg>

      {pins.length > 0 ? (
        <svg
          className="worldmap-pins"
          viewBox={`${MAP_VB.x} ${MAP_VB.y} ${MAP_VB.w} ${MAP_VB.h}`}
          preserveAspectRatio="none"
        >
          {activePin ? (
            <path
              className="worldmap-arc"
              d={`M ${YOU.x} ${YOU.y} Q ${(YOU.x + activePin.x) / 2} ${
                Math.min(YOU.y, activePin.y) - 60
              } ${activePin.x} ${activePin.y}`}
            />
          ) : null}
          {pins.map((p, i) => {
            const r = p.active ? 6 : i === hoverIdx ? 7 : 5;
            const haloR = p.active ? 12 : i === hoverIdx ? 11 : 0;
            const cls = `worldmap-pin ${p.active ? "cur" : ""} ${
              i === hoverIdx ? "hov" : ""
            } ${onPinClick ? "clickable" : ""}`;
            return (
              <g key={p.group.key} className={cls} transform={`translate(${p.x},${p.y})`}>
                {haloR > 0 ? <circle r={haloR} className="halo" /> : null}
                <circle r={r} className="dot" />
                {/* Invisible hit target — bigger than the dot so the
                    pin is easy to hover and click. */}
                <circle
                  r={14}
                  fill="transparent"
                  style={onPinClick ? { cursor: "pointer" } : undefined}
                  onMouseEnter={() => setHoverIdx(i)}
                  onMouseLeave={() =>
                    setHoverIdx((h) => (h === i ? null : h))
                  }
                  onClick={() => {
                    if (onPinClick) onPinClick(p.group.primary.id);
                  }}
                />
              </g>
            );
          })}
          <g className="worldmap-pin you" transform={`translate(${YOU.x},${YOU.y})`}>
            <circle r={3.5} className="dot" />
            <circle r={7} className="halo" />
          </g>
        </svg>
      ) : null}

      {hover ? (
        <div
          className="worldmap-tooltip"
          style={{
            left: `${((hover.x - MAP_VB.x) / MAP_VB.w) * 100}%`,
            top: `${((hover.y - MAP_VB.y) / MAP_VB.h) * 100}%`,
          }}
        >
          <div className="tip-host mono">{hover.group.host}</div>
          {locText(hover.group.primary) ? (
            <div className="tip-loc">{locText(hover.group.primary)}</div>
          ) : null}
          <div className="tip-protos mono">
            {hover.group.members
              .map((m) => `${m.protocol}:${m.port}`)
              .join(" · ")}
          </div>
          {hover.primaryMs !== undefined ? (
            <div className="tip-ms mono">best {hover.primaryMs}ms</div>
          ) : null}
          {onPinClick ? (
            <div className="tip-cta mono">click to connect</div>
          ) : null}
        </div>
      ) : null}

      {bearing ? <div className="worldmap-bearing">{bearing}</div> : null}
    </div>
  );
}
