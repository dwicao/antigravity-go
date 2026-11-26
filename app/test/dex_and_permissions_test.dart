import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/app.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/ui/settings/settings_page.dart';
import 'package:antigravity_go/ui/shell/quick_panel.dart';
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

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Automations'), findsOneWidget);
    expect(find.text('Customizations'), findsOneWidget);
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

  test('Legacy saved auto preset and exec mode are repaired for Android', () async {
    SharedPreferences.setMockInitialValues({
      'agy_permission_preset': 'auto',
      'agy_exec_mode': 'auto',
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(settingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final repaired = container.read(settingsProvider);
    expect(repaired.permissionPreset, AntigravityPermissionPreset.turbo);
    expect(repaired.executionMode, 'default');
  });

  testWidgets('QuickPanel hides Auto (Sandbox) execution mode on local Android', (tester) async {
    SharedPreferences.setMockInitialValues({'agy_exec_mode': 'auto'});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: QuickPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Execution Mode'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Auto (Sandbox)'), findsNothing);
    expect(find.textContaining('Standard —'), findsWidgets);
  });

  testWidgets('SettingsPage renders cleanly on compact 360px phone viewport without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Appearance'), 160);
    expect(find.text('Appearance'), findsOneWidget);
    await tester.scrollUntilVisible(find.text("What's New"), 160);
    expect(find.text("What's New"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
