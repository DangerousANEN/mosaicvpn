import 'dart:math';
import 'package:flutter/material.dart';

import '../../core/theme/atlas_theme.dart';
import 'speedtest_models.dart';

/// Animated circular gauge visualizing real-time throughput or ping measurements.
class SpeedtestGauge extends StatefulWidget {
  final SpeedTestProgress progress;
  final double size;

  const SpeedtestGauge({
    super.key,
    required this.progress,
    this.size = 220,
  });

  @override
  State<SpeedtestGauge> createState() => _SpeedtestGaugeState();
}

class _SpeedtestGaugeState extends State<SpeedtestGauge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.progress.isRunning) _pulseController.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant SpeedtestGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.progress.isRunning && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.progress.isRunning) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final p = widget.progress;

    // Determine current speed in Mbps for gauge position
    double currentMbps = (p.currentBps / 1000000.0);
    if (p.stage == SpeedTestStage.completed && p.result != null) {
      currentMbps = (p.result!.downloadBps / 1000000.0);
    }

    // Scale to gauge fraction (0.0 to 1.0) using logarithmic or tiered scale:
    // 0-10 Mbps -> 0.0-0.3, 10-50 Mbps -> 0.3-0.6, 50-100 Mbps -> 0.6-0.8, 100+ -> 0.8-1.0
    final double gaugeFraction = _calculateGaugeFraction(currentMbps);

    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: gaugeFraction),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          builder: (context, animatedFraction, child) {
            return SizedBox(
              width: widget.size,
              height: widget.size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: Size(widget.size, widget.size),
                    painter: _GaugePainter(
                      fraction: animatedFraction,
                      stage: p.stage,
                      pulseValue: p.isRunning ? _pulseController.value : 0.0,
                      trackColor: c.border.withValues(alpha: 0.4),
                      activeColor: _stageColor(p.stage),
                      accentColor: AtlasTheme.accent,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildCenterValue(p, currentMbps, c),
                      const SizedBox(height: 4),
                      _buildCenterSubtitle(p, c),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  double _calculateGaugeFraction(double mbps) {
    if (mbps <= 0) return 0.0;
    if (mbps <= 10) return (mbps / 10.0) * 0.30;
    if (mbps <= 50) return 0.30 + ((mbps - 10) / 40.0) * 0.30;
    if (mbps <= 100) return 0.60 + ((mbps - 50) / 50.0) * 0.20;
    return (0.80 + ((mbps - 100) / 400.0) * 0.20).clamp(0.0, 1.0);
  }

  Color _stageColor(SpeedTestStage stage) {
    switch (stage) {
      case SpeedTestStage.ping:
        return AtlasTheme.warning; // Amber
      case SpeedTestStage.download:
        return AtlasTheme.success; // Emerald / Green
      case SpeedTestStage.upload:
        return AtlasTheme.accent; // Indigo / Blue
      case SpeedTestStage.completed:
        return AtlasTheme.success;
      case SpeedTestStage.failed:
        return AtlasTheme.error;
      case SpeedTestStage.cancelled:
      case SpeedTestStage.idle:
        return AtlasTheme.textMuted;
    }
  }

  Widget _buildCenterValue(SpeedTestProgress p, double currentMbps, ThemeColors c) {
    if (p.stage == SpeedTestStage.idle) {
      return Text(
        'READY',
        style: TextStyle(
          fontFamily: AtlasTheme.monoFamily,
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: c.textSecondary,
          letterSpacing: 1.2,
        ),
      );
    }

    if (p.stage == SpeedTestStage.ping) {
      final pingVal = p.currentPingMs ?? p.latencyMs ?? 0;
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            '$pingVal',
            style: const TextStyle(
              fontFamily: AtlasTheme.monoFamily,
              fontSize: 34,
              fontWeight: FontWeight.bold,
              color: AtlasTheme.warning,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'ms',
            style: TextStyle(
              fontFamily: AtlasTheme.monoFamily,
              fontSize: 14,
              color: c.textMuted,
            ),
          ),
        ],
      );
    }

    // Download, Upload, or Completed
    final displayMbps = p.stage == SpeedTestStage.completed && p.result != null
        ? (p.result!.downloadBps / 1000000.0)
        : currentMbps;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          displayMbps >= 100
              ? displayMbps.toStringAsFixed(0)
              : displayMbps.toStringAsFixed(1),
          style: TextStyle(
            fontFamily: AtlasTheme.monoFamily,
            fontSize: 34,
            fontWeight: FontWeight.bold,
            color: _stageColor(p.stage),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'Mbps',
          style: TextStyle(
            fontFamily: AtlasTheme.monoFamily,
            fontSize: 14,
            color: c.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildCenterSubtitle(SpeedTestProgress p, ThemeColors c) {
    String text;
    Color color = c.textMuted;

    switch (p.stage) {
      case SpeedTestStage.idle:
        text = 'Click Start';
        break;
      case SpeedTestStage.ping:
        text = 'PING / LATENCY';
        color = AtlasTheme.warning;
        break;
      case SpeedTestStage.download:
        text = 'DOWNLOAD';
        color = AtlasTheme.success;
        break;
      case SpeedTestStage.upload:
        text = 'UPLOAD';
        color = AtlasTheme.accent;
        break;
      case SpeedTestStage.completed:
        text = 'TEST COMPLETE';
        color = AtlasTheme.success;
        break;
      case SpeedTestStage.failed:
        text = 'FAILED';
        color = AtlasTheme.error;
        break;
      case SpeedTestStage.cancelled:
        text = 'CANCELLED';
        break;
    }

    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: color,
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final SpeedTestStage stage;
  final double pulseValue;
  final Color trackColor;
  final Color activeColor;
  final Color accentColor;

  static const double startAngle = 135 * (pi / 180);
  static const double sweepAngle = 270 * (pi / 180);

  _GaugePainter({
    required this.fraction,
    required this.stage,
    required this.pulseValue,
    required this.trackColor,
    required this.activeColor,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - 24) / 2;

    // Background track arc
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    // Active progress arc
    if (fraction > 0.001) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10 + (pulseValue * 1.5)
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * fraction,
        false,
        activePaint,
      );

      // Indicator pip at the tip
      final tipAngle = startAngle + (sweepAngle * fraction);
      final tipX = center.dx + radius * cos(tipAngle);
      final tipY = center.dy + radius * sin(tipAngle);

      final glowPaint = Paint()
        ..color = activeColor.withValues(alpha: 0.5 + pulseValue * 0.4)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(tipX, tipY), 7 + pulseValue * 2, glowPaint);

      final pipPaint = Paint()
        ..color = AtlasTheme.textOnInk
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(tipX, tipY), 4, pipPaint);
    }

    // Tick marks around dial
    final tickPaint = Paint()
      ..color = trackColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.5;

    for (int i = 0; i <= 8; i++) {
      final angle = startAngle + (sweepAngle * (i / 8));
      final p1 = Offset(
        center.dx + (radius - 14) * cos(angle),
        center.dy + (radius - 14) * sin(angle),
      );
      final p2 = Offset(
        center.dx + (radius - 8) * cos(angle),
        center.dy + (radius - 8) * sin(angle),
      );
      canvas.drawLine(p1, p2, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.stage != stage ||
        oldDelegate.pulseValue != pulseValue ||
        oldDelegate.activeColor != activeColor;
  }
}
