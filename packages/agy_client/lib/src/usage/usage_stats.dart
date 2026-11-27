import 'dart:convert';
import 'dart:math' as math;

import '../models/agy_model.dart';
import '../models/usage_quota.dart';
import 'model_pricing.dart';
import 'usage_ledger.dart';

/// Selectable reporting timeframe on the Stats screen.
enum StatsTimeframe {
  fiveHours('5h', '5 Hours'),
  twentyFourHours('24h', '24 Hours'),
  sevenDays('7d', '7 Days'),
  fourteenDays('14d', '14 Days'),
  allTime('All', 'All-Time');

  const StatsTimeframe(this.shortLabel, this.label);

  final String shortLabel;
  final String label;
}

/// Cumulative usage, request count, and cost metrics for one model ID.
class ModelUsageAggregate {
  const ModelUsageAggregate({
    required this.modelId,
    this.requests = 0,
    this.usage = const TokenUsage(),
    this.estimatedCostUsd = 0.0,
    this.cacheSavedUsd = 0.0,
    this.lastUsedAt,
  });

  final String modelId;
  final int requests;
  final TokenUsage usage;
  final double estimatedCostUsd;
  final double cacheSavedUsd;
  final DateTime? lastUsedAt;

  String get displayName => AgyModelCatalog.resolve(modelId).displayName;

  String get provider => AgyModelCatalog.inferProvider(modelId);

  QuotaGroup get quotaGroup => AgyModelCatalog.inferQuotaGroup(modelId);

  double get avgTokensPerRequest =>
      requests > 0 ? usage.totalTokens / requests : 0.0;

  double get avgCostPerRequestUsd =>
      requests > 0 ? estimatedCostUsd / requests : 0.0;

  double get cacheHitRatePct => UsageStatsSummary.computeCacheHitRatePct(usage);

  ModelUsageAggregate addTurn(
    TokenUsage turnUsage, {
    required double costUsd,
    required double cacheSaved,
    required DateTime timestamp,
  }) {
    final nextLast =
        lastUsedAt == null || timestamp.isAfter(lastUsedAt!)
            ? timestamp
            : lastUsedAt;
    return ModelUsageAggregate(
      modelId: modelId,
      requests: requests + 1,
      usage: usage + turnUsage,
      estimatedCostUsd: estimatedCostUsd + costUsd,
      cacheSavedUsd: cacheSavedUsd + cacheSaved,
      lastUsedAt: nextLast,
    );
  }

  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        'requests': requests,
        'usage': usage.toJson(),
        'estimatedCostUsd': estimatedCostUsd,
        'cacheSavedUsd': cacheSavedUsd,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toUtc().toIso8601String(),
      };

  factory ModelUsageAggregate.fromJson(Map<String, dynamic> json) {
    return ModelUsageAggregate(
      modelId: json['modelId']?.toString() ?? 'unknown',
      requests: (json['requests'] as num?)?.toInt() ?? 0,
      usage: TokenUsage.fromJson(
        json['usage'] as Map<String, dynamic>? ?? const {},
      ),
      estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0.0,
      cacheSavedUsd: (json['cacheSavedUsd'] as num?)?.toDouble() ?? 0.0,
      lastUsedAt: DateTime.tryParse(json['lastUsedAt']?.toString() ?? ''),
    );
  }
}

/// Usage, request, and USD cost totals bucketed for a single calendar date (`YYYY-MM-DD`).
class DailyUsageBucket {
  const DailyUsageBucket({
    required this.dateKey,
    required this.date,
    this.requests = 0,
    this.usage = const TokenUsage(),
    this.estimatedCostUsd = 0.0,
    this.cacheSavedUsd = 0.0,
  });

  final String dateKey;
  final DateTime date;
  final int requests;
  final TokenUsage usage;
  final double estimatedCostUsd;
  final double cacheSavedUsd;

