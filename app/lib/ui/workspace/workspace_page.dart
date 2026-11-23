import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  String _currentPath = '';
  String _searchQuery = '';
  List<Map<String, String>> _entries = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(permissionsProvider.notifier).refresh();
      final proj = ref.read(projectsProvider).activeProject.primaryFolder;
      final root = proj.isNotEmpty
          ? proj
          : (ref.read(runtimeProvider).status.workspaceRoot ?? '');
      await _loadDir(root);
    });
  }

  Future<void> _loadDir(String path) async {
    setState(() => _loading = true);
    try {
      final items = await RuntimeBridge.instance.listWorkspaceEntries(path);
      if (mounted) {
        setState(() {
          _currentPath = path;
          _entries = items;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _navigateUp() {
    if (_currentPath.isEmpty) return;
    final idx = _currentPath.lastIndexOf('/');
    if (idx <= 0) {
      _loadDir('/');
    } else {
      _loadDir(_currentPath.substring(0, idx));
    }
  }

  static bool _isImagePath(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif');
  }

  Future<void> _openFile(String path, String name) async {
    if (_isImagePath(name)) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(name),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) =>
                  const Text('Unable to preview image file.'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    final content = await RuntimeBridge.instance.readWorkspaceFile(path);
    if (!mounted) return;
    final isBinary = content.startsWith('[Binary file (');
    final editCtrl = TextEditingController(text: content);
    var editing = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(name),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: editing
                  ? TextField(
                      controller: editCtrl,
                      maxLines: 18,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    )
                  : SelectableText(
                      editCtrl.text,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
            ),
          ),
          actions: [
            if (!isBinary && !editing)
              TextButton(
                onPressed: () => setLocal(() => editing = true),
                child: const Text('Edit'),
              ),
            if (editing)
              FilledButton(
                onPressed: () async {
                  final ok = await RuntimeBridge.instance.writeWorkspaceFile(
                    path,
                    editCtrl.text,
                  );
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ok ? 'Saved $name' : 'Failed to save $name'),
                      ),
                    );
                    await _loadDir(_currentPath);
                  }
                },
                child: const Text('Save'),
              ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    editCtrl.dispose();
  }

  Future<void> _createEntry({required bool isDir}) async {
    if (_currentPath.isEmpty) return;
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDir ? 'New Folder' : 'New File'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: isDir ? 'Folder name' : 'File name',
            hintText: isDir ? 'src' : 'notes.md',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    final target = '$_currentPath/$name';
    final ok = isDir
        ? await RuntimeBridge.instance.createWorkspaceDirectory(target)
        : await RuntimeBridge.instance.writeWorkspaceFile(target, '');
    if (mounted) {
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create $name')),
        );
      }
      await _loadDir(_currentPath);
    }
  }

  Future<void> _deleteEntry(String path, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $name?'),
        content: Text('This will permanently delete `$path`.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await RuntimeBridge.instance.deleteWorkspaceEntry(path);
    await _loadDir(_currentPath);
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final runtimeRoot = ref.watch(runtimeProvider).status.workspaceRoot ?? '';
    final extRoot = perms.externalStorageRoot;
    final downloadsPath = '$extRoot/Download';
    final theme = Theme.of(context);
    final q = _searchQuery.trim().toLowerCase();
    final visibleEntries = q.isEmpty
        ? _entries
        : _entries
            .where((e) => (e['name'] ?? '').toLowerCase().contains(q))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentPath.isEmpty
              ? 'Workspace Explorer'
              : _currentPath.split('/').last.isEmpty
                  ? '/'
                  : _currentPath.split('/').last,
        ),
        actions: [
          if (_currentPath.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Folder actions',
              onSelected: (action) async {
                if (action == 'new_file') {
                  await _createEntry(isDir: false);
                } else if (action == 'new_dir') {
                  await _createEntry(isDir: true);
                } else if (action == 'use_project') {
                  final folderName = _currentPath.split('/').last;
                  await ref.read(projectsProvider.notifier).addProject(
                        name: folderName.isEmpty ? 'Workspace' : folderName,
                        folders: [_currentPath],
                      );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Active project set to $_currentPath')),
                    );
                  }
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'new_file', child: Text('New File')),
                PopupMenuItem(value: 'new_dir', child: Text('New Folder')),
                PopupMenuItem(
                  value: 'use_project',
                  child: Text('Use Folder as Active Project'),
                ),
              ],
            ),
          if (_currentPath.isNotEmpty && _currentPath != '/')
            IconButton(
              tooltip: 'Parent folder',
              onPressed: _navigateUp,
              icon: const Icon(Icons.arrow_upward),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _loadDir(_currentPath),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!perms.allFilesAccess)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withOpacity(0.55),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_off_outlined),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'All Files Access is not granted yet. Enable it to browse /storage/emulated/0 and Downloads.',
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => ref
                        .read(permissionsProvider.notifier)
                        .requestAllFilesAccess(),
                    child: const Text('Grant Access'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ActionChip(
                    avatar: const Icon(Icons.terminal, size: 16),
                    label: const Text('App Workspace'),
                    onPressed: () => _loadDir(runtimeRoot),
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.sd_storage_outlined, size: 16),
                    label: const Text('Internal Storage'),
                    onPressed: () async {
                      if (!perms.allFilesAccess) {
                        await ref
                            .read(permissionsProvider.notifier)
                            .requestAllFilesAccess();
                      }
                      await _loadDir(extRoot);
                    },
                  ),
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.download_outlined, size: 16),
                    label: const Text('Downloads'),
                    onPressed: () async {
                      if (!perms.allFilesAccess) {
                        await ref
                            .read(permissionsProvider.notifier)
                            .requestAllFilesAccess();
                      }
                      await _loadDir(downloadsPath);
                    },
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 6),
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Filter files in folder…',
                isDense: true,
              ),
            ),
          ),
          if (_currentPath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _currentPath,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          const Divider(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visibleEntries.isEmpty
                    ? const Center(
                        child: Text(
                          'Folder is empty, runtime not installed, or All Files Access is required.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : Scrollbar(
                        child: ListView.builder(
                          itemCount: visibleEntries.length,
                          itemBuilder: (context, i) {
                            final item = visibleEntries[i];
                            final isDir = item['type'] == 'dir';
                            final name = item['name'] ?? '';
                            final path = item['path'] ?? '';
                            return ListTile(
                              leading: Icon(
                                isDir
                                    ? Icons.folder
                                    : _isImagePath(name)
                                        ? Icons.image_outlined
                                        : Icons.insert_drive_file_outlined,
                              ),
                              title: Text(name),
                              subtitle: Text(item['size'] ?? ''),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                tooltip: 'Delete',
                                onPressed: () => _deleteEntry(path, name),
                              ),
                              onTap: () => isDir
                                  ? _loadDir(path)
                                  : _openFile(path, name),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
