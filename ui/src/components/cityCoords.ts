/**
 * cityToLatLon resolves a (city, country) pair to approximate
 * lat/lon. We keep a small lookup of major cities — enough for typical
 * VPN station names. If the city is unknown we fall back to country
 * centroids, then to null. The renderer treats null as "skip pin".
 *
 * This is intentionally rough; it's a visual indicator on a small map,
 * not a routing decision.
 */

interface LatLon {
  lat: number;
  lon: number;
}

const CITY_TABLE: Record<string, LatLon> = {
  // Russia / CIS
  moscow: { lat: 55.75, lon: 37.62 },
  "saint petersburg": { lat: 59.93, lon: 30.34 },
  "st petersburg": { lat: 59.93, lon: 30.34 },
  petersburg: { lat: 59.93, lon: 30.34 },
  novosibirsk: { lat: 55.04, lon: 82.93 },
  yekaterinburg: { lat: 56.84, lon: 60.6 },
  kazan: { lat: 55.79, lon: 49.12 },
  vladivostok: { lat: 43.12, lon: 131.89 },
  kiev: { lat: 50.45, lon: 30.52 },
  kyiv: { lat: 50.45, lon: 30.52 },
  minsk: { lat: 53.9, lon: 27.57 },
  almaty: { lat: 43.25, lon: 76.92 },
  // Europe
  london: { lat: 51.51, lon: -0.13 },
  paris: { lat: 48.86, lon: 2.35 },
  amsterdam: { lat: 52.37, lon: 4.9 },
  frankfurt: { lat: 50.11, lon: 8.68 },
  berlin: { lat: 52.52, lon: 13.4 },
  munich: { lat: 48.14, lon: 11.58 },
  zurich: { lat: 47.38, lon: 8.54 },
  vienna: { lat: 48.21, lon: 16.37 },
  warsaw: { lat: 52.23, lon: 21.01 },
  prague: { lat: 50.07, lon: 14.43 },
  stockholm: { lat: 59.33, lon: 18.07 },
  helsinki: { lat: 60.17, lon: 24.94 },
  oslo: { lat: 59.91, lon: 10.75 },
  copenhagen: { lat: 55.68, lon: 12.57 },
  dublin: { lat: 53.35, lon: -6.26 },
  madrid: { lat: 40.42, lon: -3.7 },
  barcelona: { lat: 41.39, lon: 2.16 },
  rome: { lat: 41.9, lon: 12.5 },
  milan: { lat: 45.46, lon: 9.19 },
  lisbon: { lat: 38.72, lon: -9.14 },
  athens: { lat: 37.98, lon: 23.73 },
  bucharest: { lat: 44.43, lon: 26.1 },
  istanbul: { lat: 41.01, lon: 28.98 },
  // North America
  "new york": { lat: 40.71, lon: -74.01 },
  nyc: { lat: 40.71, lon: -74.01 },
  "los angeles": { lat: 34.05, lon: -118.24 },
  chicago: { lat: 41.88, lon: -87.63 },
  miami: { lat: 25.76, lon: -80.19 },
  dallas: { lat: 32.78, lon: -96.8 },
  seattle: { lat: 47.61, lon: -122.33 },
  "san francisco": { lat: 37.77, lon: -122.42 },
  toronto: { lat: 43.65, lon: -79.38 },
  montreal: { lat: 45.5, lon: -73.57 },
  vancouver: { lat: 49.28, lon: -123.12 },
  // Asia
  tokyo: { lat: 35.68, lon: 139.69 },
  osaka: { lat: 34.69, lon: 135.5 },
  seoul: { lat: 37.57, lon: 126.98 },
  "hong kong": { lat: 22.32, lon: 114.17 },
  hongkong: { lat: 22.32, lon: 114.17 },
  hk: { lat: 22.32, lon: 114.17 },
  singapore: { lat: 1.35, lon: 103.82 },
  bangkok: { lat: 13.76, lon: 100.5 },
  "kuala lumpur": { lat: 3.14, lon: 101.69 },
  jakarta: { lat: -6.21, lon: 106.85 },
  taipei: { lat: 25.03, lon: 121.57 },
  shanghai: { lat: 31.23, lon: 121.47 },
  beijing: { lat: 39.9, lon: 116.4 },
  shenzhen: { lat: 22.54, lon: 114.06 },
  guangzhou: { lat: 23.13, lon: 113.27 },
  mumbai: { lat: 19.08, lon: 72.88 },
  delhi: { lat: 28.61, lon: 77.21 },
  bangalore: { lat: 12.97, lon: 77.59 },
  dubai: { lat: 25.2, lon: 55.27 },
  "tel aviv": { lat: 32.08, lon: 34.78 },
  // Australia
  sydney: { lat: -33.87, lon: 151.21 },
  melbourne: { lat: -37.81, lon: 144.96 },
  // South America
  "sao paulo": { lat: -23.55, lon: -46.63 },
  "são paulo": { lat: -23.55, lon: -46.63 },
  "buenos aires": { lat: -34.6, lon: -58.38 },
  santiago: { lat: -33.45, lon: -70.66 },
  // Africa
  johannesburg: { lat: -26.2, lon: 28.05 },
  cairo: { lat: 30.04, lon: 31.24 },
  lagos: { lat: 6.52, lon: 3.38 },
};

