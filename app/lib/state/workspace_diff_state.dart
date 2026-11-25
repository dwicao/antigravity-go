import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'chat_models.dart';
import 'chat_state.dart';
import 'hosts_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'sessions_state.dart';

class WorkspaceDiffState {
  const WorkspaceDiffState({
    this.loading = false,
    this.cwd = '',
    this.branch = '',
    this.status = '',
    this.unifiedDiff = '',
    this.files = const [],
  });

  final bool loading;
  final String cwd;
  final String branch;
  final String status;
  final String unifiedDiff;
  final List<FileChangeEntry> files;

  int get totalAdded => files.fold<int>(0, (s, f) => s + f.added);
  int get totalRemoved => files.fold<int>(0, (s, f) => s + f.removed);
  bool get hasChanges =>
      files.isNotEmpty || unifiedDiff.trim().isNotEmpty || status.trim().isNotEmpty;

  WorkspaceDiffState copyWith({
    bool? loading,
    String? cwd,
    String? branch,
    String? status,
    String? unifiedDiff,
    List<FileChangeEntry>? files,
  }) {
    return WorkspaceDiffState(
      loading: loading ?? this.loading,
      cwd: cwd ?? this.cwd,
      branch: branch ?? this.branch,
      status: status ?? this.status,
      unifiedDiff: unifiedDiff ?? this.unifiedDiff,
      files: files ?? this.files,
    );
  }
}

final workspaceDiffProvider =
    NotifierProvider<WorkspaceDiffNotifier, WorkspaceDiffState>(
  WorkspaceDiffNotifier.new,
);

/// Tracks live uncommitted workspace changes (standard Git, Shadow Git, SSH, or
/// latest assistant turn fallback) so both the bottom-of-chat mini-view and the
/// standalone [DiffReviewPage] stay synchronized.
class WorkspaceDiffNotifier extends Notifier<WorkspaceDiffState> {
  int _refreshToken = 0;

  @override
  WorkspaceDiffState build() {
    ref.listen<String>(
      sessionsProvider.select((s) => s.activeSession?.workspacePath ?? ''),
      (_, _) => unawaited(refresh()),
    );
    ref.listen<String>(
      projectsProvider.select((p) => p.activeProject.primaryFolder),
      (_, _) => unawaited(refresh()),
    );
    ref.listen<String?>(
      hostsProvider.select((h) => h.activeSshHost?.id),
      (_, _) => unawaited(refresh()),
    );
    ref.listen<String?>(
      runtimeProvider.select((r) => r.status.workspaceRoot),
      (_, _) => unawaited(refresh()),
    );
    ref.listen<bool>(
      chatProvider.select((c) => c.isStreaming),
      (prev, next) {
        if (prev == true && next == false) {
          unawaited(refresh());
        }
      },
    );
    ref.listen<int>(
      chatProvider.select((c) => _latestChangedFilesSignature(c.messages)),
      (prev, next) {
        if (prev != next) {
          unawaited(refresh());
        }
      },
    );

    Future.microtask(() {
      if (ref.mounted) unawaited(refresh());
    });
    return const WorkspaceDiffState();
  }

