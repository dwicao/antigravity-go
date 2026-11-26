import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/chat_models.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/chat_turn_helpers.dart';
import 'package:antigravity_go/state/custom_providers_state.dart';
import 'package:antigravity_go/state/device_policy_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/state/share_inbox_state.dart';
import 'package:antigravity_go/state/side_panel_state.dart';
import 'package:antigravity_go/state/workspace_diff_state.dart';
import 'package:antigravity_go/theme/app_theme.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/message_metrics_footer.dart';
import 'package:antigravity_go/ui/chat/workspace_changes_banner.dart';
import 'package:antigravity_go/ui/workspace/diff_review_view.dart';
import 'package:antigravity_go/ui/workspace/github_diff_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ThemeData _theme() => AgyTheme.build(
      brightness: Brightness.dark,
      accent: AgyAccentPreset.indigo,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SharedInboxPayload parses text, subject, and files cleanly', () {
    final payload = SharedInboxPayload.fromMap({
      'subject': 'Build failure',
      'text': 'NullPointerException at line 42',
      'files': ['/tmp/stack.png'],
    });
    expect(payload, isNotNull);
    expect(payload!.formattedPromptText(), contains('Build failure'));
    expect(payload.formattedPromptText(), contains('NullPointerException'));
    expect(payload.files, ['/tmp/stack.png']);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sharedInboxProvider.notifier).enqueue(payload);
    final consumed = container.read(sharedInboxProvider.notifier).consume();
    expect(consumed?.files, ['/tmp/stack.png']);
    expect(container.read(sharedInboxProvider), isNull);
  });

  test('HarnessNotifier toggles autoCompact, repoMap, and lifecycle hooks', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(harnessProvider.notifier);

    await notifier.setAutoCompact(false);
    await notifier.setRepoMapEnabled(false);
    await notifier.toggleHookRule('post-edit-dart-format', true);

    final st = container.read(harnessProvider);
    expect(st.autoCompactEnabled, isFalse);
    expect(st.repoMapEnabled, isFalse);
    expect(
      st.hooksConfig.rules
          .firstWhere((r) => r.id == 'post-edit-dart-format')
          .enabled,
      isTrue,
    );
  });

  test('CustomProvidersNotifier picks local endpoint as hybrid fallback', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(customProvidersProvider.notifier);

    await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: 'ollama-1',
        name: 'Ollama Local',
        baseUrl: 'http://127.0.0.1:11434/v1',
        modelId: 'qwen2.5-coder',
      ),
    );
    final st = container.read(customProvidersProvider);
    expect(st.fallbackProfile?.id, 'ollama-1');
    expect(st.hybridOfflineFallbackEnabled, isTrue);
  });

  test('DevicePolicyState warns on low battery or cellular and applies Eco Mode', () async {
    const lowBat = DevicePolicyState(
      batteryPct: 12,
      charging: false,
      network: 'wifi',
    );
    expect(lowBat.isLowBattery, isTrue);
    expect(lowBat.shouldWarn, isTrue);

    const cellular = DevicePolicyState(
      batteryPct: 80,
      charging: false,
      network: 'cellular',
    );
    expect(cellular.isCellular, isTrue);
    expect(cellular.shouldWarn, isTrue);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(devicePolicyProvider.notifier).activateEcoMode();
    expect(container.read(devicePolicyProvider).ecoModeActive, isTrue);
    expect(container.read(settingsProvider).reasoningEffort, 'low');
  });

  test('SidePanelNotifier opens Web Preview tab cleanly', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sidePanelProvider.notifier).openTab(
          const SidePanelTab(
            id: 'preview',
            kind: SidePanelTabKind.preview,
            title: 'Preview',
          ),
        );
    final panel = container.read(sidePanelProvider);
    expect(panel.showSidePanel, isTrue);
    expect(panel.activeTab?.kind, SidePanelTabKind.preview);
  });

  testWidgets('MessageMetricsFooter renders USD cost and MessageBubble renders Listen button', (tester) async {
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.assistant,
      text: 'Updated `main.dart` and verified all checks.',
      createdAt: DateTime(2026, 11, 25, 10, 0),
      completedAt: DateTime(2026, 11, 25, 10, 0, 5),
      modelId: 'gemini-3.8-flash',
      usage: const TokenUsage(
        inputTokens: 10000,
        outputTokens: 2000,
        totalTokens: 12000,
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: Column(
              children: [
                MessageBubble(message: msg),
                MessageMetricsFooter(message: msg),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('bottom-speak-button')), findsOneWidget);
    expect(find.textContaining(r'$0.'), findsWidgets);
  });

  testWidgets('GitHubDiffViewer displays changed files, line numbers, Viewed toggle, and Split mode', (tester) async {
    const unifiedDiff = '''
diff --git a/lib/foo.dart b/lib/foo.dart
--- a/lib/foo.dart
+++ b/lib/foo.dart
@@ -1,3 +1,3 @@
 void greet() {
-  print('hi');
+  print('hello');
 }
diff --git a/lib/new_file.dart b/lib/new_file.dart
--- /dev/null
+++ b/lib/new_file.dart
@@ -0,0 +1,2 @@
+final version = 2;
+final ok = true;
''';
    const files = [
      FileChangeEntry(path: 'lib/foo.dart', added: 1, removed: 1),
      FileChangeEntry(path: 'lib/new_file.dart', added: 2, removed: 0, created: true),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: const Scaffold(
          body: GitHubDiffViewer(
            files: files,
            unifiedDiff: unifiedDiff,
            branch: 'main',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('lib/foo.dart'), findsWidgets);
    expect(find.text('lib/new_file.dart'), findsWidgets);
    expect(find.textContaining("print('hello')"), findsOneWidget);
    expect(find.text('0/2 viewed'), findsOneWidget);

    await tester.tap(find.text('Split'));
    await tester.pumpAndSettle();
    expect(find.textContaining("print('hi')"), findsOneWidget);

    await tester.tap(find.text('Added'));
    await tester.pumpAndSettle();
    expect(find.text('lib/new_file.dart'), findsWidgets);
    expect(find.text('lib/foo.dart'), findsNothing);
  });

  testWidgets('WorkspaceChangesBanner renders mini-view and opens standalone DiffReviewPage', (tester) async {
    const sampleDiff = '''
diff --git a/app/lib/main.dart b/app/lib/main.dart
--- a/app/lib/main.dart
+++ b/app/lib/main.dart
@@ -1,2 +1,2 @@
-oldInit();
+newInit();
''';
    final container = ProviderContainer(
      overrides: [
        workspaceDiffProvider.overrideWith(
          () => _FakeWorkspaceDiffNotifier(
            const WorkspaceDiffState(
              branch: 'main',
              status: ' M app/lib/main.dart\n M app/lib/app.dart',
              unifiedDiff: sampleDiff,
              files: [
                FileChangeEntry(
                  path: 'app/lib/main.dart',
                  added: 300,
                  removed: 100,
                  diff: sampleDiff,
                ),
                FileChangeEntry(
                  path: 'app/lib/app.dart',
                  added: 24,
                  removed: 26,
                  diff: '@@ -1,1 +1,1 @@\n-a\n+b',
                ),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(
      container.read(sidePanelProvider).tabs.map((t) => t.kind),
      orderedEquals([SidePanelTabKind.files, SidePanelTabKind.terminal]),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                WorkspaceChangesBanner(),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('workspace-changes-banner')), findsOneWidget);
    expect(find.text('2 files changed'), findsOneWidget);
    expect(find.text('+324'), findsOneWidget);
    expect(find.text('−126'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('app.dart'), findsOneWidget);

    await tester.tap(find.text('main.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(DiffReviewPage), findsOneWidget);
    expect(find.text('Files Changed'), findsOneWidget);
    expect(find.text('newInit();'), findsOneWidget);
    expect(find.text('oldInit();'), findsOneWidget);
  });

  test('ChatTurnHelpers extracts changed files from ReplacementChunks and ACP diff outputs', () {
    final extracted = ChatTurnHelpers.extractChangedFilesFromTools([
      const ChatToolStep(
        id: 'tc-chunks',
        toolName: 'multi_replace_file_content',
        state: ToolCallState.completed,
        parameters: {
          'TargetFile': 'app/lib/a.dart',
          'ReplacementChunks': [
            {
              'TargetContent': 'oldA()',
              'ReplacementContent': 'newA()\nsecondA()',
            },
          ],
        },
      ),
      const ChatToolStep(
        id: 'tc-acp-diff',
        toolName: 'File',
        state: ToolCallState.completed,
        parameters: {'path': 'app/lib/b.dart'},
        output: '--- a/app/lib/b.dart\n+++ b/app/lib/b.dart\n@@ -1,1 +1,2 @@\n-oldB\n+newB1\n+newB2',
      ),
    ]);
    expect(extracted, hasLength(2));
    expect(extracted[0].path, 'app/lib/a.dart');
    expect(extracted[0].added, 2);
    expect(extracted[0].removed, 1);
    expect(extracted[1].path, 'app/lib/b.dart');
    expect(extracted[1].added, 2);
    expect(extracted[1].removed, 1);
  });

  test('WorkspaceDiffNotifier switches cached session diff state without retaining stale files', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sessions = container.read(sessionsProvider.notifier);
    final s1 = await sessions.createSession(title: 'Chat A');
    final s2 = await sessions.createSession(title: 'Chat B');

    sessions.selectSession(s1.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(workspaceDiffProvider).files, isEmpty);

    sessions.selectSession(s2.id);
    expect(container.read(workspaceDiffProvider).loading, isFalse);

    await container.read(chatProvider.notifier).appendSystemFeedback(
      'Updated chat file',
      changedFiles: const [
        FileChangeEntry(
          path: 'app/lib/chat_sync_test.dart',
          added: 12,
          removed: 3,
          diff: '@@ -1,1 +1,1 @@\n-old\n+new',
        ),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final synced = container.read(workspaceDiffProvider);
    expect(synced.files.any((f) => f.path == 'app/lib/chat_sync_test.dart'), isTrue);
    expect(synced.unifiedDiff, contains('+new'));

    container.read(workspaceDiffProvider.notifier).markCommitted(synced.files);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      container
          .read(workspaceDiffProvider)
          .files
          .any((f) => f.path == 'app/lib/chat_sync_test.dart'),
      isFalse,
    );
  });
}

class _FakeWorkspaceDiffNotifier extends WorkspaceDiffNotifier {
  _FakeWorkspaceDiffNotifier(this._initial);

  final WorkspaceDiffState _initial;

  @override
  WorkspaceDiffState build() => _initial;

  @override
  Future<void> refresh({bool showLoading = false, bool force = false}) async {}
}
