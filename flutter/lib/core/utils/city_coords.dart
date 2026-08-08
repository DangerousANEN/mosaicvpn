/// cityToLatLon — port of the Tauri UI's cityCoords.ts.
/// Resolves a (city, country) pair to approximate lat/lon for map pins.
class LatLon {
  final double lat;
  final double lon;
  const LatLon(this.lat, this.lon);
}

const Map<String, LatLon> _cityTable = {
  // Russia / CIS
  'moscow': LatLon(55.75, 37.62),
  'saint petersburg': LatLon(59.93, 30.34),
  'st petersburg': LatLon(59.93, 30.34),
  'petersburg': LatLon(59.93, 30.34),
  'novosibirsk': LatLon(55.04, 82.93),
  'yekaterinburg': LatLon(56.84, 60.6),
  'kazan': LatLon(55.79, 49.12),
  'vladivostok': LatLon(43.12, 131.89),
  'kiev': LatLon(50.45, 30.52),
  'kyiv': LatLon(50.45, 30.52),
  'minsk': LatLon(53.9, 27.57),
  'almaty': LatLon(43.25, 76.92),
  // Europe
  'london': LatLon(51.51, -0.13),
  'paris': LatLon(48.86, 2.35),
  'amsterdam': LatLon(52.37, 4.9),
  'frankfurt': LatLon(50.11, 8.68),
  'berlin': LatLon(52.52, 13.4),
  'munich': LatLon(48.14, 11.58),
  'zurich': LatLon(47.38, 8.54),
  'vienna': LatLon(48.21, 16.37),
  'warsaw': LatLon(52.23, 21.01),
  'prague': LatLon(50.07, 14.43),
  'stockholm': LatLon(59.33, 18.07),
  'helsinki': LatLon(60.17, 24.94),
  'oslo': LatLon(59.91, 10.75),
  'copenhagen': LatLon(55.68, 12.57),
  'dublin': LatLon(53.35, -6.26),
  'madrid': LatLon(40.42, -3.7),
  'barcelona': LatLon(41.39, 2.16),
  'rome': LatLon(41.9, 12.5),
  'milan': LatLon(45.46, 9.19),
  'lisbon': LatLon(38.72, -9.14),
  'athens': LatLon(37.98, 23.73),
  'bucharest': LatLon(44.43, 26.1),
  'istanbul': LatLon(41.01, 28.98),
  // North America
  'new york': LatLon(40.71, -74.01),
  'nyc': LatLon(40.71, -74.01),
  'los angeles': LatLon(34.05, -118.24),
  'chicago': LatLon(41.88, -87.63),
  'miami': LatLon(25.76, -80.19),
  'dallas': LatLon(32.78, -96.8),
  'seattle': LatLon(47.61, -122.33),
  'san francisco': LatLon(37.77, -122.42),
  'toronto': LatLon(43.65, -79.38),
  'montreal': LatLon(45.5, -73.57),
  'vancouver': LatLon(49.28, -123.12),
  // Asia
  'tokyo': LatLon(35.68, 139.69),
  'osaka': LatLon(34.69, 135.5),
  'seoul': LatLon(37.57, 126.98),
  'hong kong': LatLon(22.32, 114.17),
  'hongkong': LatLon(22.32, 114.17),
  'hk': LatLon(22.32, 114.17),
  'singapore': LatLon(1.35, 103.82),
  'bangkok': LatLon(13.76, 100.5),
  'kuala lumpur': LatLon(3.14, 101.69),
  'jakarta': LatLon(-6.21, 106.85),
  'taipei': LatLon(25.03, 121.57),
  'shanghai': LatLon(31.23, 121.47),
  'beijing': LatLon(39.9, 116.4),
  'shenzhen': LatLon(22.54, 114.06),
  'guangzhou': LatLon(23.13, 113.27),
  'mumbai': LatLon(19.08, 72.88),
  'delhi': LatLon(28.61, 77.21),
  'bangalore': LatLon(12.97, 77.59),
  'dubai': LatLon(25.2, 55.27),
  'tel aviv': LatLon(32.08, 34.78),
  // Australia
  'sydney': LatLon(-33.87, 151.21),
  'melbourne': LatLon(-37.81, 144.96),
  // South America
  'sao paulo': LatLon(-23.55, -46.63),
  'são paulo': LatLon(-23.55, -46.63),
  'buenos aires': LatLon(-34.6, -58.38),
  'santiago': LatLon(-33.45, -70.66),
  // Africa
  'johannesburg': LatLon(-26.2, 28.05),
  'cairo': LatLon(30.04, 31.24),
  'lagos': LatLon(6.52, 3.38),
};

