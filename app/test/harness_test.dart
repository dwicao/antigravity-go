import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/harness/harness_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ChatMessage persists checkpointRef through JSON serialization', () {
    final original = ChatMessage(
      id: 'u1',
      role: ChatRole.user,
      text: 'Refactor auth flow',
      createdAt: DateTime.utc(2026, 11, 23, 12, 0),
      checkpointRef: 'abc1234def5678',
    );
    final decoded = ChatMessage.fromJson(original.toJson());
    expect(decoded.checkpointRef, 'abc1234def5678');
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
    final hugeText = List<String>.filled(1000000, 'u').join();

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
}
