import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('DiffHunkParser & Reverter', () {
    test('parses multi-hunk unified diff and reverts individual hunk cleanly', () {
      const diff = '''
diff --git a/lib/main.dart b/lib/main.dart
index 1111111..2222222 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,4 +1,4 @@
 void main() {
-  print('old');
+  print('new');
 }
@@ -10,3 +10,4 @@
 int add(int a, int b) {
   return a + b;
 }
+// extra comment
''';
      final files = DiffHunkParser.parse(diff);
      expect(files, hasLength(1));
      expect(files.first.filePath, 'lib/main.dart');
      expect(files.first.hunks, hasLength(2));

      final h0 = files.first.hunks[0];
      expect(h0.addedLines, 1);
      expect(h0.removedLines, 1);
      expect(h0.toSingleHunkPatch(), contains('--- a/lib/main.dart'));

      const currentFile = "void main() {\n  print('new');\n}\n";
      final reverted = DiffHunkParser.revertHunkInContent(currentFile, h0);
      expect(reverted, isNotNull);
      expect(reverted, contains("print('old');"));
      expect(reverted, isNot(contains("print('new');")));
    });
  });

  group('RepoMapBuilder', () {
    test('extracts Dart, Kotlin, and Python symbols into compact <repo_map>', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_repo_map_');
      try {
        await File('${tmp.path}/app.dart').writeAsString('''
class AuthService {
  Future<bool> login(String user) async => true;
}
''');
        await File('${tmp.path}/Main.kt').writeAsString('''
class MainActivity {
  fun onCreate() {}
}
''');
        await File('${tmp.path}/helper.py').writeAsString('''
def compute_score(x, y):
    return x + y
''');
        final mapText = await RepoMapBuilder.buildFromDirectory(tmp.path);
        expect(mapText, contains('<repo_map'));
        expect(mapText, contains('app.dart'));
        expect(mapText, contains('class AuthService'));
        expect(mapText, contains('Main.kt'));
        expect(mapText, contains('fun onCreate()'));
        expect(mapText, contains('helper.py'));
        expect(mapText, contains('def compute_score(x, y)'));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });

  group('LifecycleHooksConfig', () {
    test('blocks sensitive files and resolves PostToolUse commands', () {
      final cfg = LifecycleHooksConfig.initial();
      final envBlocked = cfg.evaluatePreToolUse(
        tool: 'write_file',
        target: '/workspace/project/.env.production',
      );
      expect(envBlocked.allowed, isFalse);

      final sdcardBlocked = cfg.evaluatePreToolUse(
        tool: 'write_file',
        target: '/sdcard/DCIM/Camera/photo.jpg',
      );
      expect(sdcardBlocked.allowed, isFalse);

      final normalAllowed = cfg.evaluatePreToolUse(
        tool: 'write_file',
        target: '/workspace/project/lib/main.dart',
      );
      expect(normalAllowed.allowed, isTrue);

      final postEnabled = LifecycleHooksConfig(
        rules: cfg.rules
            .map((r) => r.id == 'post-edit-dart-format'
                ? r.copyWith(enabled: true)
                : r)
            .toList(),
      );
      final cmds = postEnabled.postToolUseCommands(
        tool: 'write_file',
        filePath: '/workspace/lib/main.dart',
      );
      expect(cmds, ["dart format '/workspace/lib/main.dart'"]);

      final decoded = LifecycleHooksConfig.decodeJson(postEnabled.encodeJson());
      expect(decoded.rules.length, cfg.rules.length);
    });
  });

  group('VoicePromptNormalizer', () {
    test('normalizes coding phrases and workspace filenames and strips markdown for TTS', () {
      final norm = VoicePromptNormalizer.normalize(
        'please run slash compact and check chat state dot dart',
        workspaceFiles: ['app/lib/state/chat_state.dart', 'app/lib/main.dart'],
      );
      expect(norm, contains('/compact'));
      expect(norm, contains('chat_state.dart'));

      final spoken = VoicePromptNormalizer.toSpokenSummary(
        '## Fixed Bug\nUpdated `chat_state.dart`.\n```dart\nfinal x = 1;\n```',
      );
      expect(spoken, contains('Fixed Bug'));
      expect(spoken, contains('Code block omitted.'));
      expect(spoken, isNot(contains('```')));
    });
  });

  group('ModelPricingCatalog & UsageLedger', () {
    test('estimates per-turn USD cost and aggregates ledger cost', () {
      const usage = TokenUsage(
        inputTokens: 1000000,
        outputTokens: 100000,
        cacheReadTokens: 500000,
      );
      final cost = ModelPricingCatalog.estimateTurnCostUsd(
        'gemini-3.8-flash',
        usage,
      );
      expect(cost, greaterThan(0.0));
      expect(ModelPricingCatalog.formatUsd(cost), startsWith(r'$'));
      expect(
        ModelPricingCatalog.estimateTurnCostUsd('ollama/qwen2.5-coder', usage),
        0.0,
      );

      final ledger = UsageLedger([
        UsageLedgerRecord(
          timestamp: DateTime.now().toUtc(),
          modelId: 'gemini-3.8-flash',
          usage: usage,
        ),
      ]);
      expect(
        ledger.sumEstimatedCostUsd(UsageLedger.fiveHourWindow),
        closeTo(cost, 1e-9),
      );
    });
  });

  group('McpHttpClient & Local Endpoint Detection', () {
    test('parses SSE JSON-RPC responses and detects local endpoints', () {
      const sse = 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"search"}]}}\n\n';
      final events = McpHttpClient.parseSseBody(sse);
      expect(events, hasLength(1));
      expect(events.first['id'], 1);

      const local = OpenAiProviderConfig(
        id: '1',
        name: 'Ollama',
        baseUrl: 'http://127.0.0.1:11434/v1',
        modelId: 'qwen2.5-coder',
      );
      const cloud = OpenAiProviderConfig(
        id: '2',
        name: 'OpenAI',
        baseUrl: 'https://api.openai.com/v1',
        modelId: 'gpt-4.1',
      );
      expect(local.isLocalEndpoint, isTrue);
      expect(cloud.isLocalEndpoint, isFalse);
      expect(AntigravityPermissionPreset.mobileProfiles, hasLength(3));
    });
  });
}
