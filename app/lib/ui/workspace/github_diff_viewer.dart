import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../chat/change_card.dart' show DiffCountsBadge;
import 'diff_syntax_highlighter.dart';

enum GitHubDiffStatusFilter {
  all('All'),
  modified('Modified'),
  added('Added'),
  deleted('Deleted');

  const GitHubDiffStatusFilter(this.label);
  final String label;
}

class _GitHubDiffFileItem {
  _GitHubDiffFileItem({
    required this.entry,
    required this.hunks,
  });

  final FileChangeEntry entry;
  final List<DiffHunk> hunks;
  final GlobalKey cardKey = GlobalKey();

  String get path => entry.path;
  bool get isAdded => entry.created;
  bool get isDeleted => entry.deleted;
  bool get isModified => !entry.created && !entry.deleted;

  int get addedCount {
    if (entry.added > 0) return entry.added;
    return hunks.fold<int>(0, (s, h) => s + h.addedLines);
  }

  int get removedCount {
    if (entry.removed > 0) return entry.removed;
    return hunks.fold<int>(0, (s, h) => s + h.removedLines);
  }
}

/// GitHub PR-style "Files changed" diff viewer with:
/// - Changed files sidebar / jump-to-file sheet & search filter
/// - 5-block GitHub diffstat bars (`+N -M`) and `M` / `A` / `D` status badges
/// - Collapsible file cards with "Viewed" review checkboxes
/// - Dual-gutter line numbers (`old | new`) and Unified / Split (side-by-side) toggle
class GitHubDiffViewer extends StatefulWidget {
  const GitHubDiffViewer({
    super.key,
    required this.files,
    this.unifiedDiff = '',
    this.branch,
    this.onRevertHunk,
    this.showSidebarOnWide = true,
    this.initialFocusPath,
  });

  final List<FileChangeEntry> files;
  final String unifiedDiff;
  final String? branch;
  final Future<void> Function(DiffHunk hunk)? onRevertHunk;
  final bool showSidebarOnWide;
  final String? initialFocusPath;

  @override
  State<GitHubDiffViewer> createState() => _GitHubDiffViewerState();
}

class _GitHubDiffViewerState extends State<GitHubDiffViewer> {
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final Set<String> _viewedFiles = <String>{};
  final Set<String> _collapsedFiles = <String>{};
  GitHubDiffStatusFilter _statusFilter = GitHubDiffStatusFilter.all;
  bool _splitMode = false;
  bool _showFileTree = true;
  String _query = '';
  late List<_GitHubDiffFileItem> _items;

  @override
  void initState() {
    super.initState();
    _items = _buildItems();
    if (widget.initialFocusPath != null && widget.initialFocusPath!.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final item in _items) {
          if (item.path == widget.initialFocusPath) {
            _scrollToFile(item);
            break;
          }
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant GitHubDiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files ||
        oldWidget.unifiedDiff != widget.unifiedDiff) {
      _items = _buildItems();
      final validPaths = _items.map((e) => e.path).toSet();
      _viewedFiles.removeWhere((p) => !validPaths.contains(p));
      _collapsedFiles.removeWhere((p) => !validPaths.contains(p));
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<_GitHubDiffFileItem> _buildItems() {
    final parsedByPath = <String, List<DiffHunk>>{};
    if (widget.unifiedDiff.trim().isNotEmpty) {
      for (final fg in DiffHunkParser.parse(widget.unifiedDiff)) {
        parsedByPath[fg.filePath] = fg.hunks;
      }
    }

    final result = <_GitHubDiffFileItem>[];
    final seen = <String>{};

    for (final entry in widget.files) {
      seen.add(entry.path);
      var hunks = parsedByPath[entry.path] ?? const <DiffHunk>[];
      if (hunks.isEmpty && entry.diff != null && entry.diff!.trim().isNotEmpty) {
        final parsed = DiffHunkParser.parse(
          entry.diff!,
          fallbackFilePath: entry.path,
        );
        if (parsed.isNotEmpty) {
          hunks = parsed.first.hunks;
        }
      }
      result.add(_GitHubDiffFileItem(entry: entry, hunks: hunks));
    }

    // Include any files found in unifiedDiff that weren't in `widget.files`.
    for (final entry in parsedByPath.entries) {
      if (seen.contains(entry.key)) continue;
      final added = entry.value.fold<int>(0, (s, h) => s + h.addedLines);
      final removed = entry.value.fold<int>(0, (s, h) => s + h.removedLines);
      final isNew = entry.value.isNotEmpty &&
          entry.value.first.oldPath == '/dev/null';
      final isDel = entry.value.isNotEmpty &&
          entry.value.first.newPath == '/dev/null';
      result.add(
        _GitHubDiffFileItem(
          entry: FileChangeEntry(
            path: entry.key,
            added: added,
            removed: removed,
            created: isNew,
            deleted: isDel,
          ),
          hunks: entry.value,
        ),
      );
    }

    return result;
  }

  List<_GitHubDiffFileItem> get _filteredItems {
    final q = _query.trim().toLowerCase();
    return _items.where((item) {
      final matchesStatus = switch (_statusFilter) {
        GitHubDiffStatusFilter.all => true,
        GitHubDiffStatusFilter.modified => item.isModified,
        GitHubDiffStatusFilter.added => item.isAdded,
        GitHubDiffStatusFilter.deleted => item.isDeleted,
      };
      if (!matchesStatus) return false;
      if (q.isNotEmpty && !item.path.toLowerCase().contains(q)) return false;
      return true;
    }).toList(growable: false);
  }

  void _scrollToFile(_GitHubDiffFileItem item) {
    setState(() {
      _collapsedFiles.remove(item.path);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = item.cardKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: 0.05,
        );
      }
    });
  }

