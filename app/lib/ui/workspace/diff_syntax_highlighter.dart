import 'package:flutter/material.dart';

enum DiffSyntaxLanguage {
  cLike,
  python,
  shell,
  json,
  yaml,
  xmlHtml,
  markdown,
  sql,
  plain,
}

/// GitHub PR-style syntax color palette for light and dark themes.
class DiffSyntaxPalette {
  const DiffSyntaxPalette({
    required this.plain,
    required this.keyword,
    required this.function,
    required this.type,
    required this.string,
    required this.number,
    required this.comment,
    required this.annotation,
    required this.property,
    required this.operatorFg,
  });

  final Color plain;
  final Color keyword;
  final Color function;
  final Color type;
  final Color string;
  final Color number;
  final Color comment;
  final Color annotation;
  final Color property;
  final Color operatorFg;

  static DiffSyntaxPalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  // GitHub Dark Default syntax tokens
  static const dark = DiffSyntaxPalette(
    plain: Color(0xFFE6EDF3),
    keyword: Color(0xFFFF7B72),
    function: Color(0xFFD2A8FF),
    type: Color(0xFFFFA657),
    string: Color(0xFFA5D6FF),
    number: Color(0xFF79C0FF),
    comment: Color(0xFF8B949E),
    annotation: Color(0xFFFFA657),
    property: Color(0xFF79C0FF),
    operatorFg: Color(0xFFC9D1D9),
  );

  // GitHub Light Default syntax tokens
  static const light = DiffSyntaxPalette(
    plain: Color(0xFF1F2328),
    keyword: Color(0xFFCF222E),
    function: Color(0xFF8250DF),
    type: Color(0xFF953800),
    string: Color(0xFF0A3069),
    number: Color(0xFF0550AE),
    comment: Color(0xFF57606A),
    annotation: Color(0xFF953800),
    property: Color(0xFF0550AE),
    operatorFg: Color(0xFF24292F),
  );
}

/// Lightweight, fast, zero-dependency syntax tokenizer + intraline word-diff
/// emphasizer styled after GitHub PR diff views.
class DiffSyntaxHighlighter {
  const DiffSyntaxHighlighter._();

