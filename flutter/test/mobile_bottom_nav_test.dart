import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/app/app_shell.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/providers/vpn_providers.dart';
import 'package:mosaic_vpn/core/api/mock_daemon_api.dart';
import 'package:mosaic_vpn/core/models/models.dart';

void main() {
  setUp(() {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.android;
  });
  tearDown(() {
    AppPlatform.debugTargetPlatformOverride = null;
  });

  const targetWidths = [320.0, 360.0, 390.0];
  const targetScales = [1.0, 1.2, 1.35, 1.5];

  for (final width in targetWidths) {
    for (final scale in targetScales) {
      testWidgets('bottom nav does not truncate or overflow at width $width textScale $scale',
          (tester) async {
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final mock = MockDaemonApi();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              daemonApiProvider.overrideWithValue(mock),
              vpnStatusProvider.overrideWith((ref) => Stream.value(VpnStatus())),
            ],
            child: MaterialApp(
              locale: const Locale('ru'),
              supportedLocales: const [Locale('en'), Locale('ru')],
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              builder: (context, child) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: child!,
                );
              },
              home: const AppShell(),
            ),
          ),
        );

        for (var step = 0; step < 5; step++) {
          await tester.pump(const Duration(milliseconds: 150));
        }

        expect(tester.takeException(), isNull);

        final barFinder = find.byType(BottomNavigationBar);
        expect(barFinder, findsOneWidget);

        final richTexts = find.descendant(
          of: barFinder,
          matching: find.byType(RichText),
        );

        final expectedLabels = ['Подключение', 'Маршруты', 'Аккаунты', 'Ещё'];
        final foundLabels = <String>[];

        for (final elem in richTexts.evaluate()) {
          final rp = elem.renderObject as RenderParagraph;
          final text = rp.text.toPlainText();
          if (expectedLabels.contains(text)) {
            foundLabels.add(text);
            expect(
              rp.didExceedMaxLines,
              isFalse,
              reason: 'Label "$text" truncated at width $width with textScale $scale (size: ${rp.size})',
            );
          }
        }

        expect(foundLabels.toSet(), equals(expectedLabels.toSet()),
            reason: 'All bottom navigation destinations must be rendered');
      });
    }
  }
}
