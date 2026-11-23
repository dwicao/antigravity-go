import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/chat_state.dart';
import '../../state/ci_watch_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../chat/change_card.dart';

class DiffReviewView extends ConsumerStatefulWidget {
  const DiffReviewView({super.key});

  @override
  ConsumerState<DiffReviewView> createState() => _DiffReviewViewState();
}

class _DiffReviewViewState extends ConsumerState<DiffReviewView> {
  String _status = '';
  String _diff = '';
  String _branch = '';
  List<FileChangeEntry> _changedFiles = const [];
  ({String commitHash, String branch, List<FileChangeEntry> files, String output})?
      _lastPushResult;
  bool _loading = false;
  bool _pushing = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  String _activeCwd() {
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
    return projDir.isNotEmpty ? projDir : fallback;
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final res = await RuntimeBridge.instance.gitDiffDetailed(_activeCwd());
      if (mounted) {
        setState(() {
          _status = res.status.trim();
          _diff = res.diff.trim();
          _branch = res.branch.trim();
          _changedFiles = res.files;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _commitAndPush({required bool push}) async {
    final msgCtrl = TextEditingController(text: 'Update workspace files');
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(push ? 'Commit & Push to GitHub' : 'Commit Changes'),
        content: TextField(
          controller: msgCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Commit message',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(msgCtrl.text.trim()),
            child: Text(push ? 'Commit & Push' : 'Commit'),
          ),
        ],
      ),
    );
    msgCtrl.dispose();
    if (msg == null || msg.isEmpty || !mounted) return;

    setState(() => _pushing = true);
    try {
      final res = await RuntimeBridge.instance.gitCommitAndPush(
        cwd: _activeCwd(),
        message: msg,
        stageAll: true,
        push: push,
      );
      if (!mounted) return;
      final commitLabel =
          res.commitHash.isNotEmpty ? res.commitHash : 'HEAD';
      final branchLabel = res.branch.isNotEmpty ? res.branch : 'main';
      setState(() {
        _lastPushResult = (
          commitHash: commitLabel,
          branch: branchLabel,
          files: res.files,
          output: res.output,
        );
      });

      final fileLines = res.files
          .map((f) => '- `${f.path}` (+${f.added} -${f.removed})')
          .join('\n');
      final actionWord = res.pushed ? 'Committed & pushed' : 'Committed';
      final feedbackText = res.ok
          ? '**$actionWord** `$commitLabel` on `$branchLabel` (${res.files.length} changed files):\n$fileLines'
          : '**Git ${push ? 'push' : 'commit'} issue** on `$branchLabel`:\n```\n${res.output}\n```';
      await ref.read(chatProvider.notifier).appendSystemFeedback(
            feedbackText,
            changedFiles: res.files,
          );
      if (res.pushed) {
        final sid = ref.read(sessionsProvider).activeSessionId ?? 'default';
        await ref.read(ciWatchProvider.notifier).watchLatestRun(
              cwd: _activeCwd(),
              sessionId: sid,
              branch: branchLabel,
            );
      }
      await _load();
    } finally {
      if (mounted) setState(() => _pushing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Review Changes',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_branch.isNotEmpty)
                      Text(
                        'Branch: $_branch',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Commit & Push changed files',
                onPressed: (_status.isEmpty && _diff.isEmpty) || _pushing
                    ? null
                    : () => _commitAndPush(push: true),
                icon: _pushing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_upload_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Ask agent to review diff',
                onPressed: _diff.isEmpty
                    ? null
                    : () => ref.read(chatProvider.notifier).sendPrompt(
                          'Review the current git uncommitted changes and suggest any fixes.',
                        ),
                icon: const Icon(Icons.rate_review_outlined, size: 18),
              ),
              IconButton(
                tooltip: 'Refresh git diff',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : (_status.isEmpty && _diff.isEmpty && _lastPushResult == null)
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          'No uncommitted Git changes in the active project.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Scrollbar(
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (_lastPushResult != null) ...[
                            ChangeCard(
                              files: _lastPushResult!.files,
                              title:
                                  'Pushed ${_lastPushResult!.commitHash} (${_lastPushResult!.branch})',
                            ),
                            if (_lastPushResult!.output.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                _lastPushResult!.output,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                          ],
                          if (_changedFiles.isNotEmpty) ...[
                            ChangeCard(files: _changedFiles),
                            const SizedBox(height: 12),
                          ],
                          if (_status.isNotEmpty) ...[
                            Text(
                              'Git Status',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                _status,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_diff.isNotEmpty) ...[
                            Text(
                              'Diff',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                _diff,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
        ),
      ],
    );
  }
}
