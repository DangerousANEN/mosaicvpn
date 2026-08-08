import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/atlas_theme.dart';

/// Pin position on the map (in 0..1 normalized coords).
class MapPin {
  final double nx;
  final double ny;
  final String label;
  final bool active;
  final bool selected;
  final int? ms;
  final bool failed;

  const MapPin({
    required this.nx,
    required this.ny,
    required this.label,
    this.active = false,
    this.selected = false,
    this.ms,
    this.failed = false,
  });
}

/// Equirectangular (Plate Carrée) world map with graticule + server pins
/// and dashed connection line.  The SVG (world.svg) has viewBox
/// `0 0 5760 2880` — exactly 2:1 — spanning -180..180° × 90..-90°.
/// Simple linear lon/lat → x/y projection is therefore exact.
///
/// Supports mouse-wheel zoom, drag-to-pan, and hover tooltips on pins.
class WorldMapWidget extends StatefulWidget {
  final List<MapPin> pins;
  final MapPin? youPin;
  final String? bearing;

  /// If true, draw a solid line from youPin → active pin (connected).
  /// If false, draw a dashed line (selected but not yet connected).
  final bool connected;

  /// Width / height ratio of the equirectangular map (2:1).
  /// Kept for external callers that need the canonical ratio.
  static const double aspect = 2.0;

  const WorldMapWidget({
    super.key,
    required this.pins,
    this.youPin,
    this.bearing,
    this.connected = false,
  });

  /// Map lon/lat to normalized overlay coords (0..1).
  /// The SVG is a true equirectangular projection: 0..5760 px ↔ -180..180°,
  /// 0..2880 px ↔ 90..-90°. BoxFit.fill stretches the SVG to fill the 2:1
  /// SizedBox exactly, so no compensation is needed.
  static double projectX(double lon) => (lon + 180) / 360;
  static double projectY(double lat) => (90 - lat) / 180;

  @override
  State<WorldMapWidget> createState() => _WorldMapWidgetState();
}

class _WorldMapWidgetState extends State<WorldMapWidget> {
  final TransformationController _ctrl = TransformationController();
  MapPin? _hoveredPin;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        final availH = constraints.maxHeight;

        final mapW = math.min(availW, availH * 2.0);
        final mapH = mapW / 2.0;