  DailyUsageBucket addTurn(
    TokenUsage turnUsage, {
    required double costUsd,
    required double cacheSaved,
  }) {
    return DailyUsageBucket(
      dateKey: dateKey,
      date: date,
      requests: requests + 1,
      usage: usage + turnUsage,
      estimatedCostUsd: estimatedCostUsd + costUsd,
      cacheSavedUsd: cacheSavedUsd + cacheSaved,
    );
  }

  Map<String, dynamic> toJson() => {
        'dateKey': dateKey,
        'requests': requests,
        'usage': usage.toJson(),
        'estimatedCostUsd': estimatedCostUsd,
        'cacheSavedUsd': cacheSavedUsd,
      };

  factory DailyUsageBucket.fromJson(Map<String, dynamic> json) {
    final key = json['dateKey']?.toString() ?? '1970-01-01';
    final parsed = _parseDateKey(key);
    return DailyUsageBucket(
      dateKey: key,
      date: parsed,
      requests: (json['requests'] as num?)?.toInt() ?? 0,
      usage: TokenUsage.fromJson(
        json['usage'] as Map<String, dynamic>? ?? const {},
      ),
      estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0.0,
      cacheSavedUsd: (json['cacheSavedUsd'] as num?)?.toDouble() ?? 0.0,
    );
  }

  static String formatDateKey(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime _parseDateKey(String key) {
    final parts = key.split('-');
    if (parts.length == 3) {
      final y = int.tryParse(parts[0]) ?? 1970;
      final m = int.tryParse(parts[1]) ?? 1;
      final d = int.tryParse(parts[2]) ?? 1;
      return DateTime.utc(y, m, d);
    }
    return DateTime.utc(1970, 1, 1);
  }
}

/// Persistent all-time totals surviving `UsageLedger`'s 14-day rolling prune window.
class LifetimeUsageStats {
  const LifetimeUsageStats({
    this.startedAt,
    this.updatedAt,
    this.totalRequests = 0,
    this.usage = const TokenUsage(),
    this.estimatedCostUsd = 0.0,
    this.cacheSavedUsd = 0.0,
    this.byModel = const <String, ModelUsageAggregate>{},
    this.dailyBuckets = const <String, DailyUsageBucket>{},
    this.trackedSessionIds = const <String>[],
  });

  static const LifetimeUsageStats empty = LifetimeUsageStats();
  static const int _maxDailyBucketsRetained = 90;
  static const int _maxTrackedSessionIds = 1000;

  final DateTime? startedAt;
  final DateTime? updatedAt;
  final int totalRequests;
  final TokenUsage usage;
  final double estimatedCostUsd;
  final double cacheSavedUsd;
  final Map<String, ModelUsageAggregate> byModel;
  final Map<String, DailyUsageBucket> dailyBuckets;
  final List<String> trackedSessionIds;

  /// Estimates USD saved from prompt-cache reads vs full uncached input rates.
  static double estimateCacheSavingsUsd(String modelId, TokenUsage usage) {
    if (usage.cacheReadTokens <= 0) return 0.0;
    final tier = ModelPricingCatalog.resolve(modelId);
    final cacheRate =
        tier.cacheReadPerMillionUsd ?? (tier.inputPerMillionUsd * 0.25);
    final diff = math.max(0.0, tier.inputPerMillionUsd - cacheRate);
    return (usage.cacheReadTokens / 1000000.0) * diff;
  }

