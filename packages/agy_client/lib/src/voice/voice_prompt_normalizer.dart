/// Normalizes dictated speech into workspace-aware coding prompts and turns
/// markdown replies into clean spoken summaries for Android Text-to-Speech.
class VoicePromptNormalizer {
  const VoicePromptNormalizer._();

  static final Map<RegExp, String> _phraseReplacements = {
    RegExp(r'\bslash\s+(compact|diff|plan|goal|usage|credits|model|fork|rewind|mcp|teamwork|swarm|boost)\b', caseSensitive: false):
        r'/$1',
    RegExp(r'\bdot\s+(dart|kt|kts|java|py|ts|tsx|js|jsx|json|yaml|yml|md|sh|xml|gradle)\b', caseSensitive: false):
        r'.$1',
    RegExp(r'\s+underscore\s+', caseSensitive: false): '_',
    RegExp(r'\s+hyphen\s+', caseSensitive: false): '-',
  };

  /// Post-processes raw speech-to-text [transcript] using coding phrase rules
  /// and optional [workspaceFiles] filenames for accurate identifier matching.
  static String normalize(
    String transcript, {
    Iterable<String> workspaceFiles = const [],
  }) {
    var out = transcript.trim();
    if (out.isEmpty) return '';

    for (final entry in _phraseReplacements.entries) {
      out = out.replaceAllMapped(
        entry.key,
        (m) => entry.value.replaceAll(r'$1', m.group(1)!.toLowerCase()),
      );
    }

    // Match spoken spaced filenames like "chat state.dart" -> "chat_state.dart"
    // or "home shell" -> "home_shell.dart" when unambiguous in workspaceFiles.
    final files = workspaceFiles
        .map((f) => f.trim())
        .where((f) => f.isNotEmpty)
        .toList();
    if (files.isNotEmpty) {
      final bySpokenBase = <String, String>{};
      final ambiguous = <String>{};
      for (final f in files) {
        final base = f.split('/').last;
        final stem = base.contains('.')
            ? base.substring(0, base.lastIndexOf('.'))
            : base;
        final spokenStem = stem
            .replaceAll('_', ' ')
            .replaceAll('-', ' ')
            .replaceAllMapped(
              RegExp(r'([a-z])([A-Z])'),
              (m) => '${m.group(1)} ${m.group(2)}',
            )
            .toLowerCase()
            .trim();
        if (spokenStem.length < 4) continue;
        final spokenWithExt = base.contains('.')
            ? '$spokenStem.${base.split('.').last.toLowerCase()}'
            : spokenStem;

        for (final key in [spokenWithExt, spokenStem]) {
          if (bySpokenBase.containsKey(key) && bySpokenBase[key] != base) {
            ambiguous.add(key);
          } else {
            bySpokenBase[key] = base;
          }
        }
      }
      for (final bad in ambiguous) {
        bySpokenBase.remove(bad);
      }

      final sortedKeys = bySpokenBase.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final key in sortedKeys) {
        final replacement = bySpokenBase[key]!;
        final pattern = RegExp(
          '(?<![A-Za-z0-9_./-])${RegExp.escape(key)}(?![A-Za-z0-9_./-])',
          caseSensitive: false,
        );
        out = out.replaceAll(pattern, replacement);
      }
    }

    return out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  /// Strips markdown/code blocks from an assistant reply so Android TTS reads
  /// a concise, natural summary.
  static String toSpokenSummary(String markdown, {int maxChars = 650}) {
    var text = markdown.replaceAll('\r\n', '\n');
    // Collapse fenced code blocks to a brief note.
    text = text.replaceAll(
      RegExp(r'```[\s\S]*?```', multiLine: true),
      ' Code block omitted. ',
    );
    // Strip markdown links [label](url) -> label
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1) ?? '',
    );
    // Strip formatting characters.
    text = text
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'[*_~>]+'), '')
        .replaceAll(RegExp(r'^\s*[-+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (text.length <= maxChars) return text;
    final cut = text.substring(0, maxChars);
    final lastSentence = cut.lastIndexOf(RegExp(r'[.!?]\s'));
    if (lastSentence > maxChars ~/ 2) {
      return cut.substring(0, lastSentence + 1).trim();
    }
    return '${cut.trim()}…';
  }
}
