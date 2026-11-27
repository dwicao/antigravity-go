import 'dart:convert';
import 'dart:math' as math;

/// A single captured tool output stored as a named variable (`$v_*`) so
/// agents can pass large payloads by reference instead of re-emitting them
/// token-by-token.
class ToolVarEntry {
  ToolVarEntry({
    required this.name,
    required this.toolName,
    required this.rawValue,
    required this.createdAt,
    this.target = '',
  })  : charCount = rawValue.length,
        lineCount = rawValue.isEmpty ? 0 : '\n'.allMatches(rawValue).length + 1;

  final String name;
  final String toolName;
  final String target;
  final String rawValue;
  final int charCount;
  final int lineCount;
  final DateTime createdAt;

  bool _jsonParsed = false;
  Object? _parsedJson;

  /// Lazily decodes JSON payloads (including raw JSON objects/arrays).
  Object? get parsedJson {
    if (_jsonParsed) return _parsedJson;
    _jsonParsed = true;
    final trimmed = rawValue.trim();
    if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      try {
        _parsedJson = jsonDecode(trimmed);
      } catch (_) {
        _parsedJson = null;
      }
    }
    return _parsedJson;
  }

  /// Concise human & LLM-readable summary of the variable contents.
  String get summary {
    final jsonVal = parsedJson;
    if (jsonVal is List) {
      if (jsonVal.isNotEmpty && jsonVal.first is Map) {
        final keys = (jsonVal.first as Map).keys.take(5).join(', ');
        return 'JSON array (${jsonVal.length} items, keys: $keys), $charCount chars';
      }
      return 'JSON array (${jsonVal.length} items), $charCount chars';
    }
    if (jsonVal is Map) {
      final keys = jsonVal.keys.take(6).join(', ');
      return 'JSON object (keys: $keys), $charCount chars';
    }
    return '$lineCount lines, $charCount chars';
  }
}

/// Per-session registry of tool output variables (`$var_name` / `$var.field` /
/// `$var[0]` / `$var[1:50]`).
///
/// Only identifiers explicitly stored in this registry are ever resolved;
/// unknown `$ENV_VAR`, currency literals (`$100`), or code identifiers remain
/// completely untouched.
class ToolVariableStore {
  ToolVariableStore({
    this.enabled = true,
    this.inlineThresholdChars = 1200,
    this.maxEntries = 64,
    this.maxTotalChars = 8 * 1024 * 1024,
  });

  bool enabled;
  final int inlineThresholdChars;
  final int maxEntries;
  final int maxTotalChars;

  final Map<String, ToolVarEntry> _vars = <String, ToolVarEntry>{};
  final List<String> _insertionOrder = <String>[];
  String? _latestName;
  int _counter = 0;
  int _totalChars = 0;
  int _resolvedCount = 0;
  int _savedOutputChars = 0;

  static final RegExp _validNameRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static final RegExp _exprRe = RegExp(
    r'\\?\$(\{([A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[(?:-?\d+(?::\d*)?|:\d+)\]))*)\}|([A-Za-z_][A-Za-z0-9_]*(?:(?:\.[A-Za-z_][A-Za-z0-9_]*)|(?:\[(?:-?\d+(?::\d*)?|:\d+)\]))*))',
  );

  int get length => _vars.length;
  int get totalChars => _totalChars;
  int get resolvedCount => _resolvedCount;
  int get savedOutputChars => _savedOutputChars;
  String? get latestName => _latestName;

  List<ToolVarEntry> get entries => [
        for (final name in _insertionOrder)
          if (_vars[name] != null) _vars[name]!,
      ];

  bool containsRoot(String name) =>
      name == 'v_last' ? _latestName != null : _vars.containsKey(name);

  ToolVarEntry? get(String name) {
    if (name == 'v_last') {
      return _latestName != null ? _vars[_latestName] : null;
    }
    return _vars[name];
  }

  void clear() {
    _vars.clear();
    _insertionOrder.clear();
    _latestName = null;
    _totalChars = 0;
    _counter = 0;
    _resolvedCount = 0;
    _savedOutputChars = 0;
  }

