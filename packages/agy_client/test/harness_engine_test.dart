import 'dart:io';

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

    test('assigns 1M budgets for Gemini 4, Orchestrator, and Flash', () {
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('Orchestrator (Neon)'),
        1000000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gemini-4-neon'),
        1000000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gemini-4-hydrogen'),
        1000000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gemini-3.8-flash'),
        1000000,
      );
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('claude-opus-5.5-thinking'),
        200000,
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
      expect(
        reparsed.first.copyWith(passes: false, clearVerifiedAt: true).verifiedAt,
        isNull,
      );
      final strictBad = HarnessFeatureItem.parseFeatureListStrict('{corrupt');
      expect(strictBad.hasParseError, isTrue);
      expect(strictBad.items, isEmpty);
      expect(
        HarnessWorkspaceTemplates.detectVerifyCommand(
          gradlewCommand: './gradlew testArm64DebugUnitTest',
        ),
        './gradlew testArm64DebugUnitTest',
      );
    });

    test('distinguishes long identical-prefix tool calls and handles in-place callId failures', () {
      final detector = HarnessLoopDetector(repeatThreshold: 3);
      final prefix = 'x' * 200;
      expect(
        detector
            .recordToolCall(name: 'read_file', input: '${prefix}A', callId: 'c1')
            .triggered,
        isFalse,
      );
      expect(
        detector
            .recordToolCall(name: 'read_file', input: '${prefix}B', callId: 'c2')
            .triggered,
        isFalse,
      );
      expect(
        detector
            .recordToolCall(name: 'read_file', input: '${prefix}C', callId: 'c3')
            .triggered,
        isFalse,
      );

      final failDetector = HarnessLoopDetector(failureThreshold: 2);
      failDetector.recordToolCall(
        name: 'run_command',
        input: '{"cmd":"test 1"}',
        callId: 'f1',
      );
      expect(failDetector.markLastFailed(callId: 'f1').triggered, isFalse);
      failDetector.recordToolCall(
        name: 'run_command',
        input: '{"cmd":"test 2"}',
        callId: 'f2',
      );
      final hit = failDetector.markLastFailed(callId: 'f2');
      expect(hit.triggered, isTrue);
      expect(hit.kind, HarnessLoopKind.repeatedFailure);

      final emptyInputDetector = HarnessLoopDetector(repeatThreshold: 3);
      for (var i = 0; i < 5; i++) {
        expect(
          emptyInputDetector
              .recordToolCall(name: 'edit_file', input: '{}', callId: 'e-$i')
              .triggered,
          isFalse,
        );
      }
    });

    test('supports gpt-oss model budget and preserves compaction anchor turn', () {
      expect(
        HarnessContextMonitor.effectiveBudgetForModel('gpt-oss-120b'),
        160000,
      );
      final turns = List<HarnessCompactionTurn>.generate(
        8,
        (i) => HarnessCompactionTurn(
          role: i.isEven ? 'user' : 'assistant',
          text: 'Turn $i ${'word ' * 1200}',
        ),
      );
      final prompt = HarnessContextMonitor.buildCompactionPrompt(
        turns,
        compactedMessages: turns.length,
      );
      expect(prompt, contains('Turn 0 '));
      expect(prompt, contains('Turn 7 '));
    });

    test('AgyAutomation.isDueAt evaluates interval and daily schedules', () {
      final now = DateTime(2026, 11, 23, 10, 0);
      const every15m = AgyAutomation(
        id: 'a1',
        name: 'Check',
        prompt: 'git status',
        scheduleLabel: 'Every 15m',
      );
      expect(every15m.isDueAt(now), isTrue);
      expect(
        every15m.copyWith(lastRunAt: now.subtract(const Duration(minutes: 5))).isDueAt(now),
        isFalse,
      );
      expect(
        every15m.copyWith(lastRunAt: now.subtract(const Duration(minutes: 20))).isDueAt(now),
        isTrue,
      );

      const daily = AgyAutomation(
        id: 'a2',
        name: 'Daily',
        prompt: 'summarize',
        scheduleLabel: 'Daily · 09:00',
      );
      expect(daily.isDueAt(DateTime(2026, 11, 23, 8, 59)), isFalse);
      expect(daily.isDueAt(now), isTrue);
      expect(
        daily.copyWith(lastRunAt: DateTime(2026, 11, 23, 9, 5)).isDueAt(now),
        isFalse,
      );
    });
  });

  group('HarnessTurnRouter & quota-capped monitor', () {
    test('routes ultrafast, fast, trivial prompts, and compaction cleanly', () {
      final compactRoute = HarnessTurnRouter.resolveCompactionRoute();
      expect(compactRoute.modelId, HarnessTurnRouter.fastCompactionModelId);
      expect(compactRoute.effort, 'low');

      final ultrafast = HarnessTurnRouter.routeTurn(
        prompt: 'Implement full OAuth login across 4 files',
        selectedModelId: 'Orchestrator (Neon)',
        selectedEffort: 'high',
        speedTierName: 'ultrafast',
        smartRoutingEnabled: true,
      );
      expect(ultrafast.modelId, 'gemini-3.8-flash');
      expect(ultrafast.effort, 'low');

      final fast = HarnessTurnRouter.routeTurn(
        prompt: 'Refactor lib/state/chat_state.dart cleanly',
        selectedModelId: 'gemini-4-neon',
        selectedEffort: 'xhigh',
        speedTierName: 'fast',
        smartRoutingEnabled: true,
      );
      expect(fast.modelId, 'gemini-4-hydrogen');
      expect(fast.effort, 'medium');
      expect(fast.skipRepoMap, isFalse);

      final trivial = HarnessTurnRouter.routeTurn(
        prompt: 'halo apa kabar',
        selectedModelId: 'Orchestrator (Neon)',
        selectedEffort: 'high',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
      );
      expect(trivial.modelId, 'gemini-4-hydrogen');
      expect(trivial.effort, 'low');
      expect(trivial.skipRepoMap, isTrue);

      final heavy = HarnessTurnRouter.routeTurn(
        prompt: 'Fix race condition in app/lib/state/chat_state.dart and add unit tests',
        selectedModelId: 'gemini-4-neon',
        selectedEffort: 'high',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
      );
      expect(heavy.modelId, 'gemini-4-neon');
      expect(heavy.effort, 'high');
      expect(heavy.skipRepoMap, isFalse);
    });

    test('caps auto-compact threshold at maxCompactTokens on 1M context models', () {
      const monitor = HarnessContextMonitor(maxCompactTokens: 160000);
      final big = List<String>.filled(650000, 'a').join();
      final snap = monitor.evaluate(
        messageTexts: [big],
        modelId: 'gemini-4-neon',
      );
      expect(snap.budgetTokens, 1000000);
      expect(snap.usedTokens, greaterThan(160000));
      expect(snap.shouldCompact, isTrue);
    });

    test('routes conversational acks to Flash Low under quotaSaverEnabled', () {
      final ack = HarnessTurnRouter.routeTurn(
        prompt: 'ok siap makasih',
        selectedModelId: 'Orchestrator (Neon)',
        selectedEffort: 'high',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(ack.modelId, HarnessTurnRouter.fastCompactionModelId);
      expect(ack.effort, 'low');
      expect(ack.skipRepoMap, isTrue);
      expect(ack.downgraded, isTrue);

      final shortQuestion = HarnessTurnRouter.routeTurn(
        prompt: 'what is riverpod?',
        selectedModelId: 'Orchestrator (Neon)',
        selectedEffort: 'high',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(shortQuestion.modelId, HarnessTurnRouter.fastCodingModelId);
      expect(shortQuestion.effort, 'low');
    });

    test('RepoMapBuilder uses BFS so deep early dirs do not starve sibling modules', () async {
      final tmp = await Directory.systemTemp.createTemp('agy_bfs_map_');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final deepAndroid = Directory('${tmp.path}/android/app/src/main/kotlin');
      final libDir = Directory('${tmp.path}/lib');
      final pkgDir = Directory('${tmp.path}/packages');
      await deepAndroid.create(recursive: true);
      await libDir.create(recursive: true);
      await pkgDir.create(recursive: true);

      for (var i = 1; i <= 5; i++) {
        await File('${deepAndroid.path}/Helper$i.kt')
            .writeAsString('class Helper$i {}\n');
      }
      await File('${libDir.path}/main.dart')
          .writeAsString('class MyApp {}\nvoid main() {}\n');
      await File('${pkgDir.path}/core.dart')
          .writeAsString('class CoreEngine {}\n');

      final map = await RepoMapBuilder.buildFromDirectory(
        tmp.path,
        maxFiles: 3,
        useCache: false,
      );
      expect(map, contains('lib/main.dart'));
      expect(map, contains('packages/core.dart'));
    });
  });
}
