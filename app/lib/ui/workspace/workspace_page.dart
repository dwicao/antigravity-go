import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
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
    Future.microtask(() {
      final root = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      _loadDir(root);
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _currentPath.isEmpty ? 'Workspace Explorer' : _currentPath.split('/').last,
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => _loadDir(_currentPath),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Text('Workspace is empty or runtime not installed yet.'),
                )
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, i) {
                    final item = _entries[i];
                    final isDir = item['type'] == 'dir';
                    final name = item['name'] ?? '';
                    final path = item['path'] ?? '';
                    return ListTile(
                      leading: Icon(
                        isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                      ),
                      title: Text(name),
                      subtitle: Text(item['size'] ?? ''),
                      onTap: () =>
                          isDir ? _loadDir(path) : _openFile(path, name),
                    );
                  },
                ),
    );
  }
}