  /// Stores a raw tool result and returns its assigned [ToolVarEntry].
  ToolVarEntry save({
    required String toolName,
    required String rawOutput,
    String target = '',
    String? explicitName,
  }) {
    final base = _deriveBaseName(
      toolName: toolName,
      target: target,
      explicitName: explicitName,
    );
    var name = base;
    if (explicitName != null && _validNameRe.hasMatch(base)) {
      name = base;
    } else {
      while (_vars.containsKey(name) || name == 'v_last') {
        _counter++;
        name = '${base}_$_counter';
      }
    }

    final existing = _vars.remove(name);
    if (existing != null) {
      _totalChars -= existing.charCount;
      _insertionOrder.remove(name);
    }

    final entry = ToolVarEntry(
      name: name,
      toolName: toolName,
      target: target,
      rawValue: rawOutput,
      createdAt: DateTime.now(),
    );
    _vars[name] = entry;
    _insertionOrder.add(name);
    _latestName = name;
    _totalChars += entry.charCount;

    _evictIfNeeded(protectName: name);
    return entry;
  }

  void _evictIfNeeded({required String protectName}) {
    while ((_vars.length > maxEntries || _totalChars > maxTotalChars) &&
        _insertionOrder.length > 1) {
      final oldest = _insertionOrder.first;
      if (oldest == protectName) {
        if (_insertionOrder.length <= 1) break;
        final second = _insertionOrder[1];
        _insertionOrder.removeAt(1);
        final removed = _vars.remove(second);
        if (removed != null) _totalChars -= removed.charCount;
        continue;
      }
      _insertionOrder.removeAt(0);
      final removed = _vars.remove(oldest);
      if (removed != null) _totalChars -= removed.charCount;
    }
  }

  String _deriveBaseName({
    required String toolName,
    required String target,
    String? explicitName,
  }) {
    if (explicitName != null && explicitName.trim().isNotEmpty) {
      final sanitized = _sanitizeIdentifier(explicitName.trim());
      if (sanitized.isNotEmpty) return sanitized;
    }

    _counter++;
    final lowerTool = toolName.trim().toLowerCase();
    final prefix = switch (lowerTool) {
      'read_file' || 'fs_read_text_file' => 'v_read',
      'run_command' || 'terminal' || 'shell' => 'v_cmd',
      'list_dir' => 'v_list',
      'delegate_subagent' || 'invoke_subagent' => 'v_sub',
      _ when lowerTool.startsWith('phone_') => 'v_phone',
      _ => 'v_var',
    };

    final slug = _extractTargetSlug(target);
    if (slug.isEmpty) return '${prefix}_$_counter';
    final combined = '${prefix}_${slug}_$_counter';
    return combined.length > 28 ? combined.substring(0, 28) : combined;
  }