  LifetimeUsageStats addRecord(UsageLedgerRecord record) {
    final ts = record.timestamp.toUtc();
    final costUsd =
        ModelPricingCatalog.estimateTurnCostUsd(record.modelId, record.usage);
    final cacheSaved = estimateCacheSavingsUsd(record.modelId, record.usage);

    final nextStart =
        startedAt == null || ts.isBefore(startedAt!) ? ts : startedAt;
    final nextUpdated =
        updatedAt == null || ts.isAfter(updatedAt!) ? ts : updatedAt;

    final nextModels = Map<String, ModelUsageAggregate>.from(byModel);
    final existingModel =
        nextModels[record.modelId] ?? ModelUsageAggregate(modelId: record.modelId);
    nextModels[record.modelId] = existingModel.addTurn(
      record.usage,
      costUsd: costUsd,
      cacheSaved: cacheSaved,
      timestamp: ts,
    );

    final dayKey = DailyUsageBucket.formatDateKey(ts);
    final nextDaily = Map<String, DailyUsageBucket>.from(dailyBuckets);
    final existingDay = nextDaily[dayKey] ??
        DailyUsageBucket(
          dateKey: dayKey,
          date: DailyUsageBucket._parseDateKey(dayKey),
        );
    nextDaily[dayKey] = existingDay.addTurn(
      record.usage,
      costUsd: costUsd,
      cacheSaved: cacheSaved,
    );
    if (nextDaily.length > _maxDailyBucketsRetained) {
      final sortedKeys = nextDaily.keys.toList()..sort();
      for (final oldKey in sortedKeys.take(
        nextDaily.length - _maxDailyBucketsRetained,
      )) {
        nextDaily.remove(oldKey);
      }
    }

    var nextSessions = trackedSessionIds;
    final sid = record.sessionId?.trim();
    if (sid != null && sid.isNotEmpty && !trackedSessionIds.contains(sid)) {
      nextSessions = [
        ...trackedSessionIds,
        sid,
      ];
      if (nextSessions.length > _maxTrackedSessionIds) {
        nextSessions = nextSessions.sublist(
          nextSessions.length - _maxTrackedSessionIds,
        );
      }
    }

    return LifetimeUsageStats(
      startedAt: nextStart,
      updatedAt: nextUpdated,
      totalRequests: totalRequests + 1,
      usage: usage + record.usage,
      estimatedCostUsd: estimatedCostUsd + costUsd,
      cacheSavedUsd: cacheSavedUsd + cacheSaved,
      byModel: nextModels,
      dailyBuckets: nextDaily,
      trackedSessionIds: nextSessions,
    );
  }

  static LifetimeUsageStats fromRecords(Iterable<UsageLedgerRecord> records) {
    var acc = LifetimeUsageStats.empty;
    for (final r in records) {
      acc = acc.addRecord(r);
    }
    return acc;
  }

  Map<String, dynamic> toJson() => {
        if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
        'totalRequests': totalRequests,
        'usage': usage.toJson(),
        'estimatedCostUsd': estimatedCostUsd,
        'cacheSavedUsd': cacheSavedUsd,
        'byModel': {
          for (final e in byModel.entries) e.key: e.value.toJson(),
        },
        'dailyBuckets': {
          for (final e in dailyBuckets.entries) e.key: e.value.toJson(),
        },
        'trackedSessionIds': trackedSessionIds,
      };

  String encodeJson() => jsonEncode(toJson());

  factory LifetimeUsageStats.fromJson(Map<String, dynamic> json) {
    final modelsRaw = json['byModel'] as Map<String, dynamic>? ?? const {};
    final dailyRaw = json['dailyBuckets'] as Map<String, dynamic>? ?? const {};
    final sessionsRaw = json['trackedSessionIds'] as List<dynamic>? ?? const [];

    return LifetimeUsageStats(
      startedAt: DateTime.tryParse(json['startedAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      totalRequests: (json['totalRequests'] as num?)?.toInt() ?? 0,
      usage: TokenUsage.fromJson(
        json['usage'] as Map<String, dynamic>? ?? const {},
      ),
      estimatedCostUsd: (json['estimatedCostUsd'] as num?)?.toDouble() ?? 0.0,
      cacheSavedUsd: (json['cacheSavedUsd'] as num?)?.toDouble() ?? 0.0,
      byModel: {
        for (final e in modelsRaw.entries)
          if (e.value is Map<String, dynamic>)
            e.key: ModelUsageAggregate.fromJson(e.value as Map<String, dynamic>),
      },
      dailyBuckets: {
        for (final e in dailyRaw.entries)
          if (e.value is Map<String, dynamic>)
            e.key: DailyUsageBucket.fromJson(e.value as Map<String, dynamic>),
      },
      trackedSessionIds: sessionsRaw.map((e) => e.toString()).toList(),
    );
  }

  static LifetimeUsageStats decodeJson(String raw) {
    if (raw.trim().isEmpty) return LifetimeUsageStats.empty;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return LifetimeUsageStats.fromJson(decoded);
      }
    } catch (_) {}
    return LifetimeUsageStats.empty;
  }
}

/// Complete analytics snapshot produced for a chosen [StatsTimeframe].
class UsageStatsSummary {
  const UsageStatsSummary({
    required this.timeframe,
    required this.requests,
    required this.distinctSessions,
    required this.usage,
    required this.estimatedCostUsd,
    required this.cacheSavedUsd,
    required this.models,
    required this.dailySeries,
    this.startedAt,
    this.updatedAt,
  });

