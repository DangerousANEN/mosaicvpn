/// Formatting utilities for displaying bytes, speeds, durations.
library;

import 'package:intl/intl.dart';

/// Format bytes into human-readable string (B, KB, MB, GB).
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = (bytes.bitLength - 1) ~/ 10;
  final idx = i < units.length ? i : units.length - 1;
  final value = bytes / (1 << (idx * 10));
  return '${value.toStringAsFixed(idx == 0 ? 0 : 1)} ${units[idx]}';
}

/// Format bits per second into Mbps.
String formatSpeed(int bps) {
  if (bps <= 0) return '0 Mbps';
  final mbps = bps / 1000000;
  if (mbps < 1) return '${(bps / 1000).toStringAsFixed(0)} Kbps';
  return '${mbps.toStringAsFixed(1)} Mbps';
}

/// Format a duration into compact string.
String formatDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  if (d.inHours < 24) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

/// Format a timestamp for display.
String formatTime(DateTime? t) {
  if (t == null) return '—';
  return DateFormat('MMM d, HH:mm').format(t);
}

/// Format a timestamp with seconds.
String formatTimePrecise(DateTime? t) {
  if (t == null) return '—';
  return DateFormat('MMM d, HH:mm:ss').format(t);
}

/// Relative time (e.g. "3 min ago").
String formatRelative(DateTime? t) {
  if (t == null) return 'never';
  final diff = DateTime.now().difference(t);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}