  static String _sanitizeIdentifier(String raw) {
    var cleaned = raw.replaceFirst(RegExp(r'^\$+'), '');
    cleaned = cleaned
        .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) return '';
    if (RegExp(r'^[0-9]').hasMatch(cleaned)) {
      cleaned = 'v_$cleaned';
    }
    if (cleaned == 'v_last') cleaned = 'v_last_val';
    return cleaned.length > 32 ? cleaned.substring(0, 32) : cleaned;
  }

  static String _extractTargetSlug(String target) {
    final trimmed = target.trim();
    if (trimmed.isEmpty) return '';
    String token = trimmed;
    if (trimmed.contains('/')) {
      final segments = trimmed.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) token = segments.last;
    } else {
      token = trimmed.split(RegExp(r'\s+')).first;
    }
    final sanitized = token
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return '';
    return sanitized.length > 12 ? sanitized.substring(0, 12) : sanitized;
  }

  /// Formats a tool response returned back to the LLM.
  ///
  /// Outputs <= [inlineThresholdChars] are kept inline with a lightweight handle
  /// annotation; larger outputs return a compact variable reference card +
  /// head/tail preview so the model avoids re-ingesting/re-emitting thousands of
  /// raw tokens.
  String formatToolResponse(
    ToolVarEntry entry, {
    int? thresholdChars,
    int previewHead = 450,
    int previewTail = 300,
  }) {
    final limit = thresholdChars ?? inlineThresholdChars;
    if (!enabled) {
      return entry.rawValue;
    }
    if (entry.charCount <= limit) {
      if (entry.rawValue.isEmpty) {
        return '[var: \$${entry.name} (empty)]';
      }
      return '${entry.rawValue}\n\n[var: \$${entry.name} (${entry.summary})]';
    }

    final headLen = math.min(previewHead, entry.rawValue.length);
    final tailStart = math.max(headLen, entry.rawValue.length - previewTail);
    final head = entry.rawValue.substring(0, headLen);
    final tail = entry.rawValue.substring(tailStart);
    final omitted = math.max(0, tailStart - headLen);

    _savedOutputChars += math.max(0, entry.charCount - (head.length + tail.length));

    return '''[VAR STORED: \$${entry.name} | ${entry.summary}]
Reuse \$${entry.name} (or \$${entry.name}.field, \$${entry.name}[0], \$${entry.name}[1:40], \$v_last) directly in any tool argument (`write_file`, `run_command` stdin, `delegate_subagent`) or in your final reply — it expands automatically without re-typing. Use `inspect_var` for slices/queries.
--- PREVIEW ---
$head
... [$omitted middle chars stored in \$${entry.name}] ...
$tail''';
  }

  /// Evaluates an expression like `v_cmd_1`, `v_cmd_1.items[0].id`,
  /// `v_read_1[1:25]`, `v_read_1.lines`, or `v_cmd_1.length`.
  ///
  /// Returns `null` if the root variable does not exist in this store.
  String? resolveExpression(String expression) {
    final clean = expression.trim();
    if (clean.isEmpty) return null;

    final parsed = _parseExpressionParts(clean);
    if (parsed == null) return null;

    final entry = get(parsed.root);
    if (entry == null) return null;

    _resolvedCount++;

    if (parsed.steps.isEmpty) {
      return entry.rawValue;
    }

    // Handle text line slicing `[start:end]` when single slice step on entry.
    if (parsed.steps.length == 1 && parsed.steps.first.isSlice) {
      final slice = parsed.steps.first;
      return _sliceLines(entry.rawValue, slice.sliceStart!, slice.sliceEnd);
    }

    // Special convenience built-ins on the entry itself.
    if (parsed.steps.length == 1 && parsed.steps.first.field != null) {
      switch (parsed.steps.first.field) {
        case 'lines':
          return entry.lineCount.toString();
        case 'chars':
          return entry.charCount.toString();
        case 'head':
          return _sliceLines(entry.rawValue, 1, 20);
        case 'tail':
          final lines = entry.rawValue.split('\n');
          final start = math.max(1, lines.length - 19);
          return _sliceLines(entry.rawValue, start, lines.length);
      }
    }

    Object? current = entry.parsedJson;
    if (current == null) {
      // Built-ins when payload isn't JSON
      if (parsed.steps.length == 1 && parsed.steps.first.field == 'length') {
        return entry.charCount.toString();
      }
      return entry.rawValue;
    }

    for (var i = 0; i < parsed.steps.length; i++) {
      final step = parsed.steps[i];
      if (step.isSlice) {
        if (current is List) {
          final start = math.max(0, step.sliceStart! - 1);
          final end = step.sliceEnd != null
              ? math.min(current.length, step.sliceEnd!)
              : current.length;
          current = start >= current.length ? const [] : current.sublist(start, end);
        } else {
          final textVal = current is String ? current : jsonEncode(current);
          return _sliceLines(textVal, step.sliceStart!, step.sliceEnd);
        }
        continue;
      }

      if (step.index != null) {
        if (current is List) {
          final idx = step.index! < 0 ? current.length + step.index! : step.index!;
          if (idx < 0 || idx >= current.length) return '';
          current = current[idx];
        } else {
          return '';
        }
        continue;
      }

      final field = step.field!;
      final isLast = i == parsed.steps.length - 1;
      if (current is Map) {
        if (current.containsKey(field)) {
          current = current[field];
          continue;
        }
        if (isLast && field == 'length') return current.length.toString();
        if (isLast && field == 'keys') return jsonEncode(current.keys.toList());
        if (isLast && field == 'json') {
          return const JsonEncoder.withIndent('  ').convert(current);
        }
        return '';
      } else if (current is List) {
        if (isLast && field == 'length') return current.length.toString();
        if (isLast && field == 'json') {
          return const JsonEncoder.withIndent('  ').convert(current);
        }
        return '';
      } else {
        final s = current?.toString() ?? '';
        if (isLast && field == 'length') return s.length.toString();
        return '';
      }
    }

    if (current == null) return 'null';
    if (current is String) return current;
    if (current is num || current is bool) return current.toString();
    return jsonEncode(current);
  }

  static String _sliceLines(String text, int startLine, int? endLine) {
    if (text.isEmpty) return '';
    final lines = text.split('\n');
    final startIdx = (startLine - 1).clamp(0, lines.length);
    final endIdx = endLine == null
        ? lines.length
        : endLine.clamp(startIdx, lines.length);
    if (startIdx >= lines.length) return '';
    return lines.sublist(startIdx, endIdx).join('\n');
  }

  /// Inspects a saved variable slice, JSON field, or regex grep cleanly.
  String inspect(
    String nameOrExpr, {
    int? startLine,
    int? limit,
    String? grep,
    int maxChars = 6000,
  }) {
    final clean = nameOrExpr.trim().replaceFirst(RegExp(r'^\$'), '');
    final stripped = clean.startsWith('{') && clean.endsWith('}')
        ? clean.substring(1, clean.length - 1)
        : clean;
    final resolved = resolveExpression(stripped);
    if (resolved == null) {
      final available = _insertionOrder.map((e) => '\$$e').join(', ');
      return 'Variable "\$$stripped" not found. Available: ${available.isEmpty ? "(none)" : available}';
    }

    var text = resolved;
    if (grep != null && grep.trim().isNotEmpty) {
      final re = RegExp(grep, caseSensitive: false);
      final matched = <String>[];
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (re.hasMatch(lines[i])) {
          matched.add('${i + 1}: ${lines[i]}');
          if (matched.length >= 120) break;
        }
      }
      text = matched.isEmpty
          ? '(no lines matched /$grep/)'
          : matched.join('\n');
    } else if (startLine != null || limit != null) {
      final from = (startLine ?? 1).clamp(1, 1 << 30);
      final count = (limit ?? 120).clamp(1, 500);
      text = _sliceLines(text, from, from + count - 1);
    }

    if (text.length > maxChars) {
      return '${text.substring(0, maxChars)}\n... [truncated at $maxChars chars; pass start_line/limit or grep to narrow]';
    }
    return text.isEmpty ? '(empty)' : text;
  }

  /// Expands any `$var` / `${var}` / `$var.field` tokens present in [input]
  /// whose root identifier exists in this store.
  String resolveText(String input) {
    if (!enabled || _vars.isEmpty || !input.contains('\$')) {
      return input;
    }
    return input.replaceAllMapped(_exprRe, (m) {
      final whole = m.group(0)!;
      if (whole.startsWith(r'\$')) {
        return whole.substring(1);
      }
      final expr = m.group(2) ?? m.group(3) ?? '';
      final val = resolveExpression(expr);
      return val ?? whole;
    });
  }

  /// Recursively resolves `$var` references inside a tool call argument map.
  Map<String, dynamic> resolveArguments(
    Map<String, dynamic> args, {
    Set<String> skipKeys = const {'save_as', 'var_name'},
  }) {
    if (!enabled || _vars.isEmpty || args.isEmpty) return args;
    final out = <String, dynamic>{};
    for (final e in args.entries) {
      if (skipKeys.contains(e.key)) {
        out[e.key] = e.value;
      } else {
        out[e.key] = _resolveDynamicValue(e.value);
      }
    }
    return out;
  }

  dynamic _resolveDynamicValue(dynamic value) {
    if (value is String) return resolveText(value);
    if (value is List) {
      return [for (final item in value) _resolveDynamicValue(item)];
    }
    if (value is Map) {
      return value.map(
        (k, v) => MapEntry(k.toString(), _resolveDynamicValue(v)),
      );
    }
    return value;
  }

  static _ParsedExpr? _parseExpressionParts(String expr) {
    final firstSep = expr.indexOf(RegExp(r'[.\[]'));
    final root = firstSep < 0 ? expr : expr.substring(0, firstSep);
    if (!_validNameRe.hasMatch(root)) return null;
    if (firstSep < 0) return _ParsedExpr(root: root, steps: const []);

    final steps = <_PathStep>[];
    var i = firstSep;
    while (i < expr.length) {
      final ch = expr[i];
      if (ch == '.') {
        i++;
        final start = i;
        while (i < expr.length && RegExp(r'[A-Za-z0-9_]').hasMatch(expr[i])) {
          i++;
        }
        final field = expr.substring(start, i);
        if (field.isEmpty) return null;
        steps.add(_PathStep.field(field));
      } else if (ch == '[') {
        final close = expr.indexOf(']', i + 1);
        if (close < 0) return null;
        final inner = expr.substring(i + 1, close).trim();
        if (inner.contains(':')) {
          final parts = inner.split(':');
          if (parts.length != 2) return null;
          final s = parts[0].isEmpty ? 1 : int.tryParse(parts[0]);
          final e = parts[1].isEmpty ? null : int.tryParse(parts[1]);
          if (s == null || (parts[1].isNotEmpty && e == null)) return null;
          steps.add(_PathStep.slice(s, e));
        } else {
          final idx = int.tryParse(inner);
          if (idx == null) return null;
          steps.add(_PathStep.index(idx));
        }
        i = close + 1;
      } else {
        return null;
      }
    }
    return _ParsedExpr(root: root, steps: steps);
  }

  /// Concise **static** prompt instructions teaching models to reuse `$v_*`
  /// variables across tool arguments, subagents, and final responses.
  ///
  /// Kept invariant across turns so LLM prompt / KV-cache prefixes stay valid.
  String systemPromptInstructions({bool hasSubagentTool = true}) {
    final subagentHint = hasSubagentTool
        ? '\n- Pass large inputs to parallel `delegate_subagent` calls by reference (e.g. `context: "\$v_read_1"`).'
        : '';
    return '''[TOOL VARIABLES (Pass-by-Reference)]
Large tool outputs are automatically saved as variables (`\$v_read_*`, `\$v_cmd_*`, `\$v_last`).
- NEVER re-type or copy-paste thousands of lines/rows manually when a `\$v_*` variable already holds them.
- Reference `\$v_...`, `\${v_...}`, `\$v_....field`, `\$v_...[0].id`, or `\$v_...[1:50]` directly in `write_file(content: "\$v_cmd_1")`, `run_command(stdin: "\$v_cmd_1")`, `inspect_var`, or your final user reply (the orchestrator resolves them live).$subagentHint''';
  }

  /// Dynamic tail note listing active variables in this session (`\$v_*`).
  /// Intended to be appended at the end of the latest user turn (never inside
  /// the static system prompt) so prefix caching stays intact.
  String dynamicVarsContextNote({int maxItems = 8}) {
    if (!enabled || _insertionOrder.isEmpty) return '';
    final list = entries.reversed
        .take(maxItems)
        .map((e) => '\$${e.name} (${e.summary})')
        .join('; ');
    return '<tool_variables_active>Active session vars: $list. Reference \$v_* directly or use inspect_var/var_inspect instead of re-reading or re-typing.</tool_variables_active>';
  }
}

