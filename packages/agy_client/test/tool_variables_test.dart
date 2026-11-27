import 'dart:convert';

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
        'ERROR timeout here\nERROR auth failed',
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
  });
}