const COUNTRY_TABLE: Record<string, LatLon> = {
  ru: { lat: 55.75, lon: 37.62 },
  russia: { lat: 55.75, lon: 37.62 },
  ua: { lat: 50.45, lon: 30.52 },
  ukraine: { lat: 50.45, lon: 30.52 },
  by: { lat: 53.9, lon: 27.57 },
  belarus: { lat: 53.9, lon: 27.57 },
  kz: { lat: 43.25, lon: 76.92 },
  kazakhstan: { lat: 43.25, lon: 76.92 },
  us: { lat: 38.9, lon: -77.04 },
  usa: { lat: 38.9, lon: -77.04 },
  "united states": { lat: 38.9, lon: -77.04 },
  ca: { lat: 45.42, lon: -75.7 },
  canada: { lat: 45.42, lon: -75.7 },
  mx: { lat: 19.43, lon: -99.13 },
  mexico: { lat: 19.43, lon: -99.13 },
  uk: { lat: 51.51, lon: -0.13 },
  gb: { lat: 51.51, lon: -0.13 },
  "united kingdom": { lat: 51.51, lon: -0.13 },
  fr: { lat: 48.86, lon: 2.35 },
  france: { lat: 48.86, lon: 2.35 },
  de: { lat: 52.52, lon: 13.4 },
  germany: { lat: 52.52, lon: 13.4 },
  nl: { lat: 52.37, lon: 4.9 },
  netherlands: { lat: 52.37, lon: 4.9 },
  pl: { lat: 52.23, lon: 21.01 },
  poland: { lat: 52.23, lon: 21.01 },
  cz: { lat: 50.07, lon: 14.43 },
  fi: { lat: 60.17, lon: 24.94 },
  finland: { lat: 60.17, lon: 24.94 },
  se: { lat: 59.33, lon: 18.07 },
  sweden: { lat: 59.33, lon: 18.07 },
  no: { lat: 59.91, lon: 10.75 },
  norway: { lat: 59.91, lon: 10.75 },
  dk: { lat: 55.68, lon: 12.57 },
  denmark: { lat: 55.68, lon: 12.57 },
  ie: { lat: 53.35, lon: -6.26 },
  ireland: { lat: 53.35, lon: -6.26 },
  es: { lat: 40.42, lon: -3.7 },
  spain: { lat: 40.42, lon: -3.7 },
  it: { lat: 41.9, lon: 12.5 },
  italy: { lat: 41.9, lon: 12.5 },
  pt: { lat: 38.72, lon: -9.14 },
  ch: { lat: 47.38, lon: 8.54 },
  switzerland: { lat: 47.38, lon: 8.54 },
  at: { lat: 48.21, lon: 16.37 },
  tr: { lat: 41.01, lon: 28.98 },
  jp: { lat: 35.68, lon: 139.69 },
  japan: { lat: 35.68, lon: 139.69 },
  kr: { lat: 37.57, lon: 126.98 },
  cn: { lat: 31.23, lon: 121.47 },
  china: { lat: 31.23, lon: 121.47 },
  hk: { lat: 22.32, lon: 114.17 },
  tw: { lat: 25.03, lon: 121.57 },
  sg: { lat: 1.35, lon: 103.82 },
  singapore: { lat: 1.35, lon: 103.82 },
  th: { lat: 13.76, lon: 100.5 },
  my: { lat: 3.14, lon: 101.69 },
  id: { lat: -6.21, lon: 106.85 },
  in: { lat: 19.08, lon: 72.88 },
  india: { lat: 19.08, lon: 72.88 },
  ae: { lat: 25.2, lon: 55.27 },
  il: { lat: 32.08, lon: 34.78 },
  au: { lat: -33.87, lon: 151.21 },
  australia: { lat: -33.87, lon: 151.21 },
  br: { lat: -23.55, lon: -46.63 },
  ar: { lat: -34.6, lon: -58.38 },
  za: { lat: -26.2, lon: 28.05 },
};

export function cityToLatLon(
  city?: string,
  country?: string,
  _addr?: string,
): LatLon | null {
  const c = (city ?? "").trim().toLowerCase();
  if (c) {
    if (CITY_TABLE[c]) return CITY_TABLE[c];
    // try splitting on common separators ("Tokyo, Japan", "Tokyo - JP")
    for (const sep of [",", "-", "·", "|", "/"]) {
      const idx = c.indexOf(sep);
      if (idx > 0) {
        const head = c.slice(0, idx).trim();
        if (CITY_TABLE[head]) return CITY_TABLE[head];
      }
    }
    // fuzzy: contains a known city name
    for (const key of Object.keys(CITY_TABLE)) {
      if (c.includes(key)) return CITY_TABLE[key];
    }
  }
  const cn = (country ?? "").trim().toLowerCase();
  if (cn && COUNTRY_TABLE[cn]) return COUNTRY_TABLE[cn];
  return null;
}
