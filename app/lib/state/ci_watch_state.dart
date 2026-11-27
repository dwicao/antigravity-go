import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'hosts_state.dart';

class CiWatchItem {
  const CiWatchItem({
    required this.id,
    required this.cwd,
    required this.sessionId,
    required this.workflowName,
    required this.status,
    required this.startedAt,
    this.runId,
    this.branch,
    this.headSha,
    this.workflowNameFilter,
    this.htmlUrl,
    this.failedLog,
    this.suppressDefaultAutoFix = false,
  });

  final String id;
  final String cwd;
  final String sessionId;
  final String workflowName;
  final String status;
  final DateTime startedAt;
  final String? runId;
  final String? branch;
  final String? headSha;
  final String? workflowNameFilter;
  final String? htmlUrl;
  final String? failedLog;
  final bool suppressDefaultAutoFix;

  CiWatchItem copyWith({
    String? workflowName,
    String? status,
    String? runId,
    String? branch,
    String? headSha,
    String? workflowNameFilter,
    String? htmlUrl,
    String? failedLog,
    bool? suppressDefaultAutoFix,
  }) {
    return CiWatchItem(
      id: id,
      cwd: cwd,
      sessionId: sessionId,
      workflowName: workflowName ?? this.workflowName,
      status: status ?? this.status,
      startedAt: startedAt,
      runId: runId ?? this.runId,
      branch: branch ?? this.branch,
      headSha: headSha ?? this.headSha,
      workflowNameFilter: workflowNameFilter ?? this.workflowNameFilter,
      htmlUrl: htmlUrl ?? this.htmlUrl,
      failedLog: failedLog ?? this.failedLog,
      suppressDefaultAutoFix:
          suppressDefaultAutoFix ?? this.suppressDefaultAutoFix,
    );
  }
}

typedef CiShellRunner = Future<String> Function(String command, String cwd);
typedef CiCompletionCallback = Future<void> Function({
  required CiWatchItem watch,
  required bool passed,
  required String summaryMarkdown,
  String? autoFixPrompt,
});

final ciWatchProvider =
    NotifierProvider<CiWatchNotifier, List<CiWatchItem>>(CiWatchNotifier.new);

/// Automatically watches GitHub Actions CI after `git push`, exposes active
/// runs as cancellable background tasks, and feeds failure logs straight back
/// to the agent so CI failures are detected & fixed without user prompting.
class CiWatchNotifier extends Notifier<List<CiWatchItem>> {
  static const int _maxInitialMisses = 4;
  static const int _maxTrackedMisses = 10;
  static const Duration _maxWatchDuration = Duration(minutes: 45);

  final Map<String, Timer> _timers = {};
  final Map<String, int> _missCounts = {};
  final Set<String> _inFlightPolls = {};
  final Map<String, Future<void> Function(CiWatchItem watch, bool passed, String summaryMarkdown)>
      _customWatchCallbacks = {};
  CiShellRunner? shellRunnerOverride;
  CiCompletionCallback? onCompletedCallback;