  static int _latestChangedFilesSignature(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.changedFiles.isNotEmpty) {
        return Object.hash(m.id, m.changedFiles.length);
      }
    }
    return 0;
  }

  String resolveActiveCwd() {
    final sessionWs =
        ref.read(sessionsProvider).activeSession?.workspacePath.trim() ?? '';
    if (sessionWs.isNotEmpty) return sessionWs;
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder.trim();
    if (projDir.isNotEmpty) return projDir;
    final sshWs =
        ref.read(hostsProvider).activeSshHost?.defaultWorkspace.trim() ?? '';
    if (sshWs.isNotEmpty) return sshWs;
    return ref.read(runtimeProvider).status.workspaceRoot?.trim() ?? '';
  }

  List<FileChangeEntry> _latestTurnFallbackFiles() {
    final msgs = ref.read(chatProvider).messages;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.role == ChatRole.user) break;
      if (!m.isStreaming && m.changedFiles.isNotEmpty) {
        return m.changedFiles;
      }
    }
    return const [];
  }

  Future<void> refresh({bool showLoading = false}) async {
    if (!ref.mounted) return;
    final token = ++_refreshToken;
    final cwd = resolveActiveCwd();
    final sshHost = ref.read(hostsProvider).activeSshHost;

    if (showLoading) {
      state = state.copyWith(loading: true, cwd: cwd);
    }

    if (cwd.isEmpty && sshHost == null) {
      final fallback = _latestTurnFallbackFiles();
      if (!ref.mounted || token != _refreshToken) return;
      state = WorkspaceDiffState(
        loading: false,
        cwd: '',
        files: fallback,
        unifiedDiff: fallback
            .map((f) => f.diff ?? '')
            .where((d) => d.trim().isNotEmpty)
            .join('\n'),
      );
      return;
    }

    try {
      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        final raw = await SshAgyRunner.instance.runRemoteCommand(
          host: sshHost,
          cwd: cwd,
          password: pwd,
          privateKeyPem: key,
          onTrustFirstKey: (fp) => ref
              .read(hostsProvider.notifier)
              .saveHostFingerprint(sshHost.id, fp),
          command:
              "git branch --show-current 2>/dev/null || true; printf '\\n===STATUS===\\n'; git status --short -uall 2>/dev/null || true; printf '\\n===NUMSTAT===\\n'; git diff --numstat HEAD 2>/dev/null || (git diff --numstat 2>/dev/null; git diff --cached --numstat 2>/dev/null) || true; printf '\\n===DIFF===\\n'; git diff HEAD 2>/dev/null || (git diff 2>/dev/null; git diff --cached 2>/dev/null) || true",
        );
        if (!ref.mounted || token != _refreshToken) return;
        final parts = raw.split('\n===STATUS===\n');
        final branch = parts.first.trim();
        final rest1 =
            (parts.length > 1 ? parts[1] : '').split('\n===NUMSTAT===\n');
        final status = rest1.first.trim();
        final rest2 =
            (rest1.length > 1 ? rest1[1] : '').split('\n===DIFF===\n');
        final numstat = rest2.first.trim();
        final diff = (rest2.length > 1 ? rest2[1] : '').trim();
        final parsed = _mergeStatusAndNumstat(
          status: status,
          numstat: numstat,
          diff: diff,
        );
        state = WorkspaceDiffState(
          loading: false,
          cwd: cwd,
          branch: branch,
          status: status,
          unifiedDiff: diff,
          files: parsed.isEmpty && branch.isEmpty && status.isEmpty
              ? _latestTurnFallbackFiles()
              : parsed,
        );
        return;
      }

      final res = await RuntimeBridge.instance.gitDiffDetailed(cwd);
      if (!ref.mounted || token != _refreshToken) return;
      final branch = res.branch.trim();
      final status = res.status.trim();
      final diff = res.diff.trim();
      final files = res.files.isEmpty && branch.isEmpty && status.isEmpty
          ? _latestTurnFallbackFiles()
          : res.files;
      state = WorkspaceDiffState(
        loading: false,
        cwd: cwd,
        branch: branch,
        status: status,
        unifiedDiff: diff.isNotEmpty
            ? diff
            : files
                .map((f) => f.diff ?? '')
                .where((d) => d.trim().isNotEmpty)
                .join('\n'),
        files: files,
      );
    } catch (_) {
      if (!ref.mounted || token != _refreshToken) return;
      state = state.copyWith(loading: false, cwd: cwd);
    }
  }

  static List<FileChangeEntry> _mergeStatusAndNumstat({
    required String status,
    required String numstat,
    required String diff,
  }) {
    final created = <String>{};
    final deleted = <String>{};
    for (final line in status.split('\n')) {
      if (line.length < 4) continue;
      final code = line.substring(0, 2);
      var path = line.substring(3).trim();
      if (path.contains(' -> ')) {
        path = path.split(' -> ').last.trim();
      }
      if (path.startsWith('"') && path.endsWith('"') && path.length >= 2) {
        path = path.substring(1, path.length - 1);
      }
      if (path.isEmpty) continue;
      if (code.contains('?') || code.contains('A') || code.contains('R')) {
        created.add(path);
      }
      if (code.contains('D')) deleted.add(path);
    }
    final files = FileChangeEntry.parseGitNumstat(
      numstat,
      createdPaths: created,
      deletedPaths: deleted,
    );
    final seen = files.map((f) => f.path).toSet();
    for (final path in created) {
      if (!seen.contains(path)) {
        files.add(FileChangeEntry(path: path, created: true));
      }
    }
    return FileChangeEntry.attachUnifiedDiffs(files, diff);
  }
}
