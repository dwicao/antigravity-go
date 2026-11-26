import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/background_tasks_state.dart';
import '../../state/chat_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../theme/app_theme.dart';
import '../chat/secret_mask.dart';

String formatElapsed(DateTime startedAt, DateTime now) {
  final secs = now.difference(startedAt).inSeconds.clamp(0, 86400 * 7);
  if (secs < 60) return '${secs}s';
  final mins = secs ~/ 60;
  final rem = secs % 60;
  if (mins < 60) return '${mins}m ${rem}s';
  final hrs = mins ~/ 60;
  return '${hrs}h ${mins % 60}m';
}

IconData iconForBackgroundTask(BackgroundTaskKind kind) {
  return switch (kind) {
    BackgroundTaskKind.terminal => Icons.terminal,
    BackgroundTaskKind.subagent => Icons.smart_toy_outlined,
    BackgroundTaskKind.tool => Icons.build_circle_outlined,
    BackgroundTaskKind.session => Icons.forum_outlined,
    BackgroundTaskKind.queued => Icons.schedule_send_outlined,
    BackgroundTaskKind.ci => Icons.rocket_launch_outlined,
  };
}

/// AppBar pill that lights up whenever background processes, subagents,
/// background sessions, running tools, or queued prompts are active.
class BackgroundTasksAppBarPill extends ConsumerWidget {
  const BackgroundTasksAppBarPill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(backgroundTasksProvider);
    if (tasks.isEmpty) return const SizedBox.shrink();

    final hasRunningWork =
        tasks.any((t) => t.kind != BackgroundTaskKind.queued);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Tooltip(
        message: '${tasks.length} background task${tasks.length == 1 ? '' : 's'} running',
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => BackgroundTasksSheet.show(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.85),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.35),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasRunningWork)
                  RepaintBoundary(
                    child: SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  )
                else
                  Icon(
                    Icons.schedule_send_outlined,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
                const SizedBox(width: 6),
                Text(
                  '${tasks.length} bg',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim live banner above the chat composer so active background tasks
/// are immediately visible even without opening any panel.
class BackgroundTasksBanner extends ConsumerStatefulWidget {
  const BackgroundTasksBanner({super.key});

  @override
  ConsumerState<BackgroundTasksBanner> createState() =>
      _BackgroundTasksBannerState();
}

class _BackgroundTasksBannerState extends ConsumerState<BackgroundTasksBanner> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  void _syncTicker(bool active) {
    if (active && _ticker == null) {
      _now = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    } else if (!active && _ticker != null) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allTasks = ref.watch(backgroundTasksProvider);
    // Queued prompts already have their own dedicated banner below; show other background tasks here.
    final tasks = allTasks
        .where((t) => t.kind != BackgroundTaskKind.queued)
        .toList();
    _syncTicker(tasks.isNotEmpty);
    if (tasks.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final primary = tasks.first;
    final elapsed = formatElapsed(primary.startedAt, _now);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withOpacity(0.28),
        ),
      ),
      child: InkWell(
        onTap: () => BackgroundTasksSheet.show(context),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                tasks.length == 1
                    ? 'Background: ${AgySecretMask.mask(primary.title)} · $elapsed'
                    : '${tasks.length} background tasks · ${AgySecretMask.mask(primary.title)} · $elapsed',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: semantic.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: 'Force stop all background tasks',
              onPressed: () =>
                  ref.read(chatProvider.notifier).forceStopAllTasks(),
              icon: Icon(
                Icons.stop_circle_outlined,
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'View',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal bottom sheet listing every active background task with elapsed timers and cancel/open actions.
class BackgroundTasksSheet extends ConsumerStatefulWidget {
  const BackgroundTasksSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => const BackgroundTasksSheet(),
    );
  }

  @override
  ConsumerState<BackgroundTasksSheet> createState() =>
      _BackgroundTasksSheetState();
}

class _BackgroundTasksSheetState extends ConsumerState<BackgroundTasksSheet> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    Future.microtask(() {
      if (mounted) ref.read(runtimeProvider.notifier).refresh();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = ref.watch(backgroundTasksProvider);
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.layers_outlined,
                    size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Background Tasks (${tasks.length})',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (tasks.isNotEmpty)
                  TextButton.icon(
                    onPressed: () =>
                        ref.read(chatProvider.notifier).forceStopAllTasks(),
                    icon: Icon(
                      Icons.stop_circle_outlined,
                      size: 16,
                      color: theme.colorScheme.error,
                    ),
                    label: Text(
                      'Force Stop All',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                IconButton(
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () =>
                      ref.read(runtimeProvider.notifier).refresh(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'No background tasks currently running.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: semantic.textSecondary,
                    ),
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: tasks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    final elapsed = task.kind == BackgroundTaskKind.queued
                        ? 'queued'
                        : formatElapsed(task.startedAt, _now);
                    return Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          iconForBackgroundTask(task.kind),
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        title: Text(
                          AgySecretMask.mask(task.title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Text(
                          '${task.subtitle} · $elapsed',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: semantic.textSecondary,
                          ),
                        ),
                        trailing: _buildTrailing(context, ref, task),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget? _buildTrailing(
    BuildContext context,
    WidgetRef ref,
    BackgroundTaskItem task,
  ) {
    final forceStopBtn = IconButton(
      tooltip: 'Force stop task',
      icon: Icon(
        Icons.stop_circle_outlined,
        size: 20,
        color: Theme.of(context).colorScheme.error,
      ),
      onPressed: () => ref.read(chatProvider.notifier).forceStopTask(
            kindName: task.kind.name,
            nativeTaskId: task.nativeTaskId,
            sessionId: task.sessionId,
            queuedIndex: task.queuedIndex,
          ),
    );
    if (task.kind == BackgroundTaskKind.session && task.sessionId != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () {
              ref.read(sessionsProvider.notifier).selectSession(task.sessionId!);
              Navigator.of(context).pop();
            },
            child: const Text('Open'),
          ),
          forceStopBtn,
        ],
      );
    }
    if (task.kind == BackgroundTaskKind.queued && task.queuedIndex != null) {
      return IconButton(
        tooltip: 'Remove queued prompt',
        icon: const Icon(Icons.close, size: 18),
        onPressed: () => ref
            .read(chatProvider.notifier)
            .removeQueuedPrompt(task.queuedIndex!),
      );
    }
    if (task.canCancel) {
      return forceStopBtn;
    }
    return null;
  }
}
