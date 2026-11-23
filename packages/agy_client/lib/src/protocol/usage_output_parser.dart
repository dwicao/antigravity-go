import '../models/agy_model.dart';
import '../models/usage_quota.dart';

/// Parses ANSI terminal output from `agy /usage`, `agy /credits`, `agy models`,
/// and `agy acp --login` OAuth prompts.
class UsageOutputParser {
  const UsageOutputParser._();

  static final RegExp _ansiPattern = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))',
  );

  static final RegExp _oauthUrlPattern = RegExp(
    r'https://accounts\.google\.com/[^\s\)\]>"]+',
  );

  static final RegExp _emailPattern = RegExp(
    r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
  );

  static final RegExp _pctPattern = RegExp(r'(\d{1,3}(?:\.\d+)?)\s*%');

  static final RegExp _isoTimestampPattern = RegExp(
    r'\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\b',
  );

  static final RegExp _resetPattern = RegExp(
    r'(?:resets?|refresh(?:es)?)\s*(?::|in|at)?\s*([^\n,|;\)]+)',
    caseSensitive: false,
  );

  /// Strips ANSI escape codes and control sequences from CLI output.
  static String stripAnsi(String input) {
    return input
        .replaceAll(_ansiPattern, '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  /// Extracts a Google OAuth authorization URL from `agy acp --login` output.
  static String? extractOAuthUrl(String raw) {
    final clean = stripAnsi(raw);
    return _oauthUrlPattern.firstMatch(clean)?.group(0);
  }

  /// Extracts the signed-in Google email address from CLI status or profile text.
  static String? extractEmail(String raw) {
    final clean = stripAnsi(raw);
    return _emailPattern.firstMatch(clean)?.group(0);
  }

  /// Returns true if CLI output proves the account is authenticated (e.g. `agy models` succeeded).
  static bool outputIndicatesAuthenticated(String raw) {
    final clean = stripAnsi(raw).toLowerCase();
    if (clean.contains('authentication required') ||
        clean.contains('not signed in') ||
        clean.contains('please sign in') ||
        clean.contains('unauthenticated')) {
      return false;
    }
    return parseModelsOutput(raw).isNotEmpty ||
        clean.contains('models & quota') ||
        clean.contains('5-hour') ||
        clean.contains('5 hour') ||
        clean.contains('five hour') ||
        clean.contains('limit remaining') ||
        clean.contains('weekly');
  }

  /// Parses model identifiers returned by `agy models`.
  static List<AgyModelInfo> parseModelsOutput(String raw) {
    final clean = stripAnsi(raw);
    final results = <AgyModelInfo>[];
    final seen = <String>{};
    for (final line in clean.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('Available') ||
          trimmed.startsWith('Model') ||
          trimmed.startsWith('---') ||
          trimmed.startsWith('Usage') ||
          trimmed.startsWith('5-hour') ||
          trimmed.startsWith('Weekly')) {
        continue;
      }
      final parts = trimmed.split(RegExp(r'\s{2,}|\t'));
      final slug = parts.first.trim();
      if (slug.isEmpty || slug.length < 3) continue;
      final lower = slug.toLowerCase();
      final looksLikeModelSlug = lower.startsWith('gemini-') ||
          lower.startsWith('claude-') ||
          lower.startsWith('gpt-') ||
          lower.contains('orchestrator');
      if (!looksLikeModelSlug) continue;
      if (seen.add(lower)) {
        results.add(AgyModelCatalog.resolve(slug));
      }
    }
    return results;
  }

  static bool _hasFiveHourKeyword(String lower) {
    return lower.contains('5-hour') ||
        lower.contains('5 hour') ||
        lower.contains('five hour') ||
        lower.contains('five-hour') ||
        lower.contains('5h');
  }

  static bool _hasWeeklyKeyword(String lower) {
    return lower.contains('weekly') || lower.contains('7-day');
  }

  static DateTime? _extractIsoTimestamp(String text) {
    final m = _isoTimestampPattern.firstMatch(text);
    if (m == null) return null;
    return DateTime.tryParse(m.group(0)!)?.toUtc();
  }

  /// Parses `/usage`, `/credits`, and `agy models` output into quota entries.
  static ParsedUsageReport parseUsageText(String raw, {DateTime? now}) {
    final currentNow = (now ?? DateTime.now()).toUtc();
    final clean = stripAnsi(raw);
    final lines = clean
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final discoveredModels = parseModelsOutput(clean);

    final entriesById = <String, ModelQuotaEntry>{
      'gemini-4-argon': const ModelQuotaEntry(
        id: 'gemini-4-argon',
        label: 'Gemini 4 Argon',
        group: QuotaGroup.geminiArgon,
      ),
      'gemini-pro': const ModelQuotaEntry(
        id: 'gemini-pro',
        label: 'Gemini 4 Neon & Carbon',
        group: QuotaGroup.geminiPro,
      ),
      'gemini-flash': const ModelQuotaEntry(
        id: 'gemini-flash',
        label: 'Gemini 4 Hydrogen & 3.8 Flash',
        group: QuotaGroup.geminiFlash,
      ),
      'claude-gpt': const ModelQuotaEntry(
        id: 'claude-gpt',
        label: 'Claude & GPT',
        group: QuotaGroup.claudeAndGpt,
      ),
    };

    double? overall5h;
    double? overallWeekly;
    String? overall5hReset;
    String? overallWeeklyReset;
    DateTime? overall5hResetAt;
    DateTime? overallWeeklyResetAt;
    double? creditsRemaining;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase();
      // Ignore Go glog prefix lines like `ERROR: logging before google.Init: ...` or `I1123 15:29:56...`
      if (lower.startsWith('error: logging before') ||
          RegExp(r'^[iwef]\d{4}\s+\d{2}:\d{2}:\d{2}').hasMatch(lower)) {
        continue;
      }

      final nextLine = i + 1 < lines.length ? lines[i + 1] : '';
      final combined = '$line $nextLine';

      final creditMatch = RegExp(
        r'(?:ai\s*credits?|credits?\s*(?:remaining|balance)?|balance)\D*(\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(line);
      if (creditMatch != null) {
        creditsRemaining = double.tryParse(creditMatch.group(1)!);
      }

      final targetIds = _matchQuotaEntryIds(lower);
      final lineIso = _extractIsoTimestamp(line);
      final lineResetText = lineIso != null
          ? formatResetCountdown(lineIso, now: currentNow)
          : _resetPattern.firstMatch(combined)?.group(1)?.trim();

      if (targetIds.isEmpty) {
        if (_hasFiveHourKeyword(lower)) {
          final linePcts = _extractAllRemainingPcts(line);
          final pcts = linePcts.isNotEmpty
              ? linePcts
              : _extractAllRemainingPcts(combined);
          if (pcts.isNotEmpty && overall5h == null) overall5h = pcts.first;
          if (lineResetText != null && overall5hReset == null) {
            overall5hReset = lineResetText;
          }
          if (lineIso != null && overall5hResetAt == null) {
            overall5hResetAt = lineIso;
          }
        }

        if (_hasWeeklyKeyword(lower)) {
          final linePcts = _extractAllRemainingPcts(line);
          final pcts = linePcts.isNotEmpty
              ? linePcts
              : _extractAllRemainingPcts(combined);
          if (pcts.isNotEmpty && overallWeekly == null) {
            overallWeekly = pcts.first;
          }
          if (lineResetText != null && overallWeeklyReset == null) {
            overallWeeklyReset = lineResetText;
          }
          if (lineIso != null && overallWeeklyResetAt == null) {
            overallWeeklyResetAt = lineIso;
          }
        }
        continue;
      }

      final linePcts = _extractAllRemainingPcts(line);
      final combinedPcts =
          linePcts.isNotEmpty ? linePcts : _extractAllRemainingPcts(combined);
      final hasLinePcts = linePcts.isNotEmpty;
      final isWeeklyLine = _hasWeeklyKeyword(lower) ||
          (!hasLinePcts && _hasWeeklyKeyword(nextLine.toLowerCase()));
      final isFiveHourLine = _hasFiveHourKeyword(lower) ||
          (!hasLinePcts && _hasFiveHourKeyword(nextLine.toLowerCase()));

      double? fiveHPct;
      double? weeklyPct;
      if (linePcts.length >= 2) {
        fiveHPct = linePcts[0];
        weeklyPct = linePcts[1];
      } else if (combinedPcts.isNotEmpty) {
        final single = combinedPcts.first;
        if (isWeeklyLine && !isFiveHourLine) {
          weeklyPct = single;
        } else {
          fiveHPct = single;
        }
      }

      for (final targetId in targetIds) {
        final current = entriesById[targetId]!;
        entriesById[targetId] = current.copyWith(
          fiveHourRemainingPct: fiveHPct ?? current.fiveHourRemainingPct,
          weeklyRemainingPct: weeklyPct ?? current.weeklyRemainingPct,
          fiveHourResetText: (!isWeeklyLine || isFiveHourLine)
              ? (lineResetText ?? current.fiveHourResetText)
              : current.fiveHourResetText,
          weeklyResetText: isWeeklyLine
              ? (lineResetText ?? current.weeklyResetText)
              : current.weeklyResetText,
          fiveHourResetAt: (!isWeeklyLine || isFiveHourLine)
              ? (lineIso ?? current.fiveHourResetAt)
              : current.fiveHourResetAt,
          weeklyResetAt: isWeeklyLine
              ? (lineIso ?? current.weeklyResetAt)
              : current.weeklyResetAt,
          statusNote: targetIds.length > 1
              ? 'Shared Gemini Models quota pool'
              : current.statusNote,
        );
      }
    }

    // Derive overall 5h & weekly summary from per-group quotas if no standalone header existed.
    if (overall5h == null) {
      ModelQuotaEntry? min5hEntry;
      for (final entry in entriesById.values) {
        final pct = entry.fiveHourRemainingPct;
        if (pct == null) continue;
        if (min5hEntry == null ||
            pct < min5hEntry.fiveHourRemainingPct!) {
          min5hEntry = entry;
        }
      }
      if (min5hEntry != null) {
        overall5h = min5hEntry.fiveHourRemainingPct;
        overall5hReset ??= min5hEntry.fiveHourResetText;
        overall5hResetAt ??= min5hEntry.fiveHourResetAt;
      }
    }
    if (overallWeekly == null) {
      ModelQuotaEntry? minWeeklyEntry;
      for (final entry in entriesById.values) {
        final pct = entry.weeklyRemainingPct;
        if (pct == null) continue;
        if (minWeeklyEntry == null ||
            pct < minWeeklyEntry.weeklyRemainingPct!) {
          minWeeklyEntry = entry;
        }
      }
      if (minWeeklyEntry != null) {
        overallWeekly = minWeeklyEntry.weeklyRemainingPct;
        overallWeeklyReset ??= minWeeklyEntry.weeklyResetText;
        overallWeeklyResetAt ??= minWeeklyEntry.weeklyResetAt;
      }
    }

    // Check availability of each quota group against discovered `agy models` when present.
    if (discoveredModels.isNotEmpty) {
      for (final key in entriesById.keys.toList()) {
        final entry = entriesById[key]!;
        final matchingModels = discoveredModels
            .where((m) => m.quotaGroup == entry.group)
            .toList();
        entriesById[key] = entry.copyWith(
          isAvailable: matchingModels.isNotEmpty ||
              entry.fiveHourRemainingPct != null ||
              entry.weeklyRemainingPct != null,
          statusNote: entry.statusNote ??
              (matchingModels.isNotEmpty
                  ? matchingModels.map((m) => m.displayName).take(2).join(', ')
                  : 'Not included in current plan'),
        );
      }
    }

    return ParsedUsageReport(
      entries: entriesById.values.toList(),
      discoveredModels: discoveredModels,
      overallFiveHourRemainingPct: overall5h,
      overallWeeklyRemainingPct: overallWeekly,
      overallFiveHourResetText: overall5hReset,
      overallWeeklyResetText: overallWeeklyReset,
      overallFiveHourResetAt: overall5hResetAt,
      overallWeeklyResetAt: overallWeeklyResetAt,
      aiCreditsRemaining: creditsRemaining,
    );
  }

  static List<String> _matchQuotaEntryIds(String lower) {
    if (lower.contains('argon')) return const ['gemini-4-argon'];
    if (lower.contains('claude') || lower.contains('gpt')) {
      return const ['claude-gpt'];
    }
    if (lower.contains('gemini models')) {
      return const ['gemini-pro', 'gemini-flash'];
    }
    if (lower.contains('neon') ||
        lower.contains('carbon') ||
        lower.contains('gemini pro') ||
        lower.contains('gemini-pro') ||
        lower.contains('3.1 pro')) {
      return const ['gemini-pro'];
    }
    if (lower.contains('hydrogen') ||
        lower.contains('flash') ||
        lower.contains('gemini flash')) {
      return const ['gemini-flash'];
    }
    return const [];
  }

  static List<double> _extractAllRemainingPcts(String text) {
    final lower = text.toLowerCase();
    final isUsedOnly = lower.contains('used') &&
        !lower.contains('remaining') &&
        !lower.contains('left');
    final out = <double>[];
    for (final m in _pctPattern.allMatches(text)) {
      final val = double.tryParse(m.group(1)!);
      if (val == null) continue;
      final clamped = val.clamp(0.0, 100.0);
      out.add(isUsedOnly ? (100.0 - clamped).clamp(0.0, 100.0) : clamped);
    }
    return out;
  }
}

class ParsedUsageReport {
  const ParsedUsageReport({
    required this.entries,
    this.discoveredModels = const [],
    this.overallFiveHourRemainingPct,
    this.overallWeeklyRemainingPct,
    this.overallFiveHourResetText,
    this.overallWeeklyResetText,
    this.overallFiveHourResetAt,
    this.overallWeeklyResetAt,
    this.aiCreditsRemaining,
  });

  final List<ModelQuotaEntry> entries;
  final List<AgyModelInfo> discoveredModels;
  final double? overallFiveHourRemainingPct;
  final double? overallWeeklyRemainingPct;
  final String? overallFiveHourResetText;
  final String? overallWeeklyResetText;
  final DateTime? overallFiveHourResetAt;
  final DateTime? overallWeeklyResetAt;
  final double? aiCreditsRemaining;
}