  final StatsTimeframe timeframe;
  final int requests;
  final int distinctSessions;
  final TokenUsage usage;
  final double estimatedCostUsd;
  final double cacheSavedUsd;
  final List<ModelUsageAggregate> models;
  final List<DailyUsageBucket> dailySeries;
  final DateTime? startedAt;
  final DateTime? updatedAt;

  int get uncachedInputTokens => usage.inputTokens;

  /// Computes cache hit percentage across total prompt tokens (`input + cacheRead`).
  static double computeCacheHitRatePct(TokenUsage usage) {
    final totalInput = usage.inputTokens + usage.cacheReadTokens;
    if (totalInput <= 0 || usage.cacheReadTokens <= 0) return 0.0;
    return ((usage.cacheReadTokens / totalInput) * 100.0).clamp(0.0, 100.0);
  }

  double get cacheHitRatePct => computeCacheHitRatePct(usage);

  double get thinkingSharePct => usage.totalTokens > 0
      ? ((usage.thinkingTokens / usage.totalTokens) * 100.0).clamp(0.0, 100.0)
      : 0.0;

  double get avgCostPerRequestUsd =>
      requests > 0 ? estimatedCostUsd / requests : 0.0;

  double get avgTokensPerRequest =>
      requests > 0 ? usage.totalTokens / requests : 0.0;

  DailyUsageBucket? get peakCostDay {
    DailyUsageBucket? best;
    for (final d in dailySeries) {
      if (best == null || d.estimatedCostUsd > best.estimatedCostUsd) {
        best = d;
      }
    }
    return best != null && best.requests > 0 ? best : null;
  }

  /// Formats integer token/request counts cleanly (`1.24M`, `48.2K`, `850`).
  static String formatCompactCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(2)}M';
    }
    if (value >= 10000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(2)}K';
    }
    return '$value';
  }

  String toMarkdownReport() {
    final buf = StringBuffer()
      ..writeln('# Antigravity Go — Stats (${timeframe.label})')
      ..writeln()
      ..writeln('- **Estimated Spend:** ${ModelPricingCatalog.formatUsd(estimatedCostUsd)} (Saved via cache: ${ModelPricingCatalog.formatUsd(cacheSavedUsd)})')
      ..writeln('- **Requests / Turns:** $requests across $distinctSessions sessions')
      ..writeln('- **Total Tokens:** ${formatCompactCount(usage.totalTokens)} (${usage.totalTokens})')
      ..writeln('  - Uncached Input: ${formatCompactCount(uncachedInputTokens)}')
      ..writeln('  - Cache Read: ${formatCompactCount(usage.cacheReadTokens)} (${cacheHitRatePct.toStringAsFixed(1)}% hit rate)')
      ..writeln('  - Output: ${formatCompactCount(usage.outputTokens)}')
      ..writeln('  - Thinking: ${formatCompactCount(usage.thinkingTokens)} (${thinkingSharePct.toStringAsFixed(1)}%)')
      ..writeln();
    if (models.isNotEmpty) {
      buf.writeln('## Per-Model Breakdown');
      for (final m in models) {
        buf.writeln(
          '- **${m.displayName}** (`${m.modelId}`): ${ModelPricingCatalog.formatUsd(m.estimatedCostUsd)} · ${m.requests} reqs · ${formatCompactCount(m.usage.totalTokens)} tok',
        );
      }
    }
    return buf.toString().trimRight();
  }
}

