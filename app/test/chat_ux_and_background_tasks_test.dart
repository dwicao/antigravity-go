import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/background_tasks_state.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/runtime_state.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/shell/background_tasks_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRuntimeNotifier extends RuntimeNotifier {
  _FakeRuntimeNotifier(this._initial);

  final RuntimeUiState _initial;

  @override
  RuntimeUiState build() => _initial;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'Folded tools bar hides running commands until tapped and saves vertical space',
      (tester) async {
    final msg = ChatMessage(
      id: 'm-running',
      role: ChatRole.assistant,
      text: 'Checking files…',
      createdAt: DateTime(2026, 11, 23, 6, 15),
      isStreaming: true,
      tools: const [
        ChatToolStep(
          id: 'call-1',
          toolName: 'run_command',
          state: ToolCallState.running,
          parameters: {'CommandLine': 'echo SECRET_CMD_MARKER && sleep 5'},
          output: 'running line 1',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: msg),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Running 1 tool step (1 total)'), findsOneWidget);
    expect(find.textContaining('SECRET_CMD_MARKER'), findsNothing);
    expect(find.textContaining('running line 1'), findsNothing);

    await tester.tap(find.text('Running 1 tool step (1 total)'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('SECRET_CMD_MARKER'), findsOneWidget);
    expect(find.textContaining('running line 1'), findsOneWidget);
  });

  testWidgets(
      'Assistant MessageBubble renders bottom metrics footer with tokens, tok/s, duration, date, and model',
      (tester) async {
    final msg = ChatMessage(
      id: 'm-done',
      role: ChatRole.assistant,
      text: 'All checks passed.',
      createdAt: DateTime(2026, 11, 23, 6, 10),
      completedAt: DateTime(2026, 11, 23, 6, 12),
      durationSeconds: 4.5,
      tokensPerSecond: 38.4,
      modelId: 'gemini-4-hydrogen',
      usage: const TokenUsage(
        inputTokens: 900,
        outputTokens: 320,
        thinkingTokens: 80,
        totalTokens: 1300,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: msg),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1,300 tok (900 in · 320 out · 80 think)'), findsOneWidget);
    expect(find.text('38.4 tok/s'), findsOneWidget);
    expect(find.text('4.5s'), findsOneWidget);
    expect(find.text('Nov 23, 06:12'), findsOneWidget);
    expect(find.text('Gemini 4 Hydrogen'), findsOneWidget);
  });

  testWidgets(
      'BackgroundTasksAppBarPill and BackgroundTasksBanner display active background tasks',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            RuntimeUiState(
              backgroundTasks: [
                NativeBackgroundTask(
                  id: 'term-1',
                  turnId: 'turn-1',
                  kind: 'terminal',
                  title: 'gradle :app:testArm64DebugUnitTest',
                  status: 'running',
                  startedAt: DateTime.now().subtract(const Duration(seconds: 12)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final tasks = container.read(backgroundTasksProvider);
    expect(tasks, hasLength(1));
    expect(tasks.first.kind, BackgroundTaskKind.terminal);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Chat'),
              actions: const [BackgroundTasksAppBarPill()],
            ),
            body: const Column(
              children: [
                BackgroundTasksBanner(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 bg'), findsOneWidget);
    expect(
      find.textContaining('gradle :app:testArm64DebugUnitTest'),
      findsOneWidget,
    );

    await tester.tap(find.text('1 bg'));
    await tester.pump();
    expect(find.text('Background Tasks (1)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}
