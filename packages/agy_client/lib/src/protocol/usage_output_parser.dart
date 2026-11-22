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

  /// Parses `/usage`, `/credits`, and `agy models` output into quota entries.
  static ParsedUsageReport parseUsageText(String raw) {
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
    double? creditsRemaining;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final lower = line.toLowerCase();
      final nextLine = i + 1 < lines.length ? lines[i + 1] : '';
      final combined = '$line $nextLine';

      final creditMatch = RegExp(
        r'(?:ai\s*credits?|credits?\s*(?:remaining|balance)?|balance)\D*(\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(line);
      if (creditMatch != null) {
        creditsRemaining = double.tryParse(creditMatch.group(1)!);
      }

      if (lower.contains('5-hour') ||
          lower.contains('5 hour') ||
          lower.contains('5h')) {
        final pcts = _extractAllRemainingPcts(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        if (pcts.isNotEmpty && overall5h == null) overall5h = pcts.first;
        if (reset != null && overall5hReset == null) overall5hReset = reset;
      }

      if (lower.contains('weekly') || lower.contains('7-day')) {
        final pcts = _extractAllRemainingPcts(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        if (pcts.isNotEmpty && overallWeekly == null) overallWeekly = pcts.last;
        if (reset != null && overallWeeklyReset == null) {
          overallWeeklyReset = reset;
        }
      }

      final targetId = _matchQuotaEntryId(lower);
      if (targetId != null) {
        final current = entriesById[targetId]!;
        final linePcts = _extractAllRemainingPcts(line);
        final combinedPcts =
            linePcts.isNotEmpty ? linePcts : _extractAllRemainingPcts(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        final isWeeklyLine =
            lower.contains('weekly') || nextLine.toLowerCase().contains('weekly');
        final isFiveHourLine = lower.contains('5h') ||
            lower.contains('5-hour') ||
            lower.contains('5 hour') ||
            nextLine.toLowerCase().contains('5h') ||
            nextLine.toLowerCase().contains('5-hour');

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

        entriesById[targetId] = current.copyWith(
          fiveHourRemainingPct: fiveHPct ?? current.fiveHourRemainingPct,
          weeklyRemainingPct: weeklyPct ?? current.weeklyRemainingPct,
          fiveHourResetText: (!isWeeklyLine || isFiveHourLine)
              ? (reset ?? current.fiveHourResetText)
              : null,
          weeklyResetText:
              isWeeklyLine ? (reset ?? current.weeklyResetText) : null,
          statusNote: line,
        );
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
          isAvailable: matchingModels.isNotEmpty,
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
      aiCreditsRemaining: creditsRemaining,
    );
  }

  static String? _matchQuotaEntryId(String lower) {
    if (lower.contains('argon')) return 'gemini-4-argon';
    if (lower.contains('claude') || lower.contains('gpt')) return 'claude-gpt';
    if (lower.contains('neon') ||
        lower.contains('carbon') ||
        lower.contains('gemini pro') ||
        lower.contains('gemini-pro') ||
        lower.contains('3.1 pro')) {
      return 'gemini-pro';
    }
    if (lower.contains('hydrogen') ||
        lower.contains('flash') ||
        lower.contains('gemini flash')) {
      return 'gemini-flash';
    }
    return null;
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
    this.aiCreditsRemaining,
  });

  final List<ModelQuotaEntry> entries;
  final List<AgyModelInfo> discoveredModels;
  final double? overallFiveHourRemainingPct;
  final double? overallWeeklyRemainingPct;
  final String? overallFiveHourResetText;
  final String? overallWeeklyResetText;
  final double? aiCreditsRemaining;
}
