import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../theme/app_theme.dart';
import '../shell/background_tasks_sheet.dart';
import 'secret_mask.dart';

/// Compact live status card displayed above the chat composer while subagents
/// are being spawned or working asynchronously in the background.
class SubagentsActivityBanner extends ConsumerStatefulWidget {
  const SubagentsActivityBanner({super.key});

  @override
  ConsumerState<SubagentsActivityBanner> createState() =>
      _SubagentsActivityBannerState();
}

class _SubagentsActivityBannerState
    extends ConsumerState<SubagentsActivityBanner> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  void _syncTicker(bool hasActive) {
    if (hasActive && _ticker == null) {
      _now = DateTime.now();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
    } else if (!hasActive && _ticker != null) {
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
    final subagents = ref.watch(chatProvider.select((c) => c.activeSubagents));
    final activeCount = subagents.where((s) => s.isActive).length;
    final spawningCount =
        subagents.where((s) => s.status == SubagentStatus.spawning).length;
    _syncTicker(activeCount > 0);
    if (subagents.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final oldestStart = subagents
        .map((s) => s.startedAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final elapsed = formatElapsed(oldestStart, _now);

    final headerText = activeCount > 0
        ? (spawningCount == activeCount
            ? 'Spawning $activeCount subagent${activeCount == 1 ? '' : 's'}… · $elapsed'
            : '$activeCount subagent${activeCount == 1 ? '' : 's'} working · $elapsed')
        : '${subagents.length} subagent${subagents.length == 1 ? '' : 's'} finished';

    return Container(
      key: const ValueKey('subagents-activity-banner'),
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: activeCount > 0
            ? theme.colorScheme.primaryContainer.withOpacity(0.42)
            : theme.colorScheme.surfaceContainerHigh.withOpacity(0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: (activeCount > 0
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant)
              .withOpacity(0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (activeCount > 0)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                )
              else
                Icon(
                  Icons.check_circle_outline,
                  size: 15,
                  color: semantic.success,
                ),
              const SizedBox(width: 8),
              Icon(
                Icons.smart_toy_outlined,
                size: 15,
                color: activeCount > 0
                    ? theme.colorScheme.primary
                    : semantic.textSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  headerText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: semantic.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (activeCount > 0)
                IconButton(
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Stop subagents',
                  onPressed: () =>
                      ref.read(chatProvider.notifier).forceStopAllTasks(),
                  icon: Icon(
                    Icons.stop_circle_outlined,
                    color: theme.colorScheme.error,
                  ),
                ),
              IconButton(
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: 'Dismiss',
                onPressed: () =>
                    ref.read(chatProvider.notifier).dismissSubagents(),
                icon: Icon(
                  Icons.close,
                  color: semantic.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: subagents
                .map((sub) => _SubagentChip(subagent: sub, now: _now))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _SubagentChip extends StatelessWidget {
  const _SubagentChip({required this.subagent, required this.now});

  final ActiveSubagent subagent;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final isFailed = subagent.status == SubagentStatus.failed;
    final isDone = subagent.status == SubagentStatus.completed;
    final isSpawning = subagent.status == SubagentStatus.spawning;
    final tint = isFailed
        ? semantic.danger
        : isDone
            ? semantic.success
            : theme.colorScheme.primary;
    final statusWord = isFailed
        ? 'failed'
        : isDone
            ? 'done'
            : isSpawning
                ? 'spawning'
                : formatElapsed(subagent.startedAt, now);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.75),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tint.withOpacity(0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (subagent.isActive)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: tint),
            )
          else
            Icon(
              isFailed ? Icons.error_outline : Icons.check,
              size: 12,
              color: tint,
            ),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              AgySecretMask.mask(subagent.role),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: semantic.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            statusWord,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
