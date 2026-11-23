import 'dart:convert';

/// Kinds of tool-execution loops caught by [HarnessLoopDetector].
enum HarnessLoopKind {
  none,
  repeatedCall,
  pingPongCycle,
  repeatedFailure,
}

/// Result returned when checking or recording a tool invocation.
class LoopDetectionResult {
  const LoopDetectionResult({
    this.kind = HarnessLoopKind.none,
    this.triggered = false,
    this.signature = '',
    this.count = 0,
    this.reason = '',
    this.pivotPrompt = '',
  });

  static const none = LoopDetectionResult();

  final HarnessLoopKind kind;
  final bool triggered;
  final String signature;
  final int count;
  final String reason;
  final String pivotPrompt;
}

class _RecordedCall {
  const _RecordedCall({
    required this.name,
    required this.signature,
    required this.isError,
    this.callId,
  });

  final String name;
  final String signature;
  final bool isError;
  final String? callId;
}

/// Doom-loop & infinite-retry circuit breaker modeled after modern agent
/// harnesses (Claude Code / OpenCode / Codex).
///
/// Tracks canonical tool-call signatures across a rolling window to detect:
/// 1. Identical repeated tool calls (>= [repeatThreshold]).
/// 2. 2-step alternating ping-pong loops `[A, B, A, B]` (>= [cycleThreshold]).
/// 3. Consecutive failures on the same tool even with minor arg variations.
class HarnessLoopDetector {
  HarnessLoopDetector({
    this.repeatThreshold = 3,
    this.cycleThreshold = 4,
    this.failureThreshold = 3,
    this.windowSize = 12,
  });

  final int repeatThreshold;
  final int cycleThreshold;
  final int failureThreshold;
  final int windowSize;

  final List<_RecordedCall> _history = <_RecordedCall>[];

  List<String> get recentSignatures =>
      _history.map((e) => e.signature).toList(growable: false);

  void reset() => _history.clear();

  static String _fnv1a64Hex(String text) {
    // Use 32-bit FNV-1a split across two lanes so it works identically on Dart VM and JS/Web.
    var h1 = 0x811c9dc5;
    var h2 = 0x9e3779b9;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      h1 ^= c & 0xff;
      h1 = (h1 * 0x01000193) & 0xffffffff;
      h2 ^= (c >> 8) ^ (c & 0xff);
      h2 = (h2 * 0x85ebca6b) & 0xffffffff;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }

