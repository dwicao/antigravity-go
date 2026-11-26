import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/runtime/runtime_models.dart';
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
import 'package:antigravity_go/ui/chat/chat_composer_bar.dart';
import 'package:antigravity_go/ui/chat/chat_screen.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/message_metrics_footer.dart';
import 'package:antigravity_go/ui/chat/workspace_changes_banner.dart';
import 'package:antigravity_go/ui/harness/harness_page.dart';
import 'package:antigravity_go/ui/terminal/terminal_page.dart';
import 'package:antigravity_go/ui/workspace/diff_review_view.dart';
import 'package:antigravity_go/ui/workspace/diff_syntax_highlighter.dart';
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

  test('DiffSyntaxHighlighter tokenizes GitHub colors and intraline word ranges', () {
    final dartLang = DiffSyntaxHighlighter.detectLanguage('app/lib/main.dart');
    expect(dartLang, DiffSyntaxLanguage.cLike);
    expect(
      DiffSyntaxHighlighter.detectLanguage('scripts/deploy.sh'),
      DiffSyntaxLanguage.shell,
    );
    expect(
      DiffSyntaxHighlighter.detectLanguage('package.json'),
      DiffSyntaxLanguage.json,
    );

    const code = "final title = 'hello'; // note";
    final spans = DiffSyntaxHighlighter.highlightLine(
      code: code,
      language: dartLang,
      palette: DiffSyntaxPalette.dark,
    );
    expect(spans.map((s) => s.text).join(), code);
    expect(spans.first.style?.color, DiffSyntaxPalette.dark.keyword);
    expect(
      spans.any((s) => s.style?.color == DiffSyntaxPalette.dark.string),
      isTrue,
    );
    expect(
      spans.any((s) => s.style?.color == DiffSyntaxPalette.dark.comment),
      isTrue,
    );

    final wordRange = DiffSyntaxHighlighter.computeIntralineRange(
      "print('hello');",
      "print('world');",
    );
    expect(wordRange, isNotNull);
    expect("print('hello');".substring(wordRange!.start, wordRange.end), 'hello');

    final prefixSharedRange = DiffSyntaxHighlighter.computeIntralineRange(
      "print('hello');",
      "print('hi');",
    );
    expect(prefixSharedRange, isNotNull);
    expect(
      "print('hello');".substring(
        prefixSharedRange!.start,
        prefixSharedRange.end,
      ),
      'ello',
    );
  });

  test('ChatTurnHelpers preserves removals via LCS diff, multi-edit hunks, and delete_file', () {
    final extracted = ChatTurnHelpers.extractChangedFilesFromTools([
      const ChatToolStep(
        id: 'tc-lcs-del',
        toolName: 'replace_file_content',
        state: ToolCallState.completed,
        parameters: {
          'TargetFile': 'app/lib/clean.dart',
          'TargetContent': 'keep1\nremovedA\nremovedB\nkeep2',
          'ReplacementContent': 'keep1\nkeep2',
        },
      ),
      const ChatToolStep(
        id: 'tc-del-file',
        toolName: 'delete_file',
        state: ToolCallState.completed,
        parameters: {
          'TargetFile': 'app/lib/obsolete.dart',
        },
      ),
    ]);
    expect(extracted, hasLength(2));
    expect(extracted[0].path, 'app/lib/clean.dart');
    expect(extracted[0].added, 0);
    expect(extracted[0].removed, 2);
    expect(extracted[0].diff, contains('-removedA'));
    expect(extracted[0].diff, contains(' keep1'));
    expect(extracted[1].path, 'app/lib/obsolete.dart');
    expect(extracted[1].deleted, isTrue);
  });

  test('ChatTurnHelpers ignores full-file output dumps when Target/Replacement exist and respects shell git commit', () {
    final fullOld = List<String>.generate(300, (i) => 'row_$i').join('\n');
    final fullNew = List<String>.generate(300, (i) => i == 10 ? 'row_10_edit' : 'row_$i').join('\n');
    final inflatedDump = [
      '--- a/app/lib/big.dart',
      '+++ b/app/lib/big.dart',
      '@@ -1,300 +1,300 @@',
      ...fullOld.split('\n').map((l) => '-$l'),
      ...fullNew.split('\n').map((l) => '+$l'),
    ].join('\n');

    final extracted = ChatTurnHelpers.extractChangedFilesFromTools([
      ChatToolStep(
        id: 'tc-targeted',
        toolName: 'edit_file',
        state: ToolCallState.completed,
        parameters: const {
          'Path': 'app/lib/big.dart',
          'Target': 'row_10',
          'Replacement': 'row_10_edit',
        },
        output: inflatedDump,
      ),
    ]);
    expect(extracted, hasLength(1));
    expect(extracted[0].added, 1);
    expect(extracted[0].removed, 1);

    final preAndPostCommit = ChatTurnHelpers.extractUncommittedFilesFromTools([
      const ChatToolStep(
        id: 'e1',
        toolName: 'edit_file',
        state: ToolCallState.completed,
        parameters: {
          'Path': 'app/lib/committed.dart',
          'Target': 'a',
          'Replacement': 'b',
        },
      ),
      const ChatToolStep(
        id: 'c1',
        toolName: 'run_command',
        state: ToolCallState.completed,
        parameters: {'CommandLine': 'git add -A && git commit -m "ship"'},
        output: 'Command exited with code 0.',
      ),
      const ChatToolStep(
        id: 'e2',
        toolName: 'edit_file',
        state: ToolCallState.completed,
        parameters: {
          'Path': 'app/lib/after_commit.dart',
          'Target': 'x',
          'Replacement': 'y',
        },
      ),
    ]);
    expect(preAndPostCommit.committed, isTrue);
    expect(preAndPostCommit.files.map((f) => f.path), ['app/lib/after_commit.dart']);
  });

  test('WorkspaceDiffNotifier stops at compaction/git-commit and filters clean real git repos', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sessions = container.read(sessionsProvider.notifier);
    final s = await sessions.createSession(title: 'Clean After Commit');
    sessions.selectSession(s.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await container.read(chatProvider.notifier).appendSystemFeedback(
      'Edited and committed',
      changedFiles: const [
        FileChangeEntry(path: 'app/lib/old_turn.dart', added: 500, removed: 490),
      ],
      tools: const [
        ChatToolStep(
          id: 't-commit',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'git add -A && git commit -m "done"'},
        ),
      ],
    );
    await container.read(chatProvider.notifier).appendSystemFeedback(
      'Compacted context',
      isCompactionSummary: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(container.read(workspaceDiffProvider).files, isEmpty);

    final filtered = WorkspaceDiffNotifier.filterChatFilesAgainstCheckedRepos(
      const [
        FileChangeEntry(
          path: '/storage/emulated/0/Projects/antigravity-go/app/lib/a.dart',
          added: 10,
          removed: 5,
        ),
        FileChangeEntry(
          path: '/sdcard/Projects/other_non_git/b.dart',
          added: 2,
          removed: 1,
        ),
      ],
      const [
        (
          cwd: '/sdcard/Projects/antigravity-go',
          branch: 'main',
          files: <FileChangeEntry>[],
        ),
      ],
      '/sdcard/Projects/antigravity-go',
    );
    expect(filtered.map((f) => f.path), ['/sdcard/Projects/other_non_git/b.dart']);
  });

  testWidgets('RuntimeEvent parses comment/subagentId, Composer supports IME paste & Terminal exposes extra keys', (tester) async {
    final evt = RuntimeEvent.fromMap({
      'kind': 'notification_permission_action',
      'turnId': 't1',
      'optionId': 'deny',
      'approved': false,
      'comment': 'Use safe path instead',
      'subagentId': 'sub-9',
    });
    expect(evt.comment, 'Use safe path instead');
    expect(evt.subagentId, 'sub-9');

    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: Scaffold(
            body: ChatComposerBar(
              inputController: ctrl,
              isBusy: false,
              isStreamingCurrentSession: false,
              listeningVoice: false,
              isDesktopMode: false,
              enterToSend: false,
              ctxSnap: const HarnessContextSnapshot(
                usedTokens: 1000,
                budgetTokens: 1000000,
                ratio: 0.001,
                needsWarning: false,
                shouldCompact: false,
                statusLabel: 'Healthy',
                compactedMessages: 0,
                activeMessages: 1,
              ),
              onKeyEvent: (_, _) => KeyEventResult.ignored,
              onChanged: (_) {},
              onPickFile: () {},
              onPickImage: () {},
              onPasteClipboardImage: () {},
              onContentInserted: (_) {},
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
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.contentInsertionConfiguration, isNotNull);

    await tester.tap(find.byTooltip('Attach or CLI tools'));
    await tester.pumpAndSettle();
    expect(find.text('Paste clipboard image'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: _theme(),
          home: const TerminalPage(),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Paste'), findsOneWidget);
    expect(find.text('Ctrl+Z'), findsOneWidget);
    expect(find.text('Esc'), findsOneWidget);
  });

  test('HarnessState exposes Quota Saver, Smart Routing, and Auto-Pivot defaults and toggles', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initial = container.read(harnessProvider);
    expect(initial.quotaSaverEnabled, isTrue);
    expect(initial.smartRoutingEnabled, isTrue);
    expect(initial.autoPivotLoopEnabled, isTrue);

    await container.read(harnessProvider.notifier).setQuotaSaver(false);
    await container.read(harnessProvider.notifier).setSmartRouting(false);
    await container.read(harnessProvider.notifier).setAutoPivotLoop(false);

    final updated = container.read(harnessProvider);
    expect(updated.quotaSaverEnabled, isFalse);
    expect(updated.smartRoutingEnabled, isFalse);
    expect(updated.autoPivotLoopEnabled, isFalse);
  });

  testWidgets('HarnessPage exposes Inference Speed Tier selector and updates settings', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _theme(),
          home: const HarnessPage(autoRefreshOnOpen: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final tierLabel = find.text('Ultrafast');
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(tierLabel);
    await tester.pumpAndSettle();
    await tester.tap(tierLabel);
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).speedTier, InferenceSpeedTier.ultrafast);
  });

  test('WorkspaceDiffNotifier throttles refreshes during active streaming tool edits', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final diffNotifier = container.read(workspaceDiffProvider.notifier);
    final chatNotifier = container.read(chatProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    chatNotifier.seedStreamingTurnForTest(
      sessionId: 'stream-diff-sess',
      turnId: 'turn-1',
      messages: [
        ChatMessage(
          id: 'a-stream',
          role: ChatRole.assistant,
          text: 'Editing files...',
          createdAt: DateTime.utc(2026, 11, 26, 12, 0),
          isStreaming: true,
          tools: const [
            ChatToolStep(
              id: 'e1',
              toolName: 'edit_file',
              state: ToolCallState.completed,
              parameters: {
                'Path': 'app/lib/foo.dart',
                'Target': 'oldLine',
                'Replacement': 'newLine',
              },
            ),
          ],
        ),
      ],
    );

    // Streaming update should schedule the 1.5s trailing throttle instead of
    // synchronously computing diffs / updating the banner on the UI thread.
    expect(diffNotifier.hasPendingStreamingThrottleForTest, isTrue);
    await chatNotifier.stopStreaming(sessionId: 'stream-diff-sess');
    expect(diffNotifier.hasPendingStreamingThrottleForTest, isFalse);
  });

  test('WorkspaceDiffNotifier preserves active streaming paths and ChatTurnHelpers fast-paths Read tools', () async {
    expect(
      ChatTurnHelpers.isFileEditTool(
        ChatToolStep(
          id: 'r1',
          toolName: 'read_file',
          state: ToolCallState.completed,
          parameters: const {'path': 'lib/main.dart'},
          output: '---\na/\n@@ fake text inside read file @@',
        ),
      ),
      isFalse,
    );

    final filtered = WorkspaceDiffNotifier.filterChatFilesAgainstCheckedRepos(
      const [
        FileChangeEntry(
          path: '/sdcard/Projects/antigravity-go/app/lib/in_flight.dart',
          added: 12,
          removed: 3,
        ),
        FileChangeEntry(
          path: '/sdcard/Projects/antigravity-go/app/lib/committed.dart',
          added: 5,
          removed: 1,
        ),
      ],
      const [
        (
          cwd: '/sdcard/Projects/antigravity-go',
          branch: 'main',
          files: <FileChangeEntry>[],
        ),
      ],
      '/sdcard/Projects/antigravity-go',
      preservePaths: const {'/sdcard/Projects/antigravity-go/app/lib/in_flight.dart'},
    );
    expect(
      filtered.map((f) => f.path),
      ['/sdcard/Projects/antigravity-go/app/lib/in_flight.dart'],
    );

    // Concurrent ChatMessageStore.save calls serialize cleanly to the latest snapshot.
    const sid = 'concurrent-save-test';
    final first = [
      ChatMessage(
        id: 'm1',
        role: ChatRole.assistant,
        text: 'first',
        createdAt: DateTime.utc(2026, 11, 26, 13, 0),
      ),
    ];
    final second = [
      ...first,
      ChatMessage(
        id: 'm2',
        role: ChatRole.assistant,
        text: 'second',
        createdAt: DateTime.utc(2026, 11, 26, 13, 1),
        tools: List.generate(
          6,
          (i) => ChatToolStep(
            id: 't-$i',
            toolName: 'read_file',
            state: ToolCallState.completed,
            output: 'line $i',
          ),
        ),
      ),
    ];
    await Future.wait([
      ChatMessageStore.instance.save(sid, first),
      ChatMessageStore.instance.save(sid, second),
    ]);
    final loaded = await ChatMessageStore.instance.load(sid);
    expect(loaded.map((m) => m.id), ['m1', 'm2']);
  });

  testWidgets('ChatScreen does not show mini-diff banner above composer, keeping ChangeCard only after completed chat result', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sessions = container.read(sessionsProvider.notifier);
    final s = await sessions.createSession(title: 'No Mini Banner');
    sessions.selectSession(s.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    final chatNotifier = container.read(chatProvider.notifier);
    chatNotifier.seedStreamingTurnForTest(
      sessionId: s.id,
      turnId: 'turn-nobanner',
      messages: [
        ChatMessage(
          id: 'u1',
          role: ChatRole.user,
          text: 'Edit foo.dart',
          createdAt: DateTime(2026, 11, 26, 13, 20),
        ),
        ChatMessage(
          id: 'a1',
          role: ChatRole.assistant,
          text: 'Editing...',
          createdAt: DateTime(2026, 11, 26, 13, 20),
          isStreaming: true,
          changedFiles: const [
            FileChangeEntry(path: 'lib/foo.dart', added: 5, removed: 2),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(body: ChatScreen()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(WorkspaceChangesBanner), findsNothing);
    // ChangeCard is hidden while message is streaming.
    expect(find.textContaining('View Diff'), findsNothing);

    await chatNotifier.stopStreaming(sessionId: s.id);
    await tester.pump();
    // After chat result completes, ChangeCard appears below the reply, and no banner above input.
    expect(find.byType(WorkspaceChangesBanner), findsNothing);
    expect(find.textContaining('View Diff'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
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
