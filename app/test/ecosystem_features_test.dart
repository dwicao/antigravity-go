import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/runtime_state.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/state/usage_state.dart';
import 'package:antigravity_go/theme/app_theme.dart';
import 'package:antigravity_go/ui/chat/chat_composer_bar.dart';
import 'package:antigravity_go/ui/chat/chat_screen.dart';
import 'package:antigravity_go/ui/chat/message_metrics_footer.dart';
import 'package:antigravity_go/ui/chat/render/agy_markdown.dart';
import 'package:antigravity_go/ui/settings/settings_page.dart';
import 'package:antigravity_go/ui/shell/sessions_drawer.dart';
import 'package:antigravity_go/ui/usage/usage_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(this._initial);
  final ChatThreadState _initial;

  @override
  ChatThreadState build() => _initial;
}

class _FakeRuntimeNotifier extends RuntimeNotifier {
  _FakeRuntimeNotifier(this._initial);
  final RuntimeUiState _initial;

  @override
  RuntimeUiState build() => _initial;
}

class _FakeSessionsNotifier extends SessionsNotifier {
  _FakeSessionsNotifier(this._initial);
  final SessionsState _initial;

  @override
  SessionsState build() => _initial;
}

ThemeData _testTheme() => AgyTheme.build(
      brightness: Brightness.dark,
      accent: AgyAccentPreset.indigo,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AgySessionSummary serializes archived flag and SessionsNotifier archives cleanly', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(sessionsProvider.notifier);
    final s1 = await notifier.createSession(title: 'Old Task');
    final s2 = await notifier.createSession(title: 'Active Task');

    await notifier.archiveSession(s1.id, archived: true);
    final updated = container.read(sessionsProvider).sessions;
    expect(updated.firstWhere((s) => s.id == s1.id).archived, isTrue);
    expect(updated.firstWhere((s) => s.id == s2.id).archived, isFalse);

    final roundTripped = AgySessionSummary.fromJson(
      updated.firstWhere((s) => s.id == s1.id).toJson(),
    );
    expect(roundTripped.archived, isTrue);
  });

  test('SettingsNotifier updates speedTier and localeCode cleanly', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(settingsProvider.notifier);
    await notifier.setSpeedTier(InferenceSpeedTier.ultrafast);
    await notifier.setLocaleCode('id');

    final state = container.read(settingsProvider);
    expect(state.speedTier, InferenceSpeedTier.ultrafast);
    expect(state.localeCode, 'id');
  });

  testWidgets('MessageMetricsFooter renders cache hit percentage when cacheReadTokens present', (tester) async {
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.assistant,
      text: 'Done',
      createdAt: DateTime(2026, 11, 24),
      modelId: 'gemini-4-neon-high',
      usage: const TokenUsage(
        inputTokens: 600,
        outputTokens: 200,
        cacheReadTokens: 400,
        totalTokens: 1200,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme(),
        home: Scaffold(
          body: MessageMetricsFooter(message: msg),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('40% hit'), findsOneWidget);
  });

  testWidgets('AgyMarkdown code block offers Save action alongside Copy', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(
            body: AgyMarkdown(
              text: '```dart\nvoid main() {}\n```',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('SessionsDrawer shows Archived filter and Running subagent triage badge', (tester) async {
    final sActive = AgySessionSummary(
      id: 's-active',
      title: 'Live Refactor',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '',
      modelId: 'Orchestrator (Neon)',
      updatedAt: DateTime(2026, 11, 24),
    );
    final sArchived = AgySessionSummary(
      id: 's-arch',
      title: 'Legacy Build',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '',
      modelId: 'Orchestrator (Neon)',
      updatedAt: DateTime(2026, 11, 20),
      archived: true,
    );

    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(
          () => _FakeSessionsNotifier(
            SessionsState(
              sessions: [sActive, sArchived],
              activeSessionId: 's-active',
            ),
          ),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(
            ChatThreadState(
              activeBackgroundSessionIds: const {'s-active'},
              activeSubagents: [
                ActiveSubagent(
                  id: 'sub-1',
                  role: 'Researcher',
                  status: SubagentStatus.running,
                  startedAt: DateTime(2026, 11, 24),
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
        child: MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(
            body: SizedBox(width: 360, height: 800, child: SessionsDrawer()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Live Refactor'), findsOneWidget);
    expect(find.text('Legacy Build'), findsNothing);
    expect(find.text('Running · 1 sub'), findsOneWidget);
    expect(find.text('Archived (1)'), findsOneWidget);

    await tester.tap(find.text('Archived (1)'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Legacy Build'), findsOneWidget);
  });

  testWidgets('ChatComposerBar renders context ring and speed tier pill', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _testTheme(),
          home: Scaffold(
            body: ChatComposerBar(
              inputController: controller,
              isBusy: false,
              isStreamingCurrentSession: false,
              listeningVoice: false,
              isDesktopMode: false,
              enterToSend: false,
              ctxSnap: const HarnessContextSnapshot(
                usedTokens: 45000,
                budgetTokens: 100000,
                ratio: 0.45,
                needsWarning: false,
                shouldCompact: false,
                statusLabel: 'Healthy',
              ),
              onKeyEvent: (_, _) => KeyEventResult.ignored,
              onChanged: (_) {},
              onPickFile: () {},
              onPickImage: () {},
              onDictateVoice: () {},
              onTriggerSlash: () {},
              onSubmit: () {},
              onSteerSubmit: () {},
              onToggleEnterToSend: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Regular'), findsOneWidget);
    expect(find.text('45% ctx'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('ChatScreen shows stopwatch streaming bar, reconnect banner, and turn nav buttons', (tester) async {
    final now = DateTime(2026, 11, 24);
    final msgs = [
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        text: 'First prompt',
        createdAt: now,
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        text: 'First reply',
        createdAt: now,
        usage: const TokenUsage(
          inputTokens: 100,
          outputTokens: 50,
          cacheReadTokens: 100,
          totalTokens: 250,
        ),
      ),
      ChatMessage(
        id: 'u2',
        role: ChatRole.user,
        text: 'Second prompt',
        createdAt: now,
      ),
      ChatMessage(
        id: 'a2',
        role: ChatRole.assistant,
        text: 'Second reply',
        createdAt: now,
      ),
    ];

    final stoppedContainer = ProviderContainer(
      overrides: [
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            const RuntimeUiState(
              status: RuntimeStatus(
                phase: RuntimePhase.stopped,
                statusMessage: 'Stopped',
              ),
            ),
          ),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(ChatThreadState(messages: msgs)),
        ),
      ],
    );
    addTearDown(stoppedContainer.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: stoppedContainer,
        child: MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Local runtime is stopped'), findsOneWidget);
    expect(find.byTooltip('Previous user turn'), findsOneWidget);
    expect(find.byTooltip('Next user turn'), findsOneWidget);

    final streamingContainer = ProviderContainer(
      overrides: [
        runtimeProvider.overrideWith(
          () => _FakeRuntimeNotifier(
            const RuntimeUiState(
              status: RuntimeStatus(
                phase: RuntimePhase.running,
                statusMessage: 'Running',
              ),
            ),
          ),
        ),
        chatProvider.overrideWith(
          () => _FakeChatNotifier(
            ChatThreadState(
              messages: msgs,
              isStreaming: true,
              tokensPerSecond: 38,
            ),
          ),
        ),
      ],
    );
    addTearDown(streamingContainer.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: streamingContainer,
        child: MaterialApp(
          theme: _testTheme(),
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(
      find.byKey(const ValueKey('bottom-agent-working-bar')),
      findsOneWidget,
    );
    expect(find.textContaining('38 tok/s'), findsOneWidget);
    expect(find.textContaining('2 rd'), findsOneWidget);
  });

  testWidgets('UsagePage renders segmented quota bars cleanly', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(usageProvider.notifier).applyRawProbeOutput('''
5-hour window: 80% remaining (resets in 4h)
Weekly limit: 70% remaining (resets in 5d)
''');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _testTheme(),
          home: const UsagePage(autoRefreshOnOpen: false),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('5-Hour Rolling Window'), findsOneWidget);
  });

  testWidgets('SettingsPage renders App Language chips and What\'s New tile', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _testTheme(),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('Bahasa Indonesia'),
      200,
    );
    expect(find.text('Bahasa Indonesia'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text("What's New"),
      200,
    );
    expect(find.text("What's New"), findsOneWidget);
  });
}