  /// Produces a canonical signature for a tool invocation, collapsing
  /// whitespace jitter and hashing long inputs without prefix collisions.
  static String canonicalSignature(String name, String input) {
    final normalizedName = name.trim().toLowerCase();
    final collapsedInput = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsedInput.length <= 160) {
      return '$normalizedName::$collapsedInput';
    }
    return '$normalizedName::${collapsedInput.substring(0, 120)}#${_fnv1a64Hex(collapsedInput)}';
  }

  LoopDetectionResult recordToolCall({
    required String name,
    required String input,
    bool isError = false,
    String? callId,
  }) {
    final normalizedName = name.trim().toLowerCase();
    final trimmedInput = input.trim();
    final sig = canonicalSignature(name, input);
    final cid = (callId != null && callId.isNotEmpty) ? callId : null;

    if (cid != null) {
      final existingIdx = _history.lastIndexWhere((e) => e.callId == cid);
      if (existingIdx >= 0) {
        final prev = _history[existingIdx];
        final isIncomingEmpty = trimmedInput.isEmpty || trimmedInput == '{}';
        final nextSig = isIncomingEmpty ? prev.signature : sig;
        _history[existingIdx] = _RecordedCall(
          name: normalizedName.isNotEmpty && normalizedName != 'tool'
              ? normalizedName
              : prev.name,
          signature: nextSig,
          isError: prev.isError || isError,
          callId: cid,
        );
        return evaluate();
      }
    }

    _history.add(
      _RecordedCall(
        name: normalizedName,
        signature: sig,
        isError: isError,
        callId: cid,
      ),
    );
    if (_history.length > windowSize) {
      _history.removeAt(0);
    }
    return evaluate();
  }

  /// Marks the most recent recorded call as failed (used when an error arrives
  /// in a follow-up event after the tool call event).
  LoopDetectionResult markLastFailed({String? toolName, String? callId}) {
    if (_history.isEmpty) return LoopDetectionResult.none;
    if (callId != null && callId.isNotEmpty) {
      final idx = _history.lastIndexWhere((e) => e.callId == callId);
      if (idx >= 0) {
        final entry = _history[idx];
        _history[idx] = _RecordedCall(
          name: entry.name,
          signature: entry.signature,
          isError: true,
          callId: entry.callId,
        );
        return evaluate();
      }
    }
    final targetName = toolName?.trim().toLowerCase();
    for (var i = _history.length - 1; i >= 0; i--) {
      final entry = _history[i];
      if (targetName == null ||
          targetName.isEmpty ||
          entry.name == targetName) {
        _history[i] = _RecordedCall(
          name: entry.name,
          signature: entry.signature,
          isError: true,
          callId: entry.callId,
        );
        return evaluate();
      }
    }
    return LoopDetectionResult.none;
  }

  LoopDetectionResult evaluate() {
    if (_history.isEmpty) return LoopDetectionResult.none;
    final last = _history.last;

    // 1. Consecutive errors on the same tool take precedence when the latest call failed.
    if (last.isError) {
      var consecutiveErrors = 0;
      for (var i = _history.length - 1; i >= 0; i--) {
        if (_history[i].isError && _history[i].name == last.name) {
          consecutiveErrors++;
        } else {
          break;
        }
      }
      if (consecutiveErrors >= failureThreshold) {
        return LoopDetectionResult(
          kind: HarnessLoopKind.repeatedFailure,
          triggered: true,
          signature: last.signature,
          count: consecutiveErrors,
          reason:
              'Tool "${last.name}" failed $consecutiveErrors consecutive times.',
          pivotPrompt: _buildPivotPrompt(
            toolName: last.name,
            reason:
                'Tool "${last.name}" failed $consecutiveErrors consecutive times.',
          ),
        );
      }
    }

    // 2. Consecutive identical tool call signature.
    var consecutiveSame = 0;
    for (var i = _history.length - 1; i >= 0; i--) {
      if (_history[i].signature == last.signature) {
        consecutiveSame++;
      } else {
        break;
      }
    }
    if (consecutiveSame >= repeatThreshold) {
      return LoopDetectionResult(
        kind: HarnessLoopKind.repeatedCall,
        triggered: true,
        signature: last.signature,
        count: consecutiveSame,
        reason:
            'Repeated identical "${last.name}" call $consecutiveSame times in a row.',
        pivotPrompt: _buildPivotPrompt(
          toolName: last.name,
          reason:
              'You repeated the identical "${last.name}" invocation $consecutiveSame times without progress.',
        ),
      );
    }

    // 3. Non-consecutive identical signature spike in rolling window.
    final windowHits =
        _history.where((e) => e.signature == last.signature).length;
    if (windowHits >= repeatThreshold + 1) {
      return LoopDetectionResult(
        kind: HarnessLoopKind.repeatedCall,
        triggered: true,
        signature: last.signature,
        count: windowHits,
        reason:
            'Called identical "${last.name}" $windowHits times in the last ${_history.length} steps.',
        pivotPrompt: _buildPivotPrompt(
          toolName: last.name,
          reason:
              'The same "${last.name}" call recurred $windowHits times within the last ${_history.length} steps.',
        ),
      );
    }

    // 4. 2-step alternating ping-pong cycle [A, B, A, B].
    if (_history.length >= cycleThreshold && cycleThreshold >= 4) {
      final len = _history.length;
      final a = _history[len - 2].signature;
      final b = _history[len - 1].signature;
      if (a != b) {
        var matches = 0;
        for (var i = len - 1; i >= 0; i--) {
          final expected = ((len - 1 - i) % 2 == 0) ? b : a;
          if (_history[i].signature == expected) {
            matches++;
          } else {
            break;
          }
        }
        if (matches >= cycleThreshold) {
          return LoopDetectionResult(
            kind: HarnessLoopKind.pingPongCycle,
            triggered: true,
            signature: '$a <-> $b',
            count: matches,
            reason:
                'Detected a 2-step ping-pong loop across $matches tool calls.',
            pivotPrompt: _buildPivotPrompt(
              toolName: last.name,
              reason:
                  'Execution oscillated between two tool calls $matches times without converging.',
            ),
          );
        }
      }
    }

    return LoopDetectionResult.none;
  }

  static String _buildPivotPrompt({
    required String toolName,
    required String reason,
  }) {
    return '[HARNESS LOOP CIRCUIT BREAKER]\n'
        '$reason\n'
        'Stop repeating "$toolName". Take a step back:\n'
        '1. Re-read the actual error output or target file lines directly.\n'
        '2. Question your current hypothesis and identify what assumption failed.\n'
        '3. Switch to a genuinely different approach or explain the exact blocker concisely.';
  }
}

