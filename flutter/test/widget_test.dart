// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mosaic_vpn/app/app_shell.dart';

void main() {
  testWidgets('App shell renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: AppShell()),
      ),
    );
    // Allow async providers to settle.
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // App shell should render the Dashboard tab header.
    expect(find.text('Dashboard'), findsWidgets);
  });
}