class _ParsedExpr {
  const _ParsedExpr({required this.root, required this.steps});
  final String root;
  final List<_PathStep> steps;
}

class _PathStep {
  const _PathStep._({
    this.field,
    this.index,
    this.sliceStart,
    this.sliceEnd,
    this.isSlice = false,
  });

  factory _PathStep.field(String name) => _PathStep._(field: name);
  factory _PathStep.index(int idx) => _PathStep._(index: idx);
  factory _PathStep.slice(int start, int? end) =>
      _PathStep._(sliceStart: start, sliceEnd: end, isSlice: true);

  final String? field;
  final int? index;
  final int? sliceStart;
  final int? sliceEnd;
  final bool isSlice;
}

/// Incremental streaming filter that buffers candidate `$var` / `${var}`
/// expressions split across SSE/ACP text chunks and resolves known variables
/// from [store] without mangling unknown `$ENV` / currency tokens.
class StreamingVariableExpander {
  StreamingVariableExpander(this.store);

  final ToolVariableStore store;
  final StringBuffer _pending = StringBuffer();

  static final RegExp _contCharRe = RegExp(r'[A-Za-z0-9_.\[\]:-]');
  static final RegExp _identCharRe = RegExp(r'[A-Za-z0-9_]');
  static final RegExp _identStartRe = RegExp(r'[A-Za-z_]');

