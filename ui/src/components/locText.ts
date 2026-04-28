/**
 * locText returns a "City, Country" location string for a server, or
 * an empty string when neither field is populated. The result is
 * intentionally compact so it fits on a single gazetteer-style row in
 * the Pool list, the Atlas station-name block, and the routing
 * register.
 */

import type { Server } from "../api/types";

export function locText(s: Pick<Server, "city" | "country">): string {
  const city = (s.city ?? "").trim();
  const country = (s.country ?? "").trim();
  if (city && country) return `${city}, ${country}`;
  return city || country;
}
