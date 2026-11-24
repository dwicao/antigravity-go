import 'agy_model.dart';

/// Formats a 0–100 quota percentage cleanly without rounding near-100% values up to 100%.
String formatQuotaPct(double pct) {
  final clamped = pct.clamp(0.0, 100.0);
  if (clamped >= 99.95 && clamped < 100.0) return '99.9%';
  if (clamped > 0.0 && clamped < 0.05) return '0.1%';
  if ((clamped - clamped.roundToDouble()).abs() < 0.05) {
    return '${clamped.round()}%';
  }
  return '${clamped.toStringAsFixed(1)}%';
}

/// Formats a future reset timestamp as a concise countdown like `5d 13h` or `4h 48m`.
String formatResetCountdown(DateTime resetAt, {DateTime? now}) {
  final current = (now ?? DateTime.now()).toUtc();
  final target = resetAt.toUtc();
  final diff = target.difference(current);
  if (diff <= Duration.zero) return 'now';
  final days = diff.inDays;
  final hours = diff.inHours % 24;
  final mins = diff.inMinutes % 60;
  if (days > 0) {
    return hours > 0 ? '${days}d ${hours}h' : '${days}d';
  }
  if (diff.inHours > 0) {
    return mins > 0 ? '${diff.inHours}h ${mins}m' : '${diff.inHours}h';
  }
  return '${mins.clamp(1, 59)}m';
}

/// Token usage reported for a single turn, step, or cumulative session.
class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.thinkingTokens = 0,
    this.cacheReadTokens = 0,
    this.totalTokens = 0,
    this.contextTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int cacheReadTokens;
  final int totalTokens;

  /// Latest single-request context window occupancy (non-cumulative), when known.
  final int contextTokens;

  factory TokenUsage.fromJson(Map<String, dynamic> json) {
    int readAny(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v is num) return v.toInt();
        if (v is String) {
          final parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return 0;
    }

    final input = readAny([
      'input_tokens',
      'inputTokens',
      'prompt_tokens',
      'promptTokens',
      'promptTokenCount',
    ]);
    final output = readAny([
      'output_tokens',
      'outputTokens',
      'candidates_tokens',
      'candidatesTokens',
      'candidatesTokenCount',
      'completion_tokens',
      'completionTokens',
    ]);
    final thinking = readAny([
      'thinking_tokens',
      'thinkingTokens',
      'thoughts_token_count',
      'thoughtsTokenCount',
      'reasoning_tokens',
      'reasoningTokens',
    ]);
    final cacheRead = readAny([
      'cache_read_tokens',
      'cacheReadTokens',
      'cache_read_input_tokens',
      'cacheReadInputTokens',
      'cached_content_token_count',
      'cachedContentTokenCount',
    ]);
    final explicitTotal = readAny([
      'total_tokens',
      'totalTokens',
      'totalTokenCount',
    ]);
    final contextTokens = readAny([
      'context_tokens',
      'contextTokens',
      'context_window_tokens',
      'contextWindowTokens',
      'last_input_tokens',
      'lastInputTokens',
    ]);
    final total = explicitTotal > 0 ? explicitTotal : (input + output + thinking);

    return TokenUsage(
      inputTokens: input,
      outputTokens: output,
      thinkingTokens: thinking,
      cacheReadTokens: cacheRead,
      totalTokens: total,
      contextTokens: contextTokens,
    );
  }

  TokenUsage copyWith({
    int? inputTokens,
    int? outputTokens,
    int? thinkingTokens,
    int? cacheReadTokens,
    int? totalTokens,
    int? contextTokens,
  }) {
    return TokenUsage(
      inputTokens: inputTokens ?? this.inputTokens,
      outputTokens: outputTokens ?? this.outputTokens,
      thinkingTokens: thinkingTokens ?? this.thinkingTokens,
      cacheReadTokens: cacheReadTokens ?? this.cacheReadTokens,
      totalTokens: totalTokens ?? this.totalTokens,
      contextTokens: contextTokens ?? this.contextTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'thinking_tokens': thinkingTokens,
        'cache_read_tokens': cacheReadTokens,
        'total_tokens': totalTokens,
        if (contextTokens > 0) 'context_tokens': contextTokens,
      };

  TokenUsage operator +(TokenUsage other) {
    return TokenUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      thinkingTokens: thinkingTokens + other.thinkingTokens,
      cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
      totalTokens: totalTokens + other.totalTokens,
      contextTokens:
          other.contextTokens > 0 ? other.contextTokens : contextTokens,
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
    this.upgradeUrl,
    this.useG1Credits = false,
    this.overallFiveHourRemainingPct,
    this.overallWeeklyRemainingPct,
    this.overallFiveHourResetText,
    this.overallWeeklyResetText,
    this.overallFiveHourResetAt,
    this.overallWeeklyResetAt,
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
  final String? upgradeUrl;
  final bool useG1Credits;
  final double? overallFiveHourRemainingPct;
  final double? overallWeeklyRemainingPct;
  final String? overallFiveHourResetText;
  final String? overallWeeklyResetText;
  final DateTime? overallFiveHourResetAt;
  final DateTime? overallWeeklyResetAt;
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
          id: 'gemini-models',
          label: 'Gemini Models',
          group: QuotaGroup.gemini,
          statusNote:
              'Neon, Carbon, Argon, Hydrogen, Orchestrator & 3.8 Flash',
        ),
        ModelQuotaEntry(
          id: 'claude-gpt',
          label: 'Claude and GPT models',
          group: QuotaGroup.claudeAndGpt,
          statusNote: 'Claude Opus 5.5, Sonnet 5.5 & GPT-OSS 120B',
        ),
      ],
    );
  }
}
