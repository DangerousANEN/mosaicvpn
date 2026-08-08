import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/shared/widgets/world_map_widget.dart';

void main() {
  group('WorldMapWidget projection mathematics', () {
    test('Moscow projection coordinates for 400x200 map', () {
      const mapW = 400.0;
      const mapH = 200.0;

      // Coordinate of Moscow: lat 55.75, lon 37.62
      const moscowLat = 55.75;
      const moscowLon = 37.62;

      final nx = WorldMapWidget.projectX(moscowLon);
      final ny = WorldMapWidget.projectY(moscowLat);

      final x = nx * mapW;
      final y = ny * mapH;

      final expectedX = 400.0 * (37.62 + 180) / 360; // ≈ 241.8
      final expectedY = 200.0 * (90 - 55.75) / 180;  // ≈ 38.0555... ≈ 38.1

      expect(x, closeTo(241.8, 0.01));
      expect(y, closeTo(38.1, 0.05));
      expect(x, equals(expectedX));
      expect(y, equals(expectedY));
    });
  });
}
