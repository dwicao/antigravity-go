import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/chat_backup_service.dart';
import '../../state/chat_message_store.dart';
import '../../state/chat_state.dart';
import '../../state/draft_store.dart';
import '../../state/projects_state.dart';
import '../../state/session_export_helper.dart';
import '../../state/sessions_state.dart';
import '../../state/update_state.dart';

/// Backup & Restore hub for Antigravity Go conversations.
class ChatBackupPage extends ConsumerStatefulWidget {
  const ChatBackupPage({
    super.key,
    this.initialSelectedSessionIds,
    this.backupService,
  });

  /// When provided, opens in "Selected" mode pre-selecting these sessions.
  final Set<String>? initialSelectedSessionIds;

  /// Optional service override for widget tests.
  final ChatBackupService? backupService;

  @override
  ConsumerState<ChatBackupPage> createState() => _ChatBackupPageState();
}

class _ChatBackupPageState extends ConsumerState<ChatBackupPage> {
  late final ChatBackupService _service;
  late bool _allChatsMode;
  late Set<String> _selectedIds;
  bool _includeArchived = true;
  bool _compressed = true;
  bool _includeDraftsAndProjects = true;
  String _sessionFilter = '';

  bool _loadingMeta = true;
  bool _busy = false;
  int _totalStoredMessages = 0;
  DateTime? _lastBackupAt;
  List<ChatBackupSnapshotInfo> _snapshots = const [];

  @override
  void initState() {
    super.initState();
    _service = widget.backupService ?? ChatBackupService.instance;
    final initial = widget.initialSelectedSessionIds;
    if (initial != null && initial.isNotEmpty) {
      _allChatsMode = false;
      _selectedIds = Set<String>.from(initial);
    } else {
      _allChatsMode = true;
      _selectedIds = <String>{};
    }
    Future.microtask(_refreshMeta);
  }

  Future<void> _refreshMeta() async {
    final sessions = ref.read(sessionsProvider).sessions;
    var msgTotal = 0;
    for (final s in sessions) {
      final msgs = await ChatMessageStore.instance.load(s.id);
      msgTotal += msgs.isNotEmpty ? msgs.length : s.messageCount;
    }
    final snapshots = await _service.listLocalSnapshots();
    final lastBackup = await _service.getLastBackupAt();
    if (!mounted) return;
    setState(() {
      _totalStoredMessages = msgTotal;
      _snapshots = snapshots;
      _lastBackupAt = lastBackup;
      _loadingMeta = false;
    });
  }

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  List<AgySessionSummary> _targetSessions(List<AgySessionSummary> all) {
    if (_allChatsMode) {
      return _includeArchived
          ? all
          : all.where((s) => !s.archived).toList(growable: false);
    }
    return all.where((s) => _selectedIds.contains(s.id)).toList(growable: false);
  }

  Future<ChatBackupBundle?> _buildSelectedBundle() async {
    final sessions = ref.read(sessionsProvider).sessions;
    final targets = _targetSessions(sessions);
    if (targets.isEmpty) {
      _showSnack('Select at least one chat to back up.');
      return null;
    }
    final drafts = ref.read(draftStoreProvider);
    final projects = ref.read(projectsProvider).projects;
    final appVersion = ref.read(appUpdateProvider).currentVersion;
    return _service.buildBundle(
      sessions: sessions,
      drafts: drafts,
      projects: projects,
      appVersion: appVersion,
      selectedSessionIds: _allChatsMode ? null : _selectedIds,
      includeArchived: _includeArchived,
      includeDraftsAndProjects: _includeDraftsAndProjects,
    );
  }