  String addDelta(String chunk) {
    if (chunk.isEmpty) return '';
    if (!store.enabled || store.length == 0) {
      if (_pending.isEmpty) return chunk;
      final prefix = _pending.toString();
      _pending.clear();
      return '$prefix$chunk';
    }

    final out = StringBuffer();
    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];
      if (_pending.isEmpty) {
        if (ch == r'\' || ch == r'$') {
          _pending.write(ch);
        } else {
          out.write(ch);
        }
        continue;
      }

      final cur = _pending.toString();
      // Escaped literal `\$`
      if (cur == r'\') {
        if (ch == r'$') {
          _pending.write(ch);
        } else {
          _pending.clear();
          out.write(cur);
          if (ch == r'\') {
            _pending.write(ch);
          } else {
            out.write(ch);
          }
        }
        continue;
      }
      if (cur.startsWith(r'\$')) {
        // Wait for identifier end, then emit literal `$expr` without backslash.
        if (cur == r'\$' && ch == '{') {
          _pending.write(ch);
          continue;
        }
        if (cur.startsWith(r'\${')) {
          _pending.write(ch);
          if (ch == '}') {
            final full = _pending.toString();
            _pending.clear();
            out.write(full.substring(1));
          } else if (!_contCharRe.hasMatch(ch)) {
            final full = _pending.toString();
            _pending.clear();
            out.write(full.substring(1));
          }
          continue;
        }
        if ((cur.length == 2 && _identStartRe.hasMatch(ch)) ||
            (cur.length > 2 && _contCharRe.hasMatch(ch))) {
          _pending.write(ch);
          continue;
        }
        final full = _pending.toString();
        _pending.clear();
        out.write(full.substring(1));
        i--;
        continue;
      }

