import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks the application lifecycle state globally.
///
/// Used by polling timers, animations, and background workers to pause
/// or reduce frequency when the application is minimized, screen is off,
/// or user is in another app.
class AppLifecycleNotifier extends StateNotifier<AppLifecycleState>
    with WidgetsBindingObserver {
  AppLifecycleNotifier() : super(WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    this.state = state;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

final appLifecycleProvider =
    StateNotifierProvider<AppLifecycleNotifier, AppLifecycleState>((ref) {
  return AppLifecycleNotifier();
});

/// Returns true when the app is in the background or hidden.
final isAppBackgroundedProvider = Provider<bool>((ref) {
  final state = ref.watch(appLifecycleProvider);
  return state == AppLifecycleState.paused ||
      state == AppLifecycleState.inactive ||
      state == AppLifecycleState.hidden;
});