  Future<void> _saveLocalSnapshot() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bundle = await _buildSelectedBundle();
      if (bundle == null) return;
      final saved = await _service.saveLocalSnapshot(bundle);
      await _refreshMeta();
      if (!mounted) return;
      if (saved != null) {
        _showSnack(
          'Saved snapshot (${saved.sessionCount} chats, ${saved.messageCount} msgs · ${ChatBackupService.formatBytes(saved.byteLength)})',
        );
      } else {
        _showSnack('Local snapshot directory unavailable on this platform.');
      }
    } catch (e) {
      _showSnack('Snapshot failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportToDownloads({bool markdown = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bundle = await _buildSelectedBundle();
      if (bundle == null) return;
      final filename = ChatBackupService.suggestedFileName(
        at: bundle.exportedAt,
        compressed: _compressed,
        markdown: markdown,
      );
      String? savedPath;
      if (markdown) {
        final md = bundle.toMarkdownDigest();
        savedPath = await SessionExportHelper.saveTextToDownloads(
          filename: filename,
          content: md,
          mimeType: 'text/markdown',
        );
        if (savedPath == null) {
          await Clipboard.setData(ClipboardData(text: md));
          _showSnack('Downloads unavailable — Markdown backup copied to clipboard.');
          return;
        }
      } else {
        final bytes = bundle.encodeBytes(compressed: _compressed);
        savedPath = await SessionExportHelper.saveBytesToDownloads(
          filename: filename,
          bytes: bytes,
          mimeType: _compressed ? 'application/gzip' : 'application/json',
        );
        if (savedPath == null) {
          if (!_compressed) {
            await Clipboard.setData(
              ClipboardData(text: bundle.toPrettyJsonString()),
            );
            _showSnack('Downloads unavailable — JSON backup copied to clipboard.');
          } else {
            _showSnack('Could not save backup to Downloads.');
          }
          return;
        }
      }
      await _service.recordLastBackupAt(bundle.exportedAt);
      await _refreshMeta();
      if (!mounted) return;
      _showSnack(
        'Exported ${bundle.sessionCount} chats (${bundle.totalMessages} msgs) to $savedPath',
      );
    } catch (e) {
      _showSnack('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareBackupFile({ChatBackupSnapshotInfo? fromSnapshot}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      late final Uint8List bytes;
      late final String filename;
      late final String mimeType;
      late final DateTime at;

      if (fromSnapshot != null) {
        final f = File(fromSnapshot.filePath);
        bytes = await f.readAsBytes();
        filename = fromSnapshot.fileName;
        mimeType = 'application/gzip';
        at = fromSnapshot.createdAt;
      } else {
        final bundle = await _buildSelectedBundle();
        if (bundle == null) return;
        bytes = bundle.encodeBytes(compressed: _compressed);
        filename = ChatBackupService.suggestedFileName(
          at: bundle.exportedAt,
          compressed: _compressed,
        );
        mimeType = _compressed ? 'application/gzip' : 'application/json';
        at = bundle.exportedAt;
      }

      final tmpDir = await getTemporaryDirectory();
      final out = File('${tmpDir.path}/$filename');
      await out.writeAsBytes(bytes, flush: true);
      await _service.recordLastBackupAt(at);
      await _refreshMeta();
      await SharePlus.instance.share(
        ShareParams(
          subject: 'Antigravity Go Chat Backup ($filename)',
          files: [XFile(out.path, mimeType: mimeType, name: filename)],
        ),
      );
    } catch (e) {
      _showSnack('Share unavailable: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportSnapshotToDownloads(ChatBackupSnapshotInfo snap) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await File(snap.filePath).readAsBytes();
      final savedPath = await SessionExportHelper.saveBytesToDownloads(
        filename: snap.fileName,
        bytes: bytes,
        mimeType: 'application/gzip',
      );
      if (!mounted) return;
      _showSnack(
        savedPath != null
            ? 'Saved snapshot to $savedPath'
            : 'Could not save snapshot to Downloads.',
      );
    } catch (e) {
      _showSnack('Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndRestoreFile() async {
    if (_busy) return;
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (picked.isEmpty) return;
      final file = picked.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        _showSnack('Selected file could not be read.');
        return;
      }
      final bundle = ChatBackupBundle.decodeBytes(bytes);
      if (!mounted) return;
      await _openRestorePreview(bundle, sourceLabel: file.name);
    } catch (e) {
      _showSnack('Invalid backup file: $e');
    }
  }

  Future<void> _pasteAndRestoreJson() async {
    final ctrl = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste Chat Backup JSON'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            decoration: const InputDecoration(
              hintText: 'Paste .agychats.json or Replay JSON here…',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) {
                ctrl.text = data!.text!;
              }
            },
            child: const Text('Paste Clipboard'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Inspect'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (raw == null || raw.trim().isEmpty || !mounted) return;
    try {
      final bundle = ChatBackupBundle.decodeJsonString(raw);
      await _openRestorePreview(bundle, sourceLabel: 'Pasted JSON');
    } catch (e) {
      _showSnack('Invalid JSON backup: $e');
    }
  }

  Future<void> _restoreFromSnapshot(ChatBackupSnapshotInfo snap) async {
    try {
      final bundle = await _service.readSnapshotFile(snap.filePath);
      if (!mounted) return;
      await _openRestorePreview(bundle, sourceLabel: snap.fileName);
    } catch (e) {
      _showSnack('Could not read snapshot: $e');
    }
  }

  Future<void> _openRestorePreview(
    ChatBackupBundle bundle, {
    required String sourceLabel,
  }) async {
    if (bundle.entries.isEmpty) {
      _showSnack('Backup contains 0 conversations.');
      return;
    }
    final existingSessions = ref.read(sessionsProvider).sessions;
    final decision = await showDialog<
        ({ChatRestoreConflictMode mode, Set<String> selectedIds})>(
      context: context,
      builder: (_) => _RestorePreviewDialog(
        bundle: bundle,
        existingSessions: existingSessions,
        sourceLabel: sourceLabel,
        formatDateTime: _formatDateTime,
      ),
    );
    if (decision == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final existingProjects = ref.read(projectsProvider).projects;
      final applied = await _service.prepareAndPersistRestore(
        bundle: bundle,
        existingSessions: existingSessions,
        existingProjects: existingProjects,
        mode: decision.mode,
        selectedSessionIds: decision.selectedIds,
      );
      if (!mounted) return;
      await ref
          .read(projectsProvider.notifier)
          .importMissingProjects(applied.missingProjects);
      await ref
          .read(sessionsProvider.notifier)
          .importSessions(applied.upsertedSessions);
      await ref.read(draftStoreProvider.notifier).importDrafts(
            applied.restoredDrafts,
            overwrite: decision.mode == ChatRestoreConflictMode.overwriteExisting,
          );
      final chatNotifier = ref.read(chatProvider.notifier);
      for (final sid in applied.restoredSessionIds) {
        await chatNotifier.reloadSessionIfIdle(sid);
      }
      await _refreshMeta();
      if (!mounted) return;
      final s = applied.summary;
      _showSnack(
        'Restored ${s.restoredTotal} chats (${s.newSessions} new, ${s.updatedSessions} updated, ${s.copiedSessions} copied, ${s.skippedSessions} skipped · ${s.totalMessagesToWrite} msgs)',
      );
    } catch (e) {
      _showSnack('Restore failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteSnapshot(ChatBackupSnapshotInfo snap) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Snapshot?'),
        content: Text('Delete ${snap.fileName}? This cannot be undone.'),
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
    await _service.deleteLocalSnapshot(snap);
    await _refreshMeta();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider).sessions;
    final theme = Theme.of(context);
    final activeCount = sessions.where((s) => !s.archived).length;
    final archivedCount = sessions.length - activeCount;
    final targetSessions = _targetSessions(sessions);

    final filteredForPicker = sessions.where((s) {
      if (!_includeArchived && s.archived && !_selectedIds.contains(s.id)) {
        return false;
      }
      final q = _sessionFilter.trim().toLowerCase();
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) ||
          s.folder.toLowerCase().contains(q) ||
          s.hostName.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat Backup & Restore'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _busy ? null : _refreshMeta,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. Overview KPIs
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.backup_outlined,
                                size: 19,
                                color: theme.colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Local Chat Vault',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (_busy)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _MiniStat(
                                  label: 'Chats',
                                  value: '${sessions.length}',
                                  sub: archivedCount > 0
                                      ? '$activeCount active · $archivedCount arch'
                                      : '$activeCount active',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MiniStat(
                                  label: 'Messages',
                                  value: _loadingMeta
                                      ? '…'
                                      : '$_totalStoredMessages',
                                  sub: '${_snapshots.length} snapshots',
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MiniStat(
                                  label: 'Last Backup',
                                  value: _lastBackupAt == null
                                      ? 'Never'
                                      : _formatDateTime(_lastBackupAt!)
                                          .split(' ')
                                          .first,
                                  sub: _lastBackupAt == null
                                      ? 'Tap Save below'
                                      : _formatDateTime(_lastBackupAt!)
                                          .split(' ')
                                          .last,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Backups include full transcripts, reasoning, tools, usage metadata & drafts. API keys/tokens stay redacted.',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 2. Create Backup
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Create Backup',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                '${targetSessions.length} chat(s) selected',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: SegmentedButton<bool>(
                              showSelectedIcon: false,
                              segments: [
                                const ButtonSegment<bool>(
                                  value: true,
                                  label: Text(
                                    'All Chats',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                ButtonSegment<bool>(
                                  value: false,
                                  label: Text(
                                    'Select (${_selectedIds.length})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                              selected: {_allChatsMode},
                              onSelectionChanged: (s) {
                                setState(() => _allChatsMode = s.first);
                              },
                            ),
                          ),
                          if (!_allChatsMode) ...[
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    onChanged: (v) =>
                                        setState(() => _sessionFilter = v),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      prefixIcon: Icon(Icons.search, size: 18),
                                      hintText: 'Filter chats…',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                TextButton(
                                  onPressed: () => setState(() {
                                    _selectedIds = {
                                      for (final s in filteredForPicker) s.id,
                                    };
                                  }),
                                  child: const Text('All'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _selectedIds.clear()),
                                  child: const Text('None'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 210),
                              child: ListView.builder(
                                shrinkWrap: true,
                                itemCount: filteredForPicker.length,
                                itemBuilder: (_, idx) {
                                  final s = filteredForPicker[idx];
                                  final checked = _selectedIds.contains(s.id);
                                  return CheckboxListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    contentPadding: EdgeInsets.zero,
                                    value: checked,
                                    title: Text(
                                      s.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      [
                                        '${s.messageCount} msgs',
                                        if (s.folder.isNotEmpty) s.folder,
                                        if (s.archived) 'Archived',
                                      ].join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _selectedIds.add(s.id);
                                      } else {
                                        _selectedIds.remove(s.id);
                                      }
                                    }),
                                  );
                                },
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Include archived chats',
                              style: TextStyle(fontSize: 13),
                            ),
                            value: _includeArchived,
                            onChanged: (v) =>
                                setState(() => _includeArchived = v),
                          ),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Compress backup (.json.gz)',
                              style: TextStyle(fontSize: 13),
                            ),
                            subtitle: const Text(
                              'Shrinks large coding transcripts by ~80%',
                              style: TextStyle(fontSize: 11),
                            ),
                            value: _compressed,
                            onChanged: (v) => setState(() => _compressed = v),
                          ),
                          SwitchListTile.adaptive(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Include drafts & workspaces',
                              style: TextStyle(fontSize: 13),
                            ),
                            value: _includeDraftsAndProjects,
                            onChanged: (v) =>
                                setState(() => _includeDraftsAndProjects = v),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: _busy ? null : _saveLocalSnapshot,
                                icon: const Icon(Icons.save_outlined, size: 17),
                                label: const Text('Save Snapshot'),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: _busy
                                    ? null
                                    : () => _exportToDownloads(markdown: false),
                                icon: const Icon(
                                  Icons.download_outlined,
                                  size: 17,
                                ),
                                label: const Text('Save to Downloads'),
                              ),
                              OutlinedButton.icon(
                                onPressed:
                                    _busy ? null : () => _shareBackupFile(),
                                icon: const Icon(Icons.ios_share, size: 17),
                                label: const Text('Share File'),
                              ),
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _exportToDownloads(markdown: true),
                                icon: const Icon(
                                  Icons.description_outlined,
                                  size: 17,
                                ),
                                label: const Text('Export Markdown'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 3. Restore Section
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Restore Chats',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Import `.agychats.json.gz`, `.json`, or single-chat exports with conflict preview.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonalIcon(
                                onPressed:
                                    _busy ? null : _pickAndRestoreFile,
                                icon: const Icon(
                                  Icons.folder_open_outlined,
                                  size: 17,
                                ),
                                label: const Text('Restore from File…'),
                              ),
                              OutlinedButton.icon(
                                onPressed:
                                    _busy ? null : _pasteAndRestoreJson,
                                icon: const Icon(
                                  Icons.content_paste_go,
                                  size: 17,
                                ),
                                label: const Text('Paste JSON Backup'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 4. Local Snapshots
                  Card(
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'On-Device Snapshots',
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  '${_snapshots.length}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_snapshots.isEmpty)
                            Text(
                              'No local snapshots yet. Tap "Save Snapshot" above to create an instant on-device restore point.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            )
                          else
                            for (var i = 0; i < _snapshots.length; i++) ...[
                              if (i > 0) const Divider(height: 12),
                              _SnapshotRow(
                                info: _snapshots[i],
                                formattedTime:
                                    _formatDateTime(_snapshots[i].createdAt),
                                busy: _busy,
                                onRestore: () =>
                                    _restoreFromSnapshot(_snapshots[i]),
                                onShare: () => _shareBackupFile(
                                  fromSnapshot: _snapshots[i],
                                ),
                                onDownload: () =>
                                    _exportSnapshotToDownloads(_snapshots[i]),
                                onDelete: () => _deleteSnapshot(_snapshots[i]),
                              ),
                            ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    required this.sub,
  });

  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontSize: 10.5,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  const _SnapshotRow({
    required this.info,
    required this.formattedTime,
    required this.busy,
    required this.onRestore,
    required this.onShare,
    required this.onDownload,
    required this.onDelete,
  });

  final ChatBackupSnapshotInfo info;
  final String formattedTime;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onShare;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formattedTime,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              Text(
                '${info.sessionCount} chats · ${info.messageCount} msgs · ${ChatBackupService.formatBytes(info.byteLength)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        FilledButton.tonal(
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: busy ? null : onRestore,
          child: const Text('Restore', style: TextStyle(fontSize: 12)),
        ),
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: 18,
          onSelected: (v) {
            switch (v) {
              case 'download':
                onDownload();
              case 'share':
                onShare();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'download', child: Text('Save to Downloads')),
            PopupMenuItem(value: 'share', child: Text('Share File')),
            PopupMenuItem(value: 'delete', child: Text('Delete Snapshot')),
          ],
        ),
      ],
    );
  }
}

class _RestorePreviewDialog extends StatefulWidget {
  const _RestorePreviewDialog({
    required this.bundle,
    required this.existingSessions,
    required this.sourceLabel,
    required this.formatDateTime,
  });

  final ChatBackupBundle bundle;
  final List<AgySessionSummary> existingSessions;
  final String sourceLabel;
  final String Function(DateTime) formatDateTime;

  @override
  State<_RestorePreviewDialog> createState() => _RestorePreviewDialogState();
}

class _RestorePreviewDialogState extends State<_RestorePreviewDialog> {
  ChatRestoreConflictMode _mode = ChatRestoreConflictMode.mergeKeepNewer;
  late Set<String> _selectedIds;

  @override
  void initState() {
    super.initState();
    _selectedIds = {for (final e in widget.bundle.entries) e.session.id};
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existingIds = {for (final s in widget.existingSessions) s.id};
    final plan = ChatBackupService.previewRestorePlan(
      bundle: widget.bundle,
      existingSessions: widget.existingSessions,
      mode: _mode,
      selectedSessionIds: _selectedIds,
    );

    return AlertDialog(
      title: const Text('Restore Preview'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.sourceLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Exported ${widget.formatDateTime(widget.bundle.exportedAt)} · v${widget.bundle.appVersion} · ${widget.bundle.sessionCount} chats · ${widget.bundle.totalMessages} msgs',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ChatRestoreConflictMode>(
                value: _mode,
                isExpanded: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'If chat already exists',
                ),
                items: ChatRestoreConflictMode.values
                    .map(
                      (m) => DropdownMenuItem(
                        value: m,
                        child: Text(
                          m.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _mode = v);
                },
              ),
              const SizedBox(height: 4),
              Text(
                _mode.description,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.secondaryContainer.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${plan.newSessions} new · ${plan.updatedSessions} update · ${plan.copiedSessions} copy · ${plan.skippedSessions} skip (${plan.totalMessagesToWrite} msgs)',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Chats in backup (${_selectedIds.length}/${widget.bundle.entries.length})',
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _selectedIds = {
                        for (final e in widget.bundle.entries) e.session.id,
                      };
                    }),
                    child: const Text('All'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _selectedIds.clear()),
                    child: const Text('None'),
                  ),
                ],
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 190),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.bundle.entries.length,
                  itemBuilder: (_, idx) {
                    final e = widget.bundle.entries[idx];
                    final exists = existingIds.contains(e.session.id);
                    return CheckboxListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: EdgeInsets.zero,
                      value: _selectedIds.contains(e.session.id),
                      title: Text(
                        e.session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      subtitle: Text(
                        '${e.messages.length} msgs · ${exists ? "Exists locally" : "New"}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _selectedIds.add(e.session.id);
                        } else {
                          _selectedIds.remove(e.session.id);
                        }
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selectedIds.isEmpty || plan.restoredTotal == 0
              ? null
              : () => Navigator.of(context).pop((
                    mode: _mode,
                    selectedIds: Set<String>.from(_selectedIds),
                  )),
          child: Text('Restore (${plan.restoredTotal})'),
        ),
      ],
    );
  }
}
