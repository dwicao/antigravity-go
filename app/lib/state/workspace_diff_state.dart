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
/// latest assistant turn fallback) with per-session & per-CWD caching so
/// switching chats updates the bottom-of-chat mini-view instantaneously.
class WorkspaceDiffNotifier extends Notifier<WorkspaceDiffState> {
  static const Duration _cwdCacheTtl = Duration(milliseconds: 1200);
  static const int _maxCacheEntries = 24;

  int _refreshToken = 0;
  bool _scheduledCoalesced = false;
  bool _pendingForce = false;
  String? _currentSessionId;
  final Map<String, WorkspaceDiffState> _sessionCache = {};
  final Map<String, ({WorkspaceDiffState state, DateTime fetchedAt})> _cwdCache =
      {};

  @override
  WorkspaceDiffState build() {
    _currentSessionId = ref.read(sessionsProvider).activeSessionId;

    ref.listen<String?>(
      sessionsProvider.select((s) => s.activeSessionId),
      (prev, next) {
        if (prev != next) {
          _onSessionSwitch(prev, next);
        }
      },
    );
    ref.listen<String>(
      sessionsProvider.select((s) => s.activeSession?.workspacePath ?? ''),
      (prev, next) {
        if (prev != next) _scheduleRefresh();
      },
    );
    ref.listen<String?>(
      chatProvider.select((c) => c.loadedSessionId),
      (prev, next) {
        if (prev != next) {
          _applyInstantSessionSnapshot(next);
          _scheduleRefresh();
        }
      },
    );
    ref.listen<String>(
      projectsProvider.select((p) => p.activeProject.primaryFolder),
      (prev, next) {
        if (prev != next) _scheduleRefresh();
      },
    );
    ref.listen<String?>(
      hostsProvider.select((h) => h.activeSshHost?.id),
      (prev, next) {
        if (prev != next) _scheduleRefresh(force: true);
      },
    );
    ref.listen<String?>(
      runtimeProvider.select((r) => r.status.workspaceRoot),
      (prev, next) {
        if (prev != next) _scheduleRefresh();
      },
    );
    ref.listen<bool>(
      chatProvider.select((c) => c.isStreaming),
      (prev, next) {
        if (prev == true && next == false) {
          _scheduleRefresh(force: true);
        }
      },
    );
    ref.listen<int>(
      chatProvider.select((c) => _latestTurnSignature(c.messages)),
      (prev, next) {
        if (prev != next) {
          _scheduleRefresh(force: true);
        }
      },
    );

    _scheduleRefresh();
    return const WorkspaceDiffState();
  }

  void _onSessionSwitch(String? prevId, String? nextId) {
    if (prevId != null && prevId.isNotEmpty) {
      _putSessionCache(prevId, state);
    }
    _currentSessionId = nextId;
    _applyInstantSessionSnapshot(nextId);
    _scheduleRefresh();
  }

  void _applyInstantSessionSnapshot(String? sessionId) {
    final primaryCwd = resolveActiveCwd();
    final cachedSession =
        sessionId != null ? _sessionCache[sessionId] : null;
    if (cachedSession != null &&
        (primaryCwd.isEmpty ||
            cachedSession.cwd.isEmpty ||
            cachedSession.cwd == primaryCwd)) {
      state = cachedSession.copyWith(loading: false);
      return;
    }

    final cachedCwd = primaryCwd.isNotEmpty ? _cwdCache[primaryCwd]?.state : null;
    if (cachedCwd != null) {
      state = cachedCwd.copyWith(loading: false);
      return;
    }

    // Never keep stale files from the previous chat while refreshing.
    final fallback = _latestTurnFallbackFiles();
    state = WorkspaceDiffState(
      loading: false,
      cwd: primaryCwd,
      files: fallback,
      unifiedDiff: _joinFileDiffs(fallback),
    );
  }

