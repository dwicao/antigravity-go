import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

/// Compact card modeled on `dsh-Go`'s `ChangeCard` showing files changed during
/// a turn or after a Git commit/push, with `+N -M` counts and a tap-to-inspect sheet.
class ChangeCard extends StatelessWidget {
  const ChangeCard({
    super.key,
    required this.files,
    this.title,
    this.onOpenDiff,
  });

  final List<FileChangeEntry> files;
  final String? title;
  final VoidCallback? onOpenDiff;

  static const int shownCount = 4;

  @override
  Widget build(BuildContext context) {
    if (files.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final totalAdded = files.fold<int>(0, (sum, f) => sum + f.added);
    final totalRemoved = files.fold<int>(0, (sum, f) => sum + f.removed);
    final shown =
        files.length <= shownCount ? files : files.sublist(0, shownCount);
    final hiddenCount = files.length - shown.length;

    return Card(
      margin: const EdgeInsets.only(top: 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.difference_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title ??
                          '${files.length} file${files.length == 1 ? '' : 's'} changed',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (totalAdded > 0 || totalRemoved > 0)
                    DiffCountsBadge(added: totalAdded, removed: totalRemoved),
                ],
              ),
            ),
            const Divider(height: 10),
            for (final file in shown)
              InkWell(
                onTap: () => _openFileSheet(context, file),
                onLongPress: () {
                  Clipboard.setData(ClipboardData(text: file.path));
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    SnackBar(content: Text('Copied ${file.path}')),
                  );
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        file.deleted
                            ? Icons.delete_outline
                            : file.created
                                ? Icons.note_add_outlined
                                : Icons.description_outlined,
                        size: 16,
                        color: file.deleted
                            ? theme.colorScheme.error
                            : file.created
                                ? Colors.green
                                : semantic.textSecondary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: file.fileName,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (file.directory.isNotEmpty)
                                TextSpan(
                                  text: '  ${file.directory}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: semantic.textTertiary,
                                  ),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (file.created && file.added == 0 && file.removed == 0)
                        Text(
                          'new',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (file.added > 0 || file.removed > 0)
                        DiffCountsBadge(
                          added: file.added,
                          removed: file.removed,
                        ),
                    ],
                  ),
                ),
              ),
            if (hiddenCount > 0 || onOpenDiff != null) ...[
              const Divider(height: 8),
              InkWell(
                onTap: onOpenDiff ?? () => _openAllFilesSheet(context),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      Text(
                        onOpenDiff != null
                            ? 'Inspect full diff'
                            : 'View all ${files.length} changed files',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (hiddenCount > 0)
                        Text(
                          '+$hiddenCount more',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: semantic.textTertiary,
                          ),
                        ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: semantic.textTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _openFileSheet(BuildContext context, FileChangeEntry file) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      file.path,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (file.added > 0 || file.removed > 0)
                    DiffCountsBadge(added: file.added, removed: file.removed),
                ],
              ),
              const SizedBox(height: 10),
              if (file.diff != null && file.diff!.trim().isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      file.diff!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              else
                Text(
                  file.deleted
                      ? 'Deleted file (+${file.added} -${file.removed})'
                      : file.created
                          ? 'Created file (+${file.added} lines)'
                          : 'Modified (+${file.added} -${file.removed})',
                ),
              if (onOpenDiff != null) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    onOpenDiff!();
                  },
                  icon: const Icon(Icons.difference_outlined, size: 18),
                  label: const Text('Open Git Review'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openAllFilesSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
          children: [
            Text(
              'Changed Files (${files.length})',
              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            for (final f in files)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(f.fileName),
                subtitle: f.directory.isEmpty ? null : Text(f.directory),
                trailing: DiffCountsBadge(added: f.added, removed: f.removed),
              ),
          ],
        ),
      ),
    );
  }
}

class DiffCountsBadge extends StatelessWidget {
  const DiffCountsBadge({
    super.key,
    required this.added,
    required this.removed,
  });

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFamily: 'monospace',
          fontWeight: FontWeight.w700,
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (added > 0)
          Text('+$added', style: style?.copyWith(color: Colors.green)),
        if (added > 0 && removed > 0) const SizedBox(width: 4),
        if (removed > 0)
          Text(
            '−$removed',
            style: style?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
