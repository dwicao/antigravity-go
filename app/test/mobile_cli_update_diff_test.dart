import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/ci_watch_state.dart';
import 'package:antigravity_go/state/runtime_state.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/state/update_state.dart';
import 'package:antigravity_go/ui/chat/chat_screen.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/shell/background_tasks_sheet.dart';
import 'package:antigravity_go/ui/update/update_sheet.dart';
import 'package:antigravity_go/update/update_service.dart';
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

class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(this._initial);

  final ChatThreadState _initial;
  bool forceStoppedAll = false;

  @override
  ChatThreadState build() => _initial;

  @override
  Future<int> forceStopAllTasks() async {
    forceStoppedAll = true;
    state = state.copyWith(
      isStreaming: false,
      activeBackgroundSessionIds: const {},
    );
    return 1;
  }
}

class _FakeSessionsNotifier extends SessionsNotifier {
  _FakeSessionsNotifier(this._initial);

  final SessionsState _initial;

  @override
  SessionsState build() => _initial;
}

class _FakeUpdateNotifier extends AppUpdateNotifier {
  _FakeUpdateNotifier(this._initial);

  final AppUpdateState _initial;
  bool cancelledCalled = false;

  @override
  AppUpdateState build() => _initial;

  @override
  Future<void> cancelUpdate() async {
    cancelledCalled = true;
    state = state.copyWith(
      phase: UpdateTransferPhase.cancelled,
      persistedDataUsedBytes: state.totalDataUsedBytes,
      receivedBytes: 0,
      speedBps: 0,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'Narrow 320px mobile ChatScreen keeps composer TextField wide without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
    await tester.pump(const Duration(milliseconds: 200));

    final fieldRect = tester.getRect(find.byType(TextField));
    expect(fieldRect.width, greaterThanOrEqualTo(150));

    // Typing '/' shows Antigravity CLI slash commands catalog and supports filtering.
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.text('/plan'), findsOneWidget);
    expect(find.text('/goal'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/grill');
    await tester.pump();
    expect(find.text('/grill-me'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/mcp');
    await tester.pump();
    expect(
      find.text('Manage Model Context Protocol (MCP) servers'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets(
      'MessageBubble renders chronological DSH-Go style stacked milestone cards',
      (tester) async {
    final msg = ChatMessage(
      id: 'm-stack',
      role: ChatRole.assistant,
      text: 'Done updating files.',
      createdAt: DateTime(2026, 11, 23, 9, 0),
      completedAt: DateTime(2026, 11, 23, 9, 1),
      tools: const [
        ChatToolStep(
          id: 'cmd-1',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'cd /sdcard/Projects && git status'},
          output: 'clean',
        ),
        ChatToolStep(
          id: 'cmd-2',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'cd /sdcard/Projects && dart test'},
          output: 'All tests passed',
        ),
      ],
      steps: const [
        ChatMilestoneStep(
          id: 'th-1',
          kind: ChatMilestoneKind.thought,
          text: 'Now add the responsive composer widget.',
        ),
        ChatMilestoneStep(
          id: 't-1',
          kind: ChatMilestoneKind.tool,
          toolId: 'cmd-1',
        ),
        ChatMilestoneStep(
          id: 't-2',
          kind: ChatMilestoneKind.tool,
          toolId: 'cmd-2',
        ),
        ChatMilestoneStep(
          id: 'th-2',
          kind: ChatMilestoneKind.thought,
          text: "The 'return@forEachIndex' label avoids returning early.",
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

    expect(find.text('Ran 2 commands'), findsOneWidget);
    expect(
      find.textContaining('Thinking — Now add the responsive composer'),
      findsOneWidget,
    );
    expect(
      find.textContaining('cd /sdcard/Projects && git status'),
      findsOneWidget,
    );
    expect(
      find.textContaining("Thinking — The 'return@forEachIndex'"),
      findsOneWidget,
    );
  });

  testWidgets('MessageBubble renders ChangeCard for changed files', (tester) async {
    final msg = ChatMessage(
      id: 'm-diff',
      role: ChatRole.assistant,
      text: 'Committed & pushed `abc1234` on `main`.',
      createdAt: DateTime(2026, 11, 23, 8, 0),
      completedAt: DateTime(2026, 11, 23, 8, 1),
      changedFiles: const [
        FileChangeEntry(
          path: 'app/lib/ui/chat/chat_screen.dart',
          added: 42,
          removed: 12,
        ),
        FileChangeEntry(
          path: 'app/lib/ui/update/update_sheet.dart',
          added: 180,
          created: true,
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

    expect(find.text('2 files changed'), findsOneWidget);
    expect(find.textContaining('chat_screen.dart'), findsOneWidget);
    expect(find.text('+42'), findsOneWidget);
  });

  testWidgets(
      'BackgroundTasksSheet exposes Force Stop All and per-task force stop buttons',
      (tester) async {
    final fakeChat = _FakeChatNotifier(
      ChatThreadState(
        isStreaming: true,
        activeBackgroundSessionIds: const {'s-other'},
        messages: [
          ChatMessage(
            id: 'm-stream',
            role: ChatRole.assistant,
            text: '',
            createdAt: DateTime.now(),
            isStreaming: true,
            tools: const [
              ChatToolStep(
                id: 'tool-1',
                toolName: 'invoke_subagent',
                state: ToolCallState.running,
              ),
            ],
          ),
        ],
      ),
    );
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(const SessionsState(activeSessionId: 's-cur')),
        ),
        chatProvider.overrideWith(() => fakeChat),
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            RuntimeUiState(
              backgroundTasks: [
                NativeBackgroundTask(
                  id: 'term-9',
                  turnId: 't-9',
                  kind: 'terminal',
                  title: 'npm run build',
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
          home: Scaffold(body: BackgroundTasksSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Force Stop All'), findsOneWidget);
    // Terminal + session + running subagent tool each get a Force stop icon
    expect(find.byTooltip('Force stop task'), findsNWidgets(3));

    await tester.tap(find.text('Force Stop All'));
    await tester.pump();
    expect(fakeChat.forceStoppedAll, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'UpdateSheet displays progress bar, downloaded/total MB, data used, and Cancel button',
      (tester) async {
    final fakeUpdate = _FakeUpdateNotifier(
      const AppUpdateState(
        latest: AppReleaseInfo(
          tagName: 'v1.0.8',
          versionName: '1.0.8',
          htmlUrl: 'https://github.com/dwicao/antigravity-go/releases/tag/v1.0.8',
          arm64ApkUrl: 'https://example.com/app.apk',
          arm64SizeBytes: 10 * 1024 * 1024,
        ),
        phase: UpdateTransferPhase.downloading,
        receivedBytes: 5 * 1024 * 1024,
        totalBytes: 10 * 1024 * 1024,
        speedBps: 2 * 1024 * 1024,
        persistedDataUsedBytes: 2 * 1024 * 1024,
      ),
    );
    final container = ProviderContainer(
      overrides: [appUpdateProvider.overrideWith(() => fakeUpdate)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: UpdateSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('5.0 MB / 10.0 MB'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Total data used for updates: 7.0 MB'), findsOneWidget);
    expect(find.text('Cancel Update'), findsOneWidget);

    await tester.tap(find.text('Cancel Update'));
    await tester.pump();
    expect(fakeUpdate.cancelledCalled, isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'ChatScreen shows Stop button and Background task pill whenever a background CI or shell task runs',
      (tester) async {
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
                  id: 'term-bg-2',
                  turnId: 'turn-bg-2',
                  kind: 'terminal',
                  title: 'gh run watch 123',
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

    expect(find.byTooltip('Stop (Esc)'), findsOneWidget);
    expect(find.text('1 bg'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });

  test('CiWatchNotifier detects CI failure and produces autoFixPrompt', () async {
    String? receivedPrompt;
    final notifier = CiWatchNotifier()
      ..shellRunnerOverride = ((cmd, cwd) async {
        if (cmd.contains('gh run list')) {
          return '[{"databaseId": 999, "workflowName": "CI", "status": "completed", "conclusion": "failure", "url": "https://github.com/o/r/runs/999", "headBranch": "main"}]';
        }
        return 'flutter analyze failed: 1 issue';
      })
      ..onCompletedCallback = ({
        required watch,
        required passed,
        required summaryMarkdown,
        autoFixPrompt,
      }) async {
        receivedPrompt = autoFixPrompt;
      };

    final container = ProviderContainer(
      overrides: [ciWatchProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    await container.read(ciWatchProvider.notifier).watchLatestRun(
          cwd: '/tmp/repo',
          sessionId: 's1',
        );

    expect(container.read(ciWatchProvider), isEmpty);
    expect(receivedPrompt, contains('999'));
    expect(receivedPrompt, contains('flutter analyze failed'));
  });

  test('AppUpdateState.compareSemver detects newer GitHub releases accurately', () {
    const up = AppUpdateState(
      latest: AppReleaseInfo(
        tagName: 'v99.0.0',
        versionName: '99.0.0',
        htmlUrl: 'https://github.com/dwicao/antigravity-go/releases/tag/v99.0.0',
      ),
    );
    expect(up.hasNewerVersion, isTrue);
    expect(AppUpdateState.compareSemver('1.0.11', '1.0.10'), greaterThan(0));
    expect(AppUpdateState.compareSemver('1.0.9', '1.0.9'), 0);
    expect(AppUpdateState.compareSemver('1.0.8', '1.0.9'), lessThan(0));
  });

  testWidgets(
      'ChangeCard opens per-file highlighted diff sheet and calls onOpenDiff',
      (tester) async {
    var openedDiff = false;
    final msg = ChatMessage(
      id: 'm-unified',
      role: ChatRole.assistant,
      text: 'Pushed commit.',
      createdAt: DateTime(2026, 11, 23, 10, 0),
      completedAt: DateTime(2026, 11, 23, 10, 1),
      changedFiles: const [
        FileChangeEntry(
          path: 'app/lib/main.dart',
          added: 1,
          removed: 1,
          diff: '@@ -1,1 +1,1 @@\n-oldLine()\n+newLine()',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            onOpenDiff: () => openedDiff = true,
          ),
        ),
      ),
    );
    await tester.tap(find.textContaining('main.dart'));
    await tester.pumpAndSettle();

    expect(find.text('+newLine()'), findsOneWidget);
    expect(find.text('-oldLine()'), findsOneWidget);

    await tester.tap(find.text('Open Git Review'));
    await tester.pumpAndSettle();
    expect(openedDiff, isTrue);
  });

  test('CiWatchNotifier tracks latched runId via gh run view and expires on repeated empty polls', () async {
    var pollStep = 0;
    final notifier = CiWatchNotifier()
      ..shellRunnerOverride = ((cmd, cwd) async {
        pollStep++;
        if (pollStep == 1 && cmd.contains('gh run list')) {
          return '[{"databaseId": 777, "workflowName": "CI", "status": "in_progress", "conclusion": "", "url": "https://github.com/o/r/runs/777", "headBranch": "main"}]';
        }
        if (cmd.contains('gh run view 777')) {
          return '{"databaseId": 777, "workflowName": "CI", "status": "completed", "conclusion": "success", "url": "https://github.com/o/r/runs/777", "headBranch": "main"}';
        }
        return '[]';
      });

    final container = ProviderContainer(
      overrides: [ciWatchProvider.overrideWith(() => notifier)],
    );
    addTearDown(container.dispose);

    final ci = container.read(ciWatchProvider.notifier);
    await ci.watchLatestRun(cwd: '/tmp/repo', sessionId: 's1');
    expect(container.read(ciWatchProvider), hasLength(1));
    expect(container.read(ciWatchProvider).first.runId, '777');

    await ci.pollOnce(container.read(ciWatchProvider).first.id);
    expect(container.read(ciWatchProvider), isEmpty);

    // Repeated empty responses (e.g. non-git directory) expire cleanly instead of looping forever.
    final emptyNotifier = CiWatchNotifier()
      ..shellRunnerOverride = ((cmd, cwd) async => '[]');
    final container2 = ProviderContainer(
      overrides: [ciWatchProvider.overrideWith(() => emptyNotifier)],
    );
    addTearDown(container2.dispose);
    final ci2 = container2.read(ciWatchProvider.notifier);
    await ci2.watchLatestRun(cwd: '/tmp/not-a-repo', sessionId: 's2');
    expect(container2.read(ciWatchProvider), hasLength(1));
    final watchId = container2.read(ciWatchProvider).first.id;
    for (var i = 0; i < 4; i++) {
      await ci2.pollOnce(watchId);
    }
    expect(container2.read(ciWatchProvider), isEmpty);
  });

  test('ChatNotifier.extractGitPushCwd resolves push directory and ignores failed or dry-run commands', () {
    const failedPush = ChatToolStep(
      id: 't1',
      toolName: 'run_command',
      state: ToolCallState.failed,
      parameters: {'CommandLine': 'cd /sdcard/Projects/repo && git push'},
      error: 'rejected',
    );
    const dryRunPush = ChatToolStep(
      id: 't2',
      toolName: 'run_command',
      state: ToolCallState.completed,
      parameters: {'CommandLine': 'git push --dry-run'},
    );
    const cdPush = ChatToolStep(
      id: 't3',
      toolName: 'run_command',
      state: ToolCallState.completed,
      parameters: {'CommandLine': 'cd /sdcard/Projects/antigravity-go && git push origin main'},
    );

    expect(
      ChatNotifier.extractGitPushCwd([failedPush, dryRunPush], fallbackCwd: '/tmp/fallback'),
      isNull,
    );
    expect(
      ChatNotifier.extractGitPushCwd([cdPush], fallbackCwd: '/tmp/fallback'),
      '/sdcard/Projects/antigravity-go',
    );
  });
}
