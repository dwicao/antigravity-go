import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/phone/phone_bridge.dart';
import 'package:antigravity_go/state/chat_message_store.dart';
import 'package:antigravity_go/state/chat_models.dart';
import 'package:antigravity_go/state/performance_state.dart';
import 'package:antigravity_go/state/phone_state.dart';
import 'package:antigravity_go/state/session_export_helper.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/state/settings_state.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/share_card_sheet.dart';
import 'package:antigravity_go/ui/phone/phone_control_page.dart';
import 'package:antigravity_go/ui/replay/conversation_replay_page.dart';
import 'package:antigravity_go/ui/settings/background_guide_page.dart';
import 'package:antigravity_go/ui/settings/diagnostics_page.dart';
import 'package:antigravity_go/ui/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePhoneNotifier extends PhoneNotifier {
  _FakePhoneNotifier(this._initial);

  final PhoneUiState _initial;

  @override
  PhoneUiState build() => _initial;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AgySessionSummary supports pinning and folder serialization cleanly', () {
    final s = AgySessionSummary(
      id: 'sess-1',
      title: 'Fix OAuth Flow',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '/sdcard/proj',
      modelId: 'Orchestrator (Neon)',
      updatedAt: DateTime(2026, 11, 24, 15, 0),
      pinned: true,
      folder: 'Security',
    );
    final decoded = AgySessionSummary.fromJson(s.toJson());
    expect(decoded.pinned, isTrue);
    expect(decoded.folder, 'Security');
  });

  test('SessionsNotifier togglePinSession prioritizes pinned chats and Search finds transcripts',
      () async {
    final older = AgySessionSummary(
      id: 'older-sess',
      title: 'Auth Audit',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '',
      modelId: 'Orchestrator (Neon)',
      updatedAt: DateTime(2026, 11, 20),
    );
    final newer = AgySessionSummary(
      id: 'newer-sess',
      title: 'Daily Build',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '',
      modelId: 'Orchestrator (Neon)',
      updatedAt: DateTime(2026, 11, 24),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(sessionsProvider.notifier);
    await notifier.updateSession(newer);
    await notifier.createSession(title: 'Temp');
    final s1 = await notifier.createSession(title: 'Alpha Task');
    final s2 = await notifier.createSession(title: 'Beta Task');
    await notifier.setSessionFolder(s1.id, 'Work');
    await notifier.togglePinSession(s1.id);

    final list = container.read(sessionsProvider).sessions;
    expect(list.first.id, s1.id);
    expect(list.first.pinned, isTrue);
    expect(list.first.folder, 'Work');
    expect(s2.id, isNot(s1.id));

    await ChatMessageStore.instance.save(older.id, [
      ChatMessage(
        id: 'm1',
        role: ChatRole.assistant,
        text: 'Found secret_token_marker sk-1234567890abcdef inside test fixture.',
        createdAt: DateTime(2026, 11, 20),
      ),
    ]);
    final hits =
        await ChatMessageStore.instance.searchSessions('secret_token_marker', [older, newer]);
    expect(hits.length, 1);
    expect(hits.first.session.id, older.id);
    expect(hits.first.snippet, contains('secret_token_marker'));
  });

  test('SessionExportHelper renders clean redacted Markdown and JSON', () {
    final s = AgySessionSummary(
      id: 'sess-exp',
      title: 'Release Check',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '/workspace',
      modelId: 'Gemini 4 Neon',
      updatedAt: DateTime(2026, 11, 24, 15, 30),
      folder: 'Releases',
    );
    final msgs = [
      ChatMessage(
        id: 'u1',
        role: ChatRole.user,
        text: 'Check status',
        createdAt: DateTime(2026, 11, 24, 15, 30),
      ),
      ChatMessage(
        id: 'a1',
        role: ChatRole.assistant,
        text: 'Token ghp_secret1234567890abcdefghij masked.',
        createdAt: DateTime(2026, 11, 24, 15, 31),
      ),
    ];

    final md = SessionExportHelper.toMarkdown(s, msgs);
    expect(md, contains('# Release Check'));
    expect(md, contains('**Folder:** Releases'));
    expect(md, isNot(contains('ghp_secret1234567890abcdefghij')));

    final jsonStr = SessionExportHelper.toJsonString(s, msgs);
    expect(jsonStr, contains('"title": "Release Check"'));
  });

  test('PerformanceNotifier & SettingsNotifier persist new DSH-adopted settings', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final perf = container.read(performanceProvider.notifier);
    await perf.setRefreshRateMode(RefreshRateMode.max);
    await perf.setReduceMotion(true);
    await perf.setReduceBlur(true);

    expect(container.read(performanceProvider).refreshRateMode, RefreshRateMode.max);
    expect(container.read(performanceProvider).reduceMotion, isTrue);
    expect(container.read(performanceProvider).reduceBlur, isTrue);

    final settings = container.read(settingsProvider.notifier);
    await settings.setFollowWallpaperColor(true);
    await settings.setNotifyOnTurnComplete(false);
    await settings.setNotifyOnApproval(false);
    await settings.setNotifyBackgroundOnly(false);

    final st = container.read(settingsProvider);
    expect(st.followWallpaperColor, isTrue);
    expect(st.notifyOnTurnComplete, isFalse);
    expect(st.notifyOnApproval, isFalse);
    expect(st.notifyBackgroundOnly, isFalse);
  });

  testWidgets('ConversationReplayPage steps through messages with slider and Next',
      (tester) async {
    final s = AgySessionSummary(
      id: 'replay-s',
      title: 'Replay Demo',
      hostId: 'local',
      hostName: 'On Device',
      hostKind: AgyHostKind.local,
      workspacePath: '',
      modelId: 'Orchestrator',
      updatedAt: DateTime(2026, 11, 24),
    );
    final msgs = [
      ChatMessage(
        id: 'm1',
        role: ChatRole.user,
        text: 'Step one prompt',
        createdAt: DateTime(2026, 11, 24, 10, 0),
      ),
      ChatMessage(
        id: 'm2',
        role: ChatRole.assistant,
        text: 'Step two reply',
        createdAt: DateTime(2026, 11, 24, 10, 1),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: ConversationReplayPage(session: s, initialMessages: msgs),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Step 1 of 2'), findsOneWidget);
    expect(find.text('Step one prompt'), findsOneWidget);
    expect(find.text('Step two reply'), findsNothing);

    await tester.tap(find.byTooltip('Next step'));
    await tester.pump();
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(find.text('Step two reply'), findsOneWidget);
  });

  testWidgets('MessageBubble triggers onQuote and ShareCardSheet switches styles',
      (tester) async {
    String? quoted;
    final msg = ChatMessage(
      id: 'm-share',
      role: ChatRole.assistant,
      text: 'Important architectural takeaway.',
      modelId: 'Gemini 4 Neon',
      createdAt: DateTime(2026, 11, 24, 12, 0),
      tokensPerSecond: 44.0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg,
            onQuote: (q) => quoted = q,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Quote in reply'));
    await tester.pump();
    expect(quoted, 'Important architectural takeaway.');

    await tester.tap(find.byTooltip('Share Card'));
    await tester.pumpAndSettle();
    expect(find.text('Reply Share Card'), findsOneWidget);
    await tester.tap(find.text('Indigo'));
    await tester.pump();
    expect(find.text('Save PNG'), findsOneWidget);
  });

  testWidgets('SettingsPage filters sections and PhoneControlPage shows Self-Check & App Rules',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        phoneProvider.overrideWith(
          () => _FakePhoneNotifier(
            const PhoneUiState(
              selfCheck: PhoneSelfCheckResult(
                accessibilityConnected: true,
                notificationsGranted: true,
                storageGranted: true,
                batteryOptimizationIgnored: false,
                shizukuAvailable: true,
                mcpRunning: true,
                mcpPort: 38991,
              ),
              appRules: {'com.example.app': 'allow'},
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pump();

    expect(find.text('Display & Performance'), findsOneWidget);
    expect(find.text('Notifications & Background Alerts'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'wallpaper');
    await tester.pump();
    expect(find.text('Follow wallpaper color (Android 12+)'), findsOneWidget);
    expect(find.text('Display & Performance'), findsNothing);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PhoneControlPage()),
      ),
    );
    await tester.pump();
    expect(find.text('Phone Control Self-Check'), findsOneWidget);
    expect(find.text('MCP :38991'), findsOneWidget);
    expect(find.text('Per-App Rules'), findsOneWidget);
    expect(find.text('com.example.app'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: BackgroundGuidePage()),
      ),
    );
    await tester.pump();
    expect(find.text('Background Keep-Alive Guide'), findsOneWidget);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DiagnosticsPage()),
      ),
    );
    await tester.pump();
    expect(find.text('Diagnostics Bundle'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 500));
  });
}
