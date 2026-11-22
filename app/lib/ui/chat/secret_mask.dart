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

  static String mask(String text) {
    if (text.isEmpty) return text;
    var out = text;
    // URL password
    out = out.replaceAllMapped(_patterns[4], (m) => '${m.group(1)}••••${m.group(3)}');
    // Private key block
    out = out.replaceAll(_patterns[0], '-----PRIVATE KEY REDACTED-----');
    // Auth headers
    out = out.replaceAllMapped(_patterns[1], (m) => '${m.group(1)} ••••');
    // Known provider prefixes (preserve first 6 chars for recognition)
    out = out.replaceAllMapped(_patterns[2], (m) {
      final token = m.group(0)!;
      final keep = token.length > 8 ? token.substring(0, 6) : '';
      return '$keep••••';
    });
    // JWTs
    out = out.replaceAll(_patterns[3], 'eyJ••••');
    return out;
  }
}
