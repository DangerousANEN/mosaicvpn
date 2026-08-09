import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/shared/widgets/map_camera.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;

void main() {
  group('MapCamera.framing', () {
    test('centres between the client and the server', () {
      final cam = MapCamera.framing(const Offset(0.2, 0.4), const Offset(0.6, 0.8));

      expect(cam.focus.dx, closeTo(0.4, 1e-9));
      expect(cam.focus.dy, closeTo(0.6, 1e-9));
    });

    test('zooms in when the pair sits close together', () {
      final far = MapCamera.framing(const Offset(0.05, 0.1), const Offset(0.95, 0.9));
      final near = MapCamera.framing(const Offset(0.48, 0.50), const Offset(0.52, 0.54));

      expect(near.scale, greaterThan(far.scale),
          reason: 'a tighter pair should be framed closer');
    });

    test('never zooms out past the whole world', () {
      // Opposite corners span the entire map; with padding the raw scale would
      // drop below 1 and show empty space around the map.
      final cam = MapCamera.framing(const Offset(0, 0), const Offset(1, 1));

      expect(cam.scale, greaterThanOrEqualTo(MapCamera.minScale));
    });

    test('clamps instead of exploding when both points coincide', () {
      // Client and server in the same city: the span is zero, so an unguarded
      // 1/span would be infinite.
      final cam = MapCamera.framing(const Offset(0.5, 0.5), const Offset(0.5, 0.5));

      expect(cam.scale.isFinite, isTrue);
      expect(cam.scale, lessThanOrEqualTo(MapCamera.maxScale));
      expect(cam.focus, const Offset(0.5, 0.5));
    });

    test('is symmetric — argument order does not matter', () {
      final a = MapCamera.framing(const Offset(0.1, 0.2), const Offset(0.7, 0.9));
      final b = MapCamera.framing(const Offset(0.7, 0.9), const Offset(0.1, 0.2));

      expect(a, equals(b));
    });

    test('keeps both points inside the viewport after transform', () {
      const size = Size(800, 400); // 2:1, as the projection requires
      const user = Offset(0.30, 0.35);
      const server = Offset(0.70, 0.65);

      final m = MapCamera.framing(user, server).toMatrix(size);

      for (final p in [user, server]) {
        final v = m.transform3(
          Vector3(p.dx * size.width, p.dy * size.height, 0),
        );
        expect(v.x, inInclusiveRange(0, size.width),
            reason: 'point $p fell outside horizontally');
        expect(v.y, inInclusiveRange(0, size.height),
            reason: 'point $p fell outside vertically');
      }
    });
  });

  group('MapCamera.world', () {
    test('shows the entire map from the centre', () {
      expect(MapCamera.world.scale, 1.0);
      expect(MapCamera.world.focus, const Offset(0.5, 0.5));
    });
  });
}
