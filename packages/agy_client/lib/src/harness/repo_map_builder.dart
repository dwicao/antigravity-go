import 'dart:io';

/// Extracted structural symbol from source code for compact Repo Map generation.
class RepoSymbol {
  const RepoSymbol({
    required this.kind,
    required this.name,
    required this.line,
    this.signature = '',
  });

  final String kind;
  final String name;
  final int line;
  final String signature;

  String formatCompact() =>
      signature.isEmpty ? '$kind $name (L$line)' : '$kind $signature (L$line)';
}

/// Summary of extracted symbols for a single source file.
class RepoMapFileSummary {
  const RepoMapFileSummary({
    required this.relativePath,
    required this.symbols,
    required this.lineCount,
  });

  final String relativePath;
  final List<RepoSymbol> symbols;
  final int lineCount;
}

/// Zero-dependency multi-language structural Repo Map indexer modeled after
/// AST/Tree-sitter repo maps, producing dense `<repo_map>` context blocks
/// without sending full file contents.
class RepoMapBuilder {
  const RepoMapBuilder._();

  static const Set<String> supportedExtensions = {
    'dart',
    'kt',
    'kts',
    'java',
    'ts',
    'tsx',
    'js',
    'jsx',
    'mjs',
    'py',
    'go',
    'rs',
    'c',
    'cpp',
    'cc',
    'h',
    'hpp',
  };

  static const Set<String> ignoredDirs = {
    '.git',
    '.dart_tool',
    '.gradle',
    '.idea',
    '.vscode',
    '.agy-harness',
    'build',
    'dist',
    'node_modules',
    'target',
    '__pycache__',
    '.venv',
    'venv',
    'Pods',
  };

  static final RegExp _typeDeclRe = RegExp(
    r'^(?:export\s+)?(?:abstract\s+|sealed\s+|final\s+|base\s+|open\s+|data\s+|pub(?:\([^)]*\))?\s+|public\s+|private\s+|internal\s+)*'
    r'(class|interface|enum|mixin|extension|struct|trait|impl|object)\s+([A-Za-z_][A-Za-z0-9_<>,\s]*)',
  );

  static final RegExp _pyDefRe = RegExp(
    r'^(?:async\s+)?(def|class)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(\([^)]*\))?',
  );

  static final RegExp _goFuncRe = RegExp(
    r'^func\s+(?:\([^)]+\)\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(\([^)]*\))',
  );

  static final RegExp _rustFnRe = RegExp(
    r'^(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*(\([^)]*\))',
  );

  static final RegExp _ktFunRe = RegExp(
    r'^(?:(?:public|private|protected|internal|override|suspend|inline|open)\s+)*fun\s+(?:<[^>]+>\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*(\([^)]*\))',
  );

  static final RegExp _jsTsFuncRe = RegExp(
    r'^(?:export\s+(?:default\s+)?)?(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(\([^)]*\))',
  );

  static final RegExp _dartFnRe = RegExp(
    r'^(?:(?:static|external)\s+)?(?:Future<[^>]+>|Stream<[^>]+>|void|bool|int|double|String|num|dynamic|List<[^>]+>|Map<[^>]+>|[A-Z][A-Za-z0-9_<>?]*)\s+([a-z_][A-Za-z0-9_]*)\s*(\([^)]*\))',
  );

  static const Set<String> _nonFunctionKeywords = {
    'if',
    'for',
    'while',
    'switch',
    'catch',
    'return',
    'else',
    'when',
    'try',
    'new',
  };

  /// Extracts structural symbols from a single file's [source].
  static RepoMapFileSummary summarizeFile(String relativePath, String source) {
    final ext = relativePath.split('.').last.toLowerCase();
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final symbols = <RepoSymbol>[];
    var inBlockComment = false;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;

      if (inBlockComment) {
        if (trimmed.contains('*/')) inBlockComment = false;
        continue;
      }
      if (trimmed.startsWith('/*')) {
        if (!trimmed.contains('*/')) inBlockComment = true;
        continue;
      }
      if (trimmed.startsWith('//') ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('*')) {
        continue;
      }

      final lineNo = i + 1;
      final indent = raw.length - raw.trimLeft().length;

      if (ext == 'py') {
        final m = _pyDefRe.firstMatch(trimmed);
        if (m != null) {
          final kind = m.group(1)!;
          final name = m.group(2)!;
          final params = _compactParams(m.group(3) ?? '');
          symbols.add(
            RepoSymbol(
              kind: kind,
              name: name,
              line: lineNo,
              signature: '$name$params',
            ),
          );
        }
        continue;
      }

      final tm = _typeDeclRe.firstMatch(trimmed);
      if (tm != null) {
        final kind = tm.group(1)!;
        final rawName = tm.group(2)!.split(RegExp(r'[\s{(:]')).first.trim();
        if (rawName.isNotEmpty) {
          symbols.add(
            RepoSymbol(kind: kind, name: rawName, line: lineNo),
          );
          continue;
        }
      }

      if (ext == 'go') {
        final gm = _goFuncRe.firstMatch(trimmed);
        if (gm != null) {
          final name = gm.group(1)!;
          symbols.add(
            RepoSymbol(
              kind: 'func',
              name: name,
              line: lineNo,
              signature: '$name${_compactParams(gm.group(2) ?? '')}',
            ),
          );
        }
        continue;
      }

      if (ext == 'rs') {
        final rm = _rustFnRe.firstMatch(trimmed);
        if (rm != null) {
          final name = rm.group(1)!;
          symbols.add(
            RepoSymbol(
              kind: 'fn',
              name: name,
              line: lineNo,
              signature: '$name${_compactParams(rm.group(2) ?? '')}',
            ),
          );
        }
        continue;
      }

      if (ext == 'kt' || ext == 'kts') {
        final km = _ktFunRe.firstMatch(trimmed);
        if (km != null) {
          final name = km.group(1)!;
          symbols.add(
            RepoSymbol(
              kind: 'fun',
              name: name,
              line: lineNo,
              signature: '$name${_compactParams(km.group(2) ?? '')}',
            ),
          );
        }
        continue;
      }

      if (ext == 'js' || ext == 'jsx' || ext == 'ts' || ext == 'tsx' || ext == 'mjs') {
        final jm = _jsTsFuncRe.firstMatch(trimmed);
        if (jm != null) {
          final name = jm.group(1)!;
          symbols.add(
            RepoSymbol(
              kind: 'fn',
              name: name,
              line: lineNo,
              signature: '$name${_compactParams(jm.group(2) ?? '')}',
            ),
          );
        }
        continue;
      }

      if ((ext == 'dart' || ext == 'java' || ext == 'c' || ext == 'cpp' || ext == 'cc' || ext == 'h' || ext == 'hpp') &&
          indent <= 4) {
        final dm = _dartFnRe.firstMatch(trimmed);
        if (dm != null) {
          final name = dm.group(1)!;
          if (!_nonFunctionKeywords.contains(name)) {
            symbols.add(
              RepoSymbol(
                kind: 'fn',
                name: name,
                line: lineNo,
                signature: '$name${_compactParams(dm.group(2) ?? '')}',
              ),
            );
          }
        }
      }
    }

