import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/permissions_state.dart';
import '../../state/runtime_state.dart';

class WorkspacePage extends ConsumerStatefulWidget {
  const WorkspacePage({super.key});

  @override
  ConsumerState<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends ConsumerState<WorkspacePage> {
  String _currentPath = '';
  List<Map<String, String>> _entries = const [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(permissionsProvider.notifier).refresh();
      final root = ref.read(runtimeProvider).status.workspaceRoot ?? '';
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

  Future<void> _openFile(String path, String name) async {
    final content = await RuntimeBridge.instance.readWorkspaceFile(path);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
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
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final runtimeRoot = ref.watch(runtimeProvider).status.workspaceRoot ?? '';
    final extRoot = perms.externalStorageRoot;
    final downloadsPath = '$extRoot/Download';
    final theme = Theme.of(context);

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
                : _entries.isEmpty
                    ? const Center(
                        child: Text(
                          'Folder is empty, runtime not installed, or All Files Access is required.',
                          textAlign: TextAlign.center,
                        ),
                      )
                    : Scrollbar(
                        child: ListView.builder(
                          itemCount: _entries.length,
                          itemBuilder: (context, i) {
                            final item = _entries[i];
                            final isDir = item['type'] == 'dir';
                            final name = item['name'] ?? '';
                            final path = item['path'] ?? '';
                            return ListTile(
                              leading: Icon(
                                isDir
                                    ? Icons.folder
                                    : Icons.insert_drive_file_outlined,
                              ),
                              title: Text(name),
                              subtitle: Text(item['size'] ?? ''),
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
