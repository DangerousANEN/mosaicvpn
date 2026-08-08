import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/vpn_providers.dart';
import '../../core/models/models.dart';
import '../../core/utils/formatters.dart';
import '../../shared/widgets/atlas_widgets.dart';

/// SpeedTest screen — bandwidth testing for servers/profiles.
class SpeedTestScreen extends ConsumerStatefulWidget {
  const SpeedTestScreen({super.key});

  @override
  ConsumerState<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

enum _TestTarget { current, group }

class _SpeedTestScreenState extends ConsumerState<SpeedTestScreen> {
  _TestTarget _target = _TestTarget.current;
  bool _running = false;
  SpeedTestResult? _result;

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    ref.watch(serversProvider); // trigger rebuild on server list change
    ref.watch(vpnStatusProvider); // trigger rebuild on status change

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Speed Test',
            subtitle: 'Bandwidth and latency diagnostics',
          ),
          const SizedBox(height: 24),

          // Test configuration
          AtlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Test Target',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                SegmentedButton<_TestTarget>(
                  segments: const [
                    ButtonSegment(
                      value: _TestTarget.current,
                      label: Text('Current Connection'),
                    ),
                    ButtonSegment(
                      value: _TestTarget.group,
                      label: Text('All Servers (Group Test)'),
                    ),
                  ],
                  selected: {_target},
                  onSelectionChanged: (s) => setState(() => _target = s.first),
                ),
                const SizedBox(height: 20),

                // Run button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _running ? null : _runTest,
                    icon: _running
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.speed, size: 18),
                    label: Text(
                      _running ? 'Running…' : 'Start Test',
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Results
          if (_result != null) _buildResults(),
          if (_result == null && !_running)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.speed, size: 48, color: c.textMuted),
                    const SizedBox(height: 16),
                    Text(
                      'No test results yet.',
                      style: TextStyle(
                        fontFamily: AtlasTheme.serifFamily,
                        fontSize: 16,
                        color: c.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Select a target and click Start Test.',
                      style: TextStyle(fontSize: 13, color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResults() {
    final r = _result!;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Result tiles
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2.0,
            children: [
              StatTile(
                label: 'Download Speed',
                value: formatSpeed(r.downloadBps),
                icon: Icons.south,
                valueColor: AtlasTheme.success,
              ),
              StatTile(
                label: 'Upload Speed',
                value: formatSpeed(r.uploadBps),
                icon: Icons.north,
                valueColor: AtlasTheme.accent,
              ),
              StatTile(
                label: 'Latency',
                value: '${r.latencyMS}',
                unit: 'ms',
                icon: Icons.bolt,
              ),
            ],
          ),
          const SizedBox(height: 24),

          // Details
          AtlasCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Details',
                  style: TextStyle(
                    fontFamily: AtlasTheme.serifFamily,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _detailRow('Target', r.target),
                _detailRow('Server', r.serverName),
                _detailRow('Download', formatSpeed(r.downloadBps)),
                _detailRow('Upload', formatSpeed(r.uploadBps)),
                _detailRow('Latency', '${r.latencyMS} ms'),
                _detailRow('Jitter', '${r.jitterMS} ms'),
                _detailRow('Test Duration',
                    '${r.durationSeconds.toStringAsFixed(1)} s'),
                if (r.error.isNotEmpty)
                  _detailRow('Error', r.error, error: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool error = false}) {
    final c = ThemeColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: c.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 12,
                color: error ? AtlasTheme.error : c.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _runTest() async {
    setState(() => _running = true);

    try {
      final api = ref.read(daemonApiProvider);
      final SpeedTestResult result;
      if (_target == _TestTarget.current) {
        result = await api.speedTest();
      } else {
        final groupResults = await api.testSpeedGroup('all');
        result = groupResults.isNotEmpty
            ? groupResults.first
            : await api.speedTest();
      }

      if (mounted) setState(() => _result = result);
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = SpeedTestResult(
            target: _target == _TestTarget.current ? 'current' : 'group',
            serverName: '',
            downloadBps: 0,
            uploadBps: 0,
            latencyMS: 0,
            jitterMS: 0,
            durationSeconds: 0,
            error: e.toString(),
          );
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
}
