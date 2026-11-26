import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/background_tasks_state.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/chat_turn_helpers.dart';
import 'package:antigravity_go/state/runtime_state.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/ui/chat/chat_screen.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/secret_mask.dart';
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
      'ChatScreen auto-follows at bottom by default, pauses on scroll up to show Jump to latest arrow, and resumes auto-follow at bottom',
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

    // Opening a chat auto-jumps to bottom, auto-follows by default, and hides Follow/Jump pills.
    expect(find.textContaining('Message #24'), findsOneWidget);
    expect(find.byTooltip('Jump to latest'), findsNothing);
    expect(find.text('Follow'), findsNothing);
    expect(find.text('Following'), findsNothing);

    // New messages arriving while at the bottom automatically scroll into view.
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
    expect(find.byTooltip('Jump to latest'), findsNothing);

    // Scrolling up pauses auto-follow and reveals the Jump to latest arrow button.
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsOneWidget);

    // Tapping Jump to latest scrolls back to bottom, hides the arrow, and resumes auto-follow.
    await tester.tap(find.byTooltip('Jump to latest'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Jump to latest'), findsNothing);

    fakeChat.setMessages([
      ...container.read(chatProvider).messages,
      ChatMessage(
        id: 'm-26',
        role: ChatRole.assistant,
        text: 'Message #26 resumed auto-follow item',
        createdAt: DateTime(2026, 11, 23, 7, 31),
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.textContaining('Message #26 resumed auto-follow item'), findsOneWidget);

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

  testWidgets(
      'ChatScreen automatic bottom-follow stays active across horizontal scroll and pauses only on vertical scroll up',
      (tester) async {
    final longLines = List.generate(
      24,
      (i) => 'Message line $i with enough vertical height to scroll cleanly.',
    ).join('\n\n');
    final chatNotifier = _FakeChatNotifier(
      ChatThreadState(
        loadedSessionId: 's-follow',
        messages: [
          ChatMessage(
            id: 'm1',
            role: ChatRole.user,
            text: 'Start session',
            createdAt: DateTime(2026, 11, 24, 9, 0),
          ),
          ChatMessage(
            id: 'm2',
            role: ChatRole.assistant,
            text:
                '$longLines\n\n```dart\nfinal horizontalCodeBlock = "verylonghorizontaltexttotestscrollingbehavior0123456789abcdefghijklmnopqrstuvwxyz";\n```',
            createdAt: DateTime(2026, 11, 24, 9, 1),
            isStreaming: true,
          ),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-follow')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(() => chatNotifier),
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
    await tester.pump(const Duration(milliseconds: 100));

    // At bottom by default without any Follow/Jump pill.
    expect(find.text('Follow'), findsNothing);
    expect(find.text('Following'), findsNothing);
    expect(find.byTooltip('Jump to latest'), findsNothing);

    // Simulate appended streaming chunks — auto-follow stays active.
    chatNotifier.setMessages([
      ...container.read(chatProvider).messages,
      ChatMessage(
        id: 'm3',
        role: ChatRole.assistant,
        text: 'More streamed output appended to chat.',
        createdAt: DateTime(2026, 11, 24, 9, 2),
        isStreaming: true,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Jump to latest'), findsNothing);

    // Intentionally drag main vertical chat ListView upward away from bottom -> pauses and shows arrow.
    await tester.drag(find.byType(ListView), const Offset(0, 320));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Jump to latest'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
      'MilestoneStackCard formats noisy ../../../../ file steps meaningfully and summarizes mixed tool steps',
      (tester) async {
    expect(
      ChatTurnHelpers.formatDisplayPath(
        '../../../../../../storage/emulated/0/Projects/antigravity-go/app/lib/ui/chat/chat_screen.dart',
      ),
      '…/ui/chat/chat_screen.dart',
    );
    expect(ChatTurnHelpers.formatDisplayPath('../../../../../../'), '');

    final msg = ChatMessage(
      id: 'm-tools-clean',
      role: ChatRole.assistant,
      text: 'Inspected codebase.',
      createdAt: DateTime(2026, 11, 24, 14, 0),
      completedAt: DateTime(2026, 11, 24, 14, 1),
      tools: const [
        ChatToolStep(
          id: 't-read-rel',
          toolName: 'file ../../../../../../storage/emulated/0/Projects/antigravity-go/app/lib/state/chat_state.dart',
          parameters: {},
          state: ToolCallState.completed,
        ),
        ChatToolStep(
          id: 't-read-empty',
          toolName: 'file ../../../../../../',
          parameters: {
            'AbsolutePath':
                '/storage/emulated/0/Projects/antigravity-go/app/lib/ui/usage/usage_page.dart',
            'StartLine': 10,
            'EndLine': 50,
          },
          state: ToolCallState.completed,
        ),
        ChatToolStep(
          id: 't-grep',
          toolName: 'grep_search',
          parameters: {
            'Query': 'QuotaGroup',
            'SearchPath': '../../../../../../storage/emulated/0/Projects/antigravity-go/packages/agy_client',
          },
          state: ToolCallState.completed,
        ),
      ],
      steps: const [
        ChatMilestoneStep(id: 'ms-1', kind: ChatMilestoneKind.tool, toolId: 't-read-rel'),
        ChatMilestoneStep(id: 'ms-2', kind: ChatMilestoneKind.tool, toolId: 't-read-empty'),
        ChatMilestoneStep(id: 'ms-3', kind: ChatMilestoneKind.tool, toolId: 't-grep'),
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

    expect(find.text('Completed 3 steps · 2 read, 1 search'), findsOneWidget);
    expect(find.textContaining('file ../../../../../../'), findsNothing);
    expect(find.text('Read — app/lib/state/chat_state.dart'), findsOneWidget);
    expect(find.text('Read — …/ui/usage/usage_page.dart:10-50'), findsOneWidget);
    expect(find.text('Search — "QuotaGroup" in packages/agy_client'), findsOneWidget);
  });

  testWidgets('ChatComposerBar aligns Attach button, TextField, and Send vertically centered', (tester) async {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's1')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
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
    await tester.pump(const Duration(milliseconds: 100));

    final attachRect = tester.getRect(find.byTooltip('Attach or CLI tools'));
    final fieldRect = tester.getRect(find.byType(TextField));
    final sendRect = tester.getRect(find.byTooltip('Send'));

    expect((attachRect.center.dy - sendRect.center.dy).abs(), lessThanOrEqualTo(1.0));
    expect((fieldRect.center.dy - sendRect.center.dy).abs(), lessThanOrEqualTo(2.0));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
      'MessageBubble renders chronological milestones below preceding chat result text',
      (tester) async {
    final msg = ChatMessage(
      id: 'm-chrono',
      role: ChatRole.assistant,
      text: 'Background tasks done, running final checks now.',
      createdAt: DateTime(2026, 11, 24, 14, 0),
      isStreaming: false,
      tools: const [
        ChatToolStep(
          id: 't-after',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'flutter test'},
        ),
      ],
      steps: const [
        ChatMilestoneStep(
          id: 'text-0',
          kind: ChatMilestoneKind.text,
          text: 'Background tasks done, running final checks now.',
        ),
        ChatMilestoneStep(
          id: 'thought-1',
          kind: ChatMilestoneKind.thought,
          text: 'Verify flutter test result',
        ),
        ChatMilestoneStep(
          id: 'tool-t-after',
          kind: ChatMilestoneKind.tool,
          toolId: 't-after',
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

    final textPos = tester.getTopLeft(
      find.textContaining('Background tasks done, running final checks now.'),
    );
    final milestonePos = tester.getTopLeft(find.text('Ran 1 command'));
    expect(milestonePos.dy, greaterThan(textPos.dy));
  });

  testWidgets(
      'ChatScreen pins Antigravity spinner and tok/s bar at the very bottom while streaming',
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
              isStreaming: true,
              tokensPerSecond: 47.2,
              messages: [
                ChatMessage(
                  id: 'm-stream',
                  role: ChatRole.assistant,
                  text: 'Streaming detailed response…',
                  createdAt: DateTime(2026, 11, 24, 14, 1),
                  isStreaming: true,
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

    final bottomBar = find.byKey(const ValueKey('bottom-agent-working-bar'));
    expect(bottomBar, findsOneWidget);
    expect(
      find.descendant(of: bottomBar, matching: find.text('Antigravity')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: bottomBar,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bottomBar, matching: find.text('47 tok/s')),
      findsOneWidget,
    );
    // Must sit below the scrollable chat list and NOT inside MessageBubble header.
    final listRect = tester.getRect(find.byType(ListView));
    final barRect = tester.getRect(bottomBar);
    expect(barRect.top, greaterThanOrEqualTo(listRect.bottom - 1.0));
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.text('47 tok/s'),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
      'Idle 3-minute stall watchdog stays suppressed while background tasks run and warns when truly idle',
      (tester) async {
    final bgContainer = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-bg')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            RuntimeUiState(
              backgroundTasks: [
                NativeBackgroundTask(
                  id: 'term-1',
                  turnId: 'turn-bg',
                  kind: 'terminal',
                  title: 'gradle assembleRelease',
                  status: 'running',
                  startedAt: DateTime(2026, 11, 24, 14, 0),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(bgContainer.dispose);

    bgContainer.read(chatProvider.notifier).seedStreamingTurnForTest(
          sessionId: 's-bg',
          turnId: 'turn-bg',
        );
    expect(
      bgContainer.read(chatProvider.notifier).hasActiveBackgroundWorkForTest('s-bg'),
      isTrue,
    );

    await tester.pump(const Duration(seconds: 185));
    expect(bgContainer.read(chatProvider).stallWarning, isNull);
    bgContainer.dispose();

    final idleContainer = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-idle')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
      ],
    );

    idleContainer.read(chatProvider.notifier).seedStreamingTurnForTest(
          sessionId: 's-idle',
          turnId: 'turn-idle',
        );
    expect(
      idleContainer.read(chatProvider.notifier).hasActiveBackgroundWorkForTest('s-idle'),
      isFalse,
    );

    await tester.pump(const Duration(seconds: 185));
    expect(
      idleContainer.read(chatProvider).stallWarning,
      contains('3 minutes'),
    );
    idleContainer.dispose();
  });

  testWidgets(
      'Typing / shows floating slash menu without shifting ChatComposerBar on mobile',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-slash')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(const ChatThreadState()),
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

    final fieldFinder = find.byType(TextField);
    final beforeRect = tester.getRect(fieldFinder);

    await tester.enterText(fieldFinder, '/');
    await tester.pump();

    final slashItemFinder = find.text('/plan');
    expect(slashItemFinder, findsOneWidget);

    final afterRect = tester.getRect(fieldFinder);
    expect((afterRect.top - beforeRect.top).abs(), lessThanOrEqualTo(1.0));
    expect(
      (afterRect.bottom - beforeRect.bottom).abs(),
      lessThanOrEqualTo(1.0),
    );
    final slashRect = tester.getRect(slashItemFinder);
    expect(slashRect.bottom, lessThanOrEqualTo(afterRect.top));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
      'ChatScreen windows long history, collapses older milestones, and reveals all when requested',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final messages = List<ChatMessage>.generate(55, (i) {
      final isUser = i.isEven;
      final isOldStepMsg = i == 3;
      final isRecentStepMsg = i == 53;
      return ChatMessage(
        id: 'm-$i',
        role: isUser ? ChatRole.user : ChatRole.assistant,
        text: 'Message #$i',
        createdAt: DateTime(2026, 11, 25, 10, 0).add(Duration(seconds: i)),
        completedAt: isUser
            ? null
            : DateTime(2026, 11, 25, 10, 0).add(Duration(seconds: i + 1)),
        tools: isOldStepMsg
            ? const [
                ChatToolStep(
                  id: 't-old',
                  toolName: 'read_file',
                  parameters: {'AbsolutePath': '/repo/old.dart'},
                  state: ToolCallState.completed,
                ),
              ]
            : isRecentStepMsg
                ? const [
                    ChatToolStep(
                      id: 't-recent',
                      toolName: 'read_file',
                      parameters: {'AbsolutePath': '/repo/recent.dart'},
                      state: ToolCallState.completed,
                    ),
                  ]
                : const [],
        steps: isOldStepMsg
            ? const [
                ChatMilestoneStep(
                  id: 'ms-old',
                  kind: ChatMilestoneKind.tool,
                  toolId: 't-old',
                ),
              ]
            : isRecentStepMsg
                ? const [
                    ChatMilestoneStep(
                      id: 'ms-recent',
                      kind: ChatMilestoneKind.tool,
                      toolId: 't-recent',
                    ),
                  ]
                : const [],
      );
    });

    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-long')),
        ),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(const RuntimeUiState()),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(ChatThreadState(messages: messages)),
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
    await tester.pump();

    // Latest messages and recent expanded milestone are visible; oldest 15 are windowed out.
    expect(find.text('Message #54'), findsOneWidget);
    expect(find.text('Read — repo/recent.dart'), findsOneWidget);
    expect(find.text('Message #0'), findsNothing);

    final scrollableFinder = find.byType(Scrollable).first;
    final loadEarlierFinder = find.text('Load 15 earlier (15 hidden)');
    await tester.scrollUntilVisible(
      loadEarlierFinder,
      -400,
      scrollable: scrollableFinder,
      maxScrolls: 60,
    );
    await tester.pump();

    expect(loadEarlierFinder, findsOneWidget);

    await tester.tap(loadEarlierFinder);
    await tester.pump();

    expect(loadEarlierFinder, findsNothing);
    await tester.scrollUntilVisible(
      find.text('Message #0'),
      -400,
      scrollable: scrollableFinder,
      maxScrolls: 60,
    );
    await tester.pump();

    expect(find.text('Message #0'), findsOneWidget);
    // Older message milestone is collapsed by default: summary shown, detail row hidden.
    await tester.scrollUntilVisible(
      find.text('Message #3'),
      200,
      scrollable: scrollableFinder,
    );
    await tester.pump();
    expect(find.text('Read 1 file'), findsAtLeastNWidgets(1));
    expect(find.text('Read — repo/old.dart'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('AgySecretMask fast-path skips benign text accurately and still redacts all secret patterns', () {
    const shortSafe = 'hi';
    expect(identical(AgySecretMask.mask(shortSafe), shortSafe), isTrue);

    const benignLong =
        'Refactoring controller layer with 42 files changed and zero errors';
    expect(identical(AgySecretMask.mask(benignLong), benignLong), isTrue);

    expect(
      AgySecretMask.mask('https://alice:s3cr3tPass@example.com/repo.git'),
      'https://alice:••••@example.com/repo.git',
    );
    expect(
      AgySecretMask.mask('Authorization: bEaReR AbCdEfGh123456'),
      'Authorization: bEaReR ••••',
    );
    expect(
      AgySecretMask.mask('Key sk-abcdefghijklmnop1234 and AIzaSyD123456789012345678901'),
      'Key sk-abc•••• and AIzaSy••••',
    );
    expect(
      AgySecretMask.mask('eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3OCJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'),
      'eyJ••••',
    );
    expect(
      AgySecretMask.mask('-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----'),
      '-----PRIVATE KEY REDACTED-----',
    );
  });

  test('ChatMessageStore save and load roundtrip handles concurrent serialized writes', () async {
    const sessionId = 'store-perf-test-session';
    final firstBatch = [
      ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        text: 'First prompt',
        createdAt: DateTime(2026, 11, 26, 10, 0),
      ),
    ];
    final secondBatch = [
      ...firstBatch,
      ChatMessage(
        id: 'm2',
        role: ChatRole.assistant,
        text: 'Final response persisted cleanly',
        createdAt: DateTime(2026, 11, 26, 10, 1),
      ),
    ];
    await Future.wait([
      ChatMessageStore.instance.save(sessionId, firstBatch),
      ChatMessageStore.instance.save(sessionId, secondBatch),
    ]);
    final loaded = await ChatMessageStore.instance.load(sessionId);
    expect(loaded.length, 2);
    expect(loaded.last.text, 'Final response persisted cleanly');
  });
}