/// Minimal turn representation consumed by [HarnessContextMonitor] compaction
/// helpers without coupling `agy_client` to Flutter chat state classes.
class HarnessCompactionTurn {
  const HarnessCompactionTurn({
    required this.role,
    required this.text,
    this.toolSummaries = const <String>[],
  });

  final String role;
  final String text;
  final List<String> toolSummaries;
}

/// Snapshot of estimated conversation context pressure against the effective
/// working budget.
class HarnessContextSnapshot {
  const HarnessContextSnapshot({
    required this.usedTokens,
    required this.budgetTokens,
    required this.ratio,
    required this.needsWarning,
    required this.shouldCompact,
    required this.statusLabel,
    this.compactedMessages = 0,
    this.activeMessages = 0,
  });

  final int usedTokens;
  final int budgetTokens;
  final double ratio;
  final bool needsWarning;
  final bool shouldCompact;
  final String statusLabel;
  final int compactedMessages;
  final int activeMessages;

  int get percentage => (ratio * 100).clamp(0, 100).round();
}

/// Tracks conversation token saturation to trigger proactive `/compact`
/// before context rot degrades reasoning quality.
class HarnessContextMonitor {
  const HarnessContextMonitor({
    this.warningThreshold = 0.65,
    this.compactThreshold = 0.80,
  });

  final double warningThreshold;
  final double compactThreshold;

