import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/models/traffic_stats.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';

/// Stats screen — traffic charts and connection metrics.
class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  final List<FlSpot> _upSpots = [];
  final List<FlSpot> _downSpots = [];
  static const _maxPoints = 60;
  Timer? _timer;
  TrafficStats? _lastStats;

  @override
  void initState() {
    super.initState();
    // Start a single timer that ticks once per second.
    // The timer reads the latest cached stats and adds a chart point.
    // We avoid per-stream-tick setState — only the timer calls setState.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final stats = _lastStats;
      if (stats == null || !mounted) return;
      setState(() => _addPoint(stats.uploadSpeed, stats.downloadSpeed));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// Add a data point.  X coordinates are kept normalised to 0..N-1
  /// in-place (no per-tick list copy).
  void _addPoint(int upSpeed, int downSpeed) {
    final x = _upSpots.length.toDouble();
    _upSpots.add(FlSpot(x, upSpeed.toDouble()));
    _downSpots.add(FlSpot(x, downSpeed.toDouble()));
    // Trim oldest in-place — O(1) amortised, no new list
    if (_upSpots.length > _maxPoints) {
      _upSpots.removeAt(0);
      _downSpots.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final statsAsync = ref.watch(trafficStatsProvider);

    // Cache latest stats for the timer (fires once per change, NOT during build).
    // No per-tick setState here — the timer in initState drives chart updates.
    ref.listen<AsyncValue<TrafficStats>>(trafficStatsProvider, (_, next) {
      next.whenData((stats) => _lastStats = stats);
    });

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Statistics',
            subtitle: 'Traffic throughput and connection metrics',
            action: TextButton.icon(
              onPressed: () async {
                _timer?.cancel();
                final api = ref.read(daemonApiProvider);
                try {
                  await api.resetStats();
                  ref.invalidate(trafficStatsProvider);
                  setState(() {
                    _upSpots.clear();
                    _downSpots.clear();
                  });
                } catch (e) {
                  debugPrint('resetStats failed: $e');
                }
                // Restart timer
                _timer = Timer.periodic(const Duration(seconds: 1), (_) {
                  final stats = _lastStats;
                  if (stats == null || !mounted) return;
                  setState(
                      () => _addPoint(stats.uploadSpeed, stats.downloadSpeed));
                });
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset'),
            ),
          ),
          const SizedBox(height: 16),

          // Top stat tiles
          statsAsync.when(
            data: (stats) => GridView.count(
              shrinkWrap: true,
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.2,
              children: [
                StatTile(
                  label: 'Total Upload',
                  value: formatBytes(stats.totalUpload),
                  icon: Icons.north,
                  valueColor: AtlasTheme.accent,
                ),
                StatTile(
                  label: 'Total Download',
                  value: formatBytes(stats.totalDownload),
                  icon: Icons.south,
                  valueColor: AtlasTheme.success,
                ),
                StatTile(
                  label: 'Active Connections',
                  value: '${stats.activeConnections}',
                  icon: Icons.lan,
                ),
                StatTile(
                  label: 'Uptime',
                  value: formatDuration(stats.uptime),
                  icon: Icons.timer,
                ),
              ],
            ),
            loading: () => GridView.count(
              shrinkWrap: true,
              crossAxisCount: 4,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 2.2,
              children: List.generate(4, (_) => const _SkeletonTile()),
            ),
            error: (e, _) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 48, color: c.textMuted),
                  const SizedBox(height: 12),
                  Text('Unable to load statistics',
                      style: TextStyle(color: c.textMuted, fontSize: 14)),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Traffic chart
          Expanded(
            child: AtlasCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Throughput',
                        style: TextStyle(
                          fontFamily: AtlasTheme.serifFamily,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      _legendDot(AtlasTheme.accent, 'Upload'),
                      const SizedBox(width: 16),
                      _legendDot(AtlasTheme.success, 'Download'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _upSpots.length < 2
                        ? Center(
                            child: Text(
                              'Waiting for data…',
                              style: TextStyle(
                                color: c.textMuted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          )
                        : LineChart(
                            LineChartData(
                              minX: 0,
                              maxX: _upSpots.isEmpty
                                  ? 1.0
                                  : (_upSpots.length - 1).toDouble(),
                              minY: 0,
                              maxY: _maxY,
                              gridData: FlGridData(
                                show: true,
                                drawVerticalLine: false,
                                getDrawingHorizontalLine: (v) =>
                                    _drawGrid(v, c),
                              ),
                              titlesData: FlTitlesData(
                                show: true,
                                leftTitles: AxisTitles(
                                  sideTitles: SideTitles(
                                    showTitles: true,
                                    reservedSize: 48,
                                    getTitlesWidget: (v, meta) =>
                                        _leftTitle(v, meta, c),
                                  ),
                                ),
                                bottomTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                topTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                                rightTitles: AxisTitles(
                                  sideTitles: SideTitles(showTitles: false),
                                ),
                              ),
                              borderData: FlBorderData(show: false),
                              lineBarsData: [
                                _line(_upSpots, AtlasTheme.accent),
                                _line(_downSpots, AtlasTheme.success),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  double get _maxY {
    final all = [..._upSpots, ..._downSpots];
    if (all.isEmpty) return 100;
    final maxVal = all.map((s) => s.y).reduce(max);
    if (maxVal <= 0) return 100;
    return maxVal * 1.2;
  }

  LineChartBarData _line(List<FlSpot> spots, Color color) => LineChartBarData(
        spots: spots,
        isCurved: false,
        color: color,
        barWidth: 2,
        isStrokeCapRound: true,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.08),
        ),
      );

  Widget _legendDot(Color color, String label) {
    final c = ThemeColors.of(context);
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: c.textSecondary),
        ),
      ],
    );
  }
}

FlLine _drawGrid(double v, ThemeColors c) => FlLine(
      color: c.border,
      strokeWidth: 1,
      dashArray: [4, 4],
    );

Widget _leftTitle(double v, TitleMeta meta, ThemeColors c) {
  return SideTitleWidget(
    axisSide: meta.axisSide,
    child: Text(
      formatBytes(v.toInt()),
      style: TextStyle(
        fontFamily: AtlasTheme.monoFamily,
        fontSize: 9,
        color: c.textMuted,
      ),
    ),
  );
}

/// Skeleton placeholder for stat tiles while loading.
class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 12,
            decoration: BoxDecoration(
              color: c.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: 120,
            height: 20,
            decoration: BoxDecoration(
              color: c.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}
