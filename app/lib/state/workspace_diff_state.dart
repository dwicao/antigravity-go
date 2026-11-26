import 'dart:async';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
  static const Duration _cwdCacheTtl = Duration(milliseconds: 1500);
  static const Duration _streamingThrottleInterval =
      Duration(milliseconds: 1500);
  static const int _maxCacheEntries = 24;

  int _refreshToken = 0;
  bool _scheduledCoalesced = false;
  bool _pendingForce = false;
  bool _refreshInFlight = false;
  Timer? _streamingThrottleTimer;
  String? _currentSessionId;
  final Map<String, WorkspaceDiffState> _sessionCache = {};
  final Map<String, ({WorkspaceDiffState state, DateTime fetchedAt})> _cwdCache =
      {};
  final Map<String, Set<String>> _committedPathsBySession = {};

  @visibleForTesting
  bool get hasPendingStreamingThrottleForTest =>
      _streamingThrottleTimer?.isActive == true;

  @override
  WorkspaceDiffState build() {
    _currentSessionId = ref.read(sessionsProvider).activeSessionId;
    ref.onDispose(() {
      _streamingThrottleTimer?.cancel();
      _streamingThrottleTimer = null;
    });

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
          _streamingThrottleTimer?.cancel();
          _streamingThrottleTimer = null;
          _applyInstantChatResultMerge();
          _scheduleRefresh(force: true);
        }
      },
    );
    ref.listen<int>(
      chatProvider.select((c) => _messagesSignature(c.messages)),
      (prev, next) {
        if (prev != next) {
          if (ref.read(chatProvider).isStreaming) {
            _scheduleStreamingRefresh();
          } else {
            _streamingThrottleTimer?.cancel();
            _streamingThrottleTimer = null;
            _applyInstantChatResultMerge();
            _scheduleRefresh(force: true);
          }
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
    if (chatFiles.isEmpty) {
      if (state.branch.isEmpty &&
          state.status.isEmpty &&
          state.files.isNotEmpty) {
        state = state.copyWith(files: const [], unifiedDiff: '');
      }
      return;
    }
    final merged = _mergeGitAndChatFiles(state.files, chatFiles);
    _emitIfChanged(
      state.copyWith(
        files: merged,
        unifiedDiff: state.unifiedDiff.isNotEmpty
            ? state.unifiedDiff
            : _joinFileDiffs(merged),
      ),
    );
  }

  void _scheduleStreamingRefresh() {
    if (_streamingThrottleTimer?.isActive == true) return;
    _streamingThrottleTimer = Timer(_streamingThrottleInterval, () {
      _streamingThrottleTimer = null;
      if (!ref.mounted) return;
      _applyInstantChatResultMerge();
      if (!_refreshInFlight) {
        _scheduleRefresh(force: true);
      }
    });
  }

  void _emitIfChanged(WorkspaceDiffState next) {
    if (!_sameStateSummary(state, next)) {
      state = next;
    }
  }

  static bool _sameStateSummary(WorkspaceDiffState a, WorkspaceDiffState b) {
    if (a.loading != b.loading ||
        a.cwd != b.cwd ||
        a.branch != b.branch ||
        a.status != b.status ||
        a.unifiedDiff.length != b.unifiedDiff.length ||
        a.files.length != b.files.length) {
      return false;
    }
    for (var i = 0; i < a.files.length; i++) {
      final fa = a.files[i];
      final fb = b.files[i];
      if (fa.path != fb.path ||
          fa.added != fb.added ||
          fa.removed != fb.removed ||
          fa.created != fb.created ||
          fa.deleted != fb.deleted) {
        return false;
      }
    }
    return true;
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
    if (messages.isEmpty) return 0;
    final last = messages.last;
    var completedEditTools = 0;
    for (final t in last.tools) {
      if (t.state == ToolCallState.completed &&
          (ChatTurnHelpers.isFileEditTool(t) ||
              ChatTurnHelpers.hasSuccessfulGitCommit(t))) {
        completedEditTools++;
      }
    }
    return Object.hash(
      messages.length,
      last.id,
      last.isStreaming,
      last.changedFiles.length,
      completedEditTools,
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
    final out = <FileChangeEntry>[];
    for (final gf in gitFiles) {
      FileChangeEntry? matchingChat;
      for (final cf in chatFiles) {
        if (_pathsReferToSameFile(gf.path, cf.path)) {
          matchingChat = cf;
          break;
        }
      }
      if (matchingChat != null &&
          ((gf.diff == null || gf.diff!.trim().isEmpty) ||
              (gf.added == 0 &&
                  gf.removed == 0 &&
                  (matchingChat.added > 0 || matchingChat.removed > 0)))) {
        out.add(
          FileChangeEntry(
            path: gf.path,
            added: gf.added > 0 ? gf.added : matchingChat.added,
            removed: gf.removed > 0 ? gf.removed : matchingChat.removed,
            created: gf.created || matchingChat.created,
            deleted: gf.deleted || matchingChat.deleted,
            diff: (gf.diff != null && gf.diff!.trim().isNotEmpty)
                ? gf.diff
                : matchingChat.diff,
          ),
        );
      } else {
        out.add(gf);
      }
    }
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

  static String _canonicalStoragePath(String normPath) {
    if (normPath == '/storage/emulated/0') return '/sdcard';
    if (normPath.startsWith('/storage/emulated/0/')) {
      return '/sdcard/${normPath.substring('/storage/emulated/0/'.length)}';
    }
    return normPath;
  }

  static bool _isPathInsideRepo(String filePath, String repoCwd) {
    final nf = _canonicalStoragePath(_normalizePath(filePath));
    final nr = _canonicalStoragePath(_normalizePath(repoCwd));
    if (nf.isEmpty || nr.isEmpty) return false;
    return nf == nr || nf.startsWith('$nr/');
  }

  static List<FileChangeEntry> filterChatFilesAgainstCheckedRepos(
    List<FileChangeEntry> chatFiles,
    List<({String cwd, String branch, List<FileChangeEntry> files})> checkedRepos,
    String primaryCwd,
  ) {
    if (chatFiles.isEmpty || checkedRepos.isEmpty) return chatFiles;
    final realRepos = checkedRepos
        .where((r) => r.branch.isNotEmpty && r.branch != 'shadow-checkpoint')
        .toList();
    if (realRepos.isEmpty) return chatFiles;
    return chatFiles.where((cf) {
      final normPath = _normalizePath(cf.path);
      final isRelative = !normPath.startsWith('/');
      for (final repo in realRepos) {
        final covers = isRelative
            ? repo.cwd == primaryCwd
            : _isPathInsideRepo(normPath, repo.cwd);
        if (!covers) continue;
        final presentInGit =
            repo.files.any((gf) => _pathsReferToSameFile(gf.path, normPath));
        if (!presentInGit) {
          return false;
        }
      }
      return true;
    }).toList(growable: false);
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
      if (m.isCompactionSummary || m.text.startsWith('**Committed')) break;
      final List<FileChangeEntry> turnEntries;
      var stopAfterTurn = false;
      if (m.tools.isNotEmpty) {
        final uncommitted =
            ChatTurnHelpers.extractUncommittedFilesFromTools(m.tools);
        if (uncommitted.committed) {
          stopAfterTurn = true;
          turnEntries = uncommitted.files;
        } else {
          turnEntries = m.changedFiles.isNotEmpty
              ? m.changedFiles
              : uncommitted.files;
        }
      } else {
        turnEntries = m.changedFiles;
      }
      for (final f in turnEntries) {
        final norm = _normalizePath(f.path);
        if (norm.isEmpty || committed.contains(norm)) continue;
        byPath.putIfAbsent(norm, () => f);
      }
      if (stopAfterTurn || byPath.isNotEmpty) break;
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
    _refreshInFlight = true;
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
        _emitIfChanged(nextState);
        if (activeSid != null) _putSessionCache(activeSid, nextState);
        _refreshInFlight = false;
        return;
      }
    }

    if (showLoading) {
      state = state.copyWith(loading: true, cwd: primaryCwd);
    }

    if (primaryCwd.isEmpty && sshHost == null) {
      if (!ref.mounted || token != _refreshToken) {
        _refreshInFlight = false;
        return;
      }
      final nextState = WorkspaceDiffState(
        loading: false,
        cwd: '',
        files: chatFiles,
        unifiedDiff: _joinFileDiffs(chatFiles),
      );
      _emitIfChanged(nextState);
      if (activeSid != null) _putSessionCache(activeSid, nextState);
      _refreshInFlight = false;
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
        final status = rest1.first.trimRight();
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
      chosenStatus = primaryRes.status.trimRight();
      chosenDiff = primaryRes.diff.trim();
      chosenFiles = primaryRes.files;
      final checkedRepos =
          <({String cwd, String branch, List<FileChangeEntry> files})>[
        if (primaryCwd.isNotEmpty)
          (cwd: primaryCwd, branch: chosenBranch, files: chosenFiles),
      ];

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
        final secondary = (<String>{
          ..._recentToolCwds(),
          if (!isPrimaryRealRepo && !primaryHasChanges) ..._fallbackProjectCwds(),
        }..remove(primaryCwd))
            .take(2)
            .toList(growable: false);

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
            final status = item.res.status.trimRight();
            final diff = item.res.diff.trim();
            checkedRepos.add(
              (cwd: item.cwd, branch: branch, files: item.res.files),
            );
            if (chosenBranch.isEmpty && branch.isNotEmpty) {
              chosenCwd = item.cwd;
              chosenBranch = branch;
            }
            if (item.res.files.isNotEmpty ||
                status.isNotEmpty ||
                diff.isNotEmpty) {
              if (!primaryHasChanges && chosenFiles.isEmpty && chosenDiff.isEmpty) {
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
              final stillMissing = latestChatFiles.any(
                (cf) =>
                    !chosenFiles.any((gf) => _pathsReferToSameFile(gf.path, cf.path)),
              );
              if (!stillMissing) break;
            }
          }
        }
      }

      final effectiveChatFiles = filterChatFilesAgainstCheckedRepos(
        latestChatFiles,
        checkedRepos,
        primaryCwd,
      );
      final effectiveFiles =
          _mergeGitAndChatFiles(chosenFiles, effectiveChatFiles);
      final extraChatDiffs = effectiveChatFiles
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
      _emitIfChanged(nextState);
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
      _emitIfChanged(nextState);
      if (activeSid != null) _putSessionCache(activeSid, nextState);
    } finally {
      if (token == _refreshToken) {
        _refreshInFlight = false;
      }
    }
  }

  static List<FileChangeEntry> _mergeStatusAndNumstat({
    required String status,
    required String numstat,
    required String diff,
  }) {
    return FileChangeEntry.fromGitOutputs(
      status: status,
      numstat: numstat,
      diff: diff,
    );
  }
}
