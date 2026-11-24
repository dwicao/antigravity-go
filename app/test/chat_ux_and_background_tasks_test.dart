import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/background_tasks_state.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/chat_turn_helpers.dart';
import 'package:antigravity_go/state/runtime_state.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/ui/chat/chat_screen.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/subagents_activity_banner.dart';
import 'package:antigravity_go/ui/shell/background_tasks_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRuntimeNotifier extends RuntimeNotifier {
  _FakeRuntimeNotifier(this._initial);

  final RuntimeUiState _initial;

  @override
  RuntimeUiState build() => _initial;
}

class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(this._initial);

  final ChatThreadState _initial;

  @override
  ChatThreadState build() => _initial;

  void setMessages(List<ChatMessage> next) {
    state = state.copyWith(messages: next);
  }
}

class _FakeSessionsNotifier extends SessionsNotifier {
  _FakeSessionsNotifier(this._initial);

  final SessionsState _initial;

  @override
  SessionsState build() => _initial;
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
      reasoningEffort: 'high',
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
    expect(find.text('Gemini 4 Hydrogen - High'), findsOneWidget);
  });

  test('Completed messages never leave stale running tool steps in backgroundTasksProvider', () {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(
            ChatThreadState(
              isStreaming: false,
              messages: [
                ChatMessage(
                  id: 'm1',
                  role: ChatRole.assistant,
                  text: 'Done',
                  createdAt: DateTime(2026, 11, 23, 7, 0),
                  isStreaming: false,
                  tools: const [
                    ChatToolStep(
                      id: 't1',
                      toolName: 'run_command',
                      state: ToolCallState.running,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(backgroundTasksProvider), isEmpty);
  });

  testWidgets(
      'ChatScreen auto-jumps to bottom on open, shows Follow toggle at bottom, Jump to latest when scrolled up, and auto-follows new messages',
      (tester) async {
    final longMessages = List.generate(
      25,
      (i) => ChatMessage(
        id: 'm-$i',
        role: i.isEven ? ChatRole.user : ChatRole.assistant,
        text: 'Message #$i\nLine 2\nLine 3\nLine 4',
        createdAt: DateTime(2026, 11, 23, 7, i),
      ),
    );
    final fakeChat = _FakeChatNotifier(ChatThreadState(messages: longMessages));
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(() => fakeChat),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    // Opening a chat auto-jumps to the very bottom and shows Follow instead of Jump to latest.
    expect(find.textContaining('Message #24'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(find.text('Follow'), findsOneWidget);

    // Scrolling up shows Jump to latest and hides Follow.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    expect(find.text('Follow'), findsNothing);

    // Tapping Jump to latest scrolls back to bottom and shows Follow again.
    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(find.text('Follow'), findsOneWidget);

    // Tapping Follow enables Following mode and keeps scrolling to new messages.
    await tester.tap(find.text('Follow'));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);

    fakeChat.setMessages([
      ...longMessages,
      ChatMessage(
        id: 'm-25',
        role: ChatRole.assistant,
        text: 'Message #25 latest follow item',
        createdAt: DateTime(2026, 11, 23, 7, 30),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Message #25 latest follow item'), findsOneWidget);
    expect(find.text('Following'), findsOneWidget);

    // Manually scrolling up while Following pauses auto-follow and shows Jump to latest.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);
    expect(find.text('Following'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('ChatScreen queues messages when background task is active and exposes Steer button', (tester) async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            RuntimeUiState(
              backgroundTasks: [
                NativeBackgroundTask(
                  id: 'term-bg',
                  turnId: 'turn-bg',
                  kind: 'terminal',
                  title: 'sleep 30',
                  status: 'running',
                  startedAt: DateTime.now(),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Queue'), findsOneWidget);
    expect(find.byTooltip('Steer (force send now)'), findsOneWidget);
    // BackgroundTasksBanner must not appear above the composer and shift the chat viewport;
    // active background tasks remain accessible via the AppBar pill.
    expect(find.byType(BackgroundTasksBanner), findsNothing);
    expect(find.text('1 bg'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Follow up while bg runs');
    await tester.tap(find.byTooltip('Queue'));
    await tester.pump();

    expect(container.read(chatProvider).queuedPrompts, ['Follow up while bg runs']);
    expect(find.text('Steer now'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
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

  test('ChatNotifier survives session creation and extractChangedFilesFromTools skips failed tools', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(chatProvider.notifier);
    await container.read(sessionsProvider.notifier).createSession(title: 'First');
    await container.read(sessionsProvider.notifier).createSession(title: 'Second');
    expect(identical(container.read(chatProvider.notifier), notifier), isTrue);

    final changes = ChatNotifier.extractChangedFilesFromTools([
      const ChatToolStep(
        id: 't-fail',
        toolName: 'write_to_file',
        state: ToolCallState.failed,
        parameters: {'TargetFile': 'bad.dart', 'CodeContent': 'nope'},
      ),
      const ChatToolStep(
        id: 't-ok',
        toolName: 'replace_file_content',
        state: ToolCallState.completed,
        parameters: {
          'TargetFile': 'good.dart',
          'TargetContent': 'oldLine',
          'ReplacementContent': 'newLine',
        },
      ),
    ]);
    expect(changes, hasLength(1));
    expect(changes.first.path, 'good.dart');
    expect(changes.first.diff, contains('-oldLine'));
    expect(changes.first.diff, contains('+newLine'));
  });

  testWidgets(
      'Assistant MessageBubble shows compact bottom copy button after completion and copies text to clipboard',
      (tester) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map<dynamic, dynamic>)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final streamingMsg = ChatMessage(
      id: 'm-stream',
      role: ChatRole.assistant,
      text: 'Partial output',
      createdAt: DateTime(2026, 11, 24, 4, 50),
      isStreaming: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: streamingMsg),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('bottom-copy-button')), findsNothing);

    final doneMsg = ChatMessage(
      id: 'm-complete',
      role: ChatRole.assistant,
      text: 'Final answer ready.',
      createdAt: DateTime(2026, 11, 24, 4, 50),
      completedAt: DateTime(2026, 11, 24, 4, 51),
      isStreaming: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: doneMsg),
          ),
        ),
      ),
    );
    await tester.pump();

    final copyBtn = find.byKey(const ValueKey('bottom-copy-button'));
    expect(copyBtn, findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);

    await tester.tap(copyBtn);
    await tester.pump();

    expect(copiedText, 'Final answer ready.');
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Response copied'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1600));
    expect(find.text('Copy'), findsOneWidget);
  });

  test('ChatTurnHelpers tracks subagent spawn, completion/kill, and target formatting', () {
    final now = DateTime(2026, 11, 24, 10, 0);
    var list = ChatTurnHelpers.applySubagentToolEvent(
      const [],
      callId: 'call-1',
      toolName: 'invoke_subagent',
      state: ToolCallState.running,
      parameters: const {'Role': 'Codebase Researcher', 'TypeName': 'research'},
      now: now,
    );
    expect(list, hasLength(1));
    expect(list.first.status, SubagentStatus.spawning);
    expect(list.first.role, 'Codebase Researcher');

    list = ChatTurnHelpers.applySubagentToolEvent(
      list,
      callId: 'call-1',
      toolName: 'invoke_subagent',
      state: ToolCallState.completed,
      parameters: const {'Role': 'Codebase Researcher', 'TypeName': 'research'},
      output: '{"conversationId":"11111111-2222-3333-4444-555555555555"}',
      now: now,
    );
    expect(list, hasLength(1));
    expect(list.first.status, SubagentStatus.running);
    expect(
      list.first.conversationId,
      '11111111-2222-3333-4444-555555555555',
    );

    list = ChatTurnHelpers.applySubagentToolEvent(
      list,
      callId: 'call-2',
      toolName: 'manage_subagents',
      state: ToolCallState.completed,
      parameters: const {
        'Action': 'kill',
        'ConversationIds': ['11111111-2222-3333-4444-555555555555'],
      },
      now: now,
    );
    expect(list, isEmpty);

    const step = ChatToolStep(
      id: 's1',
      toolName: 'invoke_subagent',
      parameters: {'Role': 'UI Auditor', 'TypeName': 'research'},
      state: ToolCallState.completed,
    );
    expect(ChatTurnHelpers.formatToolTarget(step), 'UI Auditor (research)');
  });

  test('backgroundTasksProvider surfaces active subagents after parent turn ends', () {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(
            ChatThreadState(
              isStreaming: false,
              activeSubagents: [
                ActiveSubagent(
                  id: 'call-bg-1',
                  role: 'Security Auditor',
                  typeName: 'research',
                  status: SubagentStatus.running,
                  startedAt: DateTime(2026, 11, 24, 10, 0),
                  conversationId: 'conv-bg-1',
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
    expect(tasks.first.kind, BackgroundTaskKind.subagent);
    expect(tasks.first.title, 'Security Auditor');
    expect(tasks.first.nativeTaskId, 'subagent:call-bg-1');
  });

  testWidgets(
      'SubagentsActivityBanner renders live subagent status and dismisses cleanly',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(
            ChatThreadState(
              isStreaming: false,
              activeSubagents: [
                ActiveSubagent(
                  id: 'sub-1',
                  role: 'Database Debugger',
                  typeName: 'self',
                  status: SubagentStatus.running,
                  startedAt: DateTime.now().subtract(const Duration(seconds: 5)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SubagentsActivityBanner()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('subagents-activity-banner')), findsOneWidget);
    expect(find.textContaining('1 subagent working'), findsOneWidget);
    expect(find.text('Database Debugger'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();

    expect(container.read(chatProvider).activeSubagents, isEmpty);
    expect(find.byKey(const ValueKey('subagents-activity-banner')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
      'MessageBubble and MilestoneStackCard show spawned subagents strip and verb',
      (tester) async {
    final msg = ChatMessage(
      id: 'm-sub',
      role: ChatRole.assistant,
      text: 'Delegating codebase audit now.',
      createdAt: DateTime(2026, 11, 24, 10, 0),
      completedAt: DateTime(2026, 11, 24, 10, 1),
      isStreaming: false,
      tools: const [
        ChatToolStep(
          id: 'tool-sub-1',
          toolName: 'invoke_subagent',
          parameters: {'Role': 'Codebase Researcher', 'TypeName': 'research'},
          output: 'conversationId: conv-abc123',
          state: ToolCallState.completed,
        ),
      ],
      steps: const [
        ChatMilestoneStep(
          id: 'ms-sub-1',
          kind: ChatMilestoneKind.tool,
          toolId: 'tool-sub-1',
        ),
      ],
    );

    final active = [
      ActiveSubagent(
        id: 'tool-sub-1',
        role: 'Codebase Researcher',
        typeName: 'research',
        status: SubagentStatus.running,
        startedAt: DateTime(2026, 11, 24, 10, 0),
        conversationId: 'conv-abc123',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: msg, activeSubagents: active),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Spawned 1 subagent'), findsOneWidget);
    expect(find.byKey(const ValueKey('spawned-subagents-strip')), findsOneWidget);
    expect(find.text('Codebase Researcher'), findsWidgets);
    expect(find.text('working'), findsOneWidget);
  });
}
