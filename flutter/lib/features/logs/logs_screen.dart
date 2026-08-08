import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/theme/atlas_theme.dart';
import '../../core/providers/logs_provider.dart';

/// Logs screen — a live auto-scrolling console showing daemon/core logs.
class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _autoScroll() {
    if (!_scrollController.hasClients) return;
    final logsState = ref.read(logsProvider);
    if (!logsState.autoScroll) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _entriesToText() {
    final entries = ref.read(logsProvider).filtered;
    return entries
        .map((e) => '${e.formattedTime} ${e.level.padRight(5)} ${e.message}')
        .join('\n');
  }

  Future<void> _copyAll() async {
    final text = _entriesToText();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Copied ${ref.read(logsProvider).filtered.length} lines to clipboard')),
      );
    }
  }

  Future<void> _saveToFile() async {
    final text = _entriesToText();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final now = DateTime.now();
      final fileName =
          'mosaicbox_logs_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved: $fileName'),
            action: SnackBarAction(
              label: 'Open folder',
              onPressed: () {
                Process.start('explorer', ['/select,', file.path],
                    runInShell: true);
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        final errText = 'Save failed: $e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 10),
            content: SelectableText(
              errText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            action: SnackBarAction(
              label: 'Copy',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: errText));
              },
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    final logsState = ref.watch(logsProvider);
    final entries = logsState.filtered;

    // Auto-scroll on new entries
    ref.listen(logsProvider.select((s) => s.entries.length), (_, __) {
      _autoScroll();
    });

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with controls
          Row(
            children: [
              Text(
                'Console',
                style: TextStyle(
                  fontFamily: AtlasTheme.serifFamily,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${logsState.entries.length} lines',
                style: TextStyle(
                  fontFamily: AtlasTheme.monoFamily,
                  fontSize: 11,
                  color: c.textMuted,
                ),
              ),
              const Spacer(),

              // Level filter dropdown
              _LevelFilter(
                current: logsState.levelFilter,
                onChanged: (v) =>
                    ref.read(logsProvider.notifier).setLevelFilter(v),
              ),
              const SizedBox(width: 8),

              // Auto-scroll toggle
              _ToolButton(
                icon: logsState.autoScroll
                    ? Icons.vertical_align_bottom
                    : Icons.vertical_align_bottom_outlined,
                label: 'Auto',
                active: logsState.autoScroll,
                onPressed: () =>
                    ref.read(logsProvider.notifier).toggleAutoScroll(),
              ),
              const SizedBox(width: 8),

              // Copy all button
              _ToolButton(
                icon: Icons.copy,
                label: 'Copy',
                active: false,
                onPressed: _copyAll,
              ),
              const SizedBox(width: 8),

              // Save to file button
              _ToolButton(
                icon: Icons.save_alt,
                label: 'Save',
                active: false,
                onPressed: _saveToFile,
              ),
              const SizedBox(width: 8),

              // Clear button
              _ToolButton(
                icon: Icons.delete_outline,
                label: 'Clear',
                active: false,
                onPressed: () => ref.read(logsProvider.notifier).clear(),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Console body — selectable for manual copy
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0D0E0F),
                borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
                border: Border.all(color: c.border),
              ),
              child: entries.isEmpty
                  ? Center(
                      child: Text(
                        'Waiting for log output…',
                        style: TextStyle(
                          fontFamily: AtlasTheme.monoFamily,
                          fontSize: 12,
                          color: c.textMuted,
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          itemCount: entries.length,
                          itemExtent: 18,
                          itemBuilder: (context, i) {
                            final e = entries[i];
                            return _LogLine(entry: e);
                          },
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single log line — monospace, colored level tag, timestamp prefix.
class _LogLine extends StatelessWidget {
  final LogEntry entry;
  const _LogLine({required this.entry});

  Color get _levelColor {
    switch (entry.level) {
      case 'ERROR':
        return const Color(0xFFEF4444);
      case 'WARN':
        return const Color(0xFFF59E0B);
      case 'DEBUG':
        return const Color(0xFF6B7280);
      case 'INFO':
      default:
        return const Color(0xFF22C55E);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(
          fontFamily: AtlasTheme.monoFamily,
          fontSize: 11.5,
          height: 1.35,
        ),
        children: [
          TextSpan(
            text: '${entry.formattedTime} ',
            style: const TextStyle(color: Color(0xFF4B5563)),
          ),
          TextSpan(
            text: '${entry.level.padRight(5)} ',
            style: TextStyle(
              color: _levelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: entry.message,
            style: const TextStyle(color: Color(0xFFD1D5DB)),
          ),
        ],
      ),
    );
  }
}

/// Level filter dropdown.
class _LevelFilter extends StatelessWidget {
  final String? current;
  final ValueChanged<String?> onChanged;
  const _LevelFilter({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.bgElevated,
        borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: current,
          isDense: true,
          dropdownColor: Theme.of(context).cardColor,
          icon: Icon(Icons.filter_list, size: 14, color: c.textMuted),
          style: TextStyle(
            fontFamily: AtlasTheme.monoFamily,
            fontSize: 11,
            color: Theme.of(context).textTheme.bodyMedium?.color,
          ),
          items: const [
            DropdownMenuItem(value: null, child: Text('All')),
            DropdownMenuItem(value: 'ERROR', child: Text('ERROR')),
            DropdownMenuItem(value: 'WARN', child: Text('WARN')),
            DropdownMenuItem(value: 'INFO', child: Text('INFO')),
            DropdownMenuItem(value: 'DEBUG', child: Text('DEBUG')),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Small tool button.
class _ToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = ThemeColors.of(context);
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color:
              active ? AtlasTheme.accent.withValues(alpha: 0.12) : c.bgElevated,
          borderRadius: BorderRadius.circular(AtlasTheme.radiusSm),
          border: Border.all(
            color: active ? AtlasTheme.accent : c.border,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14, color: active ? AtlasTheme.accent : c.textMuted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontFamily: AtlasTheme.monoFamily,
                fontSize: 11,
                color: active ? AtlasTheme.accent : c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
