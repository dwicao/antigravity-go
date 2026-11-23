import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/custom_providers_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/ui/remote/custom_providers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomProvidersNotifier add, activate, read key, select null, and remove', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(customProvidersProvider.notifier);
    final saved = await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: '',
        name: 'Local Ollama',
        baseUrl: 'http://127.0.0.1:11434/',
        modelId: 'qwen2.5-coder:14b',
        contextWindowTokens: 131072,
      ),
      apiKey: 'test-key-123',
      activate: true,
    );

    expect(saved.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(container.read(activeCustomProviderProvider)?.id, saved.id);
    expect(await notifier.readApiKey(saved.id), 'test-key-123');

    await notifier.selectProvider(null);
    expect(container.read(activeCustomProviderProvider), isNull);

    await notifier.selectProvider(saved.id);
    expect(container.read(activeCustomProviderProvider)?.modelId, 'qwen2.5-coder:14b');

    await notifier.removeProfile(saved.id);
    expect(container.read(customProvidersProvider).profiles, isEmpty);
    expect(container.read(activeCustomProviderProvider), isNull);
  });

  test('contextBudgetProvider respects custom provider contextWindowTokens', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(customProvidersProvider.notifier);
    await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: 'p-custom-ctx',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        modelId: 'deepseek-chat',
        contextWindowTokens: 256000,
      ),
      activate: true,
    );

    final snap = container.read(contextBudgetProvider);
    expect(snap.budgetTokens, 256000);
  });

  test('ChatMessageStore.delete removes persisted session history cleanly', () async {
    final msg = ChatMessage(
      id: 'm-del-1',
      role: ChatRole.user,
      text: 'Temporary prompt',
      createdAt: DateTime(2026, 11, 23, 20, 0),
    );
    await ChatMessageStore.instance.save('sess-del-1', [msg]);
    expect(await ChatMessageStore.instance.load('sess-del-1'), hasLength(1));

    await ChatMessageStore.instance.delete('sess-del-1');
    expect(await ChatMessageStore.instance.load('sess-del-1'), isEmpty);
  });

  testWidgets('CustomProvidersPage renders on narrow 320px phone viewport without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CustomProvidersPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('External /v1 Models'), findsOneWidget);
    expect(find.text('Antigravity CLI (Built-in)'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Ollama (Local)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
