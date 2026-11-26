import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/harness/harness_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FixedChatNotifier extends ChatNotifier {
  _FixedChatNotifier(this._initial);

  final ChatThreadState _initial;

  @override
  ChatThreadState build() => _initial;
}

class _FixedSettingsNotifier extends SettingsNotifier {
  _FixedSettingsNotifier(this._initial);

  final AppSettings _initial;

  @override
  AppSettings build() => _initial;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ChatMessage persists checkpointRef and contextTokens through JSON serialization', () {
    final original = ChatMessage(
      id: 'u1',
      role: ChatRole.user,
      text: 'Refactor auth flow',
      createdAt: DateTime.utc(2026, 11, 23, 12, 0),
      checkpointRef: 'abc1234def5678',
      contextTokens: 42500,
    );
    final decoded = ChatMessage.fromJson(original.toJson());
    expect(decoded.checkpointRef, 'abc1234def5678');
    expect(decoded.contextTokens, 42500);
    expect(decoded.text, 'Refactor auth flow');
    expect(decoded.isCompactionSummary, isFalse);

    final compacted = ChatMessage(
      id: 'c1',
      role: ChatRole.assistant,
      text: 'Summary handoff',
      createdAt: DateTime.utc(2026, 11, 23, 12, 10),
      isCompactionSummary: true,
    );
    expect(ChatMessage.fromJson(compacted.toJson()).isCompactionSummary, isTrue);
  });

  test('harnessProvider toggles and contextBudgetProvider evaluates pressure', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(harnessProvider).loopBreakerEnabled, isTrue);
    await container.read(harnessProvider.notifier).setLoopBreaker(false);
    expect(container.read(harnessProvider).loopBreakerEnabled, isFalse);

    final snap = container.read(contextBudgetProvider);
    expect(snap.usedTokens, 0);
    expect(snap.shouldCompact, isFalse);
  });

  test('contextBudgetProvider excludes historical turns after compactThread', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(contextBudgetProvider, (_, _) {});

    // Wait for initial microtask loads (sessions / runtime / settings).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final notifier = container.read(chatProvider.notifier);
    // 4M chars (~1.05M estimated tokens) saturates the 1M Gemini context window.
    final hugeText = List<String>.filled(4000000, 'u').join();

    await notifier.appendSystemFeedback(hugeText);
    await notifier.appendSystemFeedback('Second message before compaction');

    final beforeCompact = container.read(contextBudgetProvider);
    expect(beforeCompact.percentage, 100);
    expect(beforeCompact.shouldCompact, isTrue);

    final res = await notifier.compactThread();
    expect(res.ok, isTrue);

    final afterCompact = container.read(contextBudgetProvider);
    expect(afterCompact.compactedMessages, 2);
    expect(afterCompact.percentage, lessThan(5));
    expect(afterCompact.shouldCompact, isFalse);
  });

  test('contextBudgetProvider keeps 1-prompt multi-tool turn with 970K cumulative inputTokens accurate on 1M model', () {
    final tools = List<ChatToolStep>.generate(
      15,
      (i) => ChatToolStep(
        id: 't-$i',
        toolName: 'read_file',
        state: ToolCallState.completed,
        parameters: {'path': 'file_$i.dart'},
        output: 'content $i',
      ),
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettingsNotifier(
            const AppSettings(selectedModelId: 'gemini-4-hydrogen'),
          ),
        ),
        chatProvider.overrideWith(
          () => _FixedChatNotifier(
            ChatThreadState(
              messages: [
                ChatMessage(
                  id: 'u1',
                  role: ChatRole.user,
                  text: 'Inspect repo and summarize architecture',
                  createdAt: DateTime.utc(2026, 11, 23, 12, 0),
                ),
                ChatMessage(
                  id: 'a1',
                  role: ChatRole.assistant,
                  text: 'Here is the architecture summary.',
                  createdAt: DateTime.utc(2026, 11, 23, 12, 1),
                  modelId: 'gemini-4-hydrogen',
                  tools: tools,
                  usage: const TokenUsage(
                    inputTokens: 970000,
                    outputTokens: 3500,
                    totalTokens: 973500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final snap = container.read(contextBudgetProvider);
    expect(snap.budgetTokens, 1000000);
    expect(snap.percentage, lessThan(10));
    expect(snap.shouldCompact, isFalse);
  });

  test('contextBudgetProvider prefers real step contextTokens when reported', () {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettingsNotifier(
            const AppSettings(selectedModelId: 'gemini-4-neon'),
          ),
        ),
        chatProvider.overrideWith(
          () => _FixedChatNotifier(
            ChatThreadState(
              messages: [
                ChatMessage(
                  id: 'a1',
                  role: ChatRole.assistant,
                  text: 'Done.',
                  createdAt: DateTime.utc(2026, 11, 23, 12, 1),
                  modelId: 'gemini-4-neon',
                  contextTokens: 120000,
                  usage: const TokenUsage(
                    inputTokens: 950000,
                    outputTokens: 2000,
                    contextTokens: 120000,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final snap = container.read(contextBudgetProvider);
    expect(snap.budgetTokens, 1000000);
    expect(snap.usedTokens, 120000);
    expect(snap.percentage, 12);
    expect(snap.compactAtTokens, 256000);
  });

  test('contextBudgetProvider adapts compactAtTokens from 256K to 800K for refactor workloads', () {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(
          () => _FixedSettingsNotifier(
            const AppSettings(selectedModelId: 'gemini-4-neon'),
          ),
        ),
        chatProvider.overrideWith(
          () => _FixedChatNotifier(
            ChatThreadState(
              messages: [
                ChatMessage(
                  id: 'u1',
                  role: ChatRole.user,
                  text: 'Refactor runtime bridge and ACP session architecture',
                  createdAt: DateTime.utc(2026, 11, 26, 12, 0),
                ),
                ChatMessage(
                  id: 'a1',
                  role: ChatRole.assistant,
                  text: 'Refactoring in progress.',
                  createdAt: DateTime.utc(2026, 11, 26, 12, 1),
                  modelId: 'gemini-4-neon',
                  contextTokens: 320000,
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final snap = container.read(contextBudgetProvider);
    expect(snap.compactAtTokens, 800000);
    expect(snap.shouldCompact, isFalse);
  });

  testWidgets('MessageBubble renders Rewind button on user messages with checkpoint', (tester) async {
    var rewound = false;
    final msg = ChatMessage(
      id: 'u2',
      role: ChatRole.user,
      text: 'Apply risky patch',
      createdAt: DateTime.utc(2026, 11, 23, 12, 5),
      checkpointRef: 'deadbeef1234',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            onRewind: () => rewound = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rewindBtn = find.byTooltip('Rewind workspace & thread to here');
    expect(rewindBtn, findsOneWidget);
    await tester.tap(rewindBtn);
    await tester.pump();
    expect(rewound, isTrue);
  });

  testWidgets('HarnessPage renders context budget, guardrails, and topologies at narrow phone width without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: HarnessPage(autoRefreshOnOpen: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Harness Engineering'), findsOneWidget);
    expect(find.text('Context Window Budget'), findsOneWidget);
    expect(find.text('Doom-Loop Circuit Breaker'), findsOneWidget);
    expect(find.text('Command & Path Safety Guard'), findsOneWidget);

    final listScrollable = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    ).first;
    await tester.scrollUntilVisible(
      find.text('Run Initializer Agent'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('Run Initializer Agent'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Adversarial Diff Review'),
      200,
      scrollable: listScrollable,
    );
    expect(find.text('Adversarial Diff Review'), findsOneWidget);
  });

  testWidgets('HarnessPage exposes Auto-Verify toggle and clears verifiedAt when unmarking', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: HarnessPage(autoRefreshOnOpen: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Auto-Verify After Turn'), findsOneWidget);
    await container.read(harnessProvider.notifier).setAutoVerify(true);
    expect(container.read(harnessProvider).autoVerifyEnabled, isTrue);

    final f = HarnessFeatureItem(
      id: 'f1',
      description: 'Sample feature',
      passes: true,
      verifiedAt: '2026-11-23T00:00:00Z',
    );
    expect(f.copyWith(passes: false, clearVerifiedAt: true).verifiedAt, isNull);
  });
}
