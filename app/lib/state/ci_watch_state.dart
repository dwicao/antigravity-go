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
    this.htmlUrl,
  });

  final String id;
  final String cwd;
  final String sessionId;
  final String workflowName;
  final String status;
  final DateTime startedAt;
  final String? runId;
  final String? branch;
  final String? htmlUrl;

  CiWatchItem copyWith({
    String? workflowName,
    String? status,
    String? runId,
    String? branch,
    String? htmlUrl,
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
      htmlUrl: htmlUrl ?? this.htmlUrl,
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
  final Map<String, Timer> _timers = {};
  CiShellRunner? shellRunnerOverride;
  CiCompletionCallback? onCompletedCallback;

  @override
  List<CiWatchItem> build() {
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
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

  Future<void> watchLatestRun({
    required String cwd,
    required String sessionId,
    String? branch,
  }) async {
    if (cwd.trim().isEmpty) return;
    final watchId = 'ci:${DateTime.now().millisecondsSinceEpoch}';
    final initial = CiWatchItem(
      id: watchId,
      cwd: cwd,
      sessionId: sessionId,
      workflowName: 'GitHub Actions CI',
      status: 'queued',
      branch: branch,
      startedAt: DateTime.now(),
    );
    state = [...state, initial];

    // Poll cleanly without leaking if provider is disposed.
    _timers[watchId]?.cancel();
    _timers[watchId] = Timer.periodic(
      const Duration(seconds: 12),
      (_) => pollOnce(watchId),
    );
    await pollOnce(watchId);
  }

  Future<void> pollOnce(String watchId) async {
    final idx = state.indexWhere((w) => w.id == watchId);
    if (idx < 0) {
      _timers.remove(watchId)?.cancel();
      return;
    }
    final watch = state[idx];

    try {
      final raw = await _exec(
        'gh run list -L 1 --json databaseId,workflowName,status,conclusion,url,headBranch 2>/dev/null || echo "[]"',
        watch.cwd,
      );
      if (!ref.mounted) return;
      final trimmed = raw.trim();
      if (!trimmed.startsWith('[')) return;
      final list = jsonDecode(trimmed) as List<dynamic>;
      if (list.isEmpty) return;
      final latest = list.first as Map<String, dynamic>;
      final runId = latest['databaseId']?.toString() ?? '';
      final workflow =
          latest['workflowName']?.toString() ?? watch.workflowName;
      final status = latest['status']?.toString() ?? 'in_progress';
      final conclusion = latest['conclusion']?.toString() ?? '';
      final url = latest['url']?.toString();
      final headBranch = latest['headBranch']?.toString() ?? watch.branch;

      if (status != 'completed') {
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

      // Run finished! Stop watching and surface result / auto-fix trigger.
      _timers.remove(watchId)?.cancel();
      state = state.where((w) => w.id != watchId).toList();

      final passed = conclusion == 'success';
      String? failedLog;
      if (!passed && runId.isNotEmpty) {
        failedLog = (await _exec(
          'gh run view $runId --log-failed 2>&1 | tail -n 60 || true',
          watch.cwd,
        ))
            .trim();
      }
      if (!ref.mounted) return;

      final linkText = url != null && url.isNotEmpty ? ' ($url)' : '';
      final summary = passed
          ? 'CI passed: **$workflow** run `$runId`$linkText.'
          : 'CI failed ($conclusion): **$workflow** run `$runId`$linkText.\n```\n${failedLog ?? "Check GitHub Actions logs."}\n```';
      final autoFixPrompt = passed
          ? null
          : '[Auto CI Watch] GitHub Actions CI run `$runId` ($workflow) failed on `${headBranch ?? "main"}`. Diagnose and fix the failure cleanly:\n\n```\n${failedLog ?? "gh run view $runId --log-failed"}\n```';

      if (onCompletedCallback != null) {
        await onCompletedCallback!(
          watch: watch.copyWith(
            runId: runId,
            workflowName: workflow,
            status: conclusion,
            branch: headBranch,
            htmlUrl: url,
          ),
          passed: passed,
          summaryMarkdown: summary,
          autoFixPrompt: autoFixPrompt,
        );
      }
    } catch (_) {
      // Transient CLI / offline error; keep watching until cancelled.
    }
  }

  void cancelWatch(String watchId) {
    _timers.remove(watchId)?.cancel();
    state = state.where((w) => w.id != watchId).toList();
  }

  void cancelAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    state = const [];
  }
}
