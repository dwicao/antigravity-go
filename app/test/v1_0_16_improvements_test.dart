import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/phone/phone_bridge.dart';
import 'package:antigravity_go/remote/ssh_host.dart';
import 'package:antigravity_go/state/automations_state.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/ui/phone/phone_control_page.dart';
import 'package:antigravity_go/ui/settings/runtime_setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ChatMessage.toJson redacts secrets in text, thoughts, and tool parameters before persistence', () {
    final msg = ChatMessage(
      id: 'm-secret',
      role: ChatRole.assistant,
      text: 'Using token ghp_1234567890abcdefghijklmnop and key sk-abcdef1234567890abcdef',
      thoughts: 'Bearer my_super_secret_token_value',
      createdAt: DateTime(2026, 11, 23, 19, 0),
      tools: const [
        ChatToolStep(
          id: 't1',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'curl -H "Authorization: Bearer super_secret_header_value" https://example.com'},
          output: 'Token: AIzaSyDummySecretValue1234567890abcdef',
        ),
      ],
    );

    final encoded = msg.toJson();
    expect(encoded['text'] as String, isNot(contains('1234567890abcdefghijklmnop')));
    expect(encoded['text'] as String, isNot(contains('abcdef1234567890abcdef')));
    expect(encoded['thoughts'] as String, isNot(contains('my_super_secret_token_value')));
    final toolsJson = encoded['tools'] as List<dynamic>;
    final toolMap = toolsJson.first as Map<String, dynamic>;
    final paramsMap = toolMap['parameters'] as Map<String, dynamic>;
    expect(paramsMap['CommandLine'] as String, isNot(contains('super_secret_header_value')));
    expect(toolMap['output'] as String, isNot(contains('DummySecretValue1234567890abcdef')));
  });

  test('ChatMessageStore save and load roundtrip works cleanly via fallback', () async {
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.user,
      text: 'Hello world',
      createdAt: DateTime(2026, 11, 23, 19, 5),
    );
    await ChatMessageStore.instance.save('sess-store-1', [msg]);
    final loaded = await ChatMessageStore.instance.load('sess-store-1');
    expect(loaded, hasLength(1));
    expect(loaded.first.text, 'Hello world');
  });

  test('SshHostConfig.copyWith(clearFingerprint: true) resets pinned key cleanly', () {
    const host = SshHostConfig(
      id: 'h1',
      name: 'Workstation',
      hostname: '10.0.0.5',
      username: 'dev',
      hostKeyFingerprint: 'ssh-ed25519:aa:bb:cc',
    );
    final cleared = host.copyWith(clearFingerprint: true);
    expect(cleared.hostKeyFingerprint, isNull);
    expect(cleared.hostname, '10.0.0.5');
  });

  test('PhoneControlStatus parses mcpPort, mcpToken, and shizukuAvailable cleanly', () {
    final status = PhoneControlStatus.fromMap({
      'enabled': true,
      'accessibilityConnected': true,
      'safetyGateStrict': true,
      'shizukuAvailable': true,
      'mcpPort': 43210,
      'mcpToken': 'tok123',
    });
    expect(status.enabled, isTrue);
    expect(status.shizukuAvailable, isTrue);
    expect(status.mcpPort, 43210);
    expect(status.mcpToken, 'tok123');
  });

  test('AgyAutomation cron and AutomationsNotifier daemon triggers (fileWatch, githubPr, batteryBelow) fire accurately', () async {
    final cronDue = AgyAutomation(
      id: 'cron-1',
      name: 'Morning check',
      prompt: 'Check CI',
      scheduleLabel: '15 9 * * *',
    );
    expect(cronDue.isDueAt(DateTime(2026, 11, 24, 9, 15)), isTrue);
    expect(cronDue.isDueAt(DateTime(2026, 11, 24, 9, 16)), isFalse);

    final tmpDir = Directory.systemTemp.createTempSync('agy_auto_watch_');
    addTearDown(() => tmpDir.deleteSync(recursive: true));
    final watchedFile = File('${tmpDir.path}/watched.txt')
      ..writeAsStringSync('v1');

    var ghCount = 2;
    var battery = 50;
    final fired = <String>[];

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(automationsProvider.notifier);
    notifier.onAutomationDue = (a) async => fired.add(a.name);
    notifier.githubOpenCountOverride = (_, _) async => ghCount;
    notifier.batteryLevelOverride = () async => battery;

    await notifier.add(
      name: 'Watcher',
      prompt: 'Inspect file',
      scheduleLabel: 'File Watch',
      triggerType: AutomationTriggerType.fileWatch,
      triggerTarget: watchedFile.path,
    );
    await notifier.add(
      name: 'PR Watch',
      prompt: 'Review new PR',
      scheduleLabel: 'GitHub PRs',
      triggerType: AutomationTriggerType.githubPr,
      triggerTarget: 'dwicao/antigravity-go',
    );
    await notifier.add(
      name: 'Low Battery Alert',
      prompt: 'Wrap up work',
      scheduleLabel: 'Battery Below %',
      triggerType: AutomationTriggerType.batteryBelow,
      triggerTarget: '20',
    );

    // First poll establishes baselines; battery at 50% does not fire.
    expect(await notifier.runDueAutomations(), 0);

    // Touch watched file (advance mtime > 1s cleanly), open new PR, and drop battery.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    watchedFile.writeAsStringSync('v2');
    watchedFile.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 2)));
    ghCount = 3;
    battery = 15;

    final ran = await notifier.runDueAutomations();
    expect(ran, 3);
    expect(fired, containsAll(['Watcher', 'PR Watch', 'Low Battery Alert']));
  });

  testWidgets('RuntimeSetupPage exposes Copy Logs and Save Logs buttons and PhoneControlPage shows Device Gateway tools', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RuntimeSetupPage()),
      ),
    );
    await tester.pump();
    expect(find.text('Copy Logs'), findsOneWidget);
    expect(find.text('Save Logs'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PhoneControlPage()),
      ),
    );
    await tester.pump();
    expect(find.text('Device Gateway & Hardware Tools'), findsOneWidget);
    expect(find.text('Torch On'), findsOneWidget);
    expect(find.text('Vibrate'), findsOneWidget);
    expect(find.text('Test Notify'), findsOneWidget);
  });

  test('DesktopLayoutOverride and hapticOnComplete persist via SettingsNotifier', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(settingsProvider.notifier);
    await notifier.setDesktopLayout(DesktopLayoutOverride.desktop);
    await notifier.setHapticOnComplete(false);

    expect(container.read(settingsProvider).desktopLayout, DesktopLayoutOverride.desktop);
    expect(container.read(settingsProvider).hapticOnComplete, isFalse);
  });
}
