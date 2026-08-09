import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// How the map camera should be framed.
///
/// The map used to hand zoom and panning to the user through an
/// [InteractiveViewer]. That let the world be dragged out of view entirely, and
/// it gave no feedback about which server was picked. The camera is now driven
/// by app state instead: idle shows the whole world, and selecting a server
/// frames the client and that server together.
enum MapCameraMode {
  /// Nothing selected — the whole world is visible.
  idle,

  /// A server is selected but not yet connected, drawn dimmed with a dashed
  /// route.
  candidate,

  /// The tunnel is up, drawn bright with a solid route.
  connected,
}

/// Resolved camera placement: how far to zoom, and what point to centre on.
@immutable
class MapCamera {
  /// Zoom factor. 1.0 shows the entire map.
  final double scale;

  /// Focal point in normalised map space (0..1 on both axes).
  final Offset focus;

  const MapCamera({required this.scale, required this.focus});

  static const MapCamera world = MapCamera(scale: 1.0, focus: Offset(0.5, 0.5));

  /// Minimum zoom — never pull back further than the whole world.
  static const double minScale = 1.0;

  /// Maximum zoom. Without a ceiling, a client and a server in the same city
  /// collapse the span to ~0 and the scale runs away to infinity.
  static const double maxScale = 4.0;

  /// Fraction of breathing room kept around the framed pair.
  static const double padding = 0.15;

  /// Frames [user] and [server] together with padding on all sides.
  ///
  /// Both points are normalised map coordinates. The result is clamped so the
  /// camera can neither zoom out past the world nor overshoot on a degenerate
  /// (zero-length) span.
  factory MapCamera.framing(Offset user, Offset server) {
    final minX = math.min(user.dx, server.dx);
    final maxX = math.max(user.dx, server.dx);
    final minY = math.min(user.dy, server.dy);
    final maxY = math.max(user.dy, server.dy);

    final spanX = (maxX - minX) + padding * 2;
    final spanY = (maxY - minY) + padding * 2;

    // Guard against a zero span before dividing.
    final scaleX = spanX <= 0 ? maxScale : 1.0 / spanX;
    final scaleY = spanY <= 0 ? maxScale : 1.0 / spanY;

    final scale = math.min(scaleX, scaleY).clamp(minScale, maxScale);

    return MapCamera(
      scale: scale.toDouble(),
      focus: Offset((minX + maxX) / 2, (minY + maxY) / 2),
    );
  }

  /// Builds the transform that renders this camera over a [size] canvas.
  ///
  /// The focal point is moved to the centre of the viewport and then scaled
  /// about that centre.
  Matrix4 toMatrix(Size size) {
    final centre = Offset(size.width / 2, size.height / 2);
    final focusPx = Offset(focus.dx * size.width, focus.dy * size.height);

    return Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-focusPx.dx, -focusPx.dy, 0, 1);
  }

  @override
  bool operator ==(Object other) =>
      other is MapCamera &&
      (other.scale - scale).abs() < 1e-9 &&
      (other.focus - focus).distance < 1e-9;

  @override
  int get hashCode => Object.hash(scale, focus);

  @override
  String toString() =>
      'MapCamera(scale: ${scale.toStringAsFixed(3)}, focus: $focus)';
}
