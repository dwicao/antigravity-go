import 'package:agy_client/agy_client.dart';

import 'chat_models.dart';

/// Pure message/diff/tool aggregation helpers extracted from `ChatNotifier`.
class ChatTurnHelpers {
  ChatTurnHelpers._();

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
    return prev.copyWith(
      contextTokens:
          stepUsage.contextTokens > 0 ? stepUsage.contextTokens : prev.contextTokens,
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

  static String? buildToolDiff(
    String path,
    String? oldText,
    String? newText,
  ) {
    final oldLines = oldText == null || oldText.isEmpty
        ? const <String>[]
        : oldText.split('\n');
    final newLines = newText == null || newText.isEmpty
        ? const <String>[]
        : newText.split('\n');
    if (oldLines.isEmpty && newLines.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('--- a/$path')
      ..writeln('+++ b/$path')
      ..writeln('@@ -1,${oldLines.length} +1,${newLines.length} @@');
    for (final line in oldLines.take(80)) {
      buf.writeln('-$line');
    }
    if (oldLines.length > 80) {
      buf.writeln('-... (${oldLines.length - 80} more)');
    }
    for (final line in newLines.take(80)) {
      buf.writeln('+$line');
    }
    if (newLines.length > 80) {
      buf.writeln('+... (${newLines.length - 80} more)');
    }
    return buf.toString();
  }

  static List<FileChangeEntry> extractChangedFilesFromTools(
    List<ChatToolStep> tools,
  ) {
    final byPath = <String, FileChangeEntry>{};
    for (final step in tools) {
      if (step.state == ToolCallState.failed) continue;
      final nameLower = step.toolName.toLowerCase();
      final isFileEdit = nameLower.contains('write') ||
          nameLower.contains('edit') ||
          nameLower.contains('replace') ||
          nameLower.contains('patch') ||
          nameLower.contains('create_file');
      if (!isFileEdit) continue;
      final rawPath = step.parameters['TargetFile'] ??
          step.parameters['AbsolutePath'] ??
          step.parameters['path'] ??
          step.parameters['file'];
      final path = rawPath?.toString().trim() ?? '';
      if (path.isEmpty) continue;

      final replacement = step.parameters['Replacement'] ??
          step.parameters['ReplacementContent'] ??
          step.parameters['CodeContent'] ??
          step.parameters['content'];
      final target = step.parameters['TargetContent'];
      final repStr = replacement?.toString();
      final tgtStr = target?.toString();
      final added = repStr != null ? repStr.split('\n').length : 0;
      final removed = tgtStr != null ? tgtStr.split('\n').length : 0;
      final created = (step.parameters['Overwrite'] == false) ||
          nameLower.contains('create') ||
          (nameLower.contains('write_to_file') && removed == 0);
      final prev = byPath[path];
      final diffSnippet = buildToolDiff(path, tgtStr, repStr) ?? prev?.diff;
      byPath[path] = FileChangeEntry(
        path: path,
        added: (prev?.added ?? 0) + added,
        removed: (prev?.removed ?? 0) + removed,
        created: prev?.created ?? created,
        diff: diffSnippet,
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

  static String formatToolTarget(ChatToolStep step) {
    if (step.parameters.isEmpty) return '';
    final p = step.parameters;
    final direct = p['CommandLine'] ??
        p['command'] ??
        p['TargetFile'] ??
        p['AbsolutePath'] ??
        p['Path'] ??
        p['path'] ??
        p['Query'];
    if (direct != null && direct.toString().trim().isNotEmpty) {
      return direct.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
    }
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
        p['recipient'];
    if (subagentMeta != null && subagentMeta.toString().trim().isNotEmpty) {
      return subagentMeta.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
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
}