  /// Effective working window (deliberately capped below raw theoretical limits
  /// because reasoning quality degrades well before 100% fill).
  static int effectiveBudgetForModel(String? modelId) {
    final m = (modelId ?? '').trim().toLowerCase();
    if (m.contains('gemini-3.8') || m.contains('1m')) {
      return 400000;
    }
    if (m.contains('gemini-4') ||
        m.contains('orchestrator') ||
        m.contains('neon') ||
        m.contains('carbon') ||
        m.contains('argon') ||
        m.contains('hydrogen') ||
        m.contains('gemini-2.5') ||
        m.contains('gemini-3')) {
      return 256000;
    }
    if (m.contains('claude') || m.contains('opus') || m.contains('sonnet')) {
      return 160000;
    }
    if (m.contains('gpt-5') ||
        m.contains('gpt-oss') ||
        m.contains('codex') ||
        m.contains('o3')) {
      return 160000;
    }
    return 128000;
  }

  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    return (text.length / 3.8).ceil();
  }

  HarnessContextSnapshot evaluate({
    required Iterable<String> messageTexts,
    Iterable<String> toolOutputs = const <String>[],
    String? modelId,
    int? overrideBudgetTokens,
    int compactedMessages = 0,
    int? activeMessages,
  }) {
    var totalTokens = 0;
    var msgCount = 0;
    for (final text in messageTexts) {
      msgCount++;
      totalTokens += estimateTokens(text) + 12;
    }
    for (final output in toolOutputs) {
      totalTokens += estimateTokens(output);
    }

    final budget = overrideBudgetTokens ?? effectiveBudgetForModel(modelId);
    final safeBudget = budget <= 0 ? 128000 : budget;
    final ratio = (totalTokens / safeBudget).clamp(0.0, 1.0);
    final shouldCompact = ratio >= compactThreshold;
    final needsWarning = ratio >= warningThreshold;

    final statusLabel = shouldCompact
        ? 'High — compact recommended'
        : needsWarning
            ? 'Warming — watch context'
            : 'Healthy';

    return HarnessContextSnapshot(
      usedTokens: totalTokens,
      budgetTokens: safeBudget,
      ratio: ratio,
      needsWarning: needsWarning,
      shouldCompact: shouldCompact,
      statusLabel: statusLabel,
      compactedMessages: compactedMessages,
      activeMessages: activeMessages ?? msgCount,
    );
  }

  /// Builds a bounded prompt for a stateless LLM compaction turn so `/compact`
  /// still works even when the prior session hit 100% context.
  static String buildCompactionPrompt(
    List<HarnessCompactionTurn> turns, {
    required int compactedMessages,
    String? focusInstructions,
  }) {
    final focus = focusInstructions?.trim() ?? '';
    final transcript = _renderDigest(turns, maxChars: 34000);
    final buf = StringBuffer()
      ..writeln(
        'Compact the following $compactedMessages-message conversation into a concise, self-contained handoff summary so work can resume seamlessly in a fresh context window.',
      );
    if (focus.isNotEmpty) {
      buf.writeln('Focus instructions: $focus');
    }
    buf
      ..writeln()
      ..writeln('Include only verified facts observed in the transcript under these headings:')
      ..writeln('### Goal & Decisions')
      ..writeln('### Touched Files & Changes')
      ..writeln('### Verified Checks')
      ..writeln('### Open Blockers & Next Steps')
      ..writeln()
      ..writeln('<transcript>')
      ..writeln(transcript)
      ..writeln('</transcript>');
    return buf.toString();
  }

  /// Deterministic extractive compaction fallback used when the agent runtime
  /// is offline, unauthenticated, or returns an error during `/compact`.
  static String buildFallbackCompactionSummary(
    List<HarnessCompactionTurn> turns, {
    required int compactedMessages,
    String? focusInstructions,
  }) {
    final userRequests = <String>[];
    final toolList = <String>{};
    String lastAssistant = '';

    for (final t in turns) {
      final cleaned = t.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (t.role == 'user' && cleaned.isNotEmpty) {
        userRequests.add(
          cleaned.length > 140 ? '${cleaned.substring(0, 140)}…' : cleaned,
        );
      } else if (t.role == 'assistant' && cleaned.isNotEmpty) {
        lastAssistant =
            cleaned.length > 500 ? '${cleaned.substring(0, 500)}…' : cleaned;
      }
      for (final tool in t.toolSummaries) {
        final trimmedTool = tool.trim();
        if (trimmedTool.isNotEmpty) toolList.add(trimmedTool);
      }
    }

    final recentUsers = userRequests.length > 5
        ? userRequests.sublist(userRequests.length - 5)
        : userRequests;
    final focus = focusInstructions?.trim() ?? '';

    final buf = StringBuffer()
      ..writeln('### Context Compacted ($compactedMessages messages archived)');
    if (focus.isNotEmpty) {
      buf.writeln('- **Focus**: $focus');
    }
    if (recentUsers.isNotEmpty) {
      buf.writeln('\n#### Recent User Requests');
      for (final r in recentUsers) {
        buf.writeln('- $r');
      }
    }
    if (lastAssistant.isNotEmpty) {
      buf.writeln('\n#### Latest State');
      buf.writeln(lastAssistant);
    }
    if (toolList.isNotEmpty) {
      buf.writeln('\n#### Tools Run');
      for (final tool in toolList.take(12)) {
        final oneLine = tool.replaceAll(RegExp(r'\s+'), ' ');
        buf.writeln(
          '- ${oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine}',
        );
      }
    }
    return buf.toString().trim();
  }

  static String _renderDigest(
    List<HarnessCompactionTurn> turns, {
    int maxChars = 34000,
  }) {
    if (turns.isEmpty) return '';
    final blocks = <String>[];
    for (final t in turns) {
      final body = t.text.trim();
      final clippedBody =
          body.length > 2400 ? '${body.substring(0, 2400)}\n…[truncated]' : body;
      final sb = StringBuffer('[${t.role.toUpperCase()}]');
      if (clippedBody.isNotEmpty) {
        sb.write('\n$clippedBody');
      }
      if (t.toolSummaries.isNotEmpty) {
        final tools = t.toolSummaries.take(8).join('; ');
        sb.write('\n[tools: $tools]');
      }
      blocks.add(sb.toString());
    }

    // Keep oldest anchor + as many recent turns as fit in maxChars.
    if (blocks.length == 1) return blocks.first;
    final anchor = blocks.first;
    final anchorBudget = anchor.length + 2;
    final selected = <String>[];
    var used = anchorBudget < maxChars ? anchorBudget : 0;
    var stoppedAt = 0;
    for (var i = blocks.length - 1; i >= 1; i--) {
      final b = blocks[i];
      if (used + b.length + 2 > maxChars && selected.isNotEmpty) {
        stoppedAt = i;
        break;
      }
      selected.add(b);
      used += b.length + 2;
    }
    final ordered = <String>[];
    if (anchorBudget < maxChars) {
      ordered.add(anchor);
      if (stoppedAt >= 1) {
        ordered.add('… ($stoppedAt middle turns omitted for brevity) …');
      }
    }
    ordered.addAll(selected.reversed);
    return ordered.join('\n\n');
  }
}