        return ClipRect(
          child: SizedBox(
            width: availW,
            height: availH,
            child: Stack(
              children: [
                // Interactive pan/zoom canvas covering the full available viewport
                Positioned.fill(
                  child: InteractiveViewer(
                    transformationController: _ctrl,
                    minScale: 1.0,
                    maxScale: 8.0,
                    boundaryMargin: const EdgeInsets.all(double.infinity),
                    child: Center(
                      child: SizedBox(
                        width: mapW,
                        height: mapH,
                        child: Stack(
                          children: [
                            // SVG continent layer
                            Positioned.fill(
                              child: SvgPicture.asset(
                                'assets/maps/world.svg',
                                fit: BoxFit.fill,
                                colorFilter: ColorFilter.mode(
                                  c.borderInk.withValues(alpha: 0.35),
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),

                            // Graticule + pins + arc overlay
                            Positioned.fill(
                              child: MouseRegion(
                                cursor: _hoveredPin != null
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.grab,
                                child: GestureDetector(
                                  // Pin tap → tooltip
                                  onTapDown: (details) {
                                    _handleTap(
                                        details.localPosition, mapW, mapH);
                                  },
                                  child: CustomPaint(
                                    painter: _OverlayPainter(
                                      pins: widget.pins,
                                      youPin: widget.youPin,
                                      mapW: mapW,
                                      mapH: mapH,
                                      connected: widget.connected,
                                      hoveredPin: _hoveredPin,
                                      c: c,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                            // Hover tooltip
                            if (_hoveredPin != null)
                              Positioned(
                                left: (_hoveredPin!.nx * mapW)
                                    .clamp(8.0, mapW - 8.0),
                                top: (_hoveredPin!.ny * mapH)
                                        .clamp(8.0, mapH - 8.0) -
                                    30,
                                child: FractionalTranslation(
                                  translation: const Offset(-0.5, 0),
                                  child: _PinTooltip(pin: _hoveredPin!),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Bearing caption (fixed UI overlay)
                if (widget.bearing != null)
                  Positioned(
                    top: 8,
                    right: 12,
                    child: Text(
                      widget.bearing!,
                      style: TextStyle(
                        fontFamily: AtlasTheme.monoFamily,
                        fontSize: 10,
                        color: AtlasTheme.accent,
                      ),
                    ),
                  ),

                // Zoom controls (fixed UI overlay)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ZoomButton(
                        icon: Icons.add,
                        onTap: () => _zoom(1.5),
                      ),
                      const SizedBox(height: 4),
                      _ZoomButton(
                        icon: Icons.remove,
                        onTap: () => _zoom(1 / 1.5),
                      ),
                      const SizedBox(height: 4),
                      _ZoomButton(
                        icon: Icons.fit_screen_outlined,
                        onTap: () => _ctrl.value = Matrix4.identity(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _zoom(double factor) {
    final matrix = _ctrl.value * Matrix4.diagonal3Values(factor, factor, 1);
    _ctrl.value = matrix;
  }

  void _handleTap(Offset localPos, double w, double h) {
    // Find pin closest to tap within threshold
    const threshold = 16.0; // px
    MapPin? closest;
    double closestDist = double.infinity;
    for (final p in widget.pins) {
      final dx = p.nx * w - localPos.dx;
      final dy = p.ny * h - localPos.dy;
      final dist = (dx * dx + dy * dy);
      if (dist < threshold * threshold && dist < closestDist) {
        closestDist = dist;
        closest = p;
      }
    }
    if (closest != null) {
      setState(() => _hoveredPin = closest);
    } else {
      // Tapped empty area → hide tooltip
      if (_hoveredPin != null) setState(() => _hoveredPin = null);
    }
  }
}

/// Compact tooltip card shown when hovering or tapping a pin.
class _PinTooltip extends StatelessWidget {
  final MapPin pin;
  const _PinTooltip({required this.pin});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: c.bgElevated.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: c.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pin.label,
              style: TextStyle(
                fontFamily: AtlasTheme.sansFamily,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
            if (pin.ms != null) ...[
              const SizedBox(height: 2),
              Text(
                pin.failed ? 'unreachable' : '${pin.ms} ms',
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 9,
                  color: pin.failed
                      ? AtlasTheme.error
                      : (pin.ms! > 300
                          ? AtlasTheme.warning
                          : AtlasTheme.success),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Small circular zoom button.
class _ZoomButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ZoomButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Material(
      color: c.bgElevated.withValues(alpha: 0.8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: c.border, width: 0.5),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(icon, size: 16, color: c.textSecondary),
        ),
      ),
    );
  }
}

/// Draws graticule (lat/lon grid), connection arc, and server pins.
class _OverlayPainter extends CustomPainter {
  final List<MapPin> pins;
  final MapPin? youPin;
  final double mapW;
  final double mapH;
  final bool connected;
  final MapPin? hoveredPin;
  final ThemeColors c;

  _OverlayPainter({
    required this.pins,
    this.youPin,
    required this.mapW,
    required this.mapH,
    this.connected = false,
    this.hoveredPin,
    required this.c,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // ── Graticule ──
    final gridPaint = Paint()
      ..color = c.border.withValues(alpha: 0.3)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    // Equator (slightly brighter)
    final eqPaint = Paint()
      ..color = c.border.withValues(alpha: 0.5)
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      Offset(WorldMapWidget.projectX(-180) * w, h / 2),
      Offset(WorldMapWidget.projectX(180) * w, h / 2),
      eqPaint,
    );

    // Latitude lines every 30°
    for (var lat = -60; lat <= 60; lat += 30) {
      if (lat == 0) continue;
      final y = WorldMapWidget.projectY(lat.toDouble()) * h;
      canvas.drawLine(
        Offset(WorldMapWidget.projectX(-180) * w, y),
        Offset(WorldMapWidget.projectX(180) * w, y),
        gridPaint,
      );
    }
    // Longitude lines every 30°
    for (var lon = -150; lon <= 180; lon += 30) {
      final x = WorldMapWidget.projectX(lon.toDouble()) * w;
      canvas.drawLine(
        Offset(x, WorldMapWidget.projectY(90) * h),
        Offset(x, WorldMapWidget.projectY(-90) * h),
        gridPaint,
      );
    }

    // ── Connection line (you → active pin) ── solid if connected, dashed if just selected
    final activePin = pins.where((p) => p.active).toList();
    if (youPin != null && activePin.isNotEmpty) {
      final p = activePin.first;
      final sx = youPin!.nx * w;
      final sy = youPin!.ny * h;
      final ex = p.nx * w;
      final ey = p.ny * h;

      final dx = ex - sx;
      final dy = ey - sy;
      final totalDist = math.sqrt(dx * dx + dy * dy);

      final linePaint = Paint()
        ..color = AtlasTheme.accent.withValues(alpha: connected ? 0.95 : 0.75)
        ..strokeWidth = connected ? 2.5 : 2.0
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      // Great-circle arc: bend the line towards the pole (perpendicular offset)
      final midX = (sx + ex) / 2;
      final midY = (sy + ey) / 2;
      // Perpendicular direction (rotate (dx,dy) by 90°)
      final perpX = -dy / totalDist;
      final perpY = dx / totalDist;
      // Arc curvature: 15% of total distance, bending north (negative Y)
      final bow = totalDist * 0.15 * (midY > h * 0.5 ? 1 : -1);
      final ctrlX = midX + perpX * bow;
      final ctrlY = midY + perpY * bow;

      final arcPath = Path()
        ..moveTo(sx, sy)
        ..conicTo(1.0, ctrlX, ctrlY, ex, ey);

      if (connected) {
        // Solid arc
        canvas.drawPath(arcPath, linePaint);
      } else {
        // Dashed arc: You → selected (not connected) server
        final dashWidth = (totalDist * 0.025).clamp(4.0, 10.0);
        final dashSpace = dashWidth * 0.8;
        final stepCount = (totalDist / (dashWidth + dashSpace)).floor();
        for (int i = 0; i <= stepCount; i += 2) {
          final t0 = (i * (dashWidth + dashSpace)) / totalDist;
          final t1 = ((i + 1) * dashWidth + i * dashSpace) / totalDist;
          final p0 =
              _quadPoint(sx, sy, ctrlX, ctrlY, ex, ey, t0.clamp(0.0, 1.0));
          final p1 =
              _quadPoint(sx, sy, ctrlX, ctrlY, ex, ey, t1.clamp(0.0, 1.0));
          canvas.drawLine(p0, p1, linePaint);
        }
      }
    }

    // ── Pins ──
    for (final p in pins) {
      final cx = p.nx * w;
      final cy = p.ny * h;
      final isP = p.active;

      // Dot
      final dotColor = p.failed
          ? AtlasTheme.error
          : isP
              ? AtlasTheme.accent
              : (p.ms != null && p.ms! > 0 ? AtlasTheme.success : c.textMuted);
      final dotPaint = Paint()
        ..color = dotColor
        ..style = PaintingStyle.fill;
      final r = isP ? (connected ? 6.0 : 5.0) : 2.5;
      canvas.drawCircle(Offset(cx, cy), r, dotPaint);

      // Selected (not connected): orange outline ring around pin
      if (isP && !connected) {
        final ringPaint = Paint()
          ..color = AtlasTheme.accent
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(cx, cy), r + 3.5, ringPaint);
      }

      // Connected: filled orange halo + solid dot
      if (isP && connected) {
        final filledHalo = Paint()
          ..color = AtlasTheme.accent.withValues(alpha: 0.3)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(cx, cy), r + 4, filledHalo);
      }

      // Hover halo: draw a faint ring around the hovered (tooltip) pin
      if (hoveredPin != null && !isP) {
        final hx = hoveredPin!.nx * w;
        final hy = hoveredPin!.ny * h;
        final hoverPaint = Paint()
          ..color = AtlasTheme.accent.withValues(alpha: 0.4)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(Offset(hx, hy), 6.0, hoverPaint);
      }

      // Label for active pin
      if (isP && p.label.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: p.label,
            style: TextStyle(
              fontFamily: AtlasTheme.sansFamily,
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: c.textPrimary,
            ),
          ),
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.left,
        )..layout();
        tp.paint(canvas, Offset(cx + 7, cy - tp.height / 2));
      }
    }

    // ── "You are here" pin ──
    if (youPin != null) {
      final cx = youPin!.nx * w;
      final cy = youPin!.ny * h;
      final haloPaint = Paint()
        ..color = AtlasTheme.accent.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), 10, haloPaint);
      final dotPaint = Paint()
        ..color = AtlasTheme.accent
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(cx, cy), 3.5, dotPaint);
      // Ring
      final ringPaint = Paint()
        ..color = AtlasTheme.accent.withValues(alpha: 0.5)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(Offset(cx, cy), 7, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) =>
      pins != old.pins ||
      youPin != old.youPin ||
      connected != old.connected ||
      hoveredPin != old.hoveredPin;
}

/// Quadratic Bézier interpolation at parameter t (0..1).
Offset _quadPoint(double x0, double y0, double cx, double cy, double x1,
    double y1, double t) {
  final u = 1 - t;
  return Offset(
    u * u * x0 + 2 * u * t * cx + t * t * x1,
    u * u * y0 + 2 * u * t * cy + t * t * y1,
  );
}
