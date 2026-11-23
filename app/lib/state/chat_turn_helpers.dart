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
}
