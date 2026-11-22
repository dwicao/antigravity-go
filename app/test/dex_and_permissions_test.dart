import 'package:antigravity_go/app.dart';
import 'package:antigravity_go/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('HomeShell renders 3-pane desktop/DeX layout at 1280px width', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: AntigravityGoApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Agent Controls'), findsOneWidget);
    expect(find.text('Enter sends'), findsOneWidget);
  });

  testWidgets('SettingsPage shows All Files Access and Permissions section', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SettingsPage(),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(find.text('All Files Access'), 200);
    expect(find.text('Android Permissions & Samsung DeX'), findsOneWidget);
    expect(find.text('All Files Access'), findsOneWidget);
  });
}
