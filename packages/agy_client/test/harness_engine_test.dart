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
    test('preserves selected model across ultrafast, fast, and compaction routes',
        () {
      final hydrogenCompact = HarnessTurnRouter.resolveCompactionRoute(
        selectedModelId: 'gemini-4-hydrogen',
      );
      expect(hydrogenCompact.modelId, 'gemini-4-hydrogen');
      expect(hydrogenCompact.effort, 'low');

      final orchestratorCompact = HarnessTurnRouter.resolveCompactionRoute(
        selectedModelId: 'Orchestrator (Neon)',
      );
      expect(orchestratorCompact.modelId, 'Orchestrator (Neon)');
      expect(orchestratorCompact.effort, isEmpty);

      final ultrafastHydrogen = HarnessTurnRouter.routeTurn(
        prompt: 'Implement full OAuth login across 4 files',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'xhigh',
        speedTierName: 'ultrafast',
        smartRoutingEnabled: true,
      );
      expect(ultrafastHydrogen.modelId, 'gemini-4-hydrogen');
      expect(ultrafastHydrogen.effort, 'low');
      expect(ultrafastHydrogen.downgraded, isTrue);

      final ultrafastOrchestrator = HarnessTurnRouter.routeTurn(
        prompt: 'Implement full OAuth login across 4 files',
        selectedModelId: 'Orchestrator (Neon)',
        selectedEffort: '',
        speedTierName: 'ultrafast',
        smartRoutingEnabled: true,
      );
      expect(ultrafastOrchestrator.modelId, 'Orchestrator (Neon)');
      expect(ultrafastOrchestrator.effort, '');
      expect(ultrafastOrchestrator.downgraded, isFalse);

      final fast = HarnessTurnRouter.routeTurn(
        prompt: 'Refactor lib/state/chat_state.dart cleanly',
        selectedModelId: 'gemini-4-neon',
        selectedEffort: 'xhigh',
        speedTierName: 'fast',
        smartRoutingEnabled: true,
      );
      expect(fast.modelId, 'gemini-4-neon');
      expect(fast.effort, 'medium');
      expect(fast.skipRepoMap, isFalse);
      expect(fast.downgraded, isTrue);
    });

    test('caps auto-compact threshold at maxCompactTokens on 1M context models', () {
      const monitor = HarnessContextMonitor(maxCompactTokens: 256000);
      final belowFloor = List<String>.filled(700000, 'a').join();
      final snapLow = monitor.evaluate(
        messageTexts: [belowFloor],
        modelId: 'gemini-4-neon',
      );
      expect(snapLow.budgetTokens, 1000000);
      expect(snapLow.usedTokens, greaterThan(180000));
      expect(snapLow.usedTokens, lessThan(256000));
      expect(snapLow.shouldCompact, isFalse);

      final big = List<String>.filled(1050000, 'a').join();
      final snap = monitor.evaluate(
        messageTexts: [big],
        modelId: 'gemini-4-neon',
      );
      expect(snap.budgetTokens, 1000000);
      expect(snap.usedTokens, greaterThan(256000));
      expect(snap.shouldCompact, isTrue);
      expect(snap.compactAtTokens, 256000);
    });

    test('resolveAdaptiveCompactTokens uses 256K floor and scales to 512K/800K for refactors', () {
      expect(
        HarnessContextMonitor.resolveAdaptiveCompactTokens(
          quotaSaverEnabled: false,
          budgetTokens: 1000000,
        ),
        isNull,
      );
      expect(
        HarnessContextMonitor.resolveAdaptiveCompactTokens(
          quotaSaverEnabled: true,
          budgetTokens: 1000000,
          recentPrompts: ['Explain this error concisely'],
          reasoningEffort: 'medium',
        ),
        256000,
      );
      expect(
        HarnessContextMonitor.resolveAdaptiveCompactTokens(
          quotaSaverEnabled: true,
          budgetTokens: 1000000,
          recentPrompts: ['Update button padding'],
          toolCallCount: 10,
        ),
        512000,
      );
      expect(
        HarnessContextMonitor.resolveAdaptiveCompactTokens(
          quotaSaverEnabled: true,
          budgetTokens: 1000000,
          recentPrompts: ['Refactor auth and state layer across modules'],
        ),
        800000,
      );
      expect(
        HarnessContextMonitor.resolveAdaptiveCompactTokens(
          quotaSaverEnabled: true,
          budgetTokens: 1000000,
          changedFileCount: 5,
        ),
        800000,
      );
    });

    test('adapts thinking effort across low/medium/high/extra/max while obeying selected model',
        () {
      final ack = HarnessTurnRouter.routeTurn(
        prompt: 'ok siap makasih',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(ack.modelId, 'gemini-4-hydrogen');
      expect(ack.effort, 'low');
      expect(ack.skipRepoMap, isTrue);
      expect(ack.downgraded, isTrue);

      final standardQuestion = HarnessTurnRouter.routeTurn(
        prompt: 'what is riverpod?',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(standardQuestion.modelId, 'gemini-4-hydrogen');
      expect(standardQuestion.effort, 'medium');
      expect(standardQuestion.downgraded, isFalse);

      final complexFix = HarnessTurnRouter.routeTurn(
        prompt: 'Fix typo in app/lib/state/chat_state.dart and add unit tests',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(complexFix.modelId, 'gemini-4-hydrogen');
      expect(complexFix.effort, 'high');
      expect(complexFix.skipRepoMap, isFalse);
      expect(complexFix.downgraded, isFalse);

      final deepDesign = HarnessTurnRouter.routeTurn(
        prompt: 'Redesign multi-file auth architecture end-to-end',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(deepDesign.modelId, 'gemini-4-hydrogen');
      expect(deepDesign.effort, 'xhigh');
      expect(deepDesign.downgraded, isFalse);

      final maxAudit = HarnessTurnRouter.routeTurn(
        prompt:
            'Audit the entire codebase for security leaks and redesign multi-file auth architecture end-to-end',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
        quotaSaverEnabled: true,
      );
      expect(maxAudit.modelId, 'gemini-4-hydrogen');
      expect(maxAudit.effort, 'max');
      expect(maxAudit.downgraded, isFalse);

      final claudeMax = HarnessTurnRouter.routeTurn(
        prompt: '/boost refactor auth state across modules',
        selectedModelId: 'claude-opus-5-5-medium',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
      );
      expect(claudeMax.modelId, 'claude-opus-5-5-medium');
      expect(claudeMax.effort, 'max');

      final carbonExtraFallback = HarnessTurnRouter.routeTurn(
        prompt: '/plan migrate state management across modules',
        selectedModelId: 'gemini-4-carbon',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
      );
      expect(carbonExtraFallback.modelId, 'gemini-4-carbon');
      expect(carbonExtraFallback.effort, 'high');

      final flashCappedHigh = HarnessTurnRouter.routeTurn(
        prompt: 'Audit the entire codebase from scratch',
        selectedModelId: 'gemini-3.8-flash',
        selectedEffort: 'medium',
        speedTierName: 'regular',
        smartRoutingEnabled: true,
      );
      expect(flashCappedHigh.modelId, 'gemini-3.8-flash');
      expect(flashCappedHigh.effort, 'high');

      expect(
        AgyModelCatalog.resolve('claude-opus-5-5-medium').availableEfforts,
        contains(ReasoningEffort.max),
      );
      expect(
        AgyModelCatalog.resolve('gemini-4-carbon').availableEfforts,
        contains(ReasoningEffort.max),
      );

      final manualOnly = HarnessTurnRouter.routeTurn(
        prompt: 'ok siap makasih',
        selectedModelId: 'gemini-4-hydrogen',
        selectedEffort: 'high',
        speedTierName: 'regular',
        smartRoutingEnabled: false,
      );
      expect(manualOnly.modelId, 'gemini-4-hydrogen');
      expect(manualOnly.effort, 'high');
      expect(manualOnly.downgraded, isFalse);
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

    test('HarnessContextSnapshot implements value equality and RepoMapBuilder hits cache for same parameters', () async {
      const a = HarnessContextSnapshot(
        usedTokens: 12000,
        budgetTokens: 256000,
        ratio: 12000 / 256000,
        needsWarning: false,
        shouldCompact: false,
        statusLabel: 'Healthy',
        compactedMessages: 1,
        activeMessages: 8,
        compactAtTokens: 204800,
      );
      const b = HarnessContextSnapshot(
        usedTokens: 12000,
        budgetTokens: 256000,
        ratio: 12000 / 256000,
        needsWarning: false,
        shouldCompact: false,
        statusLabel: 'Healthy',
        compactedMessages: 1,
        activeMessages: 8,
        compactAtTokens: 204800,
      );
      const c = HarnessContextSnapshot(
        usedTokens: 13000,
        budgetTokens: 256000,
        ratio: 13000 / 256000,
        needsWarning: false,
        shouldCompact: false,
        statusLabel: 'Healthy',
        compactedMessages: 1,
        activeMessages: 8,
        compactAtTokens: 204800,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));

      final tmp = await Directory.systemTemp.createTemp('agy_cache_map_');
      addTearDown(() async {
        RepoMapBuilder.invalidateCache(tmp.path);
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final src = File('${tmp.path}/sample.dart');
      await src.writeAsString('class CachedWidget {}\n');
      final first = await RepoMapBuilder.buildFromDirectory(
        tmp.path,
        maxTokens: 600,
        maxFiles: 80,
      );
      expect(first, contains('CachedWidget'));

      // Overwrite file without invalidating cache: second identical call serves cached map.
      await src.writeAsString('class ModifiedWidget {}\n');
      final cached = await RepoMapBuilder.buildFromDirectory(
        tmp.path,
        maxTokens: 600,
        maxFiles: 80,
      );
      expect(cached, equals(first));
    });
  });
}
