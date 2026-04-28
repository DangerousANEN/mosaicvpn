/**
 * WorldMap renders the equirectangular world outline (CC BY-SA
 * simple-world-map, mirrored under docs/mockups/world.svg) plus a
 * graticule and per-server pins. Pins are positioned in pixel space on
 * a 1000×500 viewBox so they line up with the world.svg and graticule
 * regardless of the rendered size.
 */

import worldUrl from "../assets/world.svg";
import type { Server } from "../api/types";
import { cityToLatLon } from "./cityCoords";

interface WorldMapProps {
  servers: Server[];
  activeServerId?: string;
  /** Optional caption shown in the top-right corner (e.g. current bearing). */
  bearing?: string;
}

interface PinPos {
  x: number;
  y: number;
  label: string;
  active: boolean;
  ms?: number;
}

// Equirectangular projection: lon -180..180 → x 0..1000, lat 90..-90 → y 0..500.
function project(lat: number, lon: number): { x: number; y: number } {
  const x = ((lon + 180) / 360) * 1000;
  const y = ((90 - lat) / 180) * 500;
  return { x, y };
}

function dedupePins(pins: PinPos[]): PinPos[] {
  // Two servers in the same city overlap; nudge subsequent pins by a
  // few px so labels don't fully occlude one another.
  const out: PinPos[] = [];
  const seen = new Map<string, number>();
  for (const p of pins) {
    const key = `${p.x.toFixed(0)},${p.y.toFixed(0)}`;
    const n = seen.get(key) ?? 0;
    seen.set(key, n + 1);
    out.push({
      ...p,
      x: p.x + n * 6,
      y: p.y + n * 4,
    });
  }
  return out;
}

export function WorldMap({
  servers,
  activeServerId,
  bearing,
}: WorldMapProps): JSX.Element {
  const pins: PinPos[] = [];
  for (const srv of servers) {
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
    pins.push({
      x,
      y,
      label: srv.city || srv.name,
      active: srv.id === activeServerId,
      ms: srv.last_test_ms && srv.last_test_ms > 0 ? srv.last_test_ms : undefined,
    });
  }
  const placed = dedupePins(pins);
  const activePin = placed.find((p) => p.active);

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

      {placed.length > 0 ? (
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
          {placed.map((p, i) => (
            <g
              key={i}
              className={`worldmap-pin ${p.active ? "cur" : ""}`}
              transform={`translate(${p.x},${p.y})`}
            >
              <circle r={p.active ? 4.5 : 3} className="dot" />
              {p.active ? <circle r={9} className="halo" /> : null}
            </g>
          ))}
          <g className="worldmap-pin you" transform={`translate(500,290)`}>
            <circle r={3.5} className="dot" />
            <circle r={7} className="halo" />
          </g>
        </svg>
      ) : null}

      {bearing ? <div className="worldmap-bearing">{bearing}</div> : null}
    </div>
  );
}