      // Active `$...` or `${...` buffer
      if (cur == r'$') {
        if (ch == '{' || _identStartRe.hasMatch(ch)) {
          _pending.write(ch);
        } else {
          _pending.clear();
          out.write(cur);
          i--;
        }
        continue;
      }

      if (cur.startsWith(r'${')) {
        if (ch == '}') {
          final expr = cur.substring(2);
          _pending.clear();
          final resolved = store.resolveExpression(expr);
          out.write(resolved ?? '$cur}');
        } else if (_contCharRe.hasMatch(ch)) {
          _pending.write(ch);
          if (_pending.length > 96) {
            out.write(_pending.toString());
            _pending.clear();
          }
        } else {
          _pending.clear();
          out.write(cur);
          i--;
        }
        continue;
      }

      // Bare `$ident...`
      // Once identifier portion finishes (no longer inside ident and ch is `.` or `[`), allow chaining;
      // otherwise trailing `.` before whitespace shouldn't swallow sentence periods!
      if (cur.endsWith('.')) {
        if (_identStartRe.hasMatch(ch)) {
          _pending.write(ch);
        } else {
          // Sentence ended after `$v_cmd_1.` -> resolve `$v_cmd_1`, re-emit `.` + `ch`
          final expr = cur.substring(1, cur.length - 1);
          _pending.clear();
          final resolved = store.resolveExpression(expr);
          out.write(resolved ?? '\$$expr');
          out.write('.');
          i--;
        }
        continue;
      }

      if (cur.endsWith(']')) {
        if (ch == '.' || ch == '[') {
          _pending.write(ch);
        } else {
          final expr = cur.substring(1);
          _pending.clear();
          final resolved = store.resolveExpression(expr);
          out.write(resolved ?? cur);
          i--;
        }
        continue;
      }

      final hasOpenBracket = cur.contains('[') &&
          '['.allMatches(cur).length > ']'.allMatches(cur).length;
      if (hasOpenBracket) {
        if (ch == ']') {
          _pending.write(ch);
        } else if (RegExp(r'[-0-9:]').hasMatch(ch)) {
          _pending.write(ch);
        } else {
          _pending.clear();
          out.write(cur);
          i--;
        }
        continue;
      }

      if (_identCharRe.hasMatch(ch) || ch == '.' || ch == '[') {
        _pending.write(ch);
        if (_pending.length > 96) {
          out.write(_pending.toString());
          _pending.clear();
        }
      } else {
        final expr = cur.substring(1);
        _pending.clear();
        final resolved = store.resolveExpression(expr);
        out.write(resolved ?? cur);
        i--;
      }
    }
    return out.toString();
  }

  /// Flushes any buffered trailing expression at the end of a stream/step.
  String flush() {
    if (_pending.isEmpty) return '';
    final cur = _pending.toString();
    _pending.clear();
    if (!store.enabled || store.length == 0) return cur;
    if (cur.startsWith(r'\$')) return cur.substring(1);
    if (cur.startsWith(r'$') && !cur.startsWith(r'${')) {
      if (cur.endsWith('.')) {
        final expr = cur.substring(1, cur.length - 1);
        final resolved = store.resolveExpression(expr);
        return '${resolved ?? '\$$expr'}.';
      }
      if (cur.length > 1) {
        final expr = cur.substring(1);
        return store.resolveExpression(expr) ?? cur;
      }
    }
    return cur;
  }
}
