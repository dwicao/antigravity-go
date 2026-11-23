import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessLoopDetector', () {
    test('triggers repeatedCall after threshold identical signatures', () {
      final detector = HarnessLoopDetector(repeatThreshold: 3);

      expect(
        detector.recordToolCall(name: 'read_file', input: '/tmp/foo.dart').triggered,
        isFalse,
      );
      expect(
        detector.recordToolCall(name: 'read_file', input: '  /tmp/foo.dart\n').triggered,
        isFalse,
      );
      final hit = detector.recordToolCall(name: 'read_file', input: '/tmp/foo.dart');
      expect(hit.triggered, isTrue);
      expect(hit.kind, HarnessLoopKind.repeatedCall);
      expect(hit.count, 3);
      expect(hit.pivotPrompt, contains('read_file'));
    });

    test('triggers pingPongCycle on alternating [A, B, A, B] calls', () {
      final detector = HarnessLoopDetector(cycleThreshold: 4);

      expect(detector.recordToolCall(name: 'edit_file', input: 'a').triggered, isFalse);
      expect(detector.recordToolCall(name: 'run_shell', input: 'test').triggered, isFalse);
      expect(detector.recordToolCall(name: 'edit_file', input: 'a').triggered, isFalse);
      final hit = detector.recordToolCall(name: 'run_shell', input: 'test');

      expect(hit.triggered, isTrue);
      expect(hit.kind, HarnessLoopKind.pingPongCycle);
      expect(hit.count, 4);
    });

    test('triggers repeatedFailure when same tool fails consecutively', () {
      final detector = HarnessLoopDetector(failureThreshold: 3);

      detector.recordToolCall(name: 'run_shell', input: 'cmd 1', isError: true);
      detector.recordToolCall(name: 'run_shell', input: 'cmd 2', isError: true);
      final hit = detector.recordToolCall(
        name: 'run_shell',
        input: 'cmd 3',
        isError: true,
      );

      expect(hit.triggered, isTrue);
      expect(hit.kind, HarnessLoopKind.repeatedFailure);
    });
  });

  group('HarnessContextMonitor', () {
    test('detects warning and compact thresholds cleanly', () {
      const monitor = HarnessContextMonitor();
      final healthy = monitor.evaluate(
        messageTexts: const <String>['hello world'],
        overrideBudgetTokens: 1000,
      );
      expect(healthy.needsWarning, isFalse);
      expect(healthy.shouldCompact, isFalse);

      final bigText = List<String>.filled(3200, 'a').join();
      final full = monitor.evaluate(
        messageTexts: <String>[bigText],
        overrideBudgetTokens: 1000,
      );
      expect(full.needsWarning, isTrue);
      expect(full.shouldCompact, isTrue);
      expect(full.percentage, greaterThanOrEqualTo(80));
    });

    test('assigns realistic budgets for Gemini 4, Orchestrator, and Flash', () {
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('Orchestrator (Neon)'),
        256000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gemini-4-neon'),
        256000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gemini-3.8-flash'),
        400000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('claude-opus-5.5-thinking'),
        160000,
      );
    });

    test('builds bounded compaction prompt and deterministic fallback summary', () {
      const turns = <HarnessCompactionTurn>[
        HarnessCompactionTurn(
          role: 'user',
          text: 'Fix context percentage bug',
          toolSummaries: ['read_file (harness_engine.dart)'],
        ),
        HarnessCompactionTurn(
          role: 'assistant',
          text: 'Updated effective budgets and compaction slicing.',
        ),
      ];

      final prompt = HarnessContextMonitor.buildCompactionPrompt(
        turns,
        compactedMessages: 2,
        focusInstructions: 'Keep file paths',
      );
      expect(prompt, contains('Focus instructions: Keep file paths'));
      expect(prompt, contains('Fix context percentage bug'));

      final fallback = HarnessContextMonitor.buildFallbackCompactionSummary(
        turns,
        compactedMessages: 2,
        focusInstructions: 'Keep file paths',
      );
      expect(fallback, contains('Context Compacted (2 messages archived)'));
      expect(fallback, contains('Keep file paths'));
      expect(fallback, contains('Fix context percentage bug'));
      expect(fallback, contains('read_file (harness_engine.dart)'));
    });
  });

  group('HarnessFeatureItem & templates', () {
    test('parses and round-trips feature_list.json', () {
      final jsonText = HarnessWorkspaceTemplates.defaultFeatureListJson(
        'Build offline sync',
        verifyCommand: 'flutter test',
      );
      final items = HarnessFeatureItem.parseFeatureList(jsonText);
      expect(items, hasLength(3));
      expect(items[1].description, 'Build offline sync');
      expect(items.every((e) => !e.passes), isTrue);

      final updated = <HarnessFeatureItem>[
        items.first.copyWith(passes: true),
        ...items.skip(1),
      ];
      final reEncoded = HarnessFeatureItem.encodeFeatureList(updated);
      final reparsed = HarnessFeatureItem.parseFeatureList(reEncoded);
      expect(reparsed.first.passes, isTrue);
      expect(reparsed[1].passes, isFalse);
    });
  });
}
