// Run inside the Linux QA sandbox with --update-goldens --tags visual.
// Real fonts are explicitly loaded: the default Ahem squares are not proof.
@Tags(['visual'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/core/platform/app_platform.dart';
import 'package:mosaic_vpn/core/theme/atlas_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dashboard_connect_ownership_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const directory = '/usr/share/fonts/truetype/dejavu';
    final sans = ByteData.sublistView(await File('$directory/DejaVuSans.ttf').readAsBytes());
    final serif = ByteData.sublistView(await File('$directory/DejaVuSerif.ttf').readAsBytes());
    for (final family in ['Roboto', 'sans-serif', 'Ahem', 'monospace']) {
      await (FontLoader(family)..addFont(Future.value(sans))).load();
    }
    await (FontLoader('serif')..addFont(Future.value(serif))).load();
    await (FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
  });
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  for (final dark in [false, true]) {
  for (final mobile in [true, false]) {
    testWidgets('readable cancellation flow ${mobile ? 'phone' : 'desktop'} dark=$dark', (tester) async {
      final api = ControlledConnectApi();
      await mountConnectDashboard(tester, api,
          size: mobile ? const Size(390, 844) : const Size(1200, 900),
          theme: dark ? AtlasTheme.darkThemeData : AtlasTheme.themeData);
      final semantics = tester.ensureSemantics();
      final name = '${mobile ? 'phone' : 'desktop'}_${dark ? 'dark' : 'light'}';
      try {
        if (mobile) {
          await tester.tap(find.bySemanticsLabel('Подключить VPN'));
          await settleDashboard(tester);
          expect(find.bySemanticsLabel('Отменить подключение'), findsOneWidget);
        } else {
          await tapConnectAction(tester);
          expect(find.text('Cancel connection'), findsOneWidget);
        }
        expect(api.connects, hasLength(1));
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('goldens/cancel_${name}_pending.png'));
        if (mobile) {
          await tester.tap(find.bySemanticsLabel('Отменить подключение'));
          await settleDashboard(tester);
        } else {
          await tapConnectAction(tester);
        }
        api.connects.single.complete();
        await settleDashboard(tester);
        expect(api.disconnects, hasLength(1));
        expect(find.byType(SnackBar), findsNothing);
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile('goldens/cancel_${name}_cancelled.png'));
      } finally {
        semantics.dispose();
      }
    });
  }
  }
}
