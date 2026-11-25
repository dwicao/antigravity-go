import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../remote/ssh_agy_runner.dart';
import '../../runtime/runtime_bridge.dart';
import '../../state/chat_state.dart';
import '../../state/ci_watch_state.dart';
import '../../state/hosts_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../theme/app_theme.dart';
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
  List<DiffFileHunks> _fileHunks = const [];
  final Map<String, DiffHunkStatus> _hunkDecisions = {};
  bool _swipeHunkMode = true;
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
    final sessionWs =
        ref.read(sessionsProvider).activeSession?.workspacePath.trim() ?? '';
    if (sessionWs.isNotEmpty) return sessionWs;
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    if (projDir.isNotEmpty) return projDir;
    final sshWs = ref.read(hostsProvider).activeSshHost?.defaultWorkspace ?? '';
    if (sshWs.isNotEmpty) return sshWs;
    return ref.read(runtimeProvider).status.workspaceRoot ?? '';
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final sshHost = ref.read(hostsProvider).activeSshHost;
      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        final raw = await SshAgyRunner.instance.runRemoteCommand(
          host: sshHost,
          cwd: _activeCwd(),
          password: pwd,
          privateKeyPem: key,
          onTrustFirstKey: (fp) => ref
              .read(hostsProvider.notifier)
              .saveHostFingerprint(sshHost.id, fp),
          command:
              "git branch --show-current 2>/dev/null || true; printf '\\n===STATUS===\\n'; git status --short 2>/dev/null || true; printf '\\n===NUMSTAT===\\n'; git diff --numstat 2>/dev/null || true; git diff --cached --numstat 2>/dev/null || true; printf '\\n===DIFF===\\n'; git diff 2>/dev/null || true; git diff --cached 2>/dev/null || true",
        );
        final parts = raw.split('\n===STATUS===\n');
        final branch = parts.first.trim();
        final rest1 = (parts.length > 1 ? parts[1] : '').split('\n===NUMSTAT===\n');
        final status = rest1.first.trim();
        final rest2 = (rest1.length > 1 ? rest1[1] : '').split('\n===DIFF===\n');
        final numstat = rest2.first.trim();
        final diff = (rest2.length > 1 ? rest2[1] : '').trim();
        final parsed = FileChangeEntry.attachUnifiedDiffs(
          FileChangeEntry.parseGitNumstat(numstat),
          diff,
        );
        final hunks = DiffHunkParser.parse(diff);
        if (mounted) {
          setState(() {
            _status = status;
            _diff = diff;
            _branch = branch;
            _changedFiles = parsed;
            _fileHunks = hunks;
            _hunkDecisions.clear();
          });
        }
        return;
      }
      final res = await RuntimeBridge.instance.gitDiffDetailed(_activeCwd());
      final hunks = DiffHunkParser.parse(res.diff.trim());
      if (mounted) {
        setState(() {
          _status = res.status.trim();
          _diff = res.diff.trim();
          _branch = res.branch.trim();
          _changedFiles = res.files;
          _fileHunks = hunks;
          _hunkDecisions.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _acceptHunk(DiffHunk hunk) async {
    setState(() {
      _hunkDecisions[hunk.id] = DiffHunkStatus.accepted;
    });
  }

  Future<void> _rejectHunk(DiffHunk hunk) async {
    final cwd = _activeCwd();
    var ok = false;
    final sshHost = ref.read(hostsProvider).activeSshHost;
    if (sshHost != null) {
      final (pwd, key) =
          await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
      final patch = hunk.toSingleHunkPatch();
      final b64 = patch.replaceAll("'", "'\\''");
      final out = await SshAgyRunner.instance.runRemoteCommand(
        host: sshHost,
        cwd: cwd,
        password: pwd,
        privateKeyPem: key,
        command: "printf '%s' '$b64' | git apply -R --unidiff-zero -",
      );
      ok = !out.toLowerCase().contains('error:');
    } else {
      final res = await RuntimeBridge.instance.revertPatch(
        cwd: cwd.isEmpty ? null : cwd,
        patchText: hunk.toSingleHunkPatch(),
      );
      ok = res['ok'] == true;
      if (!ok && cwd.isNotEmpty) {
        final fullPath = '$cwd/${hunk.filePath}';
        final raw = await RuntimeBridge.instance.readWorkspaceFile(fullPath);
        final reverted = DiffHunkParser.revertHunkInContent(raw, hunk);
        if (reverted != null) {
          ok = await RuntimeBridge.instance.writeFile(fullPath, reverted);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _hunkDecisions[hunk.id] = ok
          ? DiffHunkStatus.rejected
          : DiffHunkStatus.pending;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Reverted hunk in ${hunk.filePath}'
              : 'Could not revert hunk cleanly in ${hunk.filePath}',
        ),
      ),
    );
    if (ok) {
      await _load();
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
      final sshHost = ref.read(hostsProvider).activeSshHost;
      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        final quotedMsg = "'${msg.replaceAll("'", "'\\''")}'";
        final pushCmd = push ? ' && git push' : '';
        final out = await SshAgyRunner.instance.runRemoteCommand(
          host: sshHost,
          cwd: _activeCwd(),
          password: pwd,
          privateKeyPem: key,
          command:
              'git add -A && git commit -m $quotedMsg$pushCmd && git rev-parse --short HEAD',
        );
        if (!mounted) return;
        final lines = out.trim().split('\n');
        final commitLabel = lines.isNotEmpty && lines.last.trim().isNotEmpty
            ? lines.last.trim()
            : 'HEAD';
        final branchLabel = _branch.isNotEmpty ? _branch : 'main';
        setState(() {
          _lastPushResult = (
            commitHash: commitLabel,
            branch: branchLabel,
            files: _changedFiles,
            output: out,
          );
        });
        await ref.read(chatProvider.notifier).appendSystemFeedback(
              '**${push ? 'Committed & pushed' : 'Committed'}** `$commitLabel` on `$branchLabel` (SSH).',
              changedFiles: _changedFiles,
            );
        await _load();
        return;
      }
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
    final semantic = AgySemanticColors.of(context);
    ref.listen<String>(
      projectsProvider.select((p) => p.activeProject.primaryFolder),
      (prev, next) {
        if (prev != next) Future.microtask(_load);
      },
    );
    ref.listen<String?>(
      sessionsProvider.select((s) => s.activeSession?.workspacePath),
      (prev, next) {
        if (prev != next) Future.microtask(_load);
      },
    );
    ref.listen<String?>(
      hostsProvider.select((h) => h.activeSshHost?.id),
      (prev, next) {
        if (prev != next) Future.microtask(_load);
      },
    );
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
              if (_fileHunks.isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                  padding: EdgeInsets.zero,
                  tooltip: _swipeHunkMode
                      ? 'Switch to Raw Diff View'
                      : 'Switch to Swipe Hunk Review',
                  onPressed: () =>
                      setState(() => _swipeHunkMode = !_swipeHunkMode),
                  icon: Icon(
                    _swipeHunkMode
                        ? Icons.swipe_outlined
                        : Icons.view_headline_outlined,
                    size: 18,
                    color: _swipeHunkMode ? theme.colorScheme.primary : null,
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                padding: EdgeInsets.zero,
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
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                padding: EdgeInsets.zero,
                tooltip: 'Ask agent to review diff',
                onPressed: _diff.isEmpty
                    ? null
                    : () => ref.read(chatProvider.notifier).sendPrompt(
                          'Review the current git uncommitted changes and suggest any fixes.',
                        ),
                icon: const Icon(Icons.rate_review_outlined, size: 18),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 34, height: 34),
                padding: EdgeInsets.zero,
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
                          if (_diff.isNotEmpty && _swipeHunkMode && _fileHunks.isNotEmpty) ...[
                            Row(
                              children: [
                                Text(
                                  'Swipe Hunks (→ Accept · ← Revert)',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '${_fileHunks.fold<int>(0, (s, f) => s + f.hunks.length)} hunks',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: semantic.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            for (final fileGroup in _fileHunks) ...[
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4, top: 4),
                                child: Text(
                                  fileGroup.filePath,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              for (final hunk in fileGroup.hunks)
                                _SwipeHunkCard(
                                  hunk: hunk,
                                  status: _hunkDecisions[hunk.id] ??
                                      DiffHunkStatus.pending,
                                  onAccept: () => _acceptHunk(hunk),
                                  onReject: () => _rejectHunk(hunk),
                                ),
                            ],
                          ] else if (_diff.isNotEmpty) ...[
                            Text(
                              'Diff',
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: semantic.codeWellBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: semantic.codeWellBorder,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final line in _diff.split('\n'))
                                    DiffLineView(line: line),
                                ],
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

class _SwipeHunkCard extends StatelessWidget {
  const _SwipeHunkCard({
    required this.hunk,
    required this.status,
    required this.onAccept,
    required this.onReject,
  });

  final DiffHunk hunk;
  final DiffHunkStatus status;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    final borderColor = switch (status) {
      DiffHunkStatus.accepted => semantic.success.withOpacity(0.6),
      DiffHunkStatus.rejected => semantic.danger.withOpacity(0.6),
      DiffHunkStatus.pending => semantic.codeWellBorder,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey('hunk-${hunk.id}'),
        confirmDismiss: (dir) async {
          if (dir == DismissDirection.startToEnd) {
            onAccept();
            return false;
          } else {
            onReject();
            return false;
          }
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: semantic.success.withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline, color: semantic.success),
              const SizedBox(width: 6),
              Text(
                'Keep hunk',
                style: TextStyle(
                  color: semantic.success,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        secondaryBackground: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: semantic.danger.withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                'Revert hunk',
                style: TextStyle(
                  color: semantic.danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.undo_rounded, color: semantic.danger),
            ],
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            color: semantic.codeWellBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${hunk.header} (+${hunk.addedLines} -${hunk.removedLines})',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (status == DiffHunkStatus.accepted)
                      Icon(Icons.check_circle, size: 16, color: semantic.success)
                    else ...[
                      IconButton(
                        tooltip: 'Keep hunk',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: onAccept,
                        icon: Icon(
                          Icons.check_rounded,
                          size: 16,
                          color: semantic.success,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Revert hunk',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: onReject,
                        icon: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: semantic.danger,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in hunk.lines.take(40))
                      DiffLineView(line: line),
                    if (hunk.lines.length > 40)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '… ${hunk.lines.length - 40} more lines',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
