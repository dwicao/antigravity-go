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

  String formatUltraCompact() => '$name:$line';
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

  static bool shouldIgnoreRelativePath(
    String relativePath, {
    List<String> extraIgnorePatterns = const [],
  }) {
    final norm = relativePath.replaceAll('\\', '/').toLowerCase();
    final name = norm.split('/').last;
    if (name == 'package-lock.json' ||
        name == 'pnpm-lock.yaml' ||
        name == 'yarn.lock' ||
        name == 'cargo.lock' ||
        name == 'pubspec.lock' ||
        name == 'composer.lock' ||
        name == 'gemfile.lock' ||
        name == 'poetry.lock' ||
        name == 'pods.manifest.lock' ||
        name.endsWith('.g.dart') ||
        name.endsWith('.freezed.dart') ||
        name.endsWith('.min.js') ||
        name.endsWith('.min.css') ||
        name.endsWith('.bundle.js') ||
        name.endsWith('.map')) {
      return true;
    }
    for (final raw in extraIgnorePatterns) {
      final pat = raw.trim().toLowerCase();
      if (pat.isEmpty || pat.startsWith('#')) continue;
      final clean = pat.startsWith('/') ? pat.substring(1) : pat;
      final trimmedSlash = clean.endsWith('/') ? clean.substring(0, clean.length - 1) : clean;
      if (trimmedSlash.isEmpty) continue;
      if (trimmedSlash.startsWith('*.')) {
        if (name.endsWith(trimmedSlash.substring(1))) return true;
      } else if (norm == trimmedSlash ||
          norm.startsWith('$trimmedSlash/') ||
          norm.contains('/$trimmedSlash/') ||
          name == trimmedSlash) {
        return true;
      }
    }
    return false;
  }

  static Future<List<String>> _loadIgnorePatterns(Directory root) async {
    final out = <String>[];
    for (final fileName in const ['.agyignore', '.claudeignore', '.aiderignore']) {
      final f = File('${root.path}${Platform.pathSeparator}$fileName');
      try {
        if (await f.exists()) {
          final lines = await f.readAsLines();
          for (final l in lines) {
            final t = l.trim();
            if (t.isNotEmpty && !t.startsWith('#') && !t.startsWith('!')) {
              out.add(t);
            }
          }
        }
      } catch (_) {}
    }
    return out;
  }

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
  static final RegExp _typeNameSplitRe = RegExp(r'[\s{(:]');
  static final RegExp _wsCollapseRe = RegExp(r'\s+');

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
        final rawName = tm.group(2)!.split(_typeNameSplitRe).first.trim();
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
    final compact = raw.replaceAll(_wsCollapseRe, ' ').trim();
    if (compact.length <= 48) return compact;
    return '${compact.substring(0, 45)}...)';
  }

  /// Renders a list of file summaries into a `<repo_map>` block capped at [maxTokens].
  static String renderRepoMap(
    List<RepoMapFileSummary> summaries, {
    int maxTokens = 1600,
    String? rootLabel,
    bool compact = false,
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
      final entryBuf = compact
          ? StringBuffer('${file.relativePath}(${file.lineCount}L)')
          : StringBuffer('${file.relativePath} (${file.lineCount}L)');
      if (file.symbols.isNotEmpty) {
        entryBuf.write(': ');
        entryBuf.write(
          file.symbols
              .take(12)
              .map((s) => compact ? s.formatUltraCompact() : s.formatCompact())
              .join(compact ? ',' : ' | '),
        );
        if (file.symbols.length > 12) {
          entryBuf.write(compact
              ? ',+${file.symbols.length - 12}'
              : ' | +${file.symbols.length - 12} more');
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
    bool compact = false,
  }) async {
    final cacheKey = '$rootPath|$maxTokens|$maxFiles|$compact';
    if (useCache) {
      final cached = _dirCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _cacheTtl) {
        return cached.map;
      }
    }
    final root = Directory(rootPath);
    if (!await root.exists()) return '';
    final extraIgnores = await _loadIgnorePatterns(root);
    final rootPrefix = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';

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
        final relPath = entity.path.startsWith(rootPrefix)
            ? entity.path.substring(rootPrefix.length).replaceAll('\\', '/')
            : name;
        if (entity is Directory) {
          if (ignoredDirs.contains(name) ||
              name.startsWith('.') ||
              shouldIgnoreRelativePath(relPath, extraIgnorePatterns: extraIgnores)) {
            continue;
          }
          queue.add(entity);
        } else if (entity is File) {
          if (shouldIgnoreRelativePath(relPath, extraIgnorePatterns: extraIgnores)) {
            continue;
          }
          final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
          if (supportedExtensions.contains(ext)) {
            collected.add(entity);
          }
        }
      }
    }
    final summaries = <RepoMapFileSummary>[];
    const batchSize = 8;
    for (var start = 0; start < collected.length; start += batchSize) {
      final end = (start + batchSize < collected.length)
          ? start + batchSize
          : collected.length;
      final batch = collected.sublist(start, end);
      final results = await Future.wait(
        batch.map((file) async {
          try {
            if (await file.length() > 256 * 1024) return null;
            final content = await file.readAsString();
            final rel = file.path.startsWith(rootPrefix)
                ? file.path.substring(rootPrefix.length)
                : file.path;
            return summarizeFile(rel.replaceAll('\\', '/'), content);
          } catch (_) {
            return null;
          }
        }),
      );
      for (final s in results) {
        if (s != null) summaries.add(s);
      }
    }

    final rendered = renderRepoMap(
      summaries,
      maxTokens: maxTokens,
      rootLabel: root.path.split(Platform.pathSeparator).last,
      compact: compact,
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
