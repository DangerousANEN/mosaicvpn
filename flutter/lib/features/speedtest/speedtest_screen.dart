import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';
import 'speedtest_models.dart';
import 'speedtest_service.dart';
import 'speedtest_gauge.dart';
import 'speedtest_stage_tracker.dart';

/// SpeedTest screen — bandwidth testing with real-time stage progress and live measurements.
class SpeedTestScreen extends ConsumerStatefulWidget {
  final SpeedTestService? service;

  const SpeedTestScreen({
    super.key,
    this.service,
  });

  @override
  ConsumerState<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

enum _TestTarget { current, group }

class _SpeedTestScreenState extends ConsumerState<SpeedTestScreen> {
  _TestTarget _target = _TestTarget.current;
  bool _running = false;
  SpeedTestProgress _progress = const SpeedTestProgress();
  StreamSubscription<SpeedTestProgress>? _progressSub;
  SpeedTestService? _activeService;

  // Multi-server group test states
  List<SpeedTestResult> _groupResults = [];
  int _groupTotal = 0;
  int _groupCurrentIndex = 0;
  String _currentServerName = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _activeService?.cancel();
    super.dispose();
  }

  SpeedTestService _getService() {
    return widget.service ?? ref.read(speedTestServiceProvider);
  }

  void _runCurrentTest() async {
    final service = _getService();
    _activeService = service;

    setState(() {
      _running = true;
      _progress = const SpeedTestProgress(stage: SpeedTestStage.idle);
      _groupResults = [];
    });

    _progressSub?.cancel();
    _progressSub = service.progressStream.listen((p) {
      if (mounted) {
        setState(() => _progress = p);
      }
    });

    try {
      final vpnStatus = ref.read(vpnStatusProvider);
      final activeServerName = vpnStatus.valueOrNull?.server?.name ?? '';

      final result = await service.runTest(
        target: 'current',
        serverName: activeServerName.isNotEmpty ? activeServerName : null,
      );

      if (mounted) {
        setState(() {
          _progress = _progress.copyWith(
            result: result,
            stage: service.currentProgress.stage == SpeedTestStage.cancelled
                ? SpeedTestStage.cancelled
                : result.error.isEmpty
                    ? SpeedTestStage.completed
                    : SpeedTestStage.failed,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = _progress.copyWith(
            stage: SpeedTestStage.failed,
            error: e.toString(),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _runGroupTest() async {
    setState(() {
      _running = true;
      _progress = const SpeedTestProgress(
        stage: SpeedTestStage.ping,
        statusMessage: 'Discovering server fleet…',
        totalProgress: 0.05,
      );
      _groupResults = [];
      _groupTotal = 0;
      _groupCurrentIndex = 0;
    });

    try {
      final api = ref.read(daemonApiProvider);
      final servers = await api.listServers();

      if (servers.isEmpty) {
        // Fallback to group test on daemon directly
        final results = await api.testSpeedGroup('all');
        if (mounted) {
          setState(() {
            _groupResults = results;
            _progress = _progress.copyWith(
              stage: SpeedTestStage.completed,
              totalProgress: 1.0,
              statusMessage: 'Group test completed',
            );
          });
        }
        return;
      }

      setState(() {
        _groupTotal = servers.length;
      });

      final results = <SpeedTestResult>[];
      for (int i = 0; i < servers.length; i++) {
        if (!_running) break;
        final s = servers[i];
        if (mounted) {
          setState(() {
            _groupCurrentIndex = i + 1;
            _currentServerName = s.name.isNotEmpty ? s.name : s.id;
            _progress = _progress.copyWith(
              stage: SpeedTestStage.download,
              totalProgress: (i / servers.length),
              statusMessage:
                  'Testing server ${i + 1} of ${servers.length}: $_currentServerName',
            );
          });
        }

        try {
          final res = await api.testSpeed(s.id, testFor: const Duration(seconds: 2));
          results.add(res);
          if (mounted) {
            setState(() {
              _groupResults = List.from(results);
            });
          }
        } catch (err) {
          results.add(SpeedTestResult(
            target: s.id,
            serverName: s.name,
            downloadBps: 0,
            uploadBps: 0,
            latencyMS: 0,
            jitterMS: 0,
            durationSeconds: 0,
            error: err.toString(),
          ));
        }
      }

      if (mounted) {
        setState(() {
          _progress = _progress.copyWith(
            stage: SpeedTestStage.completed,
            totalProgress: 1.0,
            statusMessage: 'Tested ${results.length} servers',
          );
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = _progress.copyWith(
            stage: SpeedTestStage.failed,
            error: e.toString(),
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  void _cancelTest() {
    if (_target == _TestTarget.current) {
      _activeService?.cancel();
    }
    setState(() {
      _running = false;
      _progress = _progress.copyWith(
        stage: SpeedTestStage.cancelled,
        statusMessage: 'Test stopped by user',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    ref.watch(serversProvider);
    ref.watch(vpnStatusProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Speed Test',
            subtitle: 'Real-time bandwidth and latency diagnostics',
          ),
          const SizedBox(height: 20),

          // Configuration card
          AtlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Test Target',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    if (_running)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: AtlasTheme.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: AtlasTheme.accent.withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: AtlasTheme.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Text(
                              'MEASURING',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: AtlasTheme.accent,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                SegmentedButton<_TestTarget>(
                  segments: const [
                    ButtonSegment(
                      value: _TestTarget.current,
                      label: Text('Current Connection'),
                      icon: Icon(Icons.wifi, size: 16),
                    ),
                    ButtonSegment(
                      value: _TestTarget.group,
                      label: Text('All Servers (Group Test)'),
                      icon: Icon(Icons.dns, size: 16),
                    ),
                  ],
                  selected: {_target},
                  onSelectionChanged: _running
                      ? null
                      : (s) => setState(() => _target = s.first),
                ),
                const SizedBox(height: 16),

                // Action buttons (Start / Cancel / Retest)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _running
                            ? null
                            : (_target == _TestTarget.current
                                ? _runCurrentTest
                                : _runGroupTest),
                        icon: const Icon(Icons.speed, size: 18),
                        label: Text(
                          _progress.isCompleted ? 'Run Again' : 'Start Test',
                        ),
                      ),
                    ),
                    if (_running) ...[
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _cancelTest,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text('Cancel'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Live Progress and Gauge display during test or after completion
          if (_target == _TestTarget.current) ...[
            _buildCurrentConnectionView(c),
          ] else ...[
            _buildGroupTestView(c),
          ],
        ],
      ),
    );
  }

  Widget _buildCurrentConnectionView(ThemeColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Live Stage Tracker
        SpeedtestStageTracker(progress: _progress),
        const SizedBox(height: 20),

        // Live Overall Progress Bar
        if (_running) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: _progress.totalProgress.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: c.border.withValues(alpha: 0.3),
              valueColor: AlwaysStoppedAnimation<Color>(
                _progress.stage == SpeedTestStage.ping
                    ? AtlasTheme.warning
                    : (_progress.stage == SpeedTestStage.download
                        ? AtlasTheme.success
                        : AtlasTheme.accent),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _progress.statusMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: c.textSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '${(_progress.totalProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 12,
                  color: c.textMuted,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        // Central Speedometer Gauge Card
        AtlasCard(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SpeedtestGauge(progress: _progress, size: 210),
                  if (_progress.transferredBytes > 0 && _running) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${formatBytes(_progress.transferredBytes)} transferred',
                      style: TextStyle(
                        fontFamily: AtlasTheme.monoFamily,
                        fontSize: 12,
                        color: c.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 20),

        // Live or Final Stat Tiles
        _buildStatGrid(c),

        if (_progress.result != null && !_running) ...[
          const SizedBox(height: 20),
          _buildDetailsCard(_progress.result!, c),
        ],
      ],
    );
  }

  Widget _buildStatGrid(ThemeColors c) {
    final res = _progress.result;
    final int downloadBps = res?.downloadBps ?? _progress.downloadBps ?? 0;
    final int uploadBps = res?.uploadBps ?? _progress.uploadBps ?? 0;
    final int latencyMs = res?.latencyMS ?? _progress.latencyMs ?? 0;
    final int jitterMs = res?.jitterMS ?? _progress.jitterMs ?? 0;

    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.7,
      children: [
        StatTile(
          label: 'Download',
          value: downloadBps > 0 ? formatSpeed(downloadBps) : '—',
          icon: Icons.south,
          valueColor: AtlasTheme.success,
        ),
        StatTile(
          label: 'Upload',
          value: uploadBps > 0 ? formatSpeed(uploadBps) : '—',
          icon: Icons.north,
          valueColor: AtlasTheme.accent,
        ),
        StatTile(
          label: 'Ping (RTT)',
          value: latencyMs > 0 ? '$latencyMs' : '—',
          unit: latencyMs > 0 ? 'ms' : '',
          icon: Icons.bolt,
          valueColor: AtlasTheme.warning,
        ),
        StatTile(
          label: 'Jitter',
          value: jitterMs > 0 ? '±$jitterMs' : (latencyMs > 0 ? '0' : '—'),
          unit: latencyMs > 0 ? 'ms' : '',
          icon: Icons.sync_alt,
        ),
      ],
    );
  }

  Widget _buildDetailsCard(SpeedTestResult r, ThemeColors c) {
    return AtlasCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Test Details',
            style: TextStyle(
              fontFamily: AtlasTheme.serifFamily,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          _detailRow('Target', r.target, c),
          if (r.serverName.isNotEmpty) _detailRow('Server', r.serverName, c),
          _detailRow('Download Speed', formatSpeed(r.downloadBps), c),
          _detailRow('Upload Speed', formatSpeed(r.uploadBps), c),
          _detailRow('Latency', '${r.latencyMS} ms', c),
          _detailRow('Jitter', '${r.jitterMS} ms', c),
          _detailRow(
              'Test Duration', '${r.durationSeconds.toStringAsFixed(1)} s', c),
          if (r.error.isNotEmpty)
            _detailRow('Status', r.error, c, isError: true),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, ThemeColors c,
      {bool isError = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: c.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 12,
                color: isError ? AtlasTheme.error : c.textPrimary,
                fontWeight: isError ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupTestView(ThemeColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_running) ...[
          AtlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Testing Server Fleet',
                      style: TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: c.textPrimary,
                      ),
                    ),
                    Text(
                      '$_groupCurrentIndex / $_groupTotal',
                      style: TextStyle(
                        fontFamily: AtlasTheme.monoFamily,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AtlasTheme.accent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _progress.statusMessage,
                  style: TextStyle(fontSize: 12, color: c.textSecondary),
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _groupTotal > 0
                        ? (_groupCurrentIndex / _groupTotal).clamp(0.0, 1.0)
                        : null,
                    minHeight: 8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        if (_groupResults.isNotEmpty) ...[
          AtlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Fleet Speed Results (${_groupResults.length})',
                  style: const TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _groupResults.length,
                  separatorBuilder: (_, __) => Divider(
                    color: c.border.withValues(alpha: 0.5),
                    height: 16,
                  ),
                  itemBuilder: (context, index) {
                    final res = _groupResults[index];
                    return Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            res.serverName.isNotEmpty
                                ? res.serverName
                                : res.target,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '${res.latencyMS} ms',
                            style: TextStyle(
                              fontFamily: AtlasTheme.monoFamily,
                              fontSize: 12,
                              color: AtlasTheme.warning,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            formatSpeed(res.downloadBps),
                            style: const TextStyle(
                              fontFamily: AtlasTheme.monoFamily,
                              fontSize: 12,
                              color: AtlasTheme.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            formatSpeed(res.uploadBps),
                            style: const TextStyle(
                              fontFamily: AtlasTheme.monoFamily,
                              fontSize: 12,
                              color: AtlasTheme.accent,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ] else if (!_running) ...[
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.dns, size: 48, color: c.textMuted),
                  const SizedBox(height: 16),
                  Text(
                    'No group results yet.',
                    style: TextStyle(
                      fontFamily: AtlasTheme.serifFamily,
                      fontSize: 16,
                      color: c.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Click Start Test to benchmark all servers.',
                    style: TextStyle(fontSize: 13, color: c.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