/// Structured feature item stored inside `.agy-harness/feature_list.json`
/// following Anthropic's Initializer + Incremental Coder harness topology.
class HarnessFeatureItem {
  const HarnessFeatureItem({
    required this.id,
    required this.description,
    this.category = 'functional',
    this.steps = const <String>[],
    this.passes = false,
    this.verifiedAt,
  });

  final String id;
  final String category;
  final String description;
  final List<String> steps;
  final bool passes;
  final String? verifiedAt;

  HarnessFeatureItem copyWith({
    String? id,
    String? category,
    String? description,
    List<String>? steps,
    bool? passes,
    String? verifiedAt,
    bool clearVerifiedAt = false,
  }) {
    return HarnessFeatureItem(
      id: id ?? this.id,
      category: category ?? this.category,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      passes: passes ?? this.passes,
      verifiedAt: clearVerifiedAt ? null : (verifiedAt ?? this.verifiedAt),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'category': category,
        'description': description,
        'steps': steps,
        'passes': passes,
        'verifiedAt': ?verifiedAt,
      };

  static HarnessFeatureItem fromJson(Map<String, dynamic> json, [int idx = 0]) {
    final rawSteps = json['steps'];
    final steps = rawSteps is List
        ? rawSteps
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final id = (json['id'] as String?)?.trim();
    return HarnessFeatureItem(
      id: (id == null || id.isEmpty) ? 'feat-${idx + 1}' : id,
      category: (json['category'] as String?)?.trim().isNotEmpty == true
          ? (json['category'] as String).trim()
          : 'functional',
      description: (json['description'] as String?)?.trim() ?? '',
      steps: steps,
      passes: json['passes'] == true,
      verifiedAt: json['verifiedAt'] as String?,
    );
  }

  static ({List<HarnessFeatureItem> items, bool hasParseError})
      parseFeatureListStrict(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return (items: const <HarnessFeatureItem>[], hasParseError: false);
    }
    try {
      final decoded = jsonDecode(trimmed);
      final List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> &&
          decoded['features'] is List) {
        list = decoded['features'] as List<dynamic>;
      } else {
        return (items: const <HarnessFeatureItem>[], hasParseError: true);
      }
      final items = <HarnessFeatureItem>[];
      for (var i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is Map) {
          items.add(
            fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
              i,
            ),
          );
        }
      }
      return (items: items, hasParseError: false);
    } catch (_) {
      return (items: const <HarnessFeatureItem>[], hasParseError: true);
    }
  }

  static List<HarnessFeatureItem> parseFeatureList(String raw) =>
      parseFeatureListStrict(raw).items;

  static String encodeFeatureList(List<HarnessFeatureItem> items) {
    final payload = <String, dynamic>{
      'schema': 'agy-harness/v1',
      'features': items.map((e) => e.toJson()).toList(growable: false),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }
}

