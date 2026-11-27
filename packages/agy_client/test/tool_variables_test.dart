import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('ToolVariableStore', () {
    test('saves tool outputs with semantic slugs and formats compact handles for large payloads', () {
      final store = ToolVariableStore(inlineThresholdChars: 200);

      final small = store.save(
        toolName: 'read_file',
        target: '/repo/lib/main.dart',
        rawOutput: 'void main() {}',
      );
      expect(small.name, startsWith('v_read_main_dart'));
      expect(store.latestName, small.name);
      final smallFormatted = store.formatToolResponse(small);
      expect(smallFormatted, contains('void main() {}'));
      expect(smallFormatted, contains('[var: \$${small.name}'));

      final rows = List.generate(
        200,
        (i) => {'id': 'u_$i', 'visited': '2024-01-01', 'duration': 120 + i},
      );
      final hugeJson = jsonEncode(rows);
      final large = store.save(
        toolName: 'run_command',
        target: 'query_visits',
        rawOutput: hugeJson,
      );
      expect(large.summary, contains('JSON array (200 items, keys: id, visited, duration)'));
      final largeFormatted = store.formatToolResponse(large);
      expect(largeFormatted.length, lessThan(1300));
      expect(largeFormatted, contains('[VAR STORED: \$${large.name}'));
      expect(store.savedOutputChars, greaterThan(5000));
    });

    test('resolves exact variables, JSON fields, array indices, built-ins, and line slices', () {
      final store = ToolVariableStore();
      store.save(
        toolName: 'run_command',
        explicitName: 'weekly_visits',
        rawOutput: jsonEncode({
          'cohort': '2024-W01',
          'users': [
            {'id': 'u_1', 'duration': 120},
            {'id': 'u_2', 'duration': 240},
          ],
        }),
      );
      store.save(
        toolName: 'read_file',
        explicitName: 'log_lines',
        rawOutput: 'L1\nL2\nL3\nL4\nL5',
      );

      expect(store.resolveText(r'$weekly_visits.cohort'), '2024-W01');
      expect(store.resolveText(r'${weekly_visits.users[1].id}'), 'u_2');
      expect(store.resolveText(r'$weekly_visits.users[-1].duration'), '240');
      expect(store.resolveText(r'$weekly_visits.users.length'), '2');
      expect(store.resolveText(r'$weekly_visits.keys'), '["cohort","users"]');

      expect(store.resolveText(r'$log_lines.lines'), '5');
      expect(store.resolveText(r'$log_lines[2:4]'), 'L2\nL3\nL4');
      expect(store.resolveText(r'$v_last'), 'L1\nL2\nL3\nL4\nL5');
    });

    test('leaves unknown env vars, currency literals, and escaped vars untouched', () {
      final store = ToolVariableStore();
      store.save(
        toolName: 'run_command',
        rawOutput: 'PAYLOAD',
        explicitName: 'v_cmd_1',
      );

      final out = store.resolveText(
        r'Price is $100 in $HOME and $PATH; escaped=\$v_cmd_1; real=$v_cmd_1.',
      );
      expect(
        out,
        r'Price is $100 in $HOME and $PATH; escaped=$v_cmd_1; real=PAYLOAD.',
      );
    });

    test('resolveArguments handles nested maps/lists and skips save_as', () {
      final store = ToolVariableStore();
      store.save(
        toolName: 'read_file',
        explicitName: 'doc_spec',
        rawOutput: 'Spec v1 full body',
      );

      final resolved = store.resolveArguments({
        'save_as': 'doc_spec',
        'content': r'Header\n$doc_spec',
        'nested': {
          'tasks': [r'$doc_spec', r'$UNDEFINED'],
        },
      });

      expect(resolved['save_as'], 'doc_spec');
      expect(resolved['content'], r'Header\nSpec v1 full body');
      expect(
        ((resolved['nested'] as Map)['tasks'] as List),
        ['Spec v1 full body', r'$UNDEFINED'],
      );
    });

    test('inspect supports grep and startLine/limit slicing', () {
      final store = ToolVariableStore();
      store.save(
        toolName: 'read_file',
        explicitName: 'big_log',
        rawOutput: 'ok 1\nERROR timeout here\nok 3\nERROR auth failed',
      );

      expect(
        store.inspect('big_log', grep: 'ERROR'),
        '2: ERROR timeout here\n4: ERROR auth failed',
      );
      expect(
        store.inspect(r'$big_log', startLine: 2, limit: 2),
        'ERROR timeout here\nok 3',
      );
    });

    test('StreamingVariableExpander expands chunked variables cleanly across deltas', () {
      final store = ToolVariableStore();
      store.save(
        toolName: 'run_command',
        explicitName: 'v_cmd_1',
        rawOutput: jsonEncode({
          'rows': [
            {'name': 'Alice'},
            {'name': 'Bob'},
          ],
        }),
      );

      final expander = StreamingVariableExpander(store);
      final chunks = [
        'First user is ',
        r'$',
        'v_cm',
        'd_1.ro',
        'ws[0].na',
        'me, unknown ',
        r'$HO',
        'ME stays, tail ',
        r'${v_cmd_1',
        '.rows[1].name}.',
      ];
      final result = StringBuffer();
      for (final c in chunks) {
        result.write(expander.addDelta(c));
      }
      result.write(expander.flush());

      expect(
        result.toString(),
        'First user is Alice, unknown \$HOME stays, tail Bob.',
      );
    });

    test('systemPromptInstructions stays static for prompt caching while dynamicVarsContextNote tracks vars', () {
      final store = ToolVariableStore();
      final before = store.systemPromptInstructions(hasSubagentTool: true);
      expect(store.dynamicVarsContextNote(), isEmpty);

      store.save(
        toolName: 'run_command',
        explicitName: 'rows_1',
        rawOutput: 'alpha\nbeta\ngamma',
      );
      final after = store.systemPromptInstructions(hasSubagentTool: true);
      expect(after, equals(before));
      expect(
        store.dynamicVarsContextNote(),
        contains(r'$rows_1'),
      );
    });

    test('RepoMapBuilder compact mode reduces output size vs standard mode', () {
      const summary = RepoMapFileSummary(
        relativePath: 'app/lib/state/chat_state.dart',
        lineCount: 3200,
        symbols: [
          RepoSymbol(
            kind: 'class',
            name: 'ChatNotifier',
            line: 90,
          ),
          RepoSymbol(
            kind: 'fn',
            name: 'sendPrompt',
            line: 980,
            signature: 'sendPrompt(String rawText, {bool force = false})',
          ),
        ],
      );
      final regular = RepoMapBuilder.renderRepoMap([summary], compact: false);
      final compact = RepoMapBuilder.renderRepoMap([summary], compact: true);
      expect(compact.length, lessThan(regular.length));
      expect(compact, contains('ChatNotifier:90'));
      expect(compact, contains('sendPrompt:980'));
    });

    test('compressTerminalOutput strips ANSI/OSC, collapses spinners and duplicate lines', () {
      const noisy =
          '\x1B[32mPASS\x1B[0m test_a.dart   \n'
          'Downloading 10%\rDownloading 50%\rDownloading 100%\n'
          'ok line\n'
          'ok line\n'
          'ok line\n'
          'ok line\n'
          '\n\n\n\n'
          'done';
      final cleaned = ToolVariableStore.compressTerminalOutput(noisy);
      expect(cleaned, isNot(contains('\x1B')));
      expect(cleaned, isNot(contains('Downloading 10%')));
      expect(cleaned, contains('Downloading 100%'));
      expect(cleaned, contains('... [repeated 3 more times]'));
      expect(cleaned.endsWith('done'), isTrue);
    });

    test('Read-Once deduplication hits on unchanged file and invalidates on write/change', () {
      final store = ToolVariableStore(inlineThresholdChars: 100);
      final body = 'Line\n' * 100;
      final entry = store.save(
        toolName: 'read_file',
        target: '/repo/a.dart',
        rawOutput: body,
      );
      store.recordFileRead(
        path: '/repo/a.dart',
        content: body,
        varName: entry.name,
        modifiedMs: 1000,
      );

      final hit = store.checkFileRead(
        path: '/repo/a.dart',
        currentContent: body,
        modifiedMs: 1000,
      );
      expect(hit, isNotNull);
      expect(hit!.varName, entry.name);
      expect(store.readDedupHits, 1);

      expect(
        store.checkFileRead(
          path: '/repo/a.dart',
          currentContent: '$body\nchanged',
          modifiedMs: 1001,
        ),
        isNull,
      );

      store.invalidateFilePath('/repo/a.dart');
      expect(
        store.checkFileRead(
          path: '/repo/a.dart',
          currentContent: body,
          modifiedMs: 1000,
        ),
        isNull,
      );
    });

    test('RepoMapBuilder skips lockfiles and respects .agyignore patterns', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_ignore_test_');
      try {
        await File('${tmp.path}/.agyignore').writeAsString('generated/\n*.gen.dart\n');
        await File('${tmp.path}/pubspec.lock').writeAsString('packages: {}');
        await Directory('${tmp.path}/generated').create();
        await File('${tmp.path}/generated/big.dart').writeAsString('class GeneratedBig {}');
        await File('${tmp.path}/app.gen.dart').writeAsString('class GenModel {}');
        await File('${tmp.path}/main.dart').writeAsString('class MainApp {}');

        final map = await RepoMapBuilder.buildFromDirectory(tmp.path, useCache: false);
        expect(map, contains('main.dart'));
        expect(map, isNot(contains('pubspec.lock')));
        expect(map, isNot(contains('GeneratedBig')));
        expect(map, isNot(contains('GenModel')));
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
