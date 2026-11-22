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
    r'(?:resets?|refresh(?:es)?)\s+(?:in\s+|at\s+)?([^\n,|;\)]+)',
    caseSensitive: false,
  );

  /// Strips ANSI escape codes and control sequences from CLI output.
  static String stripAnsi(String input) {
    return input.replaceAll(_ansiPattern, '').replaceAll('\r', '\n');
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
          trimmed.startsWith('---')) {
        continue;
      }
      final token = trimmed.split(RegExp(r'\s{2,}|\t')).first.trim();
      if (token.isEmpty || token.length < 3) continue;
      if (token.contains(' ')) {
        if (!token.toLowerCase().contains('gemini') &&
            !token.toLowerCase().contains('claude') &&
            !token.toLowerCase().contains('orchestrator') &&
            !token.toLowerCase().contains('gpt')) {
          continue;
        }
      }
      if (seen.add(token.toLowerCase())) {
        results.add(AgyModelCatalog.resolve(token));
      }
    }
    return results;
  }

  /// Parses `/usage` (and optional `/credits`) TUI/headless output into quota entries.
  static ParsedUsageReport parseUsageText(String raw) {
    final clean = stripAnsi(raw);
    final lines = clean
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

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
        r'(?:ai\s*credits?|credits?\s*remaining|balance)\D*(\d+(?:\.\d+)?)',
        caseSensitive: false,
      ).firstMatch(line);
      if (creditMatch != null) {
        creditsRemaining = double.tryParse(creditMatch.group(1)!);
      }

      if (lower.contains('5-hour') ||
          lower.contains('5 hour') ||
          lower.contains('5h')) {
        final pct = _extractRemainingPct(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        if (pct != null && overall5h == null) overall5h = pct;
        if (reset != null && overall5hReset == null) overall5hReset = reset;
      }

      if (lower.contains('weekly') || lower.contains('7-day')) {
        final pct = _extractRemainingPct(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        if (pct != null && overallWeekly == null) overallWeekly = pct;
        if (reset != null && overallWeeklyReset == null) {
          overallWeeklyReset = reset;
        }
      }

      final targetId = _matchQuotaEntryId(lower);
      if (targetId != null) {
        final current = entriesById[targetId]!;
        final pct = _extractRemainingPct(combined);
        final reset = _resetPattern.firstMatch(combined)?.group(1)?.trim();
        final isWeeklyLine =
            lower.contains('weekly') || nextLine.toLowerCase().contains('weekly');
        final isFiveHourLine = lower.contains('5h') ||
            lower.contains('5-hour') ||
            lower.contains('5 hour') ||
            nextLine.toLowerCase().contains('5h') ||
            nextLine.toLowerCase().contains('5-hour');

        entriesById[targetId] = current.copyWith(
          fiveHourRemainingPct:
              (!isWeeklyLine || isFiveHourLine) ? (pct ?? current.fiveHourRemainingPct) : null,
          weeklyRemainingPct:
              isWeeklyLine ? (pct ?? current.weeklyRemainingPct) : null,
          fiveHourResetText:
              (!isWeeklyLine || isFiveHourLine) ? (reset ?? current.fiveHourResetText) : null,
          weeklyResetText:
              isWeeklyLine ? (reset ?? current.weeklyResetText) : null,
          statusNote: line,
        );
      }
    }

    return ParsedUsageReport(
      entries: entriesById.values.toList(),
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
        lower.contains('gemini pro')) {
      return 'gemini-pro';
    }
    if (lower.contains('hydrogen') ||
        lower.contains('flash') ||
        lower.contains('gemini flash')) {
      return 'gemini-flash';
    }
    return null;
  }

  static double? _extractRemainingPct(String text) {
    final match = _pctPattern.firstMatch(text);
    if (match == null) return null;
    final val = double.tryParse(match.group(1)!);
    if (val == null) return null;
    final clamped = val.clamp(0.0, 100.0);
    if (text.toLowerCase().contains('used') &&
        !text.toLowerCase().contains('remaining') &&
        !text.toLowerCase().contains('left')) {
      return (100.0 - clamped).clamp(0.0, 100.0);
    }
    return clamped;
  }
}

class ParsedUsageReport {
  const ParsedUsageReport({
    required this.entries,
    this.overallFiveHourRemainingPct,
    this.overallWeeklyRemainingPct,
    this.overallFiveHourResetText,
    this.overallWeeklyResetText,
    this.aiCreditsRemaining,
  });

  final List<ModelQuotaEntry> entries;
  final double? overallFiveHourRemainingPct;
  final double? overallWeeklyRemainingPct;
  final String? overallFiveHourResetText;
  final String? overallWeeklyResetText;
  final double? aiCreditsRemaining;
}
