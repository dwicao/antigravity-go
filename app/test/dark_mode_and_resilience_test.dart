import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/draft_store.dart';
import 'package:antigravity_go/theme/app_theme.dart';
import 'package:antigravity_go/ui/chat/message_bubble.dart';
import 'package:antigravity_go/ui/chat/render/agy_markdown.dart';
import 'package:antigravity_go/ui/chat/secret_mask.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('Dark theme enforces high-contrast onSurface and code well colors', () {
    final dark = AgyTheme.build(
      brightness: Brightness.dark,
      accent: AgyAccentPreset.indigo,
    );
    final semantic = dark.extension<AgySemanticColors>()!;

    expect(dark.colorScheme.onSurface.computeLuminance(), greaterThan(0.7));
    expect(dark.textTheme.bodyMedium?.color, semantic.textPrimary);
    expect(semantic.codeWellFg.computeLuminance(), greaterThan(0.7));
    expect(semantic.codeWellBg.computeLuminance(), lessThan(0.05));
    expect(semantic.inlineCodeFg.computeLuminance(), greaterThan(0.7));
  });

  testWidgets('MessageBubble renders dark-mode markdown headings, inline code, and code blocks cleanly', (tester) async {
    final dark = AgyTheme.build(
      brightness: Brightness.dark,
      accent: AgyAccentPreset.indigo,
    );
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.assistant,
      text: '# Summary\n\nChecked `/sdcard/Download` with `ls`.\n\n```bash\nls -la /sdcard/Download\n```\n\n> Verified readable.',
      createdAt: DateTime(2026, 11, 23),
      tools: const [
        ChatToolStep(
          id: 't1',
          toolName: 'run_command',
          state: ToolCallState.completed,
          output: 'file.pdf\nnotes.txt',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: dark,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(message: msg),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Summary'), findsOneWidget);
    expect(find.textContaining('ls -la /sdcard/Download'), findsOneWidget);
    expect(find.text('1 tool steps completed'), findsOneWidget);
  });

  test('StreamingMarkdownRepair closes open inline markers without closing open code fences', () {
    expect(repairStreamingMarkdown('Run `ls -la'), 'Run `ls -la`');
    expect(repairStreamingMarkdown('This is **bold'), 'This is **bold**');
    expect(repairStreamingMarkdown('```dart\nvoid main()'), '```dart\nvoid main()');
  });

  test('AgySecretMask redacts API keys, Bearer tokens, and URL passwords', () {
    expect(
      AgySecretMask.mask('key=AIzaSyDummyKeyValue1234567890123456789'),
      'key=AIzaSy••••',
    );
    expect(
      AgySecretMask.mask('Authorization: Bearer super_secret_token_99'),
      'Authorization: Bearer ••••',
    );
    expect(
      AgySecretMask.mask('https://user:pass1234@github.com/repo.git'),
      'https://user:••••@github.com/repo.git',
    );
  });

  test('DraftStore saves per-session drafts and truncates pasted NUL binary blobs', () async {
    expect(sanitizeDraftText('hello\u0000binaryjunk'), 'hello');

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(draftStoreProvider.notifier);
    notifier.save('s1', 'check downloads');
    await notifier.flush();

    expect(notifier.draftFor('s1'), 'check downloads');
    notifier.clear('s1');
    await notifier.flush();
    expect(notifier.draftFor('s1'), '');
  });
}
