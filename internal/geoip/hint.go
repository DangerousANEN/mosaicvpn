package geoip

import (
	"context"
	"net"
	"strings"
	"time"
)

// CountryCentroid maps an ISO-3166-1 alpha-2 country code to a rough
// geographic centroid (lat, lon, decimal degrees, WGS84). Used as a
// fallback when ip-api.com returns the ASN-owner's country (often
// US for cloud providers) instead of the actual datacenter location
// — if we already know the country from the server name, we can drop
// in a centroid pin without trusting the GeoIP lat/lon.
//
// The list deliberately covers common VPN-host countries, not every
// nation on Earth. Missing entries fall through to whatever ip-api.com
// returned.
var CountryCentroid = map[string][2]float64{
	"AU": {-25.0, 133.0},
	"AT": {47.5, 14.5},
	"BE": {50.5, 4.5},
	"BR": {-10.0, -55.0},
	"CA": {56.0, -106.0},
	"CH": {46.8, 8.2},
	"CN": {35.0, 105.0},
	"CZ": {49.7, 15.5},
	"DE": {51.1, 10.4},
	"DK": {56.0, 10.0},
	"EE": {58.6, 25.0},
	"ES": {40.0, -4.0},
	"FI": {64.0, 26.0},
	"FR": {46.6, 2.4},
	"GB": {54.0, -2.0},
	"HK": {22.3, 114.2},
	"ID": {-2.5, 118.0},
	"IE": {53.0, -8.0},
	"IL": {31.5, 35.0},
	"IN": {21.0, 78.0},
	"IT": {42.8, 12.8},
	"JP": {36.0, 138.0},
	"KR": {36.5, 127.8},
	"KZ": {48.0, 67.0},
	"LT": {55.3, 24.0},
	"LU": {49.8, 6.1},
	"LV": {56.9, 24.6},
	"MD": {47.4, 28.4},
	"MX": {23.6, -102.5},
	"MY": {4.0, 109.0},
	"NL": {52.1, 5.3},
	"NO": {62.0, 10.0},
	"NZ": {-41.0, 174.0},
	"PH": {12.9, 121.8},
	"PL": {51.9, 19.1},
	"PT": {39.5, -8.0},
	"RO": {45.9, 24.9},
	"RS": {44.0, 21.0},
	"RU": {61.5, 105.0},
	"SE": {62.0, 15.0},
	"SG": {1.35, 103.85},
	"SK": {48.7, 19.7},
	"TH": {15.0, 100.0},
	"TR": {39.0, 35.0},
	"TW": {23.7, 121.0},
	"UA": {49.0, 32.0},
	"US": {38.0, -97.0},
	"VN": {16.0, 108.0},
	"ZA": {-29.0, 24.0},
}

// IsoFromName tries to extract a 2-letter ISO country code from a
// server display name. Recognised forms (case-insensitive):
//
//   "DE-VLESS-WS"    →  "DE"
//   "[us] VLESS"     →  "US"
//   "🇯🇵 Tokyo"      →  ""   (we don't decode flag emoji)
//   "vps2.example"   →  ""
//
// Only codes that exist in CountryCentroid are returned, to filter
// out coincidental two-letter prefixes like "VM" or "MX-" of a name.
func IsoFromName(name string) string {
	n := strings.TrimSpace(name)
	if len(n) < 2 {
		return ""
	}
	// "[XX]" prefix
	if strings.HasPrefix(n, "[") && len(n) >= 4 && n[3] == ']' {
		c := strings.ToUpper(n[1:3])
		if _, ok := CountryCentroid[c]; ok {
			return c
		}
	}
	// "XX-…" or "XX_…" or "XX " prefix
	if len(n) >= 3 {
		sep := n[2]
		if sep == '-' || sep == '_' || sep == ' ' || sep == '.' {
			c := strings.ToUpper(n[:2])
			if _, ok := CountryCentroid[c]; ok {
				return c
			}
		}
	}
	return ""
}

// ResolveHost returns the first usable IP that host resolves to. host
// can already be an IP literal in which case it is returned verbatim.
// On error or empty host, returns an empty string.
func ResolveHost(ctx context.Context, host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.String()
	}
	cctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	r := net.Resolver{}
	addrs, err := r.LookupIPAddr(cctx, host)
	if err != nil || len(addrs) == 0 {
		return ""
	}
	// Prefer IPv4 — easier to read, more likely to have a clean
	// GeoIP entry, and matches what most users see in their
	// subscription URLs.
	for _, a := range addrs {
		if v4 := a.IP.To4(); v4 != nil {
			return v4.String()
		}
	}
	return addrs[0].IP.String()
}
