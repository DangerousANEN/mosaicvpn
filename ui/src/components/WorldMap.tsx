/**
 * WorldMap renders the equirectangular world outline (CC BY-SA
 * simple-world-map, mirrored under docs/mockups/world.svg) plus a
 * graticule and per-host pins. Pins are positioned in pixel space on
 * a 1000×500 viewBox so they line up with the world.svg and graticule
 * regardless of the rendered size.
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

// Equirectangular projection: lon -180..180 → x 0..1000, lat 90..-90 → y 0..500.
function project(lat: number, lon: number): { x: number; y: number } {
  const x = ((lon + 180) / 360) * 1000;
  const y = ((90 - lat) / 180) * 500;
  return { x, y };
}

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

  return (
    <div className="worldmap">
      <img className="worldmap-img" src={worldUrl} alt="" aria-hidden="true" />
      <svg
        className="worldmap-grat"
        viewBox="0 0 1000 500"
        preserveAspectRatio="none"
      >
        <line className="eq" x1={0} y1={250} x2={1000} y2={250} />
        {[62, 125, 187, 312, 375, 437].map((y) => (
          <line key={`h${y}`} x1={0} y1={y} x2={1000} y2={y} />
        ))}
        {[125, 250, 375, 500, 625, 750, 875].map((x) => (
          <line key={`v${x}`} x1={x} y1={0} x2={x} y2={500} />
        ))}
      </svg>

      {pins.length > 0 ? (
        <svg
          className="worldmap-pins"
          viewBox="0 0 1000 500"
          preserveAspectRatio="none"
        >
          {activePin ? (
            <path
              className="worldmap-arc"
              d={`M 500 290 Q ${(500 + activePin.x) / 2} ${
                Math.min(290, activePin.y) - 60
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
          <g className="worldmap-pin you" transform={`translate(500,290)`}>
            <circle r={3.5} className="dot" />
            <circle r={7} className="halo" />
          </g>
        </svg>
      ) : null}

      {hover ? (
        <div
          className="worldmap-tooltip"
          style={{
            left: `${(hover.x / 1000) * 100}%`,
            top: `${(hover.y / 500) * 100}%`,
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
