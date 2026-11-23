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
    expect(find.text('Pre-Turn Git Checkpoints'), findsOneWidget);
    expect(find.text('Run Initializer Agent'), findsOneWidget);
    expect(find.text('Adversarial Diff Review'), findsOneWidget);
  });
}
