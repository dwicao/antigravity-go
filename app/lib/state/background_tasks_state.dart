import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_state.dart';
import 'runtime_state.dart';
import 'sessions_state.dart';

enum BackgroundTaskKind {
  terminal,
  subagent,
  tool,
  session,
  queued,
}

class BackgroundTaskItem {
  const BackgroundTaskItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.startedAt,
    this.sessionId,
    this.nativeTaskId,
    this.queuedIndex,
    this.canCancel = false,
  });

  final String id;
  final BackgroundTaskKind kind;
  final String title;
  final String subtitle;
  final DateTime startedAt;
  final String? sessionId;
  final String? nativeTaskId;
  final int? queuedIndex;
  final bool canCancel;
}

bool _isSubagentTool(String toolName) {
  final lower = toolName.toLowerCase();
  return lower.contains('subagent') ||
      lower.contains('workflow') ||
      lower.contains('schedule');
}

String _summarizeTitle(String raw, {int maxLen = 56}) {
  final single = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (single.isEmpty) return 'Background task';
  if (single.length <= maxLen) return single;
  return '${single.substring(0, maxLen - 1)}…';
}

/// Aggregates all active background work visible across the app:
/// 1. Native background terminal processes (`terminal/create`)
/// 2. Background agent sessions running while viewing another session
/// 3. Active subagent / workflow / scheduled / command tool steps
/// 4. Queued follow-up prompts waiting for the active turn
final backgroundTasksProvider = Provider<List<BackgroundTaskItem>>((ref) {
  final runtime = ref.watch(runtimeProvider);
  final chat = ref.watch(chatProvider);
  final sessions = ref.watch(sessionsProvider);

  final items = <BackgroundTaskItem>[];
  final seenNativeIds = <String>{};
  final nativeTerminalTitles = <String>{};

  // 1. Native background shell processes (from AcpSessionManager terminal/create).
  for (final t in runtime.backgroundTasks) {
    if (t.kind == 'terminal') {
      seenNativeIds.add(t.id);
      nativeTerminalTitles.add(t.title.toLowerCase());
      items.add(
        BackgroundTaskItem(
          id: 'native:${t.id}',
          kind: BackgroundTaskKind.terminal,
          title: _summarizeTitle(t.title),
          subtitle: 'Background shell process',
          startedAt: t.startedAt,
          nativeTaskId: t.id,
          canCancel: true,
        ),
      );
    }
  }

  // 2. Active turns in sessions other than the currently visible session.
  final activeSessionId = sessions.activeSessionId;
  for (final sid in chat.activeBackgroundSessionIds) {
    if (sid == activeSessionId) continue;
    AgySessionSummary? match;
    for (final s in sessions.sessions) {
      if (s.id == sid) {
        match = s;
        break;
      }
    }
    final label = match?.title ?? 'Background conversation';
    items.add(
      BackgroundTaskItem(
        id: 'session:$sid',
        kind: BackgroundTaskKind.session,
        title: _summarizeTitle(label),
        subtitle: 'Agent running in another session',
        startedAt: match?.updatedAt ?? DateTime.now(),
        sessionId: sid,
        canCancel: false,
      ),
    );
  }

  // 3. Running tool steps in the active thread (subagents, workflows, commands, etc.).
  for (final m in chat.messages) {
    if (!m.isStreaming && m.tools.every((t) => t.state != ToolCallState.running)) {
      continue;
    }
    for (final tool in m.tools) {
      if (tool.state != ToolCallState.running) continue;
      final summary = _summarizeTitle(tool.toolName);
      // Avoid duplicating if the exact same shell command is already tracked via terminal/create.
      if (nativeTerminalTitles.any((nt) =>
          nt == summary.toLowerCase() || summary.toLowerCase().contains(nt))) {
        continue;
      }
      final isSubagent = _isSubagentTool(tool.toolName);
      items.add(
        BackgroundTaskItem(
          id: 'tool:${tool.id}',
          kind: isSubagent
              ? BackgroundTaskKind.subagent
              : BackgroundTaskKind.tool,
          title: summary,
          subtitle: isSubagent ? 'Subagent / workflow running' : 'Tool step running',
          startedAt: tool.startedAt ?? m.createdAt,
          sessionId: activeSessionId,
          canCancel: false,
        ),
      );
    }
  }

  // 4. Queued follow-up prompts waiting in background queue.
  for (var i = 0; i < chat.queuedPrompts.length; i++) {
    items.add(
      BackgroundTaskItem(
        id: 'queued:$i',
        kind: BackgroundTaskKind.queued,
        title: _summarizeTitle(chat.queuedPrompts[i]),
        subtitle: 'Queued prompt #${i + 1}',
        startedAt: DateTime.now(),
        queuedIndex: i,
        canCancel: true,
      ),
    );
  }

  // 5. Fallback: if a native turn is running for an untracked session, surface it.
  if (chat.activeBackgroundSessionIds.isEmpty && !chat.isStreaming) {
    for (final t in runtime.backgroundTasks) {
      if (t.kind == 'turn' && !seenNativeIds.contains(t.id)) {
        items.add(
          BackgroundTaskItem(
            id: 'native:${t.id}',
            kind: BackgroundTaskKind.session,
            title: _summarizeTitle(t.title),
            subtitle: 'Active background turn',
            startedAt: t.startedAt,
            nativeTaskId: t.id,
            canCancel: true,
          ),
        );
      }
    }
  }

  return items;
});