const Map<String, LatLon> _countryTable = {
  'ru': LatLon(55.75, 37.62),
  'russia': LatLon(55.75, 37.62),
  'ua': LatLon(50.45, 30.52),
  'ukraine': LatLon(50.45, 30.52),
  'by': LatLon(53.9, 27.57),
  'belarus': LatLon(53.9, 27.57),
  'kz': LatLon(43.25, 76.92),
  'kazakhstan': LatLon(43.25, 76.92),
  'us': LatLon(38.9, -77.04),
  'usa': LatLon(38.9, -77.04),
  'united states': LatLon(38.9, -77.04),
  'ca': LatLon(45.42, -75.7),
  'canada': LatLon(45.42, -75.7),
  'mx': LatLon(19.43, -99.13),
  'mexico': LatLon(19.43, -99.13),
  'uk': LatLon(51.51, -0.13),
  'gb': LatLon(51.51, -0.13),
  'united kingdom': LatLon(51.51, -0.13),
  'fr': LatLon(48.86, 2.35),
  'france': LatLon(48.86, 2.35),
  'de': LatLon(52.52, 13.4),
  'germany': LatLon(52.52, 13.4),
  'nl': LatLon(52.37, 4.9),
  'netherlands': LatLon(52.37, 4.9),
  'pl': LatLon(52.23, 21.01),
  'poland': LatLon(52.23, 21.01),
  'cz': LatLon(50.07, 14.43),
  'fi': LatLon(60.17, 24.94),
  'finland': LatLon(60.17, 24.94),
  'se': LatLon(59.33, 18.07),
  'sweden': LatLon(59.33, 18.07),
  'no': LatLon(59.91, 10.75),
  'norway': LatLon(59.91, 10.75),
  'dk': LatLon(55.68, 12.57),
  'denmark': LatLon(55.68, 12.57),
  'ie': LatLon(53.35, -6.26),
  'ireland': LatLon(53.35, -6.26),
  'es': LatLon(40.42, -3.7),
  'spain': LatLon(40.42, -3.7),
  'it': LatLon(41.9, 12.5),
  'italy': LatLon(41.9, 12.5),
  'pt': LatLon(38.72, -9.14),
  'ch': LatLon(47.38, 8.54),
  'switzerland': LatLon(47.38, 8.54),
  'at': LatLon(48.21, 16.37),
  'tr': LatLon(41.01, 28.98),
  'jp': LatLon(35.68, 139.69),
  'japan': LatLon(35.68, 139.69),
  'kr': LatLon(37.57, 126.98),
  'cn': LatLon(31.23, 121.47),
  'china': LatLon(31.23, 121.47),
  'tw': LatLon(25.03, 121.57),
  'sg': LatLon(1.35, 103.82),
  'th': LatLon(13.76, 100.5),
  'my': LatLon(3.14, 101.69),
  'id': LatLon(-6.21, 106.85),
  'in': LatLon(19.08, 72.88),
  'india': LatLon(19.08, 72.88),
  'ae': LatLon(25.2, 55.27),
  'il': LatLon(32.08, 34.78),
  'au': LatLon(-33.87, 151.21),
  'australia': LatLon(-33.87, 151.21),
  'br': LatLon(-23.55, -46.63),
  'ar': LatLon(-34.6, -58.38),
  'za': LatLon(-26.2, 28.05),
};

/// Resolves (city, country) to approximate lat/lon, or null if unknown.
LatLon? cityToLatLon({String? city, String? country}) {
  final c = (city ?? '').trim().toLowerCase();
  if (c.isNotEmpty) {
    if (_cityTable.containsKey(c)) return _cityTable[c]!;
    // try splitting on common separators
    for (final sep in [',', '-', '·', '|', '/']) {
      final idx = c.indexOf(sep);
      if (idx > 0) {
        final head = c.substring(0, idx).trim();
        if (_cityTable.containsKey(head)) return _cityTable[head]!;
      }
    }
    // fuzzy: contains a known city name
    for (final key in _cityTable.keys) {
      if (c.contains(key)) return _cityTable[key]!;
    }
  }
  final cn = (country ?? '').trim().toLowerCase();
  if (cn.isNotEmpty && _countryTable.containsKey(cn)) return _countryTable[cn]!;
  return null;
}
