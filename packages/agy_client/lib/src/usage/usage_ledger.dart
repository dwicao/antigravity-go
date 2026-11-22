import '../models/agy_model.dart';
import '../models/usage_quota.dart';
import '../protocol/usage_output_parser.dart';

/// A single recorded model turn stored in the local token & rate-limit ledger.
class UsageLedgerRecord {
  const UsageLedgerRecord({
    required this.timestamp,
    required this.modelId,
    required this.usage,
    this.sessionId,
  });

  final DateTime timestamp;
  final String modelId;
  final TokenUsage usage;
  final String? sessionId;

  QuotaGroup get quotaGroup => AgyModelCatalog.inferQuotaGroup(modelId);

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toUtc().toIso8601String(),
        'modelId': modelId,
        'usage': usage.toJson(),
        if (sessionId != null) 'sessionId': sessionId,
      };

  factory UsageLedgerRecord.fromJson(Map<String, dynamic> json) {
    return UsageLedgerRecord(
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
          DateTime.now().toUtc(),
      modelId: json['modelId'] as String? ?? 'gemini-3.8-flash',
      usage: TokenUsage.fromJson(
        json['usage'] as Map<String, dynamic>? ?? const {},
      ),
      sessionId: json['sessionId'] as String?,
    );
  }
}

/// Aggregates 5-hour and 7-day rolling usage windows and merges live `/usage` probes.
class UsageLedger {
  UsageLedger([Iterable<UsageLedgerRecord> initial = const []])
      : _records = List<UsageLedgerRecord>.from(initial);

  static const Duration fiveHourWindow = Duration(hours: 5);
  static const Duration weeklyWindow = Duration(days: 7);

  final List<UsageLedgerRecord> _records;

  List<UsageLedgerRecord> get records => List.unmodifiable(_records);

  void add(UsageLedgerRecord record) {
    _records.add(record);
    pruneOlderThan(const Duration(days: 14));
  }

  void pruneOlderThan(Duration maxAge, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(maxAge);
    _records.removeWhere((r) => r.timestamp.isBefore(cutoff));
  }

  TokenUsage sumWindow(
    Duration window, {
    QuotaGroup? group,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(window);
    var total = const TokenUsage();
    for (final r in _records) {
      if (r.timestamp.isBefore(cutoff)) continue;
      if (group != null && r.quotaGroup != group) continue;
      total = total + r.usage;
    }
    return total;
  }

  int countRequests(
    Duration window, {
    QuotaGroup? group,
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now().toUtc()).subtract(window);
    var count = 0;
    for (final r in _records) {
      if (r.timestamp.isBefore(cutoff)) continue;
      if (group != null && r.quotaGroup != group) continue;
      count++;
    }
    return count;
  }

  /// Builds a unified [UsageQuotaSnapshot] combining live CLI `/usage` data
  /// (when available) with exact 5-hour and weekly local ledger counters.
  UsageQuotaSnapshot buildSnapshot({
    ParsedUsageReport? liveProbe,
    bool useG1Credits = false,
    DateTime? now,
    String? rawProbeOutput,
    String? lastProbeError,
  }) {
    final current = now ?? DateTime.now().toUtc();
    final baseEntries = liveProbe?.entries ?? UsageQuotaSnapshot.initial().entries;

    final enriched = baseEntries.map((entry) {
      final fiveH = sumWindow(fiveHourWindow, group: entry.group, now: current);
      final week = sumWindow(weeklyWindow, group: entry.group, now: current);
      final fiveHReqs =
          countRequests(fiveHourWindow, group: entry.group, now: current);
      final weekReqs =
          countRequests(weeklyWindow, group: entry.group, now: current);
      return entry.copyWith(
        fiveHourTokensUsed: fiveH.totalTokens,
        weeklyTokensUsed: week.totalTokens,
        fiveHourRequests: fiveHReqs,
        weeklyRequests: weekReqs,
      );
    }).toList();

    return UsageQuotaSnapshot(
      entries: enriched,
      fetchedAt: current,
      discoveredModels: liveProbe?.discoveredModels ?? const [],
      aiCreditsRemaining: liveProbe?.aiCreditsRemaining,
      useG1Credits: useG1Credits,
      overallFiveHourRemainingPct: liveProbe?.overallFiveHourRemainingPct,
      overallWeeklyRemainingPct: liveProbe?.overallWeeklyRemainingPct,
      overallFiveHourResetText: liveProbe?.overallFiveHourResetText,
      overallWeeklyResetText: liveProbe?.overallWeeklyResetText,
      fiveHourLedgerTokens: sumWindow(fiveHourWindow, now: current),
      weeklyLedgerTokens: sumWindow(weeklyWindow, now: current),
      source: liveProbe != null ? 'agy-live+ledger' : 'local-ledger',
      rawProbeOutput: rawProbeOutput,
      lastProbeError: lastProbeError,
    );
  }
}
