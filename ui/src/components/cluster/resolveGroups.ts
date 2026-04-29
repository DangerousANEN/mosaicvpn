/**
 * resolveGroups — turn raw Server records into ResolvedGroup with
 * geo-projected positions, ready for any IClusterStrategy.
 *
 * Same logic as the rc35 levelCluster.resolveGroups but lives in
 * the new cluster/ namespace so strategies don't reach across
 * modules.  Groups with no resolvable lat/lon are dropped — we
 * never paint a pin at (0,0).
 */

import type { Server } from "../../api/types";
import { groupServers } from "../serverGroup";
import { cityToLatLon } from "../cityCoords";
import continentMap from "../../data/continent_map.json";
import type { ResolvedGroup } from "./types";

// Equirectangular projection calibrated to world.svg's viewBox
// (30.767, 241.591, 784.077, 458.627).  rc38: switched from the
// rc35-rc37 hand-tuned constants (which had lon=180 land 30 px
// past the right viewBox edge and lon=-180 land 55 px past the
// left edge) to a clean -180..180 / -90..90 mapping.  This makes
// GeoJSON country shapes co-register with pin positions; pin
// placement against the (now-removed) raster world.svg shifts
// slightly but the new GeoJSON country borders take over the
// role of the base map, so the world.svg mismatch is moot.
const VB_X = 30.767;
const VB_Y = 241.591;
const VB_W = 784.077;
const VB_H = 458.627;
const LON_OFFSET = VB_X + VB_W / 2; // x at lon=0
const LON_SCALE = VB_W / 360;
const LAT_OFFSET = VB_Y + VB_H / 2; // y at lat=0
const LAT_SCALE = VB_H / 180;

export function projectVB(lat: number, lon: number): { x: number; y: number } {
  return { x: LON_OFFSET + LON_SCALE * lon, y: LAT_OFFSET - LAT_SCALE * lat };
}

const CONTINENT_TO_COUNTRIES = continentMap as unknown as {
  countryToContinent: Record<string, string>;
  continentBBox: Record<string, [number, number, number, number]>;
};

export interface ResolveResult {
  resolved: ResolvedGroup[];
  /** Stable group key of the active server, or null. */
  activeKey: string | null;
}

export function resolveGroups(
  servers: Server[],
  activeServerId?: string,
): ResolveResult {
  const groups = groupServers(servers);
  const out: ResolvedGroup[] = [];
  let activeKey: string | null = null;
  for (const g of groups) {
    let lat: number | undefined;
    let lon: number | undefined;
    for (const srv of [g.primary, ...g.members]) {
      if (
        typeof srv.lat === "number" &&
        typeof srv.lon === "number" &&
        (srv.lat !== 0 || srv.lon !== 0)
      ) {
        lat = srv.lat;
        lon = srv.lon;
        break;
      }
      const c = cityToLatLon(srv.city, srv.country, srv.address);
      if (c) {
        lat = c.lat;
        lon = c.lon;
        break;
      }
    }
    if (lat === undefined || lon === undefined) continue;
    const country = (g.primary.country || "").toUpperCase();
    const city = (g.primary.city || "").trim();
    const continent =
      CONTINENT_TO_COUNTRIES.countryToContinent[country] || "";
    const { x, y } = projectVB(lat, lon);
    out.push({ group: g, vbX: x, vbY: y, country, city, continent });
    if (
      activeServerId !== undefined &&
      g.members.some((m) => m.id === activeServerId)
    ) {
      activeKey = g.key;
    }
  }
  return { resolved: out, activeKey };
}
