import 'agy_model.dart';

/// Token usage reported for a single turn, step, or cumulative session.
class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.thinkingTokens = 0,
    this.cacheReadTokens = 0,
    this.totalTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int cacheReadTokens;
  final int totalTokens;

  factory TokenUsage.fromJson(Map<String, dynamic> json) {
    return TokenUsage(
      inputTokens: (json['input_tokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['output_tokens'] as num?)?.toInt() ?? 0,
      thinkingTokens: (json['thinking_tokens'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (json['cache_read_tokens'] as num?)?.toInt() ?? 0,
      totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'thinking_tokens': thinkingTokens,
        'cache_read_tokens': cacheReadTokens,
        'total_tokens': totalTokens,
      };

  TokenUsage operator +(TokenUsage other) {
    return TokenUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      thinkingTokens: thinkingTokens + other.thinkingTokens,
      cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
      totalTokens: totalTokens + other.totalTokens,
    );
  }
}

/// Quota status for a single Antigravity model or shared model group.
class ModelQuotaEntry {
  const ModelQuotaEntry({
    required this.id,
    required this.label,
    required this.group,
    this.fiveHourRemainingPct,
    this.weeklyRemainingPct,
    this.fiveHourResetText,
    this.weeklyResetText,
    this.fiveHourResetAt,
    this.weeklyResetAt,
    this.isAvailable = true,
    this.statusNote,
    this.fiveHourTokensUsed = 0,
    this.weeklyTokensUsed = 0,
    this.fiveHourRequests = 0,
    this.weeklyRequests = 0,
  });

  final String id;
  final String label;
  final QuotaGroup group;

  /// Remaining percentage (0.0 to 100.0) for the 5-hour rolling window, when reported by `agy /usage`.
  final double? fiveHourRemainingPct;

  /// Remaining percentage (0.0 to 100.0) for the weekly window, when reported by `agy /usage`.
  final double? weeklyRemainingPct;

  final String? fiveHourResetText;
  final String? weeklyResetText;
  final DateTime? fiveHourResetAt;
  final DateTime? weeklyResetAt;
  final bool isAvailable;
  final String? statusNote;

  /// Locally observed token & request counts from session usage ledger.
  final int fiveHourTokensUsed;
  final int weeklyTokensUsed;
  final int fiveHourRequests;
  final int weeklyRequests;

  ModelQuotaEntry copyWith({
    double? fiveHourRemainingPct,
    double? weeklyRemainingPct,
    String? fiveHourResetText,
    String? weeklyResetText,
    DateTime? fiveHourResetAt,
    DateTime? weeklyResetAt,
    bool? isAvailable,
    String? statusNote,
    int? fiveHourTokensUsed,
    int? weeklyTokensUsed,
    int? fiveHourRequests,
    int? weeklyRequests,
  }) {
    return ModelQuotaEntry(
      id: id,
      label: label,
      group: group,
      fiveHourRemainingPct: fiveHourRemainingPct ?? this.fiveHourRemainingPct,
      weeklyRemainingPct: weeklyRemainingPct ?? this.weeklyRemainingPct,
      fiveHourResetText: fiveHourResetText ?? this.fiveHourResetText,
      weeklyResetText: weeklyResetText ?? this.weeklyResetText,
      fiveHourResetAt: fiveHourResetAt ?? this.fiveHourResetAt,
      weeklyResetAt: weeklyResetAt ?? this.weeklyResetAt,
      isAvailable: isAvailable ?? this.isAvailable,
      statusNote: statusNote ?? this.statusNote,
      fiveHourTokensUsed: fiveHourTokensUsed ?? this.fiveHourTokensUsed,
      weeklyTokensUsed: weeklyTokensUsed ?? this.weeklyTokensUsed,
      fiveHourRequests: fiveHourRequests ?? this.fiveHourRequests,
      weeklyRequests: weeklyRequests ?? this.weeklyRequests,
    );
  }
}

/// Complete snapshot of Antigravity usage limits, model quotas, AI credits, and local token ledger.
class UsageQuotaSnapshot {
  const UsageQuotaSnapshot({
    required this.entries,
    required this.fetchedAt,
    this.discoveredModels = const [],
    this.aiCreditsRemaining,
    this.aiCreditsUsedThisCycle,
    this.useG1Credits = false,
    this.overallFiveHourRemainingPct,
    this.overallWeeklyRemainingPct,
    this.overallFiveHourResetText,
    this.overallWeeklyResetText,
    this.fiveHourLedgerTokens = const TokenUsage(),
    this.weeklyLedgerTokens = const TokenUsage(),
    this.source = 'local-ledger',
    this.rawProbeOutput,
    this.lastProbeError,
  });

  final List<ModelQuotaEntry> entries;
  final DateTime fetchedAt;
  final List<AgyModelInfo> discoveredModels;
  final double? aiCreditsRemaining;
  final double? aiCreditsUsedThisCycle;
  final bool useG1Credits;
  final double? overallFiveHourRemainingPct;
  final double? overallWeeklyRemainingPct;
  final String? overallFiveHourResetText;
  final String? overallWeeklyResetText;
  final TokenUsage fiveHourLedgerTokens;
  final TokenUsage weeklyLedgerTokens;
  final String source;
  final String? rawProbeOutput;
  final String? lastProbeError;

  static UsageQuotaSnapshot initial() {
    return UsageQuotaSnapshot(
      fetchedAt: DateTime.now(),
      entries: const [
        ModelQuotaEntry(
          id: 'gemini-4-argon',
          label: 'Gemini 4 Argon',
          group: QuotaGroup.geminiArgon,
          statusNote: '5h & Weekly window',
        ),
        ModelQuotaEntry(
          id: 'gemini-pro',
          label: 'Gemini 4 Neon & Carbon',
          group: QuotaGroup.geminiPro,
          statusNote: 'Shared Gemini Pro limit',
        ),
        ModelQuotaEntry(
          id: 'gemini-flash',
          label: 'Gemini 4 Hydrogen & 3.8 Flash',
          group: QuotaGroup.geminiFlash,
          statusNote: 'Fast & Flash limit',
        ),
        ModelQuotaEntry(
          id: 'claude-gpt',
          label: 'Claude (5.5 / 4.6) & GPT-OSS-120b',
          group: QuotaGroup.claudeAndGpt,
          statusNote: 'Partner models shared limit',
        ),
      ],
    );
  }
}
