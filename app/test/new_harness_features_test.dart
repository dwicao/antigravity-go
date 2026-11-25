import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/chat_models.dart';
import 'package:antigravity_go/state/custom_providers_state.dart';
import 'package:antigravity_go/state/device_policy_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/state/share_inbox_state.dart';
import 'package:antigravity_go/state/side_panel_state.dart';
import 'package:antigravity_go/theme/app_theme.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/message_metrics_footer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _theme() => AgyTheme.build(
      brightness: Brightness.dark,
      accent: AgyAccentPreset.indigo,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SharedInboxPayload parses text, subject, and files cleanly', () {
    final payload = SharedInboxPayload.fromMap({
      'subject': 'Build failure',
      'text': 'NullPointerException at line 42',
      'files': ['/tmp/stack.png'],
    });
    expect(payload, isNotNull);
    expect(payload!.formattedPromptText(), contains('Build failure'));
    expect(payload.formattedPromptText(), contains('NullPointerException'));
    expect(payload.files, ['/tmp/stack.png']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sharedInboxProvider.notifier).enqueue(payload);
    final consumed = container.read(sharedInboxProvider.notifier).consume();
    expect(consumed?.files, ['/tmp/stack.png']);
    expect(container.read(sharedInboxProvider), isNull);
  });

  test('HarnessNotifier toggles autoCompact, repoMap, and lifecycle hooks', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(harnessProvider.notifier);

    await notifier.setAutoCompact(false);
    await notifier.setRepoMapEnabled(false);
    await notifier.toggleHookRule('post-edit-dart-format', true);

    final st = container.read(harnessProvider);
    expect(st.autoCompactEnabled, isFalse);
    expect(st.repoMapEnabled, isFalse);
    expect(
      st.hooksConfig.rules
          .firstWhere((r) => r.id == 'post-edit-dart-format')
          .enabled,
      isTrue,
    );
  });

  test('CustomProvidersNotifier picks local endpoint as hybrid fallback', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(customProvidersProvider.notifier);

    await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: 'ollama-1',
        name: 'Ollama Local',
        baseUrl: 'http://127.0.0.1:11434/v1',
        modelId: 'qwen2.5-coder',
      ),
    );
    final st = container.read(customProvidersProvider);
    expect(st.fallbackProfile?.id, 'ollama-1');
    expect(st.hybridOfflineFallbackEnabled, isTrue);
  });

  test('DevicePolicyState warns on low battery or cellular and applies Eco Mode', () async {
    const lowBat = DevicePolicyState(
      batteryPct: 12,
      charging: false,
      network: 'wifi',
    );
    expect(lowBat.isLowBattery, isTrue);
    expect(lowBat.shouldWarn, isTrue);

    const cellular = DevicePolicyState(
      batteryPct: 80,
      charging: false,
      network: 'cellular',
    );
    expect(cellular.isCellular, isTrue);
    expect(cellular.shouldWarn, isTrue);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(devicePolicyProvider.notifier).activateEcoMode();
    expect(container.read(devicePolicyProvider).ecoModeActive, isTrue);
    expect(container.read(settingsProvider).reasoningEffort, 'low');
  });

  test('SidePanelNotifier opens Web Preview tab cleanly', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sidePanelProvider.notifier).openTab(
          const SidePanelTab(
            id: 'preview',
            kind: SidePanelTabKind.preview,
            title: 'Preview',
          ),
        );
    final panel = container.read(sidePanelProvider);
    expect(panel.showSidePanel, isTrue);
    expect(panel.activeTab?.kind, SidePanelTabKind.preview);
  });

  testWidgets('MessageMetricsFooter renders USD cost and MessageBubble renders Listen button', (tester) async {
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.assistant,
      text: 'Updated `main.dart` and verified all checks.',
      createdAt: DateTime(2026, 11, 25, 10, 0),
      completedAt: DateTime(2026, 11, 25, 10, 0, 5),
      modelId: 'gemini-3.8-flash',
      usage: const TokenUsage(
        inputTokens: 10000,
        outputTokens: 2000,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: Column(
              children: [
                MessageBubble(message: msg),
                MessageMetricsFooter(message: msg),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('bottom-speak-button')), findsOneWidget);
    expect(find.textContaining(r'$0.'), findsWidgets);
  });
}