  static DiffSyntaxLanguage detectLanguage(String? filePath) {
    if (filePath == null || filePath.trim().isEmpty) {
      return DiffSyntaxLanguage.cLike;
    }
    final clean = filePath.trim().toLowerCase().replaceAll('\\', '/');
    final fileName = clean.split('/').last;
    if (fileName == 'dockerfile' || fileName == 'makefile') {
      return DiffSyntaxLanguage.shell;
    }
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1) : '';
    return switch (ext) {
      'dart' ||
      'kt' ||
      'kts' ||
      'java' ||
      'js' ||
      'jsx' ||
      'ts' ||
      'tsx' ||
      'mjs' ||
      'cjs' ||
      'go' ||
      'rs' ||
      'swift' ||
      'c' ||
      'h' ||
      'cc' ||
      'cpp' ||
      'hpp' ||
      'cs' ||
      'scala' ||
      'groovy' ||
      'gradle' ||
      'php' ||
      'css' ||
      'scss' =>
        DiffSyntaxLanguage.cLike,
      'py' || 'rb' || 'r' => DiffSyntaxLanguage.python,
      'sh' || 'bash' || 'zsh' || 'fish' || 'env' => DiffSyntaxLanguage.shell,
      'json' || 'arb' => DiffSyntaxLanguage.json,
      'yaml' || 'yml' || 'toml' || 'ini' || 'properties' =>
        DiffSyntaxLanguage.yaml,
      'xml' || 'html' || 'htm' || 'svg' || 'plist' =>
        DiffSyntaxLanguage.xmlHtml,
      'md' || 'markdown' => DiffSyntaxLanguage.markdown,
      'sql' => DiffSyntaxLanguage.sql,
      'txt' || 'lock' => DiffSyntaxLanguage.plain,
      _ => DiffSyntaxLanguage.cLike,
    };
  }

  static const Set<String> _cLikeKeywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'companion', 'const', 'continue', 'covariant', 'data',
    'default', 'defer', 'do', 'dynamic', 'else', 'enum', 'export', 'extends',
    'extension', 'external', 'factory', 'false', 'final', 'finally', 'fn',
    'for', 'fun', 'function', 'get', 'go', 'hide', 'if', 'impl', 'implements',
    'import', 'in', 'init', 'interface', 'internal', 'is', 'late', 'let',
    'library', 'match', 'mixin', 'mod', 'mut', 'new', 'null', 'nil', 'object',
    'on', 'open', 'operator', 'out', 'override', 'package', 'part', 'private',
    'protected', 'pub', 'public', 'required', 'rethrow', 'return', 'sealed',
    'select', 'set', 'show', 'static', 'struct', 'super', 'switch', 'sync',
    'this', 'throw', 'true', 'try', 'type', 'typedef', 'typeof', 'undefined',
    'use', 'val', 'var', 'void', 'when', 'where', 'while', 'with', 'yield',
  };

  static const Set<String> _pythonKeywords = {
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
    'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally',
    'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal',
    'not', 'or', 'pass', 'raise', 'return', 'self', 'try', 'while', 'with',
    'yield', 'end', 'do', 'module', 'require',
  };

  static const Set<String> _shellKeywords = {
    'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'select',
    'while', 'until', 'do', 'done', 'in', 'function', 'export', 'local',
    'readonly', 'unset', 'return', 'exit', 'echo', 'printf', 'cd', 'test',
    'true', 'false', 'FROM', 'RUN', 'CMD', 'COPY', 'ADD', 'ENV', 'WORKDIR',
    'EXPOSE', 'ARG', 'ENTRYPOINT',
  };

  static const Set<String> _sqlKeywords = {
    'select', 'from', 'where', 'insert', 'into', 'values', 'update', 'set',
    'delete', 'create', 'table', 'alter', 'drop', 'index', 'join', 'inner',
    'left', 'right', 'outer', 'on', 'group', 'by', 'order', 'having', 'limit',
    'as', 'and', 'or', 'not', 'null', 'is', 'in', 'exists', 'distinct',
    'primary', 'key', 'foreign', 'references', 'begin', 'commit', 'rollback',
  };

  /// Computes changed `(start, end)` substring bounds in [line] relative to
  /// [other] using common prefix/suffix trimming for GitHub-style intraline
  /// word emphasis.
  static ({int start, int end})? computeIntralineRange(
    String line,
    String? other,
  ) {
    if (other == null || line.isEmpty || other.isEmpty || line == other) {
      return null;
    }
    final minLen = line.length < other.length ? line.length : other.length;
    var prefix = 0;
    while (prefix < minLen &&
        line.codeUnitAt(prefix) == other.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < (line.length - prefix) &&
        suffix < (other.length - prefix) &&
        line.codeUnitAt(line.length - 1 - suffix) ==
            other.codeUnitAt(other.length - 1 - suffix)) {
      suffix++;
    }
    final end = line.length - suffix;
    if (end <= prefix) return null;
    // Skip noisy highlight when almost the whole line differs anyway.
    if (prefix == 0 && suffix == 0) return null;
    return (start: prefix, end: end);
  }

  /// Builds syntax-highlighted [TextSpan] children whose concatenated plain text
  /// equals [code] verbatim.
  static List<TextSpan> highlightLine({
    required String code,
    required DiffSyntaxLanguage language,
    required DiffSyntaxPalette palette,
    TextStyle baseStyle = const TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
    ),
    Color? wordHighlightBg,
    ({int start, int end})? wordRange,
  }) {
    if (code.isEmpty) {
      return [TextSpan(text: ' ', style: baseStyle.copyWith(color: palette.plain))];
    }

    final rawSegments = _tokenize(code, language, palette);
    if (wordRange == null || wordHighlightBg == null) {
      return [
        for (final seg in rawSegments)
          TextSpan(
            text: code.substring(seg.start, seg.end),
            style: baseStyle.copyWith(
              color: seg.color,
              fontStyle: seg.italic ? FontStyle.italic : null,
              fontWeight: seg.bold ? FontWeight.w700 : null,
            ),
          ),
      ];
    }

    // Split segments at [wordRange.start, wordRange.end] so intraline emphasis
    // never disturbs token syntax coloring.
    final spans = <TextSpan>[];
    for (final seg in rawSegments) {
      final cutPoints = <int>[
        seg.start,
        if (wordRange.start > seg.start && wordRange.start < seg.end)
          wordRange.start,
        if (wordRange.end > seg.start && wordRange.end < seg.end) wordRange.end,
        seg.end,
      ];
      for (var i = 0; i < cutPoints.length - 1; i++) {
        final s = cutPoints[i];
        final e = cutPoints[i + 1];
        if (e <= s) continue;
        final insideWord = s >= wordRange.start && e <= wordRange.end;
        spans.add(
          TextSpan(
            text: code.substring(s, e),
            style: baseStyle.copyWith(
              color: seg.color,
              fontStyle: seg.italic ? FontStyle.italic : null,
              fontWeight: seg.bold ? FontWeight.w700 : null,
              backgroundColor: insideWord ? wordHighlightBg : null,
            ),
          ),
        );
      }
    }
    return spans;
  }

  static List<({int start, int end, Color color, bool italic, bool bold})>
      _tokenize(
    String code,
    DiffSyntaxLanguage language,
    DiffSyntaxPalette p,
  ) {
    if (language == DiffSyntaxLanguage.plain) {
      return [(start: 0, end: code.length, color: p.plain, italic: false, bold: false)];
    }
    if (language == DiffSyntaxLanguage.markdown) {
      return _tokenizeMarkdown(code, p);
    }

    final out = <({int start, int end, Color color, bool italic, bool bold})>[];
    final n = code.length;
    var i = 0;

    void addSeg(
      int start,
      int end,
      Color color, {
      bool italic = false,
      bool bold = false,
    }) {
      if (end <= start) return;
      if (out.isNotEmpty) {
        final prev = out.last;
        if (prev.end == start &&
            prev.color == color &&
            prev.italic == italic &&
            prev.bold == bold) {
          out[out.length - 1] = (
            start: prev.start,
            end: end,
            color: color,
            italic: italic,
            bold: bold,
          );
          return;
        }
      }
      out.add((
        start: start,
        end: end,
        color: color,
        italic: italic,
        bold: bold,
      ));
    }

    bool isWordStart(int ch) =>
        (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95;
    bool isWordPart(int ch) =>
        isWordStart(ch) || (ch >= 48 && ch <= 57);
    bool isDigit(int ch) => ch >= 48 && ch <= 57;

    while (i < n) {
      final ch = code.codeUnitAt(i);

      // Line comments: // ... or -- ... or # ...
      if ((language == DiffSyntaxLanguage.cLike ||
              language == DiffSyntaxLanguage.json) &&
          ch == 47 &&
          i + 1 < n &&
          code.codeUnitAt(i + 1) == 47) {
        addSeg(i, n, p.comment, italic: true);
        break;
      }
      if ((language == DiffSyntaxLanguage.python ||
              language == DiffSyntaxLanguage.shell ||
              language == DiffSyntaxLanguage.yaml) &&
          ch == 35) {
        addSeg(i, n, p.comment, italic: true);
        break;
      }
      if (language == DiffSyntaxLanguage.sql &&
          ch == 45 &&
          i + 1 < n &&
          code.codeUnitAt(i + 1) == 45) {
        addSeg(i, n, p.comment, italic: true);
        break;
      }

      // Inline block comments /* ... */ or <!-- ... -->
      if (language == DiffSyntaxLanguage.cLike &&
          ch == 47 &&
          i + 1 < n &&
          code.codeUnitAt(i + 1) == 42) {
        final endIdx = code.indexOf('*/', i + 2);
        final stop = endIdx >= 0 ? endIdx + 2 : n;
        addSeg(i, stop, p.comment, italic: true);
        i = stop;
        continue;
      }
      if (language == DiffSyntaxLanguage.xmlHtml &&
          code.startsWith('<!--', i)) {
        final endIdx = code.indexOf('-->', i + 4);
        final stop = endIdx >= 0 ? endIdx + 3 : n;
        addSeg(i, stop, p.comment, italic: true);
        i = stop;
        continue;
      }

      // Raw / prefixed string like r'...' or b"..."
      if ((language == DiffSyntaxLanguage.cLike ||
              language == DiffSyntaxLanguage.python) &&
          (ch == 114 || ch == 102 || ch == 98 || ch == 117) &&
          i + 1 < n &&
          (code.codeUnitAt(i + 1) == 39 || code.codeUnitAt(i + 1) == 34)) {
        final quote = code.codeUnitAt(i + 1);
        final raw = ch == 114;
        var j = i + 2;
        while (j < n) {
          final c = code.codeUnitAt(j);
          if (!raw && c == 92 && j + 1 < n) {
            j += 2;
            continue;
          }
          j++;
          if (c == quote) break;
        }
        addSeg(i, j, p.string);
        i = j;
        continue;
      }

      // Quoted strings '...', "...", `...`
      if (ch == 39 || ch == 34 || ch == 96) {
        var j = i + 1;
        while (j < n) {
          final c = code.codeUnitAt(j);
          if (c == 92 && j + 1 < n) {
            j += 2;
            continue;
          }
          j++;
          if (c == ch) break;
        }
        if (language == DiffSyntaxLanguage.json && ch == 34) {
          var k = j;
          while (k < n && (code.codeUnitAt(k) == 32 || code.codeUnitAt(k) == 9)) {
            k++;
          }
          final isKey = k < n && code.codeUnitAt(k) == 58;
          addSeg(i, j, isKey ? p.property : p.string);
        } else {
          addSeg(i, j, p.string);
        }
        i = j;
        continue;
      }

      // Annotations / decorators (@override, @Composable) & C preprocessor (#include)
      if (ch == 64 || (language == DiffSyntaxLanguage.cLike && ch == 35)) {
        var j = i + 1;
        while (j < n && isWordPart(code.codeUnitAt(j))) {
          j++;
        }
        if (j > i + 1) {
          addSeg(i, j, p.annotation);
          i = j;
          continue;
        }
      }

      // Shell variables $FOO or ${FOO}
      if (language == DiffSyntaxLanguage.shell && ch == 36) {
        var j = i + 1;
        if (j < n && code.codeUnitAt(j) == 123) {
          final close = code.indexOf('}', j + 1);
          j = close >= 0 ? close + 1 : n;
        } else {
          while (j < n && isWordPart(code.codeUnitAt(j))) {
            j++;
          }
        }
        addSeg(i, j, p.property);
        i = j;
        continue;
      }

      // HTML / XML tags: <tagName ...> or </tagName>
      if (language == DiffSyntaxLanguage.xmlHtml && ch == 60) {
        var j = i + 1;
        if (j < n && (code.codeUnitAt(j) == 47 || code.codeUnitAt(j) == 63)) {
          j++;
        }
        final tagStart = j;
        while (j < n &&
            (isWordPart(code.codeUnitAt(j)) ||
                code.codeUnitAt(j) == 45 ||
                code.codeUnitAt(j) == 58)) {
          j++;
        }
        addSeg(i, tagStart, p.operatorFg);
        if (j > tagStart) {
          addSeg(tagStart, j, p.keyword);
        }
        i = j;
        continue;
      }

      // Hex numbers (0x...) and numeric literals
      if (isDigit(ch) && (i == 0 || !isWordPart(code.codeUnitAt(i - 1)))) {
        var j = i + 1;
        if (ch == 48 && j < n && (code.codeUnitAt(j) == 120 || code.codeUnitAt(j) == 88)) {
          j++;
          while (j < n &&
              (isDigit(code.codeUnitAt(j)) ||
                  (code.codeUnitAt(j) >= 97 && code.codeUnitAt(j) <= 102) ||
                  (code.codeUnitAt(j) >= 65 && code.codeUnitAt(j) <= 70) ||
                  code.codeUnitAt(j) == 95)) {
            j++;
          }
        } else {
          while (j < n &&
              (isDigit(code.codeUnitAt(j)) ||
                  code.codeUnitAt(j) == 46 ||
                  code.codeUnitAt(j) == 95)) {
            j++;
          }
        }
        addSeg(i, j, p.number);
        i = j;
        continue;
      }

      // Identifiers, keywords, types, YAML keys, and method calls
      if (isWordStart(ch)) {
        var j = i + 1;
        while (j < n && isWordPart(code.codeUnitAt(j))) {
          j++;
        }
        final word = code.substring(i, j);
        var look = j;
        while (look < n && code.codeUnitAt(look) == 32) {
          look++;
        }
        final nextChar = look < n ? code.codeUnitAt(look) : -1;

        final Color color;
        if (language == DiffSyntaxLanguage.yaml && nextChar == 58) {
          color = p.property;
        } else if (language == DiffSyntaxLanguage.xmlHtml && nextChar == 61) {
          color = p.property;
        } else if (_isKeyword(word, language)) {
          color = p.keyword;
        } else if (word == 'true' ||
            word == 'false' ||
            word == 'null' ||
            word == 'None' ||
            word == 'True' ||
            word == 'False') {
          color = p.number;
        } else if (nextChar == 40) {
          // foo(...) -> method/function call (except PascalCase constructors keep type/fn)
          final isUpper = word.codeUnitAt(0) >= 65 && word.codeUnitAt(0) <= 90;
          color = isUpper ? p.type : p.function;
        } else if (word.length >= 2 &&
            word.codeUnitAt(0) >= 65 &&
            word.codeUnitAt(0) <= 90 &&
            word.toUpperCase() != word) {
          color = p.type;
        } else if (word.length >= 2 && word.toUpperCase() == word) {
          color = p.number;
        } else {
          color = p.plain;
        }
        addSeg(i, j, color);
        i = j;
        continue;
      }

      // Operators / punctuation
      if (ch == 32 || ch == 9) {
        var j = i + 1;
        while (j < n && (code.codeUnitAt(j) == 32 || code.codeUnitAt(j) == 9)) {
          j++;
        }
        addSeg(i, j, p.plain);
        i = j;
        continue;
      }

      addSeg(i, i + 1, p.operatorFg);
      i++;
    }

    return out;
  }

  static bool _isKeyword(String word, DiffSyntaxLanguage lang) {
    return switch (lang) {
      DiffSyntaxLanguage.cLike => _cLikeKeywords.contains(word),
      DiffSyntaxLanguage.python => _pythonKeywords.contains(word),
      DiffSyntaxLanguage.shell => _shellKeywords.contains(word),
      DiffSyntaxLanguage.sql => _sqlKeywords.contains(word.toLowerCase()),
      DiffSyntaxLanguage.yaml =>
        word == 'true' || word == 'false' || word == 'null',
      DiffSyntaxLanguage.json =>
        word == 'true' || word == 'false' || word == 'null',
      _ => false,
    };
  }

  static List<({int start, int end, Color color, bool italic, bool bold})>
      _tokenizeMarkdown(String code, DiffSyntaxPalette p) {
    final trimmed = code.trimLeft();
    if (trimmed.startsWith('#')) {
      return [(start: 0, end: code.length, color: p.number, italic: false, bold: true)];
    }
    if (trimmed.startsWith('```')) {
      return [(start: 0, end: code.length, color: p.comment, italic: false, bold: false)];
    }
    if (trimmed.startsWith('>')) {
      return [(start: 0, end: code.length, color: p.comment, italic: true, bold: false)];
    }
    final out = <({int start, int end, Color color, bool italic, bool bold})>[];
    var i = 0;
    while (i < code.length) {
      final tick = code.indexOf('`', i);
      if (tick < 0) {
        out.add((
          start: i,
          end: code.length,
          color: p.plain,
          italic: false,
          bold: false,
        ));
        break;
      }
      if (tick > i) {
        out.add((
          start: i,
          end: tick,
          color: p.plain,
          italic: false,
          bold: false,
        ));
      }
      final endTick = code.indexOf('`', tick + 1);
      final stop = endTick >= 0 ? endTick + 1 : code.length;
      out.add((
        start: tick,
        end: stop,
        color: p.string,
        italic: false,
        bold: false,
      ));
      i = stop;
    }
    return out;
  }
}
