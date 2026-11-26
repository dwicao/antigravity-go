/// Masks credentials (API keys, JWTs, PEM blocks, Bearer headers, URL passwords)
/// before logs, tool outputs, or diagnostics reach the screen or shared transcripts.
class AgySecretMask {
  AgySecretMask._();

  static final List<RegExp> _patterns = [
    RegExp(r'-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----|$)'),
    RegExp(r'(?<![A-Za-z0-9_])(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
    RegExp(r'(?<![A-Za-z0-9_])(AIza[0-9A-Za-z_-]{20,}|sk-[0-9A-Za-z_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{20,}|npm_[A-Za-z0-9]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[A-Z0-9]{16})'),
    RegExp(r'(?<![A-Za-z0-9_])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'),
    RegExp(r'([a-z][a-z0-9+.-]{1,15}://[^:\s/@?#]{1,128}:)([^\s/@?#]+)(@)', caseSensitive: false),
  ];

  static bool _containsAsciiWord(String text, List<int> lowerWord) {
    final len = lowerWord.length;
    final limit = text.length - len;
    for (var i = 0; i <= limit; i++) {
      var match = true;
      for (var j = 0; j < len; j++) {
        final c = text.codeUnitAt(i + j);
        final lower = (c >= 65 && c <= 90) ? (c + 32) : c;
        if (lower != lowerWord[j]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  // Lowercase ASCII code units for 'bearer' and 'basic'.
  static const List<int> _bearerUnits = [98, 101, 97, 114, 101, 114];
  static const List<int> _basicUnits = [98, 97, 115, 105, 99];

  static String mask(String text) {
    if (text.length < 8) return text;
    var out = text;
    // URL password
    if (out.contains('://') && out.contains('@')) {
      out = out.replaceAllMapped(
          _patterns[4], (m) => '${m.group(1)}••••${m.group(3)}');
    }
    // Private key block
    if (out.contains('-----BEGIN ')) {
      out = out.replaceAll(_patterns[0], '-----PRIVATE KEY REDACTED-----');
    }
    // Auth headers
    if (_containsAsciiWord(out, _bearerUnits) ||
        _containsAsciiWord(out, _basicUnits)) {
      out = out.replaceAllMapped(_patterns[1], (m) => '${m.group(1)} ••••');
    }
    // Known provider prefixes (preserve first 6 chars for recognition)
    if (out.contains('_') ||
        out.contains('-') ||
        out.contains('AIza') ||
        out.contains('AKIA') ||
        out.contains('ASIA')) {
      out = out.replaceAllMapped(_patterns[2], (m) {
        final token = m.group(0)!;
        final keep = token.length > 8 ? token.substring(0, 6) : '';
        return '$keep••••';
      });
    }
    // JWTs
    if (out.contains('eyJ')) {
      out = out.replaceAll(_patterns[3], 'eyJ••••');
    }
    return out;
  }
}
