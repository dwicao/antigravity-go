import 'dart:math' as math;

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/workspace_diff_state.dart';
import '../../theme/app_theme.dart';
import '../workspace/diff_review_view.dart';
import 'change_card.dart' show DiffCountsBadge;

/// Milestone-style collapsible mini-view anchored at the bottom of chat showing
/// modified files and `+added / -removed` line counts. Tapping the header or
/// any file opens the dedicated standalone [DiffReviewPage].
class WorkspaceChangesBanner extends ConsumerStatefulWidget {
  const WorkspaceChangesBanner({super.key});

  @override
  ConsumerState<WorkspaceChangesBanner> createState() =>
      _WorkspaceChangesBannerState();
}

class _WorkspaceChangesBannerState
    extends ConsumerState<WorkspaceChangesBanner> {
  bool _expanded = true;

  void _openDiffPage(BuildContext context, {String? focusPath}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiffReviewPage(initialFocusPath: focusPath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(workspaceDiffProvider.select((s) => s.files));
    if (files.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    var totalAdded = 0;
    var totalRemoved = 0;
    for (final f in files) {
      totalAdded += f.added;
      totalRemoved += f.removed;
    }

    return RepaintBoundary(
      child: Container(
        key: const ValueKey('workspace-changes-banner'),
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.45),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => _openDiffPage(context),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.difference_outlined,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${files.length} file${files.length == 1 ? '' : 's'} changed',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (totalAdded > 0 || totalRemoved > 0) ...[
                          const SizedBox(width: 8),
                          DiffCountsBadge(
                            added: totalAdded,
                            removed: totalRemoved,
                          ),
                        ],
                        const SizedBox(width: 6),
                        _MiniStatBar(
                          added: totalAdded,
                          removed: totalRemoved,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              InkWell(
                onTap: () => _openDiffPage(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Diff',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 13,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: _expanded ? 'Collapse changes' : 'Expand changes',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                padding: EdgeInsets.zero,
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 18,
                  color: semantic.textSecondary,
                ),
              ),
            ],
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            SizedBox(
              height: math.min(files.length * 36.0, 132.0),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: files.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  thickness: 0.5,
                  color: theme.colorScheme.outlineVariant.withOpacity(0.25),
                ),
                itemBuilder: (ctx, index) {
                  final f = files[index];
                  final (badge, badgeColor) = f.deleted
                      ? ('D', semantic.danger)
                      : f.created
                          ? ('A', semantic.success)
                          : ('M', semantic.warning);
                  return InkWell(
                    onTap: () => _openDiffPage(ctx, focusPath: f.path),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 16,
                            height: 16,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: badgeColor.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: badgeColor.withOpacity(0.5),
                              ),
                            ),
                            child: Text(
                              badge,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: badgeColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  f.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: semantic.textPrimary,
                                  ),
                                ),
                                if (f.directory.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      f.directory,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        fontSize: 10.5,
                                        color: semantic.textTertiary,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (f.added > 0 || f.removed > 0)
                            DiffCountsBadge(added: f.added, removed: f.removed)
                          else if (f.created)
                            Text(
                              'new',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: semantic.success,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          else if (f.deleted)
                            Text(
                              'del',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: semantic.danger,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right,
                            size: 15,
                            color: semantic.textTertiary,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }
}

class _MiniStatBar extends StatelessWidget {
  const _MiniStatBar({required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final blocks = DiffStatBlocks.compute(added, removed);
    Widget box(Color color) => Container(
          width: 5,
          height: 5,
          margin: const EdgeInsets.only(right: 1.5),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.addedBlocks; i++) box(semantic.success),
        for (var i = 0; i < blocks.removedBlocks; i++) box(semantic.danger),
        for (var i = 0; i < blocks.neutralBlocks; i++)
          box(Theme.of(context).colorScheme.outlineVariant.withOpacity(0.45)),
      ],
    );
  }
}