/// Aggregates [UsageLedger] and [LifetimeUsageStats] into [UsageStatsSummary].
class UsageStatsAggregator {
  const UsageStatsAggregator._();

  static UsageStatsSummary build({
    required UsageLedger ledger,
    required LifetimeUsageStats lifetime,
    required StatsTimeframe timeframe,
    DateTime? now,
  }) {
    final current = (now ?? DateTime.now()).toUtc();
    final seriesDays = timeframe == StatsTimeframe.sevenDays ? 7 : 14;

    if (timeframe == StatsTimeframe.allTime) {
      final models = lifetime.byModel.values.toList()
        ..sort((a, b) => b.estimatedCostUsd.compareTo(a.estimatedCostUsd));
      final dailySeries = _buildContinuousDailySeries(
        buckets: lifetime.dailyBuckets,
        days: seriesDays,
        nowUtc: current,
      );
      return UsageStatsSummary(
        timeframe: timeframe,
        requests: lifetime.totalRequests,
        distinctSessions: lifetime.trackedSessionIds.length,
        usage: lifetime.usage,
        estimatedCostUsd: lifetime.estimatedCostUsd,
        cacheSavedUsd: lifetime.cacheSavedUsd,
        models: models,
        dailySeries: dailySeries,
        startedAt: lifetime.startedAt,
        updatedAt: lifetime.updatedAt,
      );
    }

    final windowDuration = switch (timeframe) {
      StatsTimeframe.fiveHours => const Duration(hours: 5),
      StatsTimeframe.twentyFourHours => const Duration(hours: 24),
      StatsTimeframe.sevenDays => const Duration(days: 7),
      StatsTimeframe.fourteenDays => const Duration(days: 14),
      StatsTimeframe.allTime => const Duration(days: 36500),
    };
    final cutoff = current.subtract(windowDuration);

    var acc = LifetimeUsageStats.empty;
    for (final r in ledger.records) {
      if (r.timestamp.isBefore(cutoff)) continue;
      acc = acc.addRecord(r);
    }

    final models = acc.byModel.values.toList()
      ..sort((a, b) => b.estimatedCostUsd.compareTo(a.estimatedCostUsd));
    final dailySeries = _buildContinuousDailySeries(
      buckets: acc.dailyBuckets,
      days: timeframe == StatsTimeframe.fiveHours ||
              timeframe == StatsTimeframe.twentyFourHours
          ? 7
          : seriesDays,
      nowUtc: current,
    );

    return UsageStatsSummary(
      timeframe: timeframe,
      requests: acc.totalRequests,
      distinctSessions: acc.trackedSessionIds.length,
      usage: acc.usage,
      estimatedCostUsd: acc.estimatedCostUsd,
      cacheSavedUsd: acc.cacheSavedUsd,
      models: models,
      dailySeries: dailySeries,
      startedAt: acc.startedAt,
      updatedAt: acc.updatedAt,
    );
  }

  static List<DailyUsageBucket> _buildContinuousDailySeries({
    required Map<String, DailyUsageBucket> buckets,
    required int days,
    required DateTime nowUtc,
  }) {
    final todayMidnight = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
    final out = <DailyUsageBucket>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = todayMidnight.subtract(Duration(days: i));
      final key = DailyUsageBucket.formatDateKey(d);
      out.add(
        buckets[key] ?? DailyUsageBucket(dateKey: key, date: d),
      );
    }
    return out;
  }
}
