import 'dart:convert';

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

  static final RegExp _glogInitNoisePattern = RegExp(
    r'^(?:ERROR:\s*logging before google\.Init:\s*)?[IWEF]\d{4}\s+\d{2}:\d{2}:\d{2}',
  );

  /// Returns true when [line] is Go glog/klog stderr bootstrap noise (e.g. timezone init).
  static bool isGlogNoiseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    return _glogInitNoisePattern.hasMatch(trimmed);
  }

  /// Strips ANSI sequences, glog noise lines, and unpacks JSON command envelopes for display.
  static String cleanProbeOutput(String raw) {
    final stripped = stripAnsi(raw);
    final outLines = <String>[];
    for (final rawLine in stripped.split('\n')) {
      final line = rawLine.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        if (outLines.isNotEmpty && outLines.last.isNotEmpty) {
          outLines.add('');
        }
        continue;
      }
      if (isGlogNoiseLine(trimmed)) continue;
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map<String, dynamic>) {
            final resp = decoded['response']?.toString();
            if (resp != null && resp.trim().isNotEmpty) {
              for (final rLine in resp.split('\n')) {
                final rt = rLine.trimRight();
                if (!isGlogNoiseLine(rt)) outLines.add(rt);
              }
              continue;
            }
          }
        } catch (_) {}
      }
      outLines.add(line);
    }
    while (outLines.isNotEmpty && outLines.last.isEmpty) {
      outLines.removeLast();
    }
    return outLines.join('\n');
  }

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
    final rawLines = clean
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !isGlogNoiseLine(l))
        .toList();

    final nonJsonLines = <String>[];
    final jsonCommands = <Map<String, dynamic>>[];
    final modelLookupText = StringBuffer();

    for (final line in rawLines) {
      if (line.startsWith('{') && line.endsWith('}')) {
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic> &&
              decoded['command'] is Map<String, dynamic>) {
            jsonCommands.add(decoded);
            final resp = decoded['response']?.toString();
            if (resp != null && resp.isNotEmpty) {
              modelLookupText.writeln(resp);
            }
            continue;
          }
        } catch (_) {}
      }
      nonJsonLines.add(line);
      modelLookupText.writeln(line);
    }

    final discoveredModels = parseModelsOutput(modelLookupText.toString());

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

    // Prefer structured `agy -p /usage --output-format json` & `/credits` payloads when present.
    for (final envelope in jsonCommands) {
      final cmd = envelope['command'] as Map<String, dynamic>?;
      if (cmd == null) continue;
      final cmdName = cmd['name']?.toString().toLowerCase() ?? '';
      final data = cmd['data'];
      if (data is! Map<String, dynamic>) continue;

      if (cmdName == 'credits') {
        final rem = (data['remaining_credits'] as num?)?.toDouble();
        if (rem != null) creditsRemaining = rem;
        continue;
      }

      if (cmdName == 'usage') {
        final groups = data['groups'];
        if (groups is! List) continue;
        for (final g in groups.whereType<Map<String, dynamic>>()) {
          final groupName = g['name']?.toString() ?? '';
          final groupDesc = g['description']?.toString() ?? '';
          var targetIds = _matchQuotaEntryIds(groupName.toLowerCase());
          if (targetIds.isEmpty && groupDesc.isNotEmpty) {
            targetIds = _matchQuotaEntryIds(groupDesc.toLowerCase());
          }
          if (targetIds.isEmpty) continue;

          final buckets = g['buckets'];
          if (buckets is! List) continue;
          for (final b in buckets.whereType<Map<String, dynamic>>()) {
            final frac = (b['remaining_fraction'] as num?)?.toDouble();
            if (frac == null) continue;
            final pct = (frac * 100.0).clamp(0.0, 100.0);
            final window = b['window']?.toString().toLowerCase() ?? '';
            final bName = b['name']?.toString().toLowerCase() ?? '';
            final resetRaw = b['reset_time']?.toString();
            final resetAt = resetRaw != null
                ? DateTime.tryParse(resetRaw)?.toUtc()
                : null;
            final resetText = resetAt != null
                ? formatResetCountdown(resetAt, now: currentNow)
                : null;

            final isWeekly =
                window == 'weekly' || window == '7d' || _hasWeeklyKeyword(bName);
            final isFiveH = window == '5h' || _hasFiveHourKeyword(bName);

            for (final targetId in targetIds) {
              final current = entriesById[targetId]!;
              entriesById[targetId] = current.copyWith(
                fiveHourRemainingPct:
                    isFiveH ? pct : current.fiveHourRemainingPct,
                weeklyRemainingPct:
                    isWeekly ? pct : current.weeklyRemainingPct,
                fiveHourResetText: isFiveH
                    ? (resetText ?? current.fiveHourResetText)
                    : current.fiveHourResetText,
                weeklyResetText: isWeekly
                    ? (resetText ?? current.weeklyResetText)
                    : current.weeklyResetText,
                fiveHourResetAt: isFiveH
                    ? (resetAt ?? current.fiveHourResetAt)
                    : current.fiveHourResetAt,
                weeklyResetAt: isWeekly
                    ? (resetAt ?? current.weeklyResetAt)
                    : current.weeklyResetAt,
                statusNote: targetIds.length > 1
                    ? 'Shared Gemini Models quota pool'
                    : current.statusNote,
              );
            }
          }
        }
      }
    }

    for (var i = 0; i < nonJsonLines.length; i++) {
      final line = nonJsonLines[i];
      final lower = line.toLowerCase();

      // Skip plain model catalog lines from `agy models` so they don't bleed into the next quota line.
      if (_isModelCatalogLine(lower)) continue;

      final nextLine = i + 1 < nonJsonLines.length ? nonJsonLines[i + 1] : '';
      final allowNextLine = nextLine.isNotEmpty &&
          _matchQuotaEntryIds(nextLine.toLowerCase()).isEmpty &&
          !_isModelCatalogLine(nextLine.toLowerCase());
      final combined = allowNextLine ? '$line $nextLine' : line;

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
              : (allowNextLine ? _extractAllRemainingPcts(combined) : const <double>[]);
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
              : (allowNextLine ? _extractAllRemainingPcts(combined) : const <double>[]);
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
          (!hasLinePcts &&
              allowNextLine &&
              _hasWeeklyKeyword(nextLine.toLowerCase()));
      final isFiveHourLine = _hasFiveHourKeyword(lower) ||
          (!hasLinePcts &&
              allowNextLine &&
              _hasFiveHourKeyword(nextLine.toLowerCase()));

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

  static bool _isModelCatalogLine(String lower) {
    if (lower.contains('%') ||
        lower.contains('remaining') ||
        lower.contains('limit') ||
        lower.contains('resets') ||
        lower.contains('weekly') ||
        lower.contains('5-hour') ||
        lower.contains('5 hour') ||
        lower.contains('five hour')) {
      return false;
    }
    final firstToken = lower.split(RegExp(r'\s+')).first;
    return firstToken.startsWith('gemini-') ||
        firstToken.startsWith('claude-') ||
        firstToken.startsWith('gpt-') ||
        firstToken.contains('orchestrator');
  }

  static List<String> _matchQuotaEntryIds(String lower) {
    if (lower.contains('argon') && !lower.contains('gemini models')) {
      return const ['gemini-4-argon'];
    }
    if (lower.contains('claude') || lower.contains('gpt')) {
      return const ['claude-gpt'];
    }
    if (lower.contains('gemini models')) {
      return const ['gemini-4-argon', 'gemini-pro', 'gemini-flash'];
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
