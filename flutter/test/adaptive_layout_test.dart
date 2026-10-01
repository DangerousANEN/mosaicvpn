import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mosaic_vpn/app/app_shell.dart';

/// Adaptive layout across the widths that actually matter.
///
/// The shell used to branch on one boolean (`isWide = shortestSide > 600`), so
/// a tablet in portrait and a desktop monitor took the same path and tablets
/// got a bare 72px rail with no labels. These tests pin the three tiers to real
/// device sizes, and fail if the shell collapses back to a single threshold.
void main() {
  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AppShell()),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('phone portrait 360x640 keeps bottom navigation', (tester) async {
    await pumpAt(tester, const Size(360, 640));
    expect(find.byType(BottomNavigationBar), findsOneWidget,
        reason: 'a 360dp-wide phone must stay on the mobile layout');
  });

  testWidgets('phone portrait 411x914 stays compact', (tester) async {
    await pumpAt(tester, const Size(411, 914));
    expect(find.byType(BottomNavigationBar), findsOneWidget,
        reason: 'a modern tall phone must not be promoted to the rail layout');
  });

  testWidgets('tablet portrait 800x1280 shows the rail', (tester) async {
    await pumpAt(tester, const Size(800, 1280));
    expect(find.byType(BottomNavigationBar), findsNothing,
        reason: 'a tablet gets the rail instead of bottom navigation');
  });

  testWidgets('tablet landscape 1280x800 shows the rail', (tester) async {
    await pumpAt(tester, const Size(1280, 800));
    expect(find.byType(BottomNavigationBar), findsNothing,
        reason: 'a landscape tablet gets the rail instead of bottom navigation');
  });

  testWidgets('laptop 1366x768 shows the rail', (tester) async {
    await pumpAt(tester, const Size(1366, 768));
    expect(find.byType(BottomNavigationBar), findsNothing,
        reason: 'a laptop window must use the rail, not the phone tab bar');
  });

  testWidgets('phone landscape 640x360 stays compact', (tester) async {
    await pumpAt(tester, const Size(640, 360));
    expect(find.byType(BottomNavigationBar), findsOneWidget,
        reason: 'shortestSide drives the tier, so a landscape phone stays mobile');
  });
}
