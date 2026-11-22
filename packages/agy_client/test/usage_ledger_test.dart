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

      final argon = snapshot.entries.firstWhere((e) => e.id == 'gemini-4-argon');
      expect(argon.fiveHourTokensUsed, 1500);
      expect(argon.fiveHourRequests, 1);

      final claudeGpt =
          snapshot.entries.firstWhere((e) => e.id == 'claude-gpt');
      expect(claudeGpt.fiveHourTokensUsed, 0);
      expect(claudeGpt.weeklyTokensUsed, 5000);
    });
  });
}
