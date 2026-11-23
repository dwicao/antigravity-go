import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/chat_state.dart';
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

    // Typing '/' shows Antigravity CLI slash commands catalog.
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.text('/plan'), findsOneWidget);
    expect(find.text('/grill-me'), findsOneWidget);
    expect(find.text('/mcp'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
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
}