/// Prompt & artifact templates for Initializer, Incremental Coder, and
/// Adversarial Reviewer harness topologies.
class HarnessWorkspaceTemplates {
  const HarnessWorkspaceTemplates._();

  static String? detectVerifyCommand({
    bool isFlutter = false,
    bool hasPubspec = false,
    bool hasPackageJson = false,
    bool hasPyproject = false,
    bool hasCargoToml = false,
    bool hasGradlew = false,
    String? gradlewCommand,
  }) {
    if (isFlutter) return 'flutter test';
    if (hasPubspec) return 'dart test';
    if (hasPackageJson) return 'npm test';
    if (hasPyproject) return 'pytest';
    if (hasCargoToml) return 'cargo test';
    if (gradlewCommand != null && gradlewCommand.trim().isNotEmpty) {
      return gradlewCommand.trim();
    }
    if (hasGradlew) return './gradlew test';
    return null;
  }

  static String defaultFeatureListJson(
    String goal, {
    String? verifyCommand,
  }) {
    final cleanGoal = goal.trim().isEmpty
        ? 'Deliver verified project milestone'
        : goal.trim();
    final verifyStep = (verifyCommand != null && verifyCommand.trim().isNotEmpty)
        ? 'Run verification gate: ${verifyCommand.trim()}'
        : 'Run project test/lint suite and confirm clean exit';
    return HarnessFeatureItem.encodeFeatureList(<HarnessFeatureItem>[
      HarnessFeatureItem(
        id: 'F-001',
        category: 'setup',
        description: 'Inspect repository baseline and confirm existing checks pass',
        steps: <String>[
          'Check git status and inspect key source files',
          verifyStep,
        ],
      ),
      HarnessFeatureItem(
        id: 'F-002',
        category: 'core',
        description: cleanGoal,
        steps: <String>[
          'Implement cohesive, well-tested changes without duplicating logic',
          verifyStep,
        ],
      ),
      HarnessFeatureItem(
        id: 'F-003',
        category: 'verification',
        description: 'Run adversarial diff review and end-to-end verification',
        steps: <String>[
          'Inspect git diff for regressions, missing error handling, or dead code',
          verifyStep,
        ],
      ),
    ]);
  }

  static String defaultProgressTxt(
    String goal, {
    String? verifyCommand,
  }) {
    final now = DateTime.now().toUtc().toIso8601String();
    final cleanGoal = goal.trim().isEmpty ? '(unspecified goal)' : goal.trim();
    final verify =
        (verifyCommand == null || verifyCommand.trim().isEmpty)
            ? 'auto-detect project tests'
            : verifyCommand.trim();
    return '''# Antigravity Harness Progress Log
Initialized: $now
Goal: $cleanGoal
Verify Gate: $verify

## Rules for Every Coding Session
1. Read `.agy-harness/feature_list.json` and `.agy-harness/progress.txt` first.
2. Pick ONE unfinished feature (`passes == false`) to work on per turn.
3. Run `$verify` before marking any feature `"passes": true`.
4. Leave working tree clean or append a concise handoff summary below.

## Session Notes
- [$now] Initialized harness ledger.
''';
  }