    return RepoMapFileSummary(
      relativePath: relativePath,
      symbols: symbols,
      lineCount: lines.length,
    );
  }

  static String _compactParams(String raw) {
    final compact = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (compact.length <= 48) return compact;
    return '${compact.substring(0, 45)}...)';
  }

  /// Renders a list of file summaries into a `<repo_map>` block capped at [maxTokens].
  static String renderRepoMap(
    List<RepoMapFileSummary> summaries, {
    int maxTokens = 1600,
    String? rootLabel,
  }) {
    if (summaries.isEmpty) return '';
    final maxChars = maxTokens * 4;
    final buf = StringBuffer('<repo_map');
    if (rootLabel != null && rootLabel.isNotEmpty) {
      buf.write(' root="$rootLabel"');
    }
    buf.writeln('>');

    var includedFiles = 0;
    for (final file in summaries) {
      final entryBuf = StringBuffer('${file.relativePath} (${file.lineCount}L)');
      if (file.symbols.isNotEmpty) {
        entryBuf.write(': ');
        entryBuf.write(
          file.symbols.take(12).map((s) => s.formatCompact()).join(' | '),
        );
        if (file.symbols.length > 12) {
          entryBuf.write(' | +${file.symbols.length - 12} more');
        }
      }
      final line = entryBuf.toString();
      if (buf.length + line.length + 32 > maxChars) {
        final remaining = summaries.length - includedFiles;
        if (remaining > 0) {
          buf.writeln('... ($remaining more files omitted for token budget)');
        }
        break;
      }
      buf.writeln(line);
      includedFiles++;
    }
    buf.write('</repo_map>');
    return buf.toString();
  }

  static const Duration _cacheTtl = Duration(seconds: 60);
  static final Map<String, ({String map, DateTime fetchedAt})> _dirCache = {};

  static void invalidateCache([String? rootPath]) {
    if (rootPath == null || rootPath.isEmpty) {
      _dirCache.clear();
    } else {
      _dirCache.removeWhere((k, _) => k.startsWith('$rootPath|'));
    }
  }

  /// Scans [rootPath] and builds a compact `<repo_map>` string.
  static Future<String> buildFromDirectory(
    String rootPath, {
    int maxTokens = 1600,
    int maxFiles = 120,
    bool useCache = true,
  }) async {
    final cacheKey = '$rootPath|$maxTokens|$maxFiles';
    if (useCache) {
      final cached = _dirCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _cacheTtl) {
        return cached.map;
      }
    }
    final root = Directory(rootPath);
    if (!await root.exists()) return '';

    // Breadth-first scan ensures monorepo modules (e.g. app/lib, packages/)
    // are represented evenly before hitting [maxFiles] instead of one deep
    // alphabetical folder exhausting the entire budget.
    final collected = <File>[];
    final queue = <Directory>[root];
    var head = 0;
    while (head < queue.length && collected.length < maxFiles) {
      final dir = queue[head++];
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        continue;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (collected.length >= maxFiles) break;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (entity is Directory) {
          if (ignoredDirs.contains(name) || name.startsWith('.')) continue;
          queue.add(entity);
        } else if (entity is File) {
          final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
          if (supportedExtensions.contains(ext)) {
            collected.add(entity);
          }
        }
      }
    }
    final rootPrefix = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    final summaries = <RepoMapFileSummary>[];
    for (final file in collected) {
      try {
        if (await file.length() > 256 * 1024) continue;
        final content = await file.readAsString();
        final rel = file.path.startsWith(rootPrefix)
            ? file.path.substring(rootPrefix.length)
            : file.path;
        summaries.add(summarizeFile(rel.replaceAll('\\', '/'), content));
      } catch (_) {}
    }

    final rendered = renderRepoMap(
      summaries,
      maxTokens: maxTokens,
      rootLabel: root.path.split(Platform.pathSeparator).last,
    );
    if (useCache) {
      if (_dirCache.length >= 16) {
        _dirCache.remove(_dirCache.keys.first);
      }
      _dirCache[cacheKey] = (map: rendered, fetchedAt: DateTime.now());
    }
    return rendered;
  }
}
