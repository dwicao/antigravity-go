import 'dart:async';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'chat_state.dart';
import 'chat_turn_helpers.dart';
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
      files.isNotEmpty ||
      unifiedDiff.trim().isNotEmpty ||
      status.trim().isNotEmpty;

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
      chatProvider.select((c) => _latestTurnSignature(c.messages)),
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

  static int _latestTurnSignature(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role == ChatRole.assistant) {
        final completedTools =
            m.tools.where((t) => t.state == ToolCallState.completed).length;
        return Object.hash(
          messages.length,
          m.id,
          m.isStreaming,
          m.changedFiles.length,
          m.tools.length,
          completedTools,
        );
      }
    }
    return messages.length;
  }

  List<String> _candidateLocalCwds() {
    final seen = <String>{};
    final out = <String>[];
    void addCandidate(String? raw) {
      final p = raw?.trim() ?? '';
      if (p.isEmpty) return;
      if (seen.add(p)) out.add(p);
    }

    addCandidate(ref.read(sessionsProvider).activeSession?.workspacePath);
    final project = ref.read(projectsProvider).activeProject;
    addCandidate(project.primaryFolder);
    for (final folder in project.folders) {
      addCandidate(folder);
    }
    addCandidate(ref.read(runtimeProvider).status.workspaceRoot);

    // Also inspect tool working directories or edited file parents from the
    // most recent assistant turns in case files were edited outside session CWD.
    final msgs = ref.read(chatProvider).messages;
    for (var i = msgs.length - 1; i >= 0 && i >= msgs.length - 4; i--) {
      final m = msgs[i];
      for (final f in m.changedFiles) {
        if (f.path.startsWith('/')) {
          addCandidate(File(f.path).parent.path);
        }
      }
      for (final t in m.tools) {
        final toolCwd = t.parameters['Cwd'] ??
            t.parameters['cwd'] ??
            t.parameters['workdir'];
        if (toolCwd != null) addCandidate(toolCwd.toString());
        final rawFile = t.parameters['TargetFile'] ??
            t.parameters['AbsolutePath'] ??
            t.parameters['path'] ??
            t.parameters['file_path'];
        final fileStr = rawFile?.toString().trim() ?? '';
        if (fileStr.startsWith('/')) {
          addCandidate(File(fileStr).parent.path);
        }
      }
    }

    return out;
  }

  String resolveActiveCwd() {
    final sshWs =
        ref.read(hostsProvider).activeSshHost?.defaultWorkspace.trim() ?? '';
    final candidates = _candidateLocalCwds();
    if (candidates.isNotEmpty) return candidates.first;
    return sshWs;
  }

  List<FileChangeEntry> _latestTurnFallbackFiles() {
    final msgs = ref.read(chatProvider).messages;
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.role == ChatRole.user) break;
      if (m.changedFiles.isNotEmpty) {
        return m.changedFiles;
      }
      if (m.tools.isNotEmpty) {
        final extracted = ChatTurnHelpers.extractChangedFilesFromTools(m.tools);
        if (extracted.isNotEmpty) return extracted;
      }
    }
    return const [];
  }

  Future<void> refresh({bool showLoading = false}) async {
    if (!ref.mounted) return;
    final token = ++_refreshToken;
    final primaryCwd = resolveActiveCwd();
    final sshHost = ref.read(hostsProvider).activeSshHost;

    if (showLoading) {
      state = state.copyWith(loading: true, cwd: primaryCwd);
    }

    if (primaryCwd.isEmpty && sshHost == null) {
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
          cwd: primaryCwd,
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
        final fallback = _latestTurnFallbackFiles();
        final effectiveFiles = parsed.isNotEmpty ? parsed : fallback;
        state = WorkspaceDiffState(
          loading: false,
          cwd: primaryCwd,
          branch: branch,
          status: status,
          unifiedDiff: diff.isNotEmpty
              ? diff
              : effectiveFiles
                  .map((f) => f.diff ?? '')
                  .where((d) => d.trim().isNotEmpty)
                  .join('\n'),
          files: effectiveFiles,
        );
        return;
      }

      final candidates = _candidateLocalCwds();
      String chosenCwd = primaryCwd;
      String chosenBranch = '';
      String chosenStatus = '';
      String chosenDiff = '';
      List<FileChangeEntry> chosenFiles = const [];

      for (final candidate in candidates) {
        final res = await RuntimeBridge.instance.gitDiffDetailed(candidate);
        if (!ref.mounted || token != _refreshToken) return;
        final branch = res.branch.trim();
        final status = res.status.trim();
        final diff = res.diff.trim();
        if (chosenBranch.isEmpty && branch.isNotEmpty) {
          chosenCwd = candidate;
          chosenBranch = branch;
        }
        if (res.files.isNotEmpty || status.isNotEmpty || diff.isNotEmpty) {
          chosenCwd = candidate;
          chosenBranch = branch;
          chosenStatus = status;
          chosenDiff = diff;
          chosenFiles = res.files;
          break;
        }
      }

      final fallback = _latestTurnFallbackFiles();
      final effectiveFiles =
          chosenFiles.isNotEmpty ? chosenFiles : fallback;
      final effectiveDiff = chosenDiff.isNotEmpty
          ? chosenDiff
          : effectiveFiles
              .map((f) => f.diff ?? '')
              .where((d) => d.trim().isNotEmpty)
              .join('\n');

      state = WorkspaceDiffState(
        loading: false,
        cwd: chosenCwd,
        branch: chosenBranch,
        status: chosenStatus,
        unifiedDiff: effectiveDiff,
        files: effectiveFiles,
      );
    } catch (_) {
      if (!ref.mounted || token != _refreshToken) return;
      final fallback = _latestTurnFallbackFiles();
      state = WorkspaceDiffState(
        loading: false,
        cwd: primaryCwd,
        files: fallback,
        unifiedDiff: fallback
            .map((f) => f.diff ?? '')
            .where((d) => d.trim().isNotEmpty)
            .join('\n'),
      );
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
