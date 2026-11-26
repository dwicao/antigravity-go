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

/// Tracks live uncommitted workspace changes (standard Git, Shadow Git, SSH, and
/// chat-result `changedFiles` / file-edit tool outputs) with per-session &
/// per-CWD caching so the bottom-of-chat mini-view updates instantaneously and
/// always reflects files changed in the active chat result.
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
  final Map<String, Set<String>> _committedPathsBySession = {};

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
      chatProvider.select((c) => _messagesSignature(c.messages)),
      (prev, next) {
        if (prev != next) {
          _applyInstantChatResultMerge();
          _scheduleRefresh(force: true);
        }
      },
    );

    _scheduleRefresh();
    return const WorkspaceDiffState();
  }

  /// Marks [files] as committed for the active session so chat-turn fallback
  /// entries don't reappear as uncommitted after Commit & Push.
  void markCommitted(List<FileChangeEntry> files) {
    final sid = ref.read(sessionsProvider).activeSessionId ?? _currentSessionId;
    if (sid != null && sid.isNotEmpty) {
      final set = _committedPathsBySession.putIfAbsent(sid, () => <String>{});
      for (final f in files) {
        set.add(_normalizePath(f.path));
      }
    }
    _cwdCache.clear();
    if (sid != null) _sessionCache.remove(sid);
    unawaited(refresh(force: true));
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
    final chatFiles = _sessionChatResultFiles(sessionId: sessionId);
    final cachedSession =
        sessionId != null ? _sessionCache[sessionId] : null;
    if (cachedSession != null &&
        (primaryCwd.isEmpty ||
            cachedSession.cwd.isEmpty ||
            cachedSession.cwd == primaryCwd)) {
      final merged = _mergeGitAndChatFiles(cachedSession.files, chatFiles);
      state = cachedSession.copyWith(
        loading: false,
        files: merged,
        unifiedDiff: cachedSession.unifiedDiff.isNotEmpty
            ? cachedSession.unifiedDiff
            : _joinFileDiffs(merged),
      );
      return;
    }

    final cachedCwd = primaryCwd.isNotEmpty ? _cwdCache[primaryCwd]?.state : null;
    if (cachedCwd != null) {
      final merged = _mergeGitAndChatFiles(cachedCwd.files, chatFiles);
      state = cachedCwd.copyWith(
        loading: false,
        files: merged,
        unifiedDiff: cachedCwd.unifiedDiff.isNotEmpty
            ? cachedCwd.unifiedDiff
            : _joinFileDiffs(merged),
      );
      return;
    }

    state = WorkspaceDiffState(
      loading: false,
      cwd: primaryCwd,
      files: chatFiles,
      unifiedDiff: _joinFileDiffs(chatFiles),
    );
  }

  void _applyInstantChatResultMerge() {
    final sid = ref.read(sessionsProvider).activeSessionId ?? _currentSessionId;
    final chatFiles = _sessionChatResultFiles(sessionId: sid);
    if (chatFiles.isEmpty) return;
    final merged = _mergeGitAndChatFiles(state.files, chatFiles);
    if (merged.length != state.files.length) {
      state = state.copyWith(
        files: merged,
        unifiedDiff: state.unifiedDiff.isNotEmpty
            ? state.unifiedDiff
            : _joinFileDiffs(merged),
      );
    }
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

  static int _messagesSignature(List<ChatMessage> messages) {
    var totalChanged = 0;
    var completedTools = 0;
    for (final m in messages) {
      totalChanged += m.changedFiles.length;
      for (final t in m.tools) {
        if (t.state == ToolCallState.completed) completedTools++;
      }
    }
    final last = messages.isEmpty ? null : messages.last;
    return Object.hash(
      messages.length,
      totalChanged,
      completedTools,
      last?.id,
      last?.isStreaming,
      last?.tools.length,
    );
  }

  static String _normalizePath(String raw) {
    return raw.trim().replaceAll('\\', '/').replaceFirst(RegExp(r'^\./+'), '');
  }

  static bool _pathsReferToSameFile(String a, String b) {
    final na = _normalizePath(a);
    final nb = _normalizePath(b);
    if (na == nb) return true;
    if (na.isEmpty || nb.isEmpty) return false;
    return na.endsWith('/$nb') || nb.endsWith('/$na');
  }

  /// Merges live git working-tree entries with file changes reported in the
  /// active chat's result so chat-reported changes always reflect in the
  /// bottom-of-chat mini-view while preferring live git line stats/diffs.
  static List<FileChangeEntry> _mergeGitAndChatFiles(
    List<FileChangeEntry> gitFiles,
    List<FileChangeEntry> chatFiles,
  ) {
    if (chatFiles.isEmpty) return gitFiles;
    if (gitFiles.isEmpty) return chatFiles;
    final out = <FileChangeEntry>[...gitFiles];
    for (final cf in chatFiles) {
      final alreadyInGit =
          out.any((gf) => _pathsReferToSameFile(gf.path, cf.path));
      if (!alreadyInGit) {
        out.add(cf);
      }
    }
    return out;
  }

  List<String> _recentToolCwds() {
    final seen = <String>{};
    final out = <String>[];
    void addPath(String? raw) {
      final p = raw?.trim() ?? '';
      if (p.isNotEmpty && seen.add(p)) out.add(p);
    }

    final msgs = ref.read(chatProvider).messages;
    for (var i = msgs.length - 1; i >= 0 && i >= msgs.length - 6; i--) {
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

  List<FileChangeEntry> _sessionChatResultFiles({String? sessionId}) {
    final chat = ref.read(chatProvider);
    final sid =
        sessionId ?? ref.read(sessionsProvider).activeSessionId ?? _currentSessionId;
    if (chat.loadedSessionId != null &&
        sid != null &&
        chat.loadedSessionId != sid) {
      return const [];
    }
    final committed =
        sid == null ? const <String>{} : (_committedPathsBySession[sid] ?? const <String>{});
    final msgs = chat.messages;
    final byPath = <String, FileChangeEntry>{};
    for (var i = msgs.length - 1; i >= 0; i--) {
      final m = msgs[i];
      if (m.role != ChatRole.assistant) continue;
      if (m.text.startsWith('**Committed')) break;
      final turnEntries = m.changedFiles.isNotEmpty
          ? m.changedFiles
          : ChatTurnHelpers.extractChangedFilesFromTools(m.tools);
      for (final f in turnEntries) {
        final norm = _normalizePath(f.path);
        if (norm.isEmpty || committed.contains(norm)) continue;
        byPath.putIfAbsent(norm, () => f);
      }
      if (byPath.isNotEmpty) break;
    }
    return byPath.values.toList(growable: false);
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
    final chatFiles = _sessionChatResultFiles(sessionId: activeSid);

    if (!force && sshHost == null && primaryCwd.isNotEmpty) {
      final cached = _cwdCache[primaryCwd];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _cwdCacheTtl) {
        final effective = _mergeGitAndChatFiles(cached.state.files, chatFiles);
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
      if (!ref.mounted || token != _refreshToken) return;
      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: '',
        files: chatFiles,
        unifiedDiff: _joinFileDiffs(chatFiles),
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
        final latestChatFiles = _sessionChatResultFiles(sessionId: activeSid);
        final effectiveFiles = _mergeGitAndChatFiles(parsed, latestChatFiles);
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

      // Also check tool-edited directories when primaryCwd is clean OR when
      // the chat result reports files not yet found in primaryCwd.
      final latestChatFiles = _sessionChatResultFiles(sessionId: activeSid);
      final hasUnmatchedChatFiles = latestChatFiles.any(
        (cf) => !chosenFiles.any((gf) => _pathsReferToSameFile(gf.path, cf.path)),
      );

      if (!primaryHasChanges || hasUnmatchedChatFiles) {
        final isPrimaryRealRepo =
            chosenBranch.isNotEmpty && chosenBranch != 'shadow-checkpoint';
        final secondary = <String>{
          ..._recentToolCwds(),
          if (!isPrimaryRealRepo && !primaryHasChanges) ..._fallbackProjectCwds(),
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
              if (!primaryHasChanges) {
                chosenCwd = item.cwd;
                chosenBranch = branch;
                chosenStatus = status;
                chosenDiff = diff;
                chosenFiles = item.res.files;
              } else {
                chosenFiles = _mergeGitAndChatFiles(chosenFiles, item.res.files);
                if (diff.isNotEmpty) {
                  chosenDiff = '$chosenDiff\n$diff'.trim();
                }
              }
              break;
            }
          }
        }
      }

      final effectiveFiles = _mergeGitAndChatFiles(chosenFiles, latestChatFiles);
      final extraChatDiffs = latestChatFiles
          .where(
            (cf) =>
                !chosenFiles.any((gf) => _pathsReferToSameFile(gf.path, cf.path)),
          )
          .map((f) => f.diff ?? '')
          .where((d) => d.trim().isNotEmpty)
          .join('\n');
      final effectiveDiff = [
        if (chosenDiff.isNotEmpty) chosenDiff,
        if (chosenDiff.isEmpty && chosenFiles.isNotEmpty)
          _joinFileDiffs(chosenFiles),
        if (extraChatDiffs.isNotEmpty) extraChatDiffs,
      ].join('\n').trim();

      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: chosenCwd,
        branch: chosenBranch,
        status: chosenStatus,
        unifiedDiff: effectiveDiff,
        files: effectiveFiles,
      );
      state = nextState;
      _putCwdCache(primaryCwd, WorkspaceDiffState(
        cwd: chosenCwd,
        branch: chosenBranch,
        status: chosenStatus,
        unifiedDiff: chosenDiff,
        files: chosenFiles,
      ));
      if (chosenCwd != primaryCwd) {
        _putCwdCache(chosenCwd, WorkspaceDiffState(
          cwd: chosenCwd,
          branch: chosenBranch,
          status: chosenStatus,
          unifiedDiff: chosenDiff,
          files: chosenFiles,
        ));
      }
      if (activeSid != null) {
        _putSessionCache(activeSid, nextState);
      }
    } catch (_) {
      if (!ref.mounted || token != _refreshToken) return;
      final latestChatFiles = _sessionChatResultFiles(sessionId: activeSid);
      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: primaryCwd,
        files: latestChatFiles,
        unifiedDiff: _joinFileDiffs(latestChatFiles),
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
