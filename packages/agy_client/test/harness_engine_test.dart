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