  void _toggleViewed(String path, bool viewed) {
    setState(() {
      if (viewed) {
        _viewedFiles.add(path);
        _collapsedFiles.add(path);
      } else {
        _viewedFiles.remove(path);
        _collapsedFiles.remove(path);
      }
    });
  }

  void _showJumpToFileSheet(List<_GitHubDiffFileItem> visible) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.72,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'Changed Files (${visible.length})',
                      style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const Spacer(),
                    Text(
                      '${_viewedFiles.length}/${_items.length} viewed',
                      style: Theme.of(ctx).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: visible.length,
                  itemBuilder: (_, idx) {
                    final item = visible[idx];
                    final viewed = _viewedFiles.contains(item.path);
                    return ListTile(
                      dense: true,
                      leading: _StatusBadge(item: item),
                      title: Text(
                        item.entry.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          decoration:
                              viewed ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      subtitle: item.entry.directory.isEmpty
                          ? null
                          : Text(
                              item.entry.directory,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DiffCountsBadge(
                            added: item.addedCount,
                            removed: item.removedCount,
                          ),
                          if (viewed) ...[
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Colors.green,
                            ),
                          ],
                        ],
                      ),
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _scrollToFile(item);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final filtered = _filteredItems;
    final totalAdded = _items.fold<int>(0, (s, e) => s + e.addedCount);
    final totalRemoved = _items.fold<int>(0, (s, e) => s + e.removedCount);
    final allCollapsed = filtered.isNotEmpty &&
        filtered.every((i) => _collapsedFiles.contains(i.path));
    final viewedRatio =
        _items.isEmpty ? 0.0 : (_viewedFiles.length / _items.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide =
            widget.showSidebarOnWide && constraints.maxWidth >= 720;

        final mainColumn = Column(
          children: [
            // Summary & PR-style toolbar
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (isWide)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: _showFileTree
                              ? 'Hide file tree'
                              : 'Show file tree',
                          onPressed: () =>
                              setState(() => _showFileTree = !_showFileTree),
                          icon: Icon(
                            Icons.account_tree_outlined,
                            size: 16,
                            color: _showFileTree
                                ? theme.colorScheme.primary
                                : null,
                          ),
                        ),
                      if (!isWide)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                          ),
                          onPressed: _items.isEmpty
                              ? null
                              : () => _showJumpToFileSheet(filtered),
                          icon: const Icon(Icons.folder_open_outlined, size: 15),
                          label: Text(
                            '${_items.length} file${_items.length == 1 ? '' : 's'}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        )
                      else
                        Text(
                          '${_items.length} file${_items.length == 1 ? '' : 's'} changed',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (widget.branch != null && widget.branch!.isNotEmpty)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          avatar: const Icon(Icons.call_split_rounded, size: 13),
                          label: Text(
                            widget.branch!,
                            style: const TextStyle(fontSize: 10.5),
                          ),
                        ),
                      if (totalAdded > 0 || totalRemoved > 0)
                        DiffCountsBadge(
                          added: totalAdded,
                          removed: totalRemoved,
                        ),
                      _GitHubDiffStatBar(
                        added: totalAdded,
                        removed: totalRemoved,
                      ),
                      SegmentedButton<bool>(
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Unified', style: TextStyle(fontSize: 11)),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('Split', style: TextStyle(fontSize: 11)),
                          ),
                        ],
                        selected: {_splitMode},
                        onSelectionChanged: (s) =>
                            setState(() => _splitMode = s.first),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                        tooltip: allCollapsed ? 'Expand all' : 'Collapse all',
                        onPressed: filtered.isEmpty
                            ? null
                            : () {
                                setState(() {
                                  if (allCollapsed) {
                                    _collapsedFiles.clear();
                                  } else {
                                    _collapsedFiles.addAll(
                                      filtered.map((e) => e.path),
                                    );
                                  }
                                });
                              },
                        icon: Icon(
                          allCollapsed
                              ? Icons.unfold_more_rounded
                              : Icons.unfold_less_rounded,
                          size: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 32,
                          child: TextField(
                            controller: _searchCtrl,
                            style: const TextStyle(fontSize: 12),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Filter changed files…',
                              prefixIcon: const Icon(Icons.search, size: 15),
                              suffixIcon: _query.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.close, size: 14),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        setState(() => _query = '');
                                      },
                                    )
                                  : null,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onChanged: (v) => setState(() => _query = v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${_viewedFiles.length}/${_items.length} viewed',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: semantic.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final f in GitHubDiffStatusFilter.values) ...[
                                ChoiceChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    f.label,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  selected: _statusFilter == f,
                                  onSelected: (_) =>
                                      setState(() => _statusFilter = f),
                                ),
                                const SizedBox(width: 6),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_items.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: viewedRatio,
                        minHeight: 3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _items.isEmpty
                              ? 'No file changes to display.'
                              : 'No files match the active filter.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: semantic.textSecondary,
                          ),
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollCtrl,
                      child: filtered.length <= 40
                          ? SingleChildScrollView(
                              controller: _scrollCtrl,
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final item in filtered)
                                    _GitHubDiffFileCard(
                                      key: item.cardKey,
                                      item: item,
                                      collapsed:
                                          _collapsedFiles.contains(item.path),
                                      viewed:
                                          _viewedFiles.contains(item.path),
                                      focused: widget.initialFocusPath ==
                                          item.path,
                                      splitMode: _splitMode,
                                      onToggleCollapsed: () {
                                        setState(() {
                                          if (_collapsedFiles
                                              .contains(item.path)) {
                                            _collapsedFiles.remove(item.path);
                                          } else {
                                            _collapsedFiles.add(item.path);
                                          }
                                        });
                                      },
                                      onToggleViewed: (v) =>
                                          _toggleViewed(item.path, v),
                                      onRevertHunk: widget.onRevertHunk,
                                    ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              controller: _scrollCtrl,
                              padding: const EdgeInsets.all(10),
                              itemCount: filtered.length,
                              itemBuilder: (ctx, idx) {
                                final item = filtered[idx];
                                final collapsed =
                                    _collapsedFiles.contains(item.path);
                                final viewed = _viewedFiles.contains(item.path);
                                return _GitHubDiffFileCard(
                                  key: item.cardKey,
                                  item: item,
                                  collapsed: collapsed,
                                  viewed: viewed,
                                  focused:
                                      widget.initialFocusPath == item.path,
                                  splitMode: _splitMode,
                                  onToggleCollapsed: () {
                                    setState(() {
                                      if (collapsed) {
                                        _collapsedFiles.remove(item.path);
                                      } else {
                                        _collapsedFiles.add(item.path);
                                      }
                                    });
                                  },
                                  onToggleViewed: (v) =>
                                      _toggleViewed(item.path, v),
                                  onRevertHunk: widget.onRevertHunk,
                                );
                              },
                            ),
                    ),
            ),
          ],
        );

        if (!isWide || !_showFileTree) return mainColumn;

        return Row(
          children: [
            SizedBox(
              width: 235,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerLowest,
                  border: Border(
                    right: BorderSide(
                      color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      child: Text(
                        'Files (${filtered.length})',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, idx) {
                          final item = filtered[idx];
                          final viewed = _viewedFiles.contains(item.path);
                          return InkWell(
                            onTap: () => _scrollToFile(item),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              child: Row(
                                children: [
                                  _StatusBadge(item: item),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.entry.fileName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            decoration: viewed
                                                ? TextDecoration.lineThrough
                                                : null,
                                          ),
                                        ),
                                        if (item.entry.directory.isNotEmpty)
                                          Text(
                                            item.entry.directory,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: semantic.textTertiary,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  DiffCountsBadge(
                                    added: item.addedCount,
                                    removed: item.removedCount,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: mainColumn),
          ],
        );
      },
    );
  }
}

/// Dedicated full-screen GitHub Diff Viewer page launchable from chat `ChangeCard`
/// or anywhere else in the app.
class GitHubDiffPage extends StatelessWidget {
  const GitHubDiffPage({
    super.key,
    required this.files,
    this.unifiedDiff = '',
    this.title = 'Files Changed',
    this.branch,
    this.initialFocusPath,
  });

  final List<FileChangeEntry> files;
  final String unifiedDiff;
  final String title;
  final String? branch;
  final String? initialFocusPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title),
            if (branch != null && branch!.isNotEmpty)
              Text(
                branch!,
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
      body: GitHubDiffViewer(
        files: files,
        unifiedDiff: unifiedDiff,
        branch: branch,
        initialFocusPath: initialFocusPath,
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.item});

  final _GitHubDiffFileItem item;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final (letter, color) = item.isAdded
        ? ('A', semantic.success)
        : item.isDeleted
            ? ('D', semantic.danger)
            : ('M', semantic.warning);

    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withOpacity(0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.55)),
      ),
      child: Text(
        letter,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

class _GitHubDiffStatBar extends StatelessWidget {
  const _GitHubDiffStatBar({
    required this.added,
    required this.removed,
  });

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final blocks = DiffStatBlocks.compute(added, removed);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.addedBlocks; i++)
          _block(semantic.success),
        for (var i = 0; i < blocks.removedBlocks; i++)
          _block(semantic.danger),
        for (var i = 0; i < blocks.neutralBlocks; i++)
          _block(Theme.of(context).colorScheme.outlineVariant.withOpacity(0.5)),
      ],
    );
  }

  Widget _block(Color color) {
    return Container(
      width: 6,
      height: 6,
      margin: const EdgeInsets.only(right: 1.5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

class _GitHubDiffFileCard extends StatelessWidget {
  const _GitHubDiffFileCard({
    super.key,
    required this.item,
    required this.collapsed,
    required this.viewed,
    this.focused = false,
    required this.splitMode,
    required this.onToggleCollapsed,
    required this.onToggleViewed,
    this.onRevertHunk,
  });

  final _GitHubDiffFileItem item;
  final bool collapsed;
  final bool viewed;
  final bool focused;
  final bool splitMode;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<bool> onToggleViewed;
  final Future<void> Function(DiffHunk hunk)? onRevertHunk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: semantic.codeWellBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          width: focused ? 1.6 : 1,
          color: focused
              ? theme.colorScheme.primary
              : viewed
                  ? semantic.success.withOpacity(0.45)
                  : semantic.codeWellBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // GitHub-style file header bar
          InkWell(
            onTap: onToggleCollapsed,
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(10),
              bottom: Radius.circular(collapsed ? 10 : 0),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.55),
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(9),
                  bottom: Radius.circular(collapsed ? 9 : 0),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  const SizedBox(width: 4),
                  _StatusBadge(item: item),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  DiffCountsBadge(
                    added: item.addedCount,
                    removed: item.removedCount,
                  ),
                  const SizedBox(width: 6),
                  _GitHubDiffStatBar(
                    added: item.addedCount,
                    removed: item.removedCount,
                  ),
                  IconButton(
                    tooltip: 'Copy path',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: item.path));
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text('Copied ${item.path}')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                  ),
                  Tooltip(
                    message: 'Mark file as viewed',
                    child: InkWell(
                      onTap: () => onToggleViewed(!viewed),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: Checkbox(
                                value: viewed,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                                onChanged: (v) => onToggleViewed(v ?? false),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              'Viewed',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            const Divider(height: 1),
            if (item.hunks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  item.isDeleted
                      ? 'Deleted file (−${item.removedCount} lines)'
                      : item.isAdded
                          ? 'New file (+${item.addedCount} lines)'
                          : 'No textual patch hunks available.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: semantic.textSecondary,
                  ),
                ),
              )
            else if (splitMode)
              SelectionArea(
                child: _SplitHunksView(
                  filePath: item.path,
                  hunks: item.hunks,
                  onRevertHunk: onRevertHunk,
                ),
              )
            else
              SelectionArea(
                child: _UnifiedHunksView(
                  filePath: item.path,
                  hunks: item.hunks,
                  onRevertHunk: onRevertHunk,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _UnifiedHunksView extends StatelessWidget {
  const _UnifiedHunksView({
    required this.filePath,
    required this.hunks,
    this.onRevertHunk,
  });

  final String filePath;
  final List<DiffHunk> hunks;
  final Future<void> Function(DiffHunk hunk)? onRevertHunk;

  static List<({DiffLineRow row, String? counterpart})> _pairRows(
    DiffHunk hunk,
  ) {
    final rows = hunk.toNumberedRows();
    final counterparts = List<String?>.filled(rows.length, null);
    var i = 0;
    while (i < rows.length) {
      if (rows[i].kind != DiffRowKind.deletion) {
        i++;
        continue;
      }
      final delStart = i;
      while (i < rows.length && rows[i].kind == DiffRowKind.deletion) {
        i++;
      }
      final delCount = i - delStart;
      final addStart = i;
      while (i < rows.length && rows[i].kind == DiffRowKind.addition) {
        i++;
      }
      final addCount = i - addStart;
      final pairCount = delCount < addCount ? delCount : addCount;
      for (var k = 0; k < pairCount; k++) {
        counterparts[delStart + k] = rows[addStart + k].text;
        counterparts[addStart + k] = rows[delStart + k].text;
      }
    }
    return [
      for (var j = 0; j < rows.length; j++)
        (row: rows[j], counterpart: counterparts[j]),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final theme = Theme.of(context);
    final language = DiffSyntaxHighlighter.detectLanguage(filePath);

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final hunk in hunks)
                    for (final item in _pairRows(hunk))
                      if (item.row.kind == DiffRowKind.hunkHeader)
                        Container(
                          color: theme.colorScheme.primary.withOpacity(0.08),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  item.row.text,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: semantic.diffHunkFg,
                                  ),
                                ),
                              ),
                              if (onRevertHunk != null)
                                InkWell(
                                  onTap: () => onRevertHunk!(hunk),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    child: Text(
                                      'Revert hunk',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: semantic.danger,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        )
                      else
                        _UnifiedDiffCodeRow(
                          row: item.row,
                          language: language,
                          counterpartText: item.counterpart,
                        ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UnifiedDiffCodeRow extends StatelessWidget {
  const _UnifiedDiffCodeRow({
    required this.row,
    required this.language,
    this.counterpartText,
  });

  final DiffLineRow row;
  final DiffSyntaxLanguage language;
  final String? counterpartText;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final syntaxPalette = DiffSyntaxPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isAdd = row.kind == DiffRowKind.addition;
    final isDel = row.kind == DiffRowKind.deletion;
    final bg = isAdd
        ? semantic.diffAddBg
        : isDel
            ? semantic.diffDelBg
            : null;
    final fg = isAdd
        ? semantic.diffAddFg
        : isDel
            ? semantic.diffDelFg
            : semantic.textPrimary;
    final wordBg = isAdd
        ? semantic.success.withOpacity(isDark ? 0.34 : 0.28)
        : isDel
            ? semantic.danger.withOpacity(isDark ? 0.36 : 0.26)
            : null;
    final wordRange = (isAdd || isDel)
        ? DiffSyntaxHighlighter.computeIntralineRange(row.text, counterpartText)
        : null;
    final gutterAccent = isAdd
        ? semantic.success
        : isDel
            ? semantic.danger
            : Colors.transparent;
    final marker = isAdd
        ? '+'
        : isDel
            ? '-'
            : ' ';

    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          left: BorderSide(color: gutterAccent, width: 3),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 4),
          SizedBox(
            width: 34,
            child: Text(
              row.oldLineNumber?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: isDel ? semantic.diffDelFg : semantic.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            child: Text(
              row.newLineNumber?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: isAdd ? semantic.diffAddFg : semantic.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            marker,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          const SizedBox(width: 4),
          Text.rich(
            TextSpan(
              children: DiffSyntaxHighlighter.highlightLine(
                code: row.text,
                language: language,
                palette: syntaxPalette,
                wordHighlightBg: wordBg,
                wordRange: wordRange,
              ),
            ),
            softWrap: false,
          ),
          const SizedBox(width: 14),
        ],
      ),
    );
  }
}

class _SplitHunksView extends StatelessWidget {
  const _SplitHunksView({
    required this.filePath,
    required this.hunks,
    this.onRevertHunk,
  });

  final String filePath;
  final List<DiffHunk> hunks;
  final Future<void> Function(DiffHunk hunk)? onRevertHunk;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final theme = Theme.of(context);
    final language = DiffSyntaxHighlighter.detectLanguage(filePath);

    return LayoutBuilder(
      builder: (context, constraints) {
        final halfWidth =
            ((constraints.maxWidth - 2) / 2).clamp(260.0, 2000.0);
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: halfWidth * 2 + 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final hunk in hunks)
                  for (final pair in hunk.toSplitPairs())
                    if (pair.isHunkHeader)
                      Container(
                        color: theme.colorScheme.primary.withOpacity(0.08),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                pair.hunkHeaderText!,
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: semantic.diffHunkFg,
                                ),
                              ),
                            ),
                            if (onRevertHunk != null)
                              InkWell(
                                onTap: () => onRevertHunk!(hunk),
                                child: Text(
                                  'Revert hunk',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: semantic.danger,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      )
                    else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: halfWidth,
                            child: _SplitHalfCell(
                              row: pair.left,
                              isLeft: true,
                              language: language,
                              counterpartText: pair.right?.text,
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 22,
                            color: semantic.codeWellBorder,
                          ),
                          SizedBox(
                            width: halfWidth,
                            child: _SplitHalfCell(
                              row: pair.right,
                              isLeft: false,
                              language: language,
                              counterpartText: pair.left?.text,
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SplitHalfCell extends StatelessWidget {
  const _SplitHalfCell({
    required this.row,
    required this.isLeft,
    required this.language,
    this.counterpartText,
  });

  final DiffLineRow? row;
  final bool isLeft;
  final DiffSyntaxLanguage language;
  final String? counterpartText;

  @override
  Widget build(BuildContext context) {
    final semantic = AgySemanticColors.of(context);
    final syntaxPalette = DiffSyntaxPalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final r = row;
    if (r == null) {
      return Container(
        height: 22,
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withOpacity(0.25),
      );
    }
    final isDel = r.kind == DiffRowKind.deletion;
    final isAdd = r.kind == DiffRowKind.addition;
    final lineNum = isLeft ? r.oldLineNumber : r.newLineNumber;
    final bg = isDel
        ? semantic.diffDelBg
        : isAdd
            ? semantic.diffAddBg
            : null;
    final fg = isDel
        ? semantic.diffDelFg
        : isAdd
            ? semantic.diffAddFg
            : semantic.textPrimary;
    final wordBg = isDel
        ? semantic.danger.withOpacity(isDark ? 0.36 : 0.26)
        : isAdd
            ? semantic.success.withOpacity(isDark ? 0.34 : 0.28)
            : null;
    final wordRange = (isDel || isAdd)
        ? DiffSyntaxHighlighter.computeIntralineRange(r.text, counterpartText)
        : null;
    final gutterAccent = isDel
        ? semantic.danger
        : isAdd
            ? semantic.success
            : Colors.transparent;
    final marker = isDel
        ? '-'
        : isAdd
            ? '+'
            : ' ';

    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      decoration: BoxDecoration(
        color: bg,
        border: Border(
          left: BorderSide(color: gutterAccent, width: 3),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              lineNum?.toString() ?? '',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10.5,
                color: isDel
                    ? semantic.diffDelFg
                    : isAdd
                        ? semantic.diffAddFg
                        : semantic.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            marker,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: fg,
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: DiffSyntaxHighlighter.highlightLine(
                  code: r.text,
                  language: language,
                  palette: syntaxPalette,
                  wordHighlightBg: wordBg,
                  wordRange: wordRange,
                ),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
