import 'package:agy_client/agy_client.dart';

import 'chat_models.dart';

/// Pure message/diff/tool aggregation helpers extracted from `ChatNotifier`.
class ChatTurnHelpers {
  ChatTurnHelpers._();

  static bool isImagePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic') ||
        lower.endsWith('.heif');
  }

  static List<ChatToolStep> finalizeTools(
    List<ChatToolStep> tools, {
    bool failed = false,
  }) {
    var changed = false;
    final out = tools.map((t) {
      if (t.state == ToolCallState.running ||
          t.state == ToolCallState.pending) {
        changed = true;
        return ChatToolStep(
          id: t.id,
          toolName: t.toolName,
          state: failed ? ToolCallState.failed : ToolCallState.completed,
          parameters: t.parameters,
          output: t.output,
          error: t.error,
          durationSeconds: t.durationSeconds,
          startedAt: t.startedAt,
        );
      }
      return t;
    }).toList();
    return changed ? out : tools;
  }

  static TokenUsage? mergeStepUsage(TokenUsage? prev, TokenUsage? stepUsage) {
    if (stepUsage == null) return prev;
    if (prev == null) return stepUsage;
    return TokenUsage(
      inputTokens:
          stepUsage.inputTokens > 0 ? stepUsage.inputTokens : prev.inputTokens,
      outputTokens: stepUsage.outputTokens > 0
          ? stepUsage.outputTokens
          : prev.outputTokens,
      thinkingTokens: stepUsage.thinkingTokens > 0
          ? stepUsage.thinkingTokens
          : prev.thinkingTokens,
      cacheReadTokens: stepUsage.cacheReadTokens > 0
          ? stepUsage.cacheReadTokens
          : prev.cacheReadTokens,
      totalTokens:
          stepUsage.totalTokens > 0 ? stepUsage.totalTokens : prev.totalTokens,
      contextTokens: stepUsage.contextTokens > 0
          ? stepUsage.contextTokens
          : prev.contextTokens,
    );
  }

  static String? extractGitPushCwd(
    List<ChatToolStep> tools, {
    required String fallbackCwd,
  }) {
    for (final t in tools.reversed) {
      if (t.state == ToolCallState.failed ||
          (t.error != null && t.error!.isNotEmpty)) {
        continue;
      }
      final cmd =
          (t.parameters['CommandLine'] ?? t.parameters['command'] ?? '')
              .toString();
      final lower = cmd.toLowerCase();
      if (!lower.contains('git push') ||
          lower.contains('--dry-run') ||
          lower.contains('--help')) {
        continue;
      }
      final paramCwd = (t.parameters['Cwd'] ??
              t.parameters['cwd'] ??
              t.parameters['workdir'] ??
              '')
          .toString()
          .trim();
      if (paramCwd.isNotEmpty) return paramCwd;

      final cdMatch = RegExp(
        r'''(?:^|[;&|]\s*)cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))''',
      ).firstMatch(cmd);
      if (cdMatch != null) {
        final dir =
            (cdMatch.group(1) ?? cdMatch.group(2) ?? cdMatch.group(3) ?? '')
                .trim();
        if (dir.isNotEmpty) return dir;
      }

      final gitCMatch = RegExp(
        r'''git\s+-C\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))''',
      ).firstMatch(cmd);
      if (gitCMatch != null) {
        final dir =
            (gitCMatch.group(1) ?? gitCMatch.group(2) ?? gitCMatch.group(3) ?? '')
                .trim();
        if (dir.isNotEmpty) return dir;
      }

      if (fallbackCwd.isNotEmpty) return fallbackCwd;
    }
    return null;
  }

  static ({String diff, int added, int removed}) _buildDiffWithStats(
    String path,
    String? oldText,
    String? newText,
  ) {
    final res = UnifiedLineDiff.compute(
      path: path,
      oldText: oldText,
      newText: newText,
      maxBodyLines: 160,
    );
    return (diff: res.diff, added: res.added, removed: res.removed);
  }

  static String? buildToolDiff(
    String path,
    String? oldText,
    String? newText,
  ) {
    final res = _buildDiffWithStats(path, oldText, newText);
    return res.diff.isEmpty ? null : '${res.diff}\n';
  }

  static ({int added, int removed}) _countPatchLines(String patch) {
    var added = 0;
    var removed = 0;
    for (final l in patch.split('\n')) {
      if (l.startsWith('+') && !l.startsWith('+++')) {
        added++;
      } else if (l.startsWith('-') && !l.startsWith('---')) {
        removed++;
      }
    }
    return (added: added, removed: removed);
  }

  static bool hasDiffOutput(String? rawOutput) {
    if (rawOutput == null || rawOutput.isEmpty) return false;
    final trimmedLeft = rawOutput.trimLeft();
    if (trimmedLeft.startsWith('--- a/') || trimmedLeft.startsWith('@@ ')) {
      return true;
    }
    return rawOutput.contains('\n@@ ');
  }

  static bool isFileEditTool(ChatToolStep step) {
    final nameLower = step.toolName.toLowerCase();
    final p = step.parameters;
    final hasEditParams = p.containsKey('Replacement') ||
        p.containsKey('Target') ||
        p.containsKey('ReplacementContent') ||
        p.containsKey('TargetContent') ||
        p.containsKey('ReplacementChunks') ||
        p.containsKey('oldText') ||
        p.containsKey('newText') ||
        p.containsKey('old_string') ||
        p.containsKey('new_string') ||
        p.containsKey('oldContent') ||
        p.containsKey('newContent') ||
        p.containsKey('old_content') ||
        p.containsKey('new_content') ||
        p.containsKey('originalContent') ||
        p.containsKey('CodeContent') ||
        p.containsKey('Content') ||
        p.containsKey('diff') ||
        p.containsKey('patch');
    final isDeleteTool = nameLower.contains('delete_file') ||
        nameLower.contains('remove_file') ||
        nameLower.contains('unlink') ||
        nameLower == 'delete' ||
        p['Deleted'] == true ||
        p['deleted'] == true;
    if (nameLower.contains('write') ||
        nameLower.contains('edit') ||
        nameLower.contains('replace') ||
        nameLower.contains('patch') ||
        nameLower.contains('create_file') ||
        isDeleteTool ||
        hasEditParams) {
      return true;
    }
    if (nameLower.contains('read') ||
        nameLower.contains('view') ||
        nameLower.contains('grep') ||
        nameLower.contains('find') ||
        nameLower.contains('list') ||
        nameLower.contains('search') ||
        nameLower.contains('fetch')) {
      return false;
    }
    return hasDiffOutput(step.output);
  }

  static bool hasSuccessfulGitCommit(ChatToolStep step) {
    if (step.state != ToolCallState.completed ||
        (step.error != null && step.error!.trim().isNotEmpty)) {
      return false;
    }
    final cmd = (step.parameters['CommandLine'] ??
            step.parameters['command'] ??
            step.parameters['cmd'] ??
            step.toolName)
        .toString();
    final lower = cmd.toLowerCase();
    if (!lower.contains('git') ||
        !lower.contains('commit') ||
        lower.contains('--dry-run') ||
        lower.contains('--help')) {
      return false;
    }
    final hasCommitCmd = RegExp(
      r'(?:^|[;&|\s])git(?:\s+-[^\s]+(?:\s+[^\s]+)?)*\s+commit\b',
      caseSensitive: false,
    ).hasMatch(cmd);
    if (!hasCommitCmd) return false;
    final outLower = (step.output ?? '').toLowerCase();
    if (outLower.contains('command exited with code ') &&
        !outLower.contains('command exited with code 0')) {
      return false;
    }
    if (outLower.contains('fatal:')) return false;
    return true;
  }

  /// Extracts changed files from [tools], discarding any file edits that
  /// happened before the last successful `git commit` shell command in the turn.
  static ({bool committed, List<FileChangeEntry> files})
      extractUncommittedFilesFromTools(List<ChatToolStep> tools) {
    var lastCommitIdx = -1;
    for (var i = 0; i < tools.length; i++) {
      if (hasSuccessfulGitCommit(tools[i])) {
        lastCommitIdx = i;
      }
    }
    if (lastCommitIdx < 0) {
      return (committed: false, files: extractChangedFilesFromTools(tools));
    }
    final postCommitTools = tools.sublist(lastCommitIdx + 1);
    return (
      committed: true,
      files: extractChangedFilesFromTools(postCommitTools),
    );
  }

  static List<FileChangeEntry> extractChangedFilesFromTools(
    List<ChatToolStep> tools,
  ) {
    final byPath = <String, FileChangeEntry>{};
    for (final step in tools) {
      if (step.state == ToolCallState.failed) continue;
      if (!isFileEditTool(step)) continue;
      final nameLower = step.toolName.toLowerCase();
      final p = step.parameters;
      final isDeleteTool = nameLower.contains('delete_file') ||
          nameLower.contains('remove_file') ||
          nameLower.contains('unlink') ||
          nameLower == 'delete' ||
          p['Deleted'] == true ||
          p['deleted'] == true;
      final hasOutputDiff = hasDiffOutput(step.output);
      final outStr = hasOutputDiff ? step.output!.trim() : '';

      var path = (p['TargetFile'] ??
                  p['AbsolutePath'] ??
                  p['Path'] ??
                  p['path'] ??
                  p['file_path'] ??
                  p['filePath'] ??
                  p['File'] ??
                  p['file'] ??
                  '')
          .toString()
          .trim();
      if (path.isEmpty && hasOutputDiff) {
        final plusMatch = RegExp(
          r'^\+\+\+\s+(?:b/)?(.+)$',
          multiLine: true,
        ).firstMatch(outStr);
        final headerPath = plusMatch?.group(1)?.trim() ?? '';
        if (headerPath.isNotEmpty && headerPath != '/dev/null') {
          path = headerPath;
        }
      }
      if (path.isEmpty) continue;

      var added = 0;
      var removed = 0;
      var hadTargetText = false;
      String? diffSnippet;
      final chunks = p['ReplacementChunks'];
      if (chunks is List && chunks.isNotEmpty) {
        hadTargetText = true;
        final buf = StringBuffer();
        for (final ch in chunks) {
          if (ch is! Map) continue;
          final rep = ch['ReplacementContent']?.toString();
          final tgt = ch['TargetContent']?.toString();
          final part = _buildDiffWithStats(path, tgt, rep);
          added += part.added;
          removed += part.removed;
          if (part.diff.isNotEmpty) buf.writeln(part.diff);
        }
        final combined = buf.toString().trimRight();
        if (combined.isNotEmpty) diffSnippet = combined;
      } else {
        final replacement = p['Replacement'] ??
            p['ReplacementContent'] ??
            p['CodeContent'] ??
            p['Content'] ??
            p['newText'] ??
            p['new_text'] ??
            p['new_string'] ??
            p['newString'] ??
            p['newContent'] ??
            p['new_content'] ??
            p['after'] ??
            p['content'];
        final target = p['Target'] ??
            p['TargetContent'] ??
            p['oldText'] ??
            p['old_text'] ??
            p['old_string'] ??
            p['oldString'] ??
            p['oldContent'] ??
            p['old_content'] ??
            p['originalContent'] ??
            p['original_content'] ??
            p['before'];
        final rawPatch = p['diff'] ?? p['patch'];
        final repStr = replacement?.toString();
        final tgtStr = target?.toString();
        if (tgtStr != null || repStr != null) {
          hadTargetText = tgtStr != null;
          if (!hadTargetText && hasOutputDiff) {
            final outCounts = _countPatchLines(outStr);
            if (outCounts.added > 0 || outCounts.removed > 0) {
              diffSnippet = outStr.startsWith('@@ ')
                  ? '--- a/$path\n+++ b/$path\n$outStr'
                  : outStr;
              added = outCounts.added;
              removed = outCounts.removed;
            } else {
              final res = _buildDiffWithStats(path, tgtStr, repStr);
              added = res.added;
              removed = res.removed;
              diffSnippet = res.diff.isEmpty ? null : res.diff;
            }
          } else {
            final res = _buildDiffWithStats(path, tgtStr, repStr);
            added = res.added;
            removed = res.removed;
            diffSnippet = res.diff.isEmpty ? null : res.diff;
          }
        } else if (rawPatch is String && rawPatch.trim().isNotEmpty) {
          hadTargetText = true;
          diffSnippet = rawPatch.trimRight();
          final counts = _countPatchLines(diffSnippet);
          added = counts.added;
          removed = counts.removed;
        }
      }

      if (hasOutputDiff) {
        final outCounts = _countPatchLines(outStr);
        if (diffSnippet == null ||
            (added == 0 && removed == 0) ||
            (!hadTargetText && (outCounts.added > 0 || outCounts.removed > 0))) {
          diffSnippet = outStr.startsWith('@@ ')
              ? '--- a/$path\n+++ b/$path\n$outStr'
              : outStr;
          added = outCounts.added;
          removed = outCounts.removed;
        }
      }

      final created = !isDeleteTool &&
          ((p['Overwrite'] == false) ||
              nameLower.contains('create') ||
              ((nameLower.contains('write_to_file') ||
                      nameLower.contains('write_file')) &&
                  removed == 0));
      final deleted = isDeleteTool || (step.output?.contains('+++ /dev/null') ?? false);
      final prev = byPath[path];
      final combinedDiff = [
        if (prev?.diff != null && prev!.diff!.trim().isNotEmpty) prev.diff!.trimRight(),
        if (diffSnippet != null && diffSnippet.trim().isNotEmpty)
          diffSnippet.trimRight(),
      ].join('\n');
      byPath[path] = FileChangeEntry(
        path: path,
        added: (prev?.added ?? 0) + added,
        removed: (prev?.removed ?? 0) + removed,
        created: prev?.created ?? created,
        deleted: (prev?.deleted ?? false) || deleted,
        diff: combinedDiff.isNotEmpty ? combinedDiff : prev?.diff,
      );
    }
    return byPath.values.toList();
  }

  static bool isSubagentSpawnTool(String toolName) {
    final lower = toolName.toLowerCase();
    return lower.contains('invoke_subagent') ||
        lower.contains('invoking subagent') ||
        lower.contains('invoke subagent') ||
        lower.contains('run_workflow') ||
        lower.contains('browser_subagent');
  }

  static bool isSubagentTool(String toolName) {
    final lower = toolName.toLowerCase();
    return lower.contains('subagent') ||
        lower.contains('workflow') ||
        lower.contains('schedule') ||
        lower.contains('send_message');
  }

  static String? extractConversationId(String? rawOutput) {
    if (rawOutput == null || rawOutput.trim().isEmpty) return null;
    final uuidMatch = RegExp(
      r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
    ).firstMatch(rawOutput);
    if (uuidMatch != null) return uuidMatch.group(0);
    final kvMatch = RegExp(
      r'''conversationId["']?\s*[:=]\s*["']?([A-Za-z0-9_-]{6,})''',
    ).firstMatch(rawOutput);
    return kvMatch?.group(1);
  }

  static String extractSubagentRole(
    String toolName,
    Map<String, dynamic> parameters,
  ) {
    final role = (parameters['Role'] ?? parameters['role'])?.toString().trim();
    if (role != null && role.isNotEmpty) return role;
    final name = (parameters['Name'] ?? parameters['name'])?.toString().trim();
    if (name != null && name.isNotEmpty) return name;
    final desc = (parameters['Description'] ?? parameters['description'])
        ?.toString()
        .trim();
    if (desc != null && desc.isNotEmpty) return desc;
    final typeName =
        (parameters['TypeName'] ?? parameters['typeName'])?.toString().trim();
    if (typeName != null && typeName.isNotEmpty) return typeName;
    if (toolName.toLowerCase().contains('workflow')) return 'Workflow';
    if (toolName.toLowerCase().contains('browser')) return 'Browser Subagent';
    return 'Subagent';
  }

  /// Formats noisy relative (`../../../../../../...`) or long device paths into
  /// a concise, meaningful path where the filename & parent context stay visible.
  static String formatDisplayPath(String rawPath) {
    var clean = rawPath.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) return '';
    if (clean.startsWith('file://')) {
      clean = clean.substring('file://'.length);
    }

    // Resolve `.` / `..` segments cleanly and drop meaningless leading `..` escapes.
    final rawSegments = clean.split('/');
    final normalized = <String>[];
    for (final seg in rawSegments) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (normalized.isNotEmpty) normalized.removeLast();
        continue;
      }
      normalized.add(seg);
    }
    if (normalized.isEmpty) return '';

    // Strip verbose Android storage / app-private prefixes when deeper path exists.
    List<String> trimmed = normalized;
    final projectsIdx = trimmed.indexOf('Projects');
    if (projectsIdx >= 0 && projectsIdx + 2 < trimmed.length) {
      trimmed = trimmed.sublist(projectsIdx + 2);
    } else if (trimmed.length > 3 &&
        trimmed[0] == 'storage' &&
        trimmed[1] == 'emulated' &&
        trimmed[2] == '0') {
      trimmed = trimmed.sublist(3);
    } else if (trimmed.length > 1 && trimmed[0] == 'sdcard') {
      trimmed = trimmed.sublist(1);
    } else {
      final runtimeIdx = trimmed.indexOf('runtime');
      if (runtimeIdx >= 0 &&
          runtimeIdx + 2 < trimmed.length &&
          trimmed[runtimeIdx + 1] == 'workspace') {
        trimmed = trimmed.sublist(runtimeIdx + 2);
      }
    }

    if (trimmed.length > 4) {
      return '…/${trimmed.sublist(trimmed.length - 3).join('/')}';
    }
    return trimmed.join('/');
  }

  static String formatToolTarget(ChatToolStep step) {
    final p = step.parameters;
    if (p.isNotEmpty) {
      final directCmd = p['CommandLine'] ?? p['command'] ?? p['cmd'];
      if (directCmd != null && directCmd.toString().trim().isNotEmpty) {
        return directCmd.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
      }

      final startLine = p['StartLine'] ?? p['start_line'] ?? p['line'];
      final endLine = p['EndLine'] ?? p['end_line'];
      final lineSuffix = startLine != null
          ? (endLine != null && endLine != startLine
              ? ':$startLine-$endLine'
              : ':$startLine')
          : '';

      final rawFilePath = p['TargetFile'] ??
          p['AbsolutePath'] ??
          p['Path'] ??
          p['path'] ??
          p['file_path'] ??
          p['filePath'] ??
          p['File'] ??
          p['file'] ??
          p['ItemPath'];
      if (rawFilePath != null && rawFilePath.toString().trim().isNotEmpty) {
        final formatted = formatDisplayPath(rawFilePath.toString());
        if (formatted.isNotEmpty) return '$formatted$lineSuffix';
      }

      final nodePaths = p['NodePaths'];
      if (nodePaths is List && nodePaths.isNotEmpty) {
        final items = nodePaths
            .map((e) => formatDisplayPath(e.toString()))
            .where((s) => s.isNotEmpty)
            .take(2)
            .toList();
        if (items.isNotEmpty) return items.join(', ');
      }

      final dirPath = p['DirectoryPath'] ?? p['SearchDirectory'];
      final query = (p['Query'] ?? p['query'])?.toString().trim() ?? '';
      final pattern = (p['Pattern'] ?? p['pattern'])?.toString().trim() ?? '';
      if (query.isNotEmpty) {
        final inDir = dirPath != null
            ? formatDisplayPath(dirPath.toString())
            : (p['SearchPath'] != null
                ? formatDisplayPath(p['SearchPath'].toString())
                : '');
        return inDir.isNotEmpty ? '"$query" in $inDir' : '"$query"';
      }
      if (pattern.isNotEmpty) {
        final inDir = dirPath != null
            ? formatDisplayPath(dirPath.toString())
            : '';
        return inDir.isNotEmpty ? '$pattern in $inDir' : pattern;
      }
      if (dirPath != null && dirPath.toString().trim().isNotEmpty) {
        final formattedDir = formatDisplayPath(dirPath.toString());
        if (formattedDir.isNotEmpty) return formattedDir;
      }

      final url = (p['Url'] ?? p['url'])?.toString().trim() ?? '';
      if (url.isNotEmpty) return url;

      final role = (p['Role'] ?? p['role'])?.toString().trim() ?? '';
      final typeName = (p['TypeName'] ?? p['typeName'])?.toString().trim() ?? '';
      if (role.isNotEmpty && typeName.isNotEmpty) {
        return '$role ($typeName)';
      }
      if (role.isNotEmpty) return role;
      if (typeName.isNotEmpty) return typeName;

      final subagentMeta = p['Name'] ??
          p['name'] ??
          p['Description'] ??
          p['description'] ??
          p['Action'] ??
          p['action'] ??
          p['Recipient'] ??
          p['recipient'] ??
          p['CommandId'];
      if (subagentMeta != null && subagentMeta.toString().trim().isNotEmpty) {
        return subagentMeta.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
      }
    }

    // Fallback when ACP puts `file ../../../../../../...` directly into toolName.
    final titleMatch = RegExp(
      r'^(?:file|read|view|edit|write|analy[sz]e)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(step.toolName.trim());
    if (titleMatch != null) {
      final candidate = formatDisplayPath(titleMatch.group(1)!);
      if (candidate.isNotEmpty) return candidate;
    }
    return '';
  }

  static List<ActiveSubagent> applySubagentToolEvent(
    List<ActiveSubagent> current, {
    required String callId,
    required String toolName,
    required ToolCallState state,
    required Map<String, dynamic> parameters,
    String? output,
    String? errorMessage,
    DateTime? now,
  }) {
    final ts = now ?? DateTime.now();
    final lower = toolName.toLowerCase();

    if (lower.contains('manage_subagents') ||
        lower.contains('manage subagents')) {
      final action =
          (parameters['Action'] ?? parameters['action'])?.toString().trim();
      if (action == 'kill_all') {
        return const [];
      }
      if (action == 'kill') {
        final rawIds =
            parameters['ConversationIds'] ?? parameters['conversationIds'];
        if (rawIds is List) {
          final killSet = rawIds.map((e) => e.toString()).toSet();
          return current
              .where(
                (s) =>
                    !killSet.contains(s.id) &&
                    (s.conversationId == null ||
                        !killSet.contains(s.conversationId)),
              )
              .toList();
        }
      }
      if (action == 'list' &&
          state == ToolCallState.completed &&
          output != null) {
        final trimmed = output.trim().toLowerCase();
        if (trimmed == '[]' ||
            trimmed.contains('no active') ||
            trimmed.contains('0 active')) {
          return current
              .map(
                (s) => s.isActive
                    ? s.copyWith(status: SubagentStatus.completed)
                    : s,
              )
              .toList();
        }
      }
      return current;
    }

    if (!isSubagentSpawnTool(toolName)) {
      return current;
    }

    final isFailed = state == ToolCallState.failed ||
        (errorMessage != null && errorMessage.trim().isNotEmpty);
    final role = extractSubagentRole(toolName, parameters);
    final typeName =
        (parameters['TypeName'] ?? parameters['typeName'])?.toString().trim() ??
            (lower.contains('workflow') ? 'workflow' : '');
    final model =
        (parameters['Model'] ?? parameters['model'])?.toString().trim() ?? '';
    final convId = extractConversationId(output);

    final nextStatus = isFailed
        ? SubagentStatus.failed
        : (state == ToolCallState.running || state == ToolCallState.pending)
            ? SubagentStatus.spawning
            : SubagentStatus.running;

    final idx = current.indexWhere(
      (s) =>
          s.id == callId ||
          (convId != null && s.conversationId == convId),
    );
    final next = [...current];
    if (idx >= 0) {
      final prev = next[idx];
      next[idx] = prev.copyWith(
        role: role != 'Subagent' ? role : prev.role,
        typeName: typeName.isNotEmpty ? typeName : prev.typeName,
        model: model.isNotEmpty ? model : prev.model,
        status: nextStatus,
        conversationId: convId ?? prev.conversationId,
      );
    } else {
      next.add(
        ActiveSubagent(
          id: callId,
          role: role,
          typeName: typeName,
          model: model,
          status: nextStatus,
          startedAt: ts,
          conversationId: convId,
        ),
      );
    }
    return next;
  }

  /// Resolves the target index inside [userIndices] when navigating Previous
  /// (`delta < 0`) or Next (`delta > 0`). Uses the current viewport's top
  /// visible message when no sequential cursor is active so navigation never
  /// jumps in the wrong direction after manual scrolling.
  static int? resolveTurnNavigationTarget({
    required List<int> userIndices,
    required int delta,
    int? currentCursor,
    int? firstVisibleMessageIndex,
    double? firstVisibleMessageTop,
    bool isAtBottom = false,
  }) {
    if (userIndices.isEmpty || delta == 0) return null;
    if (currentCursor != null) {
      return (currentCursor + delta).clamp(0, userIndices.length - 1);
    }
    if (delta > 0 && isAtBottom) {
      return null;
    }
    if (firstVisibleMessageIndex == null) {
      return delta < 0 ? userIndices.length - 1 : 0;
    }
    var k = -1;
    for (var i = 0; i < userIndices.length; i++) {
      if (userIndices[i] <= firstVisibleMessageIndex) {
        k = i;
      } else {
        break;
      }
    }
    if (delta < 0) {
      if (k < 0) return 0;
      final scrolledPastTurnTop = userIndices[k] < firstVisibleMessageIndex ||
          (firstVisibleMessageTop != null && firstVisibleMessageTop < -12.0);
      if (scrolledPastTurnTop) return k;
      return (k - 1).clamp(0, userIndices.length - 1);
    }
    if (isAtBottom) {
      return userIndices.length - 1;
    }
    return (k + 1).clamp(0, userIndices.length - 1);
  }
}