  void _scheduleRefresh({bool force = false}) {
    if (force) _pendingForce = true;
    if (_scheduledCoalesced) return;
    _scheduledCoalesced = true;
    Future.microtask(() {
      _scheduledCoalesced = false;
      final shouldForce = _pendingForce;
      _pendingForce = false;
      if (ref.mounted) {
        unawaited(refresh(force: shouldForce));
      }
    });
  }

  void _putSessionCache(String sessionId, WorkspaceDiffState value) {
    if (_sessionCache.length >= _maxCacheEntries &&
        !_sessionCache.containsKey(sessionId)) {
      _sessionCache.remove(_sessionCache.keys.first);
    }
    _sessionCache[sessionId] = value.copyWith(loading: false);
  }

  void _putCwdCache(String cwd, WorkspaceDiffState value) {
    if (cwd.isEmpty) return;
    if (_cwdCache.length >= _maxCacheEntries && !_cwdCache.containsKey(cwd)) {
      _cwdCache.remove(_cwdCache.keys.first);
    }
    _cwdCache[cwd] = (
      state: value.copyWith(loading: false),
      fetchedAt: DateTime.now(),
    );
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

  List<String> _recentToolCwds() {
    final seen = <String>{};
    final out = <String>[];
    void addPath(String? raw) {
      final p = raw?.trim() ?? '';
      if (p.isNotEmpty && seen.add(p)) out.add(p);
    }

    final msgs = ref.read(chatProvider).messages;
    for (var i = msgs.length - 1; i >= 0 && i >= msgs.length - 4; i--) {
      final m = msgs[i];
      for (final f in m.changedFiles) {
        if (f.path.startsWith('/')) {
          addPath(File(f.path).parent.path);
        }
      }
      for (final t in m.tools) {
        final toolCwd = t.parameters['Cwd'] ??
            t.parameters['cwd'] ??
            t.parameters['workdir'];
        if (toolCwd != null) addPath(toolCwd.toString());
        final rawFile = t.parameters['TargetFile'] ??
            t.parameters['AbsolutePath'] ??
            t.parameters['path'] ??
            t.parameters['file_path'];
        final fileStr = rawFile?.toString().trim() ?? '';
        if (fileStr.startsWith('/')) {
          addPath(File(fileStr).parent.path);
        }
      }
    }
    return out;
  }

  List<String> _fallbackProjectCwds() {
    final seen = <String>{};
    final out = <String>[];
    void addCandidate(String? raw) {
      final p = raw?.trim() ?? '';
      if (p.isEmpty) return;
      if (seen.add(p)) out.add(p);
    }

    final project = ref.read(projectsProvider).activeProject;
    addCandidate(project.primaryFolder);
    for (final folder in project.folders) {
      addCandidate(folder);
    }
    addCandidate(ref.read(runtimeProvider).status.workspaceRoot);
    return out;
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

  static String _joinFileDiffs(List<FileChangeEntry> files) {
    return files
        .map((f) => f.diff ?? '')
        .where((d) => d.trim().isNotEmpty)
        .join('\n');
  }

  Future<void> refresh({bool showLoading = false, bool force = false}) async {
    if (!ref.mounted) return;
    final token = ++_refreshToken;
    final activeSid =
        ref.read(sessionsProvider).activeSessionId ?? _currentSessionId;
    final primaryCwd = resolveActiveCwd();
    final sshHost = ref.read(hostsProvider).activeSshHost;

    if (!force && sshHost == null && primaryCwd.isNotEmpty) {
      final cached = _cwdCache[primaryCwd];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _cwdCacheTtl) {
        final fallback = _latestTurnFallbackFiles();
        final effective =
            cached.state.files.isNotEmpty ? cached.state.files : fallback;
        final nextState = cached.state.copyWith(
          loading: false,
          files: effective,
          unifiedDiff: cached.state.unifiedDiff.isNotEmpty
              ? cached.state.unifiedDiff
              : _joinFileDiffs(effective),
        );
        state = nextState;
        if (activeSid != null) _putSessionCache(activeSid, nextState);
        return;
      }
    }

    if (showLoading) {
      state = state.copyWith(loading: true, cwd: primaryCwd);
    }

    if (primaryCwd.isEmpty && sshHost == null) {
      final fallback = _latestTurnFallbackFiles();
      if (!ref.mounted || token != _refreshToken) return;
      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: '',
        files: fallback,
        unifiedDiff: _joinFileDiffs(fallback),
      );
      state = nextState;
      if (activeSid != null) _putSessionCache(activeSid, nextState);
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
        final nextState = WorkspaceDiffState(
          loading: false,
          cwd: primaryCwd,
          branch: branch,
          status: status,
          unifiedDiff:
              diff.isNotEmpty ? diff : _joinFileDiffs(effectiveFiles),
          files: effectiveFiles,
        );
        state = nextState;
        if (activeSid != null) _putSessionCache(activeSid, nextState);
        return;
      }

      String chosenCwd = primaryCwd;
      String chosenBranch = '';
      String chosenStatus = '';
      String chosenDiff = '';
      List<FileChangeEntry> chosenFiles = const [];

      final primaryRes = await RuntimeBridge.instance.gitDiffDetailed(primaryCwd);
      if (!ref.mounted || token != _refreshToken) return;
      chosenBranch = primaryRes.branch.trim();
      chosenStatus = primaryRes.status.trim();
      chosenDiff = primaryRes.diff.trim();
      chosenFiles = primaryRes.files;

      final primaryHasChanges =
          chosenFiles.isNotEmpty || chosenStatus.isNotEmpty || chosenDiff.isNotEmpty;

      if (!primaryHasChanges) {
        final isPrimaryRealRepo =
            chosenBranch.isNotEmpty && chosenBranch != 'shadow-checkpoint';
        final secondary = <String>{
          ..._recentToolCwds(),
          if (!isPrimaryRealRepo) ..._fallbackProjectCwds(),
        }..remove(primaryCwd);

        if (secondary.isNotEmpty) {
          final results = await Future.wait(
            secondary.map((c) async {
              final r = await RuntimeBridge.instance.gitDiffDetailed(c);
              return (cwd: c, res: r);
            }),
          );
          if (!ref.mounted || token != _refreshToken) return;
          for (final item in results) {
            final branch = item.res.branch.trim();
            final status = item.res.status.trim();
            final diff = item.res.diff.trim();
            if (chosenBranch.isEmpty && branch.isNotEmpty) {
              chosenCwd = item.cwd;
              chosenBranch = branch;
            }
            if (item.res.files.isNotEmpty ||
                status.isNotEmpty ||
                diff.isNotEmpty) {
              chosenCwd = item.cwd;
              chosenBranch = branch;
              chosenStatus = status;
              chosenDiff = diff;
              chosenFiles = item.res.files;
              break;
            }
          }
        }
      }

      final fallback = _latestTurnFallbackFiles();
      final effectiveFiles = chosenFiles.isNotEmpty ? chosenFiles : fallback;
      final effectiveDiff =
          chosenDiff.isNotEmpty ? chosenDiff : _joinFileDiffs(effectiveFiles);

      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: chosenCwd,
        branch: chosenBranch,
        status: chosenStatus,
        unifiedDiff: effectiveDiff,
        files: effectiveFiles,
      );
      state = nextState;
      _putCwdCache(primaryCwd, nextState);
      if (chosenCwd != primaryCwd) {
        _putCwdCache(chosenCwd, nextState);
      }
      if (activeSid != null) {
        _putSessionCache(activeSid, nextState);
      }
    } catch (_) {
      if (!ref.mounted || token != _refreshToken) return;
      final fallback = _latestTurnFallbackFiles();
      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: primaryCwd,
        files: fallback,
        unifiedDiff: _joinFileDiffs(fallback),
      );
      state = nextState;
      if (activeSid != null) _putSessionCache(activeSid, nextState);
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
