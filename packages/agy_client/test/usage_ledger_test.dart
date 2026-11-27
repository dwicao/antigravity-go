import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('UsageLedger', () {
    test('aggregates 5-hour and weekly windows per quota group', () {
      final now = DateTime.utc(2026, 11, 22, 12, 0);
      final ledger = UsageLedger([
        UsageLedgerRecord(
          timestamp: now.subtract(const Duration(hours: 2)),
          modelId: 'gemini-4-argon',
          usage: const TokenUsage(
            inputTokens: 1000,
            outputTokens: 500,
            thinkingTokens: 200,
            totalTokens: 1500,
          ),
        ),
        UsageLedgerRecord(
          timestamp: now.subtract(const Duration(days: 2)),
          modelId: 'claude-opus-5.5-thinking',
          usage: const TokenUsage(
            inputTokens: 4000,
            outputTokens: 1000,
            totalTokens: 5000,
          ),
        ),
        UsageLedgerRecord(
          timestamp: now.subtract(const Duration(days: 10)),
          modelId: 'gemini-4-neon',
          usage: const TokenUsage(totalTokens: 99999),
        ),
      ]);

      final snapshot = ledger.buildSnapshot(now: now, useG1Credits: true);
      expect(snapshot.fiveHourLedgerTokens.totalTokens, 1500);
      expect(snapshot.weeklyLedgerTokens.totalTokens, 6500);
      expect(snapshot.useG1Credits, isTrue);

      final gemini = snapshot.entries.firstWhere((e) => e.id == 'gemini-models');
      expect(gemini.fiveHourTokensUsed, 1500);
      expect(gemini.fiveHourRequests, 1);
      expect(gemini.weeklyTokensUsed, 1500);

      final claudeGpt =
          snapshot.entries.firstWhere((e) => e.id == 'claude-gpt');
      expect(claudeGpt.fiveHourTokensUsed, 0);
      expect(claudeGpt.weeklyTokensUsed, 5000);
    });

    test('LifetimeUsageStats and UsageStatsAggregator compute spend, cache savings, and timeframes',
        () {
      final now = DateTime.utc(2026, 11, 27, 6, 0);
      final oldTurn = UsageLedgerRecord(
        timestamp: now.subtract(const Duration(days: 20)),
        modelId: 'gemini-4-neon',
        sessionId: 's-old',
        usage: const TokenUsage(
          inputTokens: 100000,
          cacheReadTokens: 60000,
          outputTokens: 20000,
          thinkingTokens: 10000,
          totalTokens: 130000,
        ),
      );
      final recentTurn = UsageLedgerRecord(
        timestamp: now.subtract(const Duration(hours: 2)),
        modelId: 'gemini-4-hydrogen',
        sessionId: 's-new',
        usage: const TokenUsage(
          inputTokens: 50000,
          cacheReadTokens: 25000,
          outputTokens: 10000,
          thinkingTokens: 5000,
          totalTokens: 65000,
        ),
      );

      final ledger = UsageLedger([oldTurn, recentTurn]);
      // Rolling ledger prunes turns older than 14 days on add(), whereas lifetime preserves all-time.
      ledger.pruneOlderThan(const Duration(days: 14), now: now);
      var lifetime = LifetimeUsageStats.empty.addRecord(oldTurn).addRecord(recentTurn);
      lifetime = LifetimeUsageStats.decodeJson(lifetime.encodeJson());

      final allTime = UsageStatsAggregator.build(
        ledger: ledger,
        lifetime: lifetime,
        timeframe: StatsTimeframe.allTime,
        now: now,
      );
      expect(allTime.requests, 2);
      expect(allTime.distinctSessions, 2);
      expect(allTime.usage.totalTokens, 195000);
      expect(allTime.cacheSavedUsd, greaterThan(0.05));
      expect(allTime.models.length, 2);
      expect(allTime.models.first.modelId, 'gemini-4-neon');
      expect(allTime.toMarkdownReport(), contains('Gemini 4 Neon'));

      final fiveHours = UsageStatsAggregator.build(
        ledger: ledger,
        lifetime: lifetime,
        timeframe: StatsTimeframe.fiveHours,
        now: now,
      );
      expect(fiveHours.requests, 1);
      expect(fiveHours.usage.totalTokens, 65000);
      expect(fiveHours.models.single.modelId, 'gemini-4-hydrogen');
    });

    test('computes cacheHitRatePct accurately when cacheReadTokens exceeds inputTokens or inputTokens is zero',
        () {
      final now = DateTime.utc(2026, 11, 27, 7, 0);
      final acpParsed = TokenUsage.fromJson({
        'inputTokens': 12000,
        'cachedReadTokens': 30000,
        'outputTokens': 250,
        'thoughtTokens': 500,
        'totalTokens': 12750,
      });
      expect(acpParsed.cacheReadTokens, 30000);
      expect(acpParsed.thinkingTokens, 500);

      final openaiParsed = TokenUsage.fromJson({
        'prompt_tokens': 1000,
        'completion_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 750},
        'completion_tokens_details': {'reasoning_tokens': 40},
      });
      expect(openaiParsed.cacheReadTokens, 750);
      expect(openaiParsed.thinkingTokens, 40);

      final turn1 = UsageLedgerRecord(
        timestamp: now,
        modelId: 'gemini-4-hydrogen',
        sessionId: 's1',
        usage: acpParsed,
      );
      final turn2 = UsageLedgerRecord(
        timestamp: now,
        modelId: 'gemini-4-hydrogen',
        sessionId: 's1',
        usage: const TokenUsage(
          inputTokens: 0,
          cacheReadTokens: 8000,
          outputTokens: 100,
          totalTokens: 100,
        ),
      );

      final ledger = UsageLedger([turn1, turn2]);
      final lifetime = LifetimeUsageStats.empty.addRecord(turn1).addRecord(turn2);
      final summary = UsageStatsAggregator.build(
        ledger: ledger,
        lifetime: lifetime,
        timeframe: StatsTimeframe.allTime,
        now: now,
      );

      // Total prompt = 12,000 uncached + 38,000 cached = 50,000 -> 76.0% hit rate.
      expect(summary.uncachedInputTokens, 12000);
      expect(summary.usage.cacheReadTokens, 38000);
      expect(summary.cacheHitRatePct, closeTo(76.0, 0.01));
      expect(summary.models.single.cacheHitRatePct, closeTo(76.0, 0.01));

      final fullCacheSummary = UsageStatsSummary(
        timeframe: StatsTimeframe.allTime,
        requests: 1,
        distinctSessions: 1,
        usage: const TokenUsage(inputTokens: 0, cacheReadTokens: 5000),
        estimatedCostUsd: 0.0,
        cacheSavedUsd: 0.0,
        models: const [],
        dailySeries: const [],
      );
      expect(fullCacheSummary.cacheHitRatePct, closeTo(100.0, 0.01));
    });
  });
}
