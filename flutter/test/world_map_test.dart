import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mosaic_vpn/shared/widgets/world_map_widget.dart';

void main() {
  testWidgets('WorldMapWidget renders correctly within constraints', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: WorldMapWidget(
              pins: const [],
              bearing: 'N 45° W',
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    // Verify WorldMapWidget builds without exceptions
    expect(find.byType(WorldMapWidget), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('N 45° W'), findsOneWidget);
  });
}
