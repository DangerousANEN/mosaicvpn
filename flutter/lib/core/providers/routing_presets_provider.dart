import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/routing_preset.dart';
import '../models/preferences.dart';
import 'vpn_providers.dart';

const String _kUserPresetsKey = 'mosaic.user_routing_presets.v1';

/// All routing presets: built-ins merged with user-created ones.
final routingPresetsProvider =
    FutureProvider<List<RoutingPreset>>((ref) async {
  final storage = await SharedPreferences.getInstance();
  final raw = storage.getString(_kUserPresetsKey);
  var custom = const <RoutingPreset>[];
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw) as List;
      custom = decoded
          .whereType<Map<String, dynamic>>()
          .map(RoutingPreset.fromJson)
          .toList(growable: false);
    } on FormatException {
      custom = const [];
    }
  }
  return mergePresets(kBuiltInPresets, custom);
});

/// Persists the user preset list and invalidates the provider.
Future<void> saveUserPresets(
  WidgetRef ref,
  List<RoutingPreset> allPresets,
) async {
  final storage = await SharedPreferences.getInstance();
  final custom =
      allPresets.where((preset) => !preset.builtIn).toList(growable: false);
  await storage.setString(
    _kUserPresetsKey,
    jsonEncode([for (final p in custom) p.toJson()]),
  );
  ref.invalidate(routingPresetsProvider);
}

/// Applies a preset to daemon preferences: routing mode plus per-app lists.
/// Returns the updated Preferences object.
Future<Preferences> applyRoutingPreset(WidgetRef ref, RoutingPreset preset) async {
  final api = ref.read(daemonApiProvider);
  final current = await api.getPrefs();
  final updated = current.copyWith(
    routingMode: preset.routingMode,
    proxyPackages: preset.proxyPackages,
    bypassProcesses: preset.bypassPackages,
  );
  // setPrefs merges on top of stored JSON and returns the normalized value.
  await api.setPrefs(updated.toJson());
  ref.invalidate(prefsProvider);
  return updated;
}