  static String buildInitializerPrompt({
    required String goal,
    String? verifyCommand,
  }) {
    final verifyLine = (verifyCommand != null && verifyCommand.trim().isNotEmpty)
        ? 'Verification command: `${verifyCommand.trim()}`'
        : 'Identify the project test/verify command (e.g. `flutter test`, `dart test`, `pytest`, `npm test`, `./gradlew test`).';
    return '''Run as a **Harness Initializer Agent** for this repository:

Goal: $goal
$verifyLine

Tasks:
1. Inspect the workspace structure, git status, and baseline test health.
2. Populate `.agy-harness/feature_list.json` with a concrete, ordered list of small verifiable features (`id`, `category`, `description`, `steps`, `passes: false`). Only mark features `passes: true` if already implemented AND verified.
3. Update `.agy-harness/progress.txt` with environment setup notes, the exact verification command, and the recommended first feature (`F-001` / next pending item).
4. Do NOT start large feature implementation yet — leave a clean, deterministic handoff for the Coder session.''';
  }

  static String buildNextFeaturePrompt({
    HarnessFeatureItem? nextFeature,
    String? verifyCommand,
  }) {
    final targetBlock = nextFeature == null
        ? 'Read `.agy-harness/feature_list.json` and `.agy-harness/progress.txt`, select the first feature with `"passes": false`, and implement ONLY that feature cleanly.'
        : 'Target Feature: **${nextFeature.id}** — ${nextFeature.description}\n'
            'Acceptance Steps:\n'
            '${nextFeature.steps.isEmpty ? '- Implement and verify cleanly' : nextFeature.steps.map((s) => '- $s').join('\n')}';
    final verifyLine = (verifyCommand != null && verifyCommand.trim().isNotEmpty)
        ? 'You MUST run `${verifyCommand.trim()}` and observe it passing before setting `"passes": true`.'
        : 'Run the project verification command before setting `"passes": true`.';
    return '''Run as an **Incremental Coder Agent** inside the Antigravity Harness:

1. Read `.agy-harness/progress.txt` and `.agy-harness/feature_list.json`.
2. $targetBlock
3. $verifyLine
4. Update `.agy-harness/feature_list.json` (`"passes": true` ONLY if verified end-to-end) and append a concise session handoff note to `.agy-harness/progress.txt`.''';
  }

  static String buildAdversarialReviewPrompt({
    String? verifyCommand,
    int? pendingCount,
  }) {
    final verifyLine = (verifyCommand != null && verifyCommand.trim().isNotEmpty)
        ? 'Re-run `${verifyCommand.trim()}` independently and inspect failures/warnings.'
        : 'Re-run the project test/analyzer suite independently.';
    final pendingNote = pendingCount != null
        ? 'There are currently $pendingCount unfinished feature(s) in `.agy-harness/feature_list.json`.\n'
        : '';
    return '''Run as an **Adversarial Verifier & Diff Reviewer Agent** (Evaluator topology):

${pendingNote}Do NOT blindly trust prior claims. Independently inspect the workspace:
1. Run `git status` and `git diff` to inspect every changed file.
2. Check for silent regressions, swallowed errors, missing edge-case guards, duplicated logic, or skipped tests.
3. $verifyLine
4. Verify `.agy-harness/feature_list.json` accuracy — if a feature marked `"passes": true` lacks test coverage or fails verification, flip it back to `"passes": false` and document the exact defect in `.agy-harness/progress.txt`.
5. Summarize concrete PASS / FAIL verdict with exact file paths and commands run.''';
  }
}
