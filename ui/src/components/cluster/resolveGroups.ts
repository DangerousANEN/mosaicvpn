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

// Mirror of WorldMap.MAP_VB and projectVB from levelCluster.ts —
// the LON/LAT scale + offset that align world.svg's native viewBox
// to the (0..1000, 0..500) projection grid.
const LON_OFFSET = 409.7;
const LON_SCALE = 2.414;
const LAT_OFFSET = 530.8;
const LAT_SCALE = 2.787;

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