  @override
  List<CiWatchItem> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
      _missCounts.clear();
      _inFlightPolls.clear();
      _customWatchCallbacks.clear();
    });
    return const [];
  }

  Future<String> _exec(String command, String cwd) async {
    if (shellRunnerOverride != null) {
      return shellRunnerOverride!(command, cwd);
    }
    final sshHost = ref.read(hostsProvider).activeSshHost;
    if (sshHost != null) {
      final (pwd, key) =
          await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
      return SshAgyRunner.instance.runRemoteCommand(
        host: sshHost,
        command: command,
        cwd: cwd,
        password: pwd,
        privateKeyPem: key,
      );
    }
    return RuntimeBridge.instance.runShellCommand(command: command, cwd: cwd);
  }

  static Object? _decodeJsonPayload(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final arrStart = trimmed.indexOf('[');
    final objStart = trimmed.indexOf('{');
    int start = -1;
    String closeChar = '';
    if (arrStart >= 0 && (objStart < 0 || arrStart < objStart)) {
      start = arrStart;
      closeChar = ']';
    } else if (objStart >= 0) {
      start = objStart;
      closeChar = '}';
    }
    if (start < 0) return null;
    final end = trimmed.lastIndexOf(closeChar);
    if (end <= start) return null;
    try {
      return jsonDecode(trimmed.substring(start, end + 1));
    } catch (_) {
      return null;
    }
  }

  void _recordMissOrExpire(String watchId, {required bool hasRunId}) {
    final misses = (_missCounts[watchId] ?? 0) + 1;
    _missCounts[watchId] = misses;
    final limit = hasRunId ? _maxTrackedMisses : _maxInitialMisses;
    if (misses >= limit) {
      cancelWatch(watchId);
    }
  }

  Future<String> watchLatestRun({
    required String cwd,
    required String sessionId,
    String? branch,
    String? headSha,
    String? workflowNameFilter,
    bool suppressDefaultAutoFix = false,
    Future<void> Function(
      CiWatchItem watch,
      bool passed,
      String summaryMarkdown,
    )? onDone,
  }) async {
    if (cwd.trim().isEmpty) return '';
    final watchId = 'ci:${DateTime.now().microsecondsSinceEpoch}';
    final initial = CiWatchItem(
      id: watchId,
      cwd: cwd,
      sessionId: sessionId,
      workflowName: workflowNameFilter?.trim().isNotEmpty == true
          ? workflowNameFilter!.trim()
          : 'GitHub Actions CI',
      status: 'queued',
      branch: branch,
      headSha: headSha,
      workflowNameFilter: workflowNameFilter,
      suppressDefaultAutoFix: suppressDefaultAutoFix,
      startedAt: DateTime.now(),
    );
    if (onDone != null) {
      _customWatchCallbacks[watchId] = onDone;
    }
    state = [...state, initial];

    // Poll cleanly without leaking if provider is disposed.
    _timers[watchId]?.cancel();
    _timers[watchId] = Timer.periodic(
      const Duration(seconds: 12),
      (_) => pollOnce(watchId),
    );
    await pollOnce(watchId);
    return watchId;
  }

  Future<void> pollOnce(String watchId) async {
    final idx = state.indexWhere((w) => w.id == watchId);
    if (idx < 0) {
      _timers.remove(watchId)?.cancel();
      _missCounts.remove(watchId);
      return;
    }
    final watch = state[idx];
    if (DateTime.now().difference(watch.startedAt) > _maxWatchDuration) {
      cancelWatch(watchId);
      return;
    }
    if (!_inFlightPolls.add(watchId)) return;

    try {
      final rawRunId = watch.runId?.trim() ?? '';
      final safeRunId =
          RegExp(r'^\d+$').hasMatch(rawRunId) ? rawRunId : '';
      final hasRunId = safeRunId.isNotEmpty;
      final cmd = hasRunId
          ? 'gh run view $safeRunId --json databaseId,workflowName,status,conclusion,url,headBranch,headSha 2>/dev/null || echo "{}"'
          : 'gh run list -L 8 --json databaseId,workflowName,status,conclusion,url,headBranch,headSha 2>/dev/null || echo "[]"';
      final raw = await _exec(cmd, watch.cwd);
      if (!ref.mounted) return;

      final decoded = _decodeJsonPayload(raw);
      Map<String, dynamic>? latest;
      if (decoded is Map<String, dynamic> && decoded.isNotEmpty) {
        latest = decoded;
      } else if (decoded is List<dynamic> && decoded.isNotEmpty) {
        var candidates = decoded.whereType<Map<String, dynamic>>().toList();
        final wfFilter = watch.workflowNameFilter?.trim().toLowerCase() ?? '';
        if (wfFilter.isNotEmpty) {
          final wfMatches = candidates
              .where(
                (r) => (r['workflowName']?.toString() ?? '')
                    .toLowerCase()
                    .contains(wfFilter),
              )
              .toList();
          if (wfMatches.isNotEmpty) {
            candidates = wfMatches;
          } else {
            candidates = const [];
          }
        }
        final shaFilter = watch.headSha?.trim().toLowerCase() ?? '';
        if (candidates.isNotEmpty && shaFilter.isNotEmpty) {
          final shaMatches = candidates
              .where(
                (r) {
                  final s = (r['headSha']?.toString() ?? '').toLowerCase();
                  return s.isNotEmpty &&
                      (s == shaFilter ||
                          s.startsWith(shaFilter) ||
                          shaFilter.startsWith(s));
                },
              )
              .toList();
          if (shaMatches.isNotEmpty) {
            candidates = shaMatches;
          } else if (candidates.any(
            (r) => (r['headSha']?.toString() ?? '').isNotEmpty,
          )) {
            // Wait for the pushed commit's run to appear rather than latching onto an older run.
            candidates = const [];
          }
        }
        if (candidates.isNotEmpty) {
          if (watch.branch != null && watch.branch!.isNotEmpty) {
            final branchMatches = candidates
                .where((r) => r['headBranch']?.toString() == watch.branch)
                .toList();
            if (branchMatches.isNotEmpty) {
              latest = branchMatches.first;
            } else if (wfFilter.isEmpty) {
              latest = candidates.first;
            }
          } else {
            latest = candidates.first;
          }
        }
      }

      if (latest == null) {
        _recordMissOrExpire(watchId, hasRunId: hasRunId);
        return;
      }
      _missCounts[watchId] = 0;

      final runId = latest['databaseId']?.toString() ?? watch.runId ?? '';
      final workflow =
          latest['workflowName']?.toString() ?? watch.workflowName;
      final status = latest['status']?.toString() ?? 'in_progress';
      final conclusion = latest['conclusion']?.toString() ?? '';
      final url = latest['url']?.toString() ?? watch.htmlUrl;
      final headBranch = latest['headBranch']?.toString() ?? watch.branch;

      final isCompleted = status.trim().toLowerCase() == 'completed' ||
          conclusion.trim().isNotEmpty;

      if (!isCompleted) {
        final curIdx = state.indexWhere((w) => w.id == watchId);
        if (curIdx >= 0) {
          final next = [...state];
          next[curIdx] = next[curIdx].copyWith(
            runId: runId.isNotEmpty ? runId : null,
            workflowName: workflow,
            status: status,
            branch: headBranch,
            htmlUrl: url,
          );
          state = next;
        }
        return;
      }

      // Run finished! Stop watching immediately and surface result / auto-fix trigger.
      _timers.remove(watchId)?.cancel();
      _missCounts.remove(watchId);
      final customCb = _customWatchCallbacks.remove(watchId);
      state = state.where((w) => w.id != watchId).toList();

      final normalizedConclusion =
          conclusion.trim().isEmpty ? 'completed' : conclusion.trim();
      final passed = normalizedConclusion.toLowerCase() == 'success';
      final validRunId = RegExp(r'^\d+$').hasMatch(runId) ? runId : '';
      String? failedLog;
      if (!passed && validRunId.isNotEmpty) {
        failedLog = (await _exec(
          'gh run view $validRunId --log-failed 2>&1 | tail -n 60 || true',
          watch.cwd,
        ))
            .trim();
      }
      if (!ref.mounted) return;

      final linkText = url != null && url.isNotEmpty ? ' ($url)' : '';
      final summary = passed
          ? 'CI passed: **$workflow** run `$runId`$linkText.'
          : 'CI failed ($normalizedConclusion): **$workflow** run `$runId`$linkText.\n```\n${failedLog ?? "Check GitHub Actions logs."}\n```';
      final autoFixPrompt = (passed || watch.suppressDefaultAutoFix)
          ? null
          : '[Auto CI Watch] GitHub Actions CI run `$runId` ($workflow) failed on `${headBranch ?? "main"}`. Diagnose and fix the failure cleanly:\n\n```\n${failedLog ?? "gh run view $runId --log-failed"}\n```';

      final finalWatch = watch.copyWith(
        runId: runId,
        workflowName: workflow,
        status: normalizedConclusion,
        branch: headBranch,
        htmlUrl: url,
        failedLog: failedLog,
      );

      if (customCb != null) {
        await customCb(finalWatch, passed, summary);
      } else if (onCompletedCallback != null) {
        await onCompletedCallback!(
          watch: finalWatch,
          passed: passed,
          summaryMarkdown: summary,
          autoFixPrompt: autoFixPrompt,
        );
      }
    } catch (_) {
      _recordMissOrExpire(
        watchId,
        hasRunId: watch.runId != null && watch.runId!.isNotEmpty,
      );
    } finally {
      _inFlightPolls.remove(watchId);
    }
  }

  void cancelWatch(String watchId) {
    _timers.remove(watchId)?.cancel();
    _missCounts.remove(watchId);
    _inFlightPolls.remove(watchId);
    _customWatchCallbacks.remove(watchId);
    state = state.where((w) => w.id != watchId).toList();
  }

  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _missCounts.clear();
    _inFlightPolls.clear();
    _customWatchCallbacks.clear();
    state = const [];
  }
}
