import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/atlas_theme.dart';
import '../core/providers/vpn_providers.dart';
import '../features/onboarding/onboarding_wizard.dart';
import 'app_shell.dart';

/// Root app widget.
///
/// Watches themeModeProvider (q8) to switch between dark/light themes.
/// Watches languageProvider to switch locale (en/ru/system).
class MosaicApp extends ConsumerWidget {
  const MosaicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);
    final onboarding = ref.watch(onboardingProvider);

    final ThemeMode mode;
    switch (themeMode) {
      case 'dark':
        mode = ThemeMode.dark;
        break;
      case 'light':
        mode = ThemeMode.light;
        break;
      default:
        mode = ThemeMode.system;
    }

    late Locale locale;
    switch (language) {
      case 'en':
        locale = const Locale('en');
        break;
      case 'ru':
        locale = const Locale('ru');
        break;
      default:
        locale = WidgetsBinding.instance.platformDispatcher.locale;
    }

    return MaterialApp(
      title: 'MosaicVPN',
      debugShowCheckedModeBanner: false,
      theme: AtlasTheme.themeData,
      darkTheme: AtlasTheme.darkThemeData,
      themeMode: mode,
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: onboarding.when(
        data: (needed) => needed
            ? OnboardingWizard(
                onDone: () => ref.invalidate(onboardingProvider),
              )
            : const AppShell(),
        loading: () => const AppShell(),
        error: (_, __) => const AppShell(),
      ),
    );
  }
}

/// Whether the first-launch setup wizard should run. Android-only for now:
/// desktop builds already target power users.
final onboardingProvider = FutureProvider<bool>((ref) async {
  final storage = await SharedPreferences.getInstance();
  return !(storage.getBool('mosaic.onboarding_done.v1') ?? false);
});
