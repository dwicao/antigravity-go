import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'chat_state.dart';
import 'ci_watch_state.dart';
import 'harness_state.dart';
import 'hosts_state.dart';
import 'sessions_state.dart';

class RsiLoopState {
  const RsiLoopState({
    this.phase = RsiPhase.idle,
    this.sessionId,
    this.cwd,
    this.config = const RsiConfig(),
    this.profile = const RsiProjectProfile(),
    this.currentGeneration = 0,
    this.ciFixAttempts = 0,
    this.baselineSha,
    this.activeTargetSha,
    this.activeTargetVersion,
    this.activeWatchId,
    this.activeCiRunId,
    this.activeReleaseRunId,
    this.statusDetail = '',
    this.lastError,
    this.archive = const [],
  });

  final RsiPhase phase;
  final String? sessionId;
  final String? cwd;
  final RsiConfig config;
  final RsiProjectProfile profile;
  final int currentGeneration;
  final int ciFixAttempts;
  final String? baselineSha;
  final String? activeTargetSha;
  final String? activeTargetVersion;
  final String? activeWatchId;
  final String? activeCiRunId;
  final String? activeReleaseRunId;
  final String statusDetail;
  final String? lastError;
  final List<RsiArchiveEntry> archive;

  bool get isActive => phase.isActive;

  RsiLoopState copyWith({
    RsiPhase? phase,
    String? sessionId,
    bool clearSessionId = false,
    String? cwd,
    bool clearCwd = false,
    RsiConfig? config,
    RsiProjectProfile? profile,
    int? currentGeneration,
    int? ciFixAttempts,
    String? baselineSha,
    bool clearBaselineSha = false,
    String? activeTargetSha,
    bool clearActiveTargetSha = false,
    String? activeTargetVersion,
    bool clearActiveTargetVersion = false,
    String? activeWatchId,
    bool clearActiveWatchId = false,
    String? activeCiRunId,
    bool clearActiveCiRunId = false,
    String? activeReleaseRunId,
    bool clearActiveReleaseRunId = false,
    String? statusDetail,
    String? lastError,
    bool clearLastError = false,
    List<RsiArchiveEntry>? archive,
  }) {
    return RsiLoopState(
      phase: phase ?? this.phase,
      sessionId: clearSessionId ? null : (sessionId ?? this.sessionId),
      cwd: clearCwd ? null : (cwd ?? this.cwd),
      config: config ?? this.config,
      profile: profile ?? this.profile,
      currentGeneration: currentGeneration ?? this.currentGeneration,
      ciFixAttempts: ciFixAttempts ?? this.ciFixAttempts,
      baselineSha: clearBaselineSha ? null : (baselineSha ?? this.baselineSha),
      activeTargetSha: clearActiveTargetSha
          ? null
          : (activeTargetSha ?? this.activeTargetSha),
      activeTargetVersion: clearActiveTargetVersion
          ? null
          : (activeTargetVersion ?? this.activeTargetVersion),
      activeWatchId:
          clearActiveWatchId ? null : (activeWatchId ?? this.activeWatchId),
      activeCiRunId:
          clearActiveCiRunId ? null : (activeCiRunId ?? this.activeCiRunId),
      activeReleaseRunId: clearActiveReleaseRunId
          ? null
          : (activeReleaseRunId ?? this.activeReleaseRunId),
      statusDetail: statusDetail ?? this.statusDetail,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      archive: archive ?? this.archive,
    );
  }
}

typedef RsiSendPromptFn = Future<void> Function(
  String prompt, {
  String? sessionId,
});
typedef RsiFeedbackFn = Future<void> Function(
  String markdown, {
  String? sessionId,
});

final rsiLoopProvider =
    NotifierProvider<RsiLoopNotifier, RsiLoopState>(RsiLoopNotifier.new);

/// Orchestrates bounded Recursive Self-Improvement loops for any Git project:
/// Auto-detects branch, version manifest, local verify gate, GitHub CI, and
/// release/APK workflow -> Propose -> Verify/CI (+ Self-Heal) -> Release -> Next Gen.
class RsiLoopNotifier extends Notifier<RsiLoopState> {
  static const _prefsKey = 'agy_rsi_loop_v1';
  static const int _maxArchiveEntries = 30;
  static final RegExp _safeGitRefRe = RegExp(r'^[0-9A-Za-z._/-]+$');

  CiShellRunner? shellRunnerOverride;
  RsiSendPromptFn? sendPromptOverride;
  RsiFeedbackFn? feedbackOverride;

  int _loopEpoch = 0;
  String? _lastProposedSummary;

  @override
  RsiLoopState build() {
    Future.microtask(_loadPersisted);
    return const RsiLoopState();
  }

  bool ownsTurn(String sessionId) {
    return state.isActive &&
        state.sessionId == sessionId &&
        (state.phase == RsiPhase.proposing || state.phase == RsiPhase.fixingCi);
  }

  Future<void> _loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final cfgMap = decoded['config'];
      final archRaw = decoded['archive'];
      final config = cfgMap is Map<String, dynamic>
          ? RsiConfig.fromJson(cfgMap)
          : const RsiConfig();
      final archive = archRaw is List
          ? archRaw
              .whereType<Map<String, dynamic>>()
              .map(RsiArchiveEntry.fromJson)
              .toList()
          : const <RsiArchiveEntry>[];
      state = state.copyWith(config: config, archive: archive);
    } catch (_) {}
  }

  Future<void> _savePersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode({
        'config': state.config.toJson(),
        'archive': state.archive.map((e) => e.toJson()).toList(),
      });
      await prefs.setString(_prefsKey, payload);
    } catch (_) {}
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

  AgySessionSummary? _findSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return null;
    for (final s in ref.read(sessionsProvider).sessions) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  Future<void> _postFeedback(String markdown, {String? sessionId}) async {
    if (feedbackOverride != null) {
      await feedbackOverride!(markdown, sessionId: sessionId);
      return;
    }
    final target = _findSession(sessionId ?? state.sessionId);
    await ref.read(chatProvider.notifier).appendSystemFeedback(
          markdown,
          targetSession: target,
        );
  }

  Future<void> _sendAgentPrompt(String prompt, {String? sessionId}) async {
    if (sendPromptOverride != null) {
      await sendPromptOverride!(prompt, sessionId: sessionId);
      return;
    }
    final target = _findSession(sessionId ?? state.sessionId);
    await ref.read(chatProvider.notifier).sendPrompt(
          prompt,
          force: true,
          targetSession: target,
        );
  }

  Future<void> updateConfig(RsiConfig nextConfig) async {
    state = state.copyWith(config: nextConfig.normalized());
    await _savePersisted();
  }

  Future<void> clearArchive() async {
    state = state.copyWith(archive: const []);
    await _savePersisted();
  }

  void dismissBanner() {
    if (state.isActive) return;
    state = state.copyWith(
      phase: RsiPhase.idle,
      statusDetail: '',
      clearLastError: true,
    );
  }

  Future<void> stop({bool cancelStreamingTurn = false}) async {
    final epoch = ++_loopEpoch;
    final watchId = state.activeWatchId;
    if (watchId != null && watchId.isNotEmpty) {
      ref.read(ciWatchProvider.notifier).cancelWatch(watchId);
    }
    final sid = state.sessionId;
    final wasGen = state.currentGeneration;
    if (state.isActive) {
      await _recordArchive(
        RsiArchiveEntry(
          generation: wasGen > 0 ? wasGen : 1,
          status: 'stopped',
          summary: 'Stopped by user during ${state.phase.label}.',
          version: state.activeTargetVersion,
          commitSha: state.activeTargetSha,
          ciRunId: state.activeCiRunId,
          releaseRunId: state.activeReleaseRunId,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
    if (!ref.mounted || _loopEpoch != epoch) return;
    state = state.copyWith(
      phase: RsiPhase.stopped,
      statusDetail: 'RSI loop stopped.',
      clearActiveWatchId: true,
      clearLastError: true,
    );
    if (cancelStreamingTurn && sid != null && sid.isNotEmpty) {
      await ref.read(chatProvider.notifier).stopStreaming(sessionId: sid);
    }
    await _postFeedback('**RSI Loop stopped** (generation $wasGen).', sessionId: sid);
  }

  Future<RsiProjectProfile> _probeProfile(String cwd) async {
    const cmd = r'''
echo "===RSI:BRANCH==="
git rev-parse --abbrev-ref HEAD 2>/dev/null || true
echo "===RSI:ORIGIN_HEAD==="
git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true
echo "===RSI:HEAD_SHA==="
git rev-parse HEAD 2>/dev/null || true
echo "===RSI:ORIGIN_URL==="
git remote get-url origin 2>/dev/null || true
echo "===RSI:HAS_GH==="
if command -v gh >/dev/null 2>&1; then echo 1; else echo 0; fi
echo "===RSI:LATEST_TAG==="
git describe --tags --abbrev=0 2>/dev/null || true
echo "===RSI:HAS_SYNC==="
if [ -f tooling/sync_version.py ]; then echo 1; else echo 0; fi
echo "===RSI:HAS_GOMOD==="
if [ -f go.mod ]; then echo 1; else echo 0; fi
echo "===RSI:HAS_GRADLEW==="
if [ -f gradlew ] || [ -f android/gradlew ]; then echo 1; else echo 0; fi
echo "===RSI:APP_PUBSPEC==="
head -n 45 app/pubspec.yaml 2>/dev/null || true
echo "===RSI:ROOT_PUBSPEC==="
head -n 45 pubspec.yaml 2>/dev/null || true
echo "===RSI:PACKAGE_JSON==="
head -n 40 package.json 2>/dev/null || true
echo "===RSI:CARGO_TOML==="
head -n 40 Cargo.toml 2>/dev/null || true
echo "===RSI:PYPROJECT_TOML==="
head -n 40 pyproject.toml 2>/dev/null || true
echo "===RSI:WORKFLOWS==="
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  echo "---WF_FILE:$f"
  head -n 80 "$f" 2>/dev/null || true
done
''';
    final raw = await _exec(cmd, cwd);
    final customVerify = ref.read(harnessProvider).customVerifyCommand;
    return RsiProjectProfile.parseProbeOutput(
      raw,
      customVerifyCommand: customVerify,
    );
  }

  Future<bool> start({
    required String sessionId,
    required String cwd,
    RsiConfig? config,
  }) async {
    final cleanCwd = cwd.trim();
    if (cleanCwd.isEmpty) {
      await _postFeedback(
        'Cannot start `/rsi`: no active workspace folder selected.',
        sessionId: sessionId,
      );
      return false;
    }
    final normalizedConfig = (config ?? state.config).normalized();
    final epoch = ++_loopEpoch;
    if (state.activeWatchId != null && state.activeWatchId!.isNotEmpty) {
      ref.read(ciWatchProvider.notifier).cancelWatch(state.activeWatchId!);
    }

    final repoCheck = (await _exec(
      'git rev-parse --is-inside-work-tree 2>/dev/null || true',
      cleanCwd,
    ))
        .trim();
    if (!ref.mounted || _loopEpoch != epoch) return false;
    if (repoCheck != 'true') {
      state = state.copyWith(
        phase: RsiPhase.failed,
        sessionId: sessionId,
        cwd: cleanCwd,
        config: normalizedConfig,
        lastError: 'Active workspace is not a Git repository.',
        statusDetail: 'Requires a Git repository.',
      );
      await _postFeedback(
        'Cannot start `/rsi`: `$cleanCwd` is not a Git repository.',
        sessionId: sessionId,
      );
      return false;
    }

    final profile = await _probeProfile(cleanCwd);
    if (!ref.mounted || _loopEpoch != epoch) return false;

    state = state.copyWith(
      phase: RsiPhase.proposing,
      sessionId: sessionId,
      cwd: cleanCwd,
      config: normalizedConfig,
      profile: profile,
      currentGeneration: 1,
      ciFixAttempts: 0,
      clearBaselineSha: true,
      clearActiveTargetSha: true,
      clearActiveTargetVersion: true,
      clearActiveWatchId: true,
      clearActiveCiRunId: true,
      clearActiveReleaseRunId: true,
      clearLastError: true,
      statusDetail:
          'Generation 1/${normalizedConfig.maxGenerations}: proposing improvement (${profile.manifestKind.label})…',
    );
    await _savePersisted();
    await _launchGeneration(epoch: epoch);
    return true;
  }

  Future<void> _launchGeneration({required int epoch}) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    final cwd = state.cwd ?? '';
    final sid = state.sessionId ?? '';
    final gen = state.currentGeneration;
    final maxGen = state.config.maxGenerations;

    final profile = await _probeProfile(cwd);
    if (!ref.mounted || _loopEpoch != epoch) return;

    final nextVersion = RsiPromptBuilder.nextPatchVersion(profile.currentVersion);
    _lastProposedSummary = null;
    state = state.copyWith(
      phase: RsiPhase.proposing,
      profile: profile,
      baselineSha: profile.headSha,
      activeTargetVersion: nextVersion,
      clearActiveTargetSha: true,
      clearActiveCiRunId: true,
      clearActiveReleaseRunId: true,
      statusDetail: 'Gen $gen/$maxGen · Proposing v$nextVersion…',
    );

    final prompt = RsiPromptBuilder.buildProposerPrompt(
      generation: gen,
      maxGenerations: maxGen,
      config: state.config,
      profile: profile,
      archive: state.archive,
    );
    await _sendAgentPrompt(prompt, sessionId: sid);
  }

  /// Called by [ChatNotifier] when a turn owned by this RSI loop completes.
  Future<void> onChatTurnFinished({
    required String sessionId,
    required String assistantText,
    bool hasError = false,
    String? errorText,
  }) async {
    if (!state.isActive || state.sessionId != sessionId) return;
    if (state.phase != RsiPhase.proposing && state.phase != RsiPhase.fixingCi) {
      return;
    }
    final epoch = _loopEpoch;
    final cwd = state.cwd ?? '';
    final branch = state.profile.branch;

    if (hasError) {
      final msg = (errorText ?? 'Agent turn failed.').trim();
      await _failLoop(
        epoch: epoch,
        status: 'error',
        summary: 'Generation ${state.currentGeneration} errored: $msg',
        userMessage: '**RSI Loop halted** at Gen ${state.currentGeneration}: $msg',
      );
      return;
    }

    _lastProposedSummary = RsiPromptBuilder.extractSummary(
      assistantText,
      fallback: _lastProposedSummary ??
          'Self-improvement iteration ${state.currentGeneration}',
    );

    // Inspect deterministic Git state after the Proposer / Self-Heal turn.
    final dirty =
        (await _exec('git status --porcelain 2>/dev/null || true', cwd)).trim();
    var headSha =
        (await _exec('git rev-parse HEAD 2>/dev/null || true', cwd)).trim();
    if (!ref.mounted || _loopEpoch != epoch) return;

    if (dirty.isNotEmpty) {
      if (state.profile.syncCommand != null) {
        await _exec('${state.profile.syncCommand} >/dev/null 2>&1 || true', cwd);
      }
      final targetVer = state.activeTargetVersion ?? 'next';
      await _exec(
        'git add -A && git commit -m "chore(rsi): generation ${state.currentGeneration} (v$targetVer)" >/dev/null 2>&1 || true',
        cwd,
      );
      headSha =
          (await _exec('git rev-parse HEAD 2>/dev/null || true', cwd)).trim();
      if (!ref.mounted || _loopEpoch != epoch) return;
    }

    final baseline = state.baselineSha ?? '';
    if (headSha.isEmpty ||
        (baseline.isNotEmpty &&
            headSha == baseline &&
            state.phase == RsiPhase.proposing)) {
      await _recordArchive(
        RsiArchiveEntry(
          generation: state.currentGeneration,
          status: 'no_changes',
          summary: _lastProposedSummary ?? 'No code changes committed.',
          timestamp: DateTime.now().toUtc(),
        ),
      );
      if (!ref.mounted || _loopEpoch != epoch) return;
      state = state.copyWith(
        phase: RsiPhase.completed,
        statusDetail: 'Stopped: proposer produced no new commits.',
      );
      await _postFeedback(
        '**RSI Loop finished** at Gen ${state.currentGeneration}: no new changes were committed.',
        sessionId: sessionId,
      );
      return;
    }

    // Re-probe version after proposer edit.
    final updatedProfile = await _probeProfile(cwd);
    if (!ref.mounted || _loopEpoch != epoch) return;
    final resolvedVersion =
        updatedProfile.versionFilePath != null
            ? updatedProfile.currentVersion
            : (state.activeTargetVersion ?? updatedProfile.currentVersion);

    // Push to remote branch if the repo has a GitHub remote.
    if (updatedProfile.hasGitHubRemote) {
      if (!_safeGitRefRe.hasMatch(branch)) {
        await _failLoop(
          epoch: epoch,
          status: 'error',
          summary: 'Invalid branch name: $branch',
          userMessage: '**RSI Loop halted**: invalid branch name `$branch`.',
        );
        return;
      }
      final remoteSha = (await _exec(
        'git rev-parse "origin/$branch" 2>/dev/null || true',
        cwd,
      ))
          .trim();
      if (remoteSha != headSha) {
        final pushOut = await _pushRef(refSpec: branch, cwd: cwd);
        if (!ref.mounted || _loopEpoch != epoch) return;
        final afterRemote = (await _exec(
          'git rev-parse "origin/$branch" 2>/dev/null || true',
          cwd,
        ))
            .trim();
        if (afterRemote != headSha && pushOut.toLowerCase().contains('fatal:')) {
          await _failLoop(
            epoch: epoch,
            status: 'error',
            summary: 'Failed to push $branch ($headSha): $pushOut',
            userMessage:
                '**RSI Loop halted**: failed to push `$branch`:\n```\n$pushOut\n```',
          );
          return;
        }
      }
    }

    state = state.copyWith(
      phase: RsiPhase.waitingCi,
      profile: updatedProfile,
      activeTargetSha: headSha,
      activeTargetVersion: resolvedVersion,
    );

    final shortSha = headSha.length > 7 ? headSha.substring(0, 7) : headSha;

    if (updatedProfile.canWatchGitHubCi) {
      final wfLabel = updatedProfile.ciWorkflowName ?? 'GitHub Actions CI';
      state = state.copyWith(
        statusDetail:
            'Gen ${state.currentGeneration}/${state.config.maxGenerations} · Watching $wfLabel ($shortSha)…',
      );
      await _postFeedback(
        '**RSI Gen ${state.currentGeneration}/${state.config.maxGenerations}**: Pushed `$shortSha` on `$branch` (`v$resolvedVersion`). Watching **$wfLabel**…',
        sessionId: sessionId,
      );

      final watchId = await ref.read(ciWatchProvider.notifier).watchLatestRun(
        cwd: cwd,
        sessionId: sessionId,
        branch: branch,
        headSha: headSha,
        workflowNameFilter: updatedProfile.ciWorkflowName,
        suppressDefaultAutoFix: true,
        onDone: (watch, passed, summaryMarkdown) async {
          await _handleCiOutcome(
            epoch: epoch,
            watch: watch,
            passed: passed,
          );
        },
      );
      if (ref.mounted && _loopEpoch == epoch && state.phase == RsiPhase.waitingCi) {
        state = state.copyWith(activeWatchId: watchId);
      }
      return;
    }

    // Fallback for repos without GitHub Actions CI: run local verification command cleanly.
    final verifyCmd = updatedProfile.verifyCommand?.trim() ?? '';
    if (verifyCmd.isNotEmpty) {
      state = state.copyWith(
        statusDetail:
            'Gen ${state.currentGeneration}/${state.config.maxGenerations} · Running `$verifyCmd`…',
      );
      final res = await _exec(
        '$verifyCmd 2>&1; printf "\\n__RSI_EXIT=%d__\\n" \$?',
        cwd,
      );
      if (!ref.mounted || _loopEpoch != epoch) return;
      final exitMatch = RegExp(r'__RSI_EXIT=(\d+)__').firstMatch(res);
      final exitCode = int.tryParse(exitMatch?.group(1) ?? '1') ?? 1;
      final cleanOut = res.replaceAll(RegExp(r'__RSI_EXIT=\d+__'), '').trim();
      final lines = cleanOut.split('\n');
      final tail = lines.length > 50
          ? lines.sublist(lines.length - 50).join('\n')
          : cleanOut;
      if (exitCode != 0) {
        await _handleVerificationFailure(
          epoch: epoch,
          sourceLabel: 'Local verification (`$verifyCmd`)',
          failedLog: tail,
          runId: null,
        );
        return;
      }
    }

    // Local verification passed (or none defined); proceed to release or complete gen.
    await _postFeedback(
      '**RSI Gen ${state.currentGeneration}/${state.config.maxGenerations}**: Commit `$shortSha` verified locally${verifyCmd.isNotEmpty ? ' (`$verifyCmd` passed)' : ''}.',
      sessionId: sessionId,
    );
    await _proceedAfterVerificationPassed(
      epoch: epoch,
      ciRunId: null,
      usedRemoteCi: false,
    );
  }

  Future<String> _pushRef({required String refSpec, required String cwd}) async {
    final safeRef = refSpec.trim();
    if (safeRef.isEmpty || !_safeGitRefRe.hasMatch(safeRef)) {
      return 'fatal: invalid git ref "$refSpec"';
    }
    final cmd = '''
if git push origin "$safeRef" 2>/dev/null; then
  echo "PUSH_OK"
elif command -v gh >/dev/null 2>&1; then
  TOK="\$(gh auth token 2>/dev/null || true)"
  if [ -n "\$TOK" ]; then
    B64="\$(printf 'x-access-token:%s' "\$TOK" | base64 | tr -d '\\n')"
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c "http.https://github.com/.extraheader=AUTHORIZATION: basic \$B64" push origin "$safeRef" 2>&1
  else
    git push origin "$safeRef" 2>&1
  fi
else
  git push origin "$safeRef" 2>&1
fi
''';
    return (await _exec(cmd, cwd)).trim();
  }

  Future<void> _handleVerificationFailure({
    required int epoch,
    required String sourceLabel,
    required String failedLog,
    required String? runId,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    final sid = state.sessionId ?? '';
    if (state.ciFixAttempts < state.config.maxCiFixAttemptsPerGen) {
      final nextAttempt = state.ciFixAttempts + 1;
      state = state.copyWith(
        phase: RsiPhase.fixingCi,
        ciFixAttempts: nextAttempt,
        statusDetail:
            'Gen ${state.currentGeneration}/${state.config.maxGenerations} · Self-healing ($nextAttempt/${state.config.maxCiFixAttemptsPerGen})…',
      );
      await _postFeedback(
        '**RSI Gen ${state.currentGeneration}**: $sourceLabel failed — launching self-heal attempt `$nextAttempt/${state.config.maxCiFixAttemptsPerGen}`.',
        sessionId: sid,
      );
      final fixPrompt = RsiPromptBuilder.buildFailureFixPrompt(
        generation: state.currentGeneration,
        attempt: nextAttempt,
        maxAttempts: state.config.maxCiFixAttemptsPerGen,
        branch: state.profile.branch,
        sourceLabel: sourceLabel,
        failedLog: failedLog,
        pushToRemote: state.profile.hasGitHubRemote,
      );
      await _sendAgentPrompt(fixPrompt, sessionId: sid);
      return;
    }

    await _failLoop(
      epoch: epoch,
      status: runId != null ? 'ci_failed' : 'verify_failed',
      summary:
          '$sourceLabel failed after ${state.ciFixAttempts} fix attempt(s): ${_lastProposedSummary ?? ''}',
      userMessage:
          '**RSI Loop halted** at Gen ${state.currentGeneration}: $sourceLabel failed after ${state.ciFixAttempts} self-heal attempt(s).',
    );
  }

  Future<void> _handleCiOutcome({
    required int epoch,
    required CiWatchItem watch,
    required bool passed,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch || state.phase != RsiPhase.waitingCi) {
      return;
    }
    final ciRunId = watch.runId ?? '';

    state = state.copyWith(
      clearActiveWatchId: true,
      activeCiRunId: ciRunId.isNotEmpty ? ciRunId : null,
    );

    if (!passed) {
      await _handleVerificationFailure(
        epoch: epoch,
        sourceLabel: 'GitHub Actions **${watch.workflowName}** run `$ciRunId`',
        failedLog: watch.failedLog ?? '',
        runId: ciRunId,
      );
      return;
    }

    await _proceedAfterVerificationPassed(
      epoch: epoch,
      ciRunId: ciRunId,
      usedRemoteCi: true,
    );
  }

  Future<void> _proceedAfterVerificationPassed({
    required int epoch,
    required String? ciRunId,
    required bool usedRemoteCi,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    final sid = state.sessionId ?? '';
    final cwd = state.cwd ?? '';
    final profile = state.profile;
    final mode = state.config.releaseMode;

    final wantsRelease = switch (mode) {
      RsiReleaseMode.ciOnly => false,
      RsiReleaseMode.auto => profile.shouldRunRelease,
      RsiReleaseMode.tagAndRelease => profile.hasGitHubRemote && profile.hasGhCli,
    };

    if (!wantsRelease) {
      final status = usedRemoteCi ? 'ci_passed' : 'verified_local';
      await _recordArchive(
        RsiArchiveEntry(
          generation: state.currentGeneration,
          status: status,
          summary: _lastProposedSummary ??
              (usedRemoteCi ? 'CI passed.' : 'Verified locally.'),
          version: state.activeTargetVersion,
          commitSha: state.activeTargetSha,
          ciRunId: ciRunId,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      if (usedRemoteCi) {
        await _postFeedback(
          '**RSI Gen ${state.currentGeneration}/${state.config.maxGenerations} Complete**: CI run `$ciRunId` passed!',
          sessionId: sid,
        );
      }
      await _advanceOrComplete(epoch: epoch);
      return;
    }

    // Verification/CI is green -> tag & trigger/create release.
    final version = state.activeTargetVersion ?? profile.currentVersion;
    final tag = 'v$version';
    final targetSha = state.activeTargetSha ?? 'HEAD';
    if (!_safeGitRefRe.hasMatch(tag) || !_safeGitRefRe.hasMatch(targetSha)) {
      await _failLoop(
        epoch: epoch,
        status: 'error',
        summary: 'Invalid tag or commit SHA for release: $tag ($targetSha)',
        userMessage:
            '**RSI Loop halted** at Gen ${state.currentGeneration}: invalid release tag/SHA.',
      );
      return;
    }

    state = state.copyWith(
      phase: RsiPhase.releasing,
      statusDetail: profile.hasReleaseWorkflow
          ? 'Gen ${state.currentGeneration}/${state.config.maxGenerations} · Running ${profile.releaseWorkflowName ?? "Release"} ($tag)…'
          : 'Gen ${state.currentGeneration}/${state.config.maxGenerations} · Creating GitHub Release $tag…',
    );

    await _exec(
      'if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then git tag "$tag" "$targetSha"; fi',
      cwd,
    );
    final pushTagOut = await _pushRef(refSpec: tag, cwd: cwd);
    if (!ref.mounted || _loopEpoch != epoch) return;

    if (pushTagOut.toLowerCase().contains('fatal:') ||
        pushTagOut.toLowerCase().contains('error:')) {
      await _failLoop(
        epoch: epoch,
        status: 'error',
        summary: 'Verification passed, but failed pushing tag $tag: $pushTagOut',
        userMessage:
            '**RSI Loop halted** at Gen ${state.currentGeneration}: pushing tag `$tag` failed:\n```\n$pushTagOut\n```',
      );
      return;
    }

    if (profile.hasReleaseWorkflow) {
      final wfName = profile.releaseWorkflowName ?? 'Release';
      await _postFeedback(
        '**RSI Gen ${state.currentGeneration}**: CI green${ciRunId != null ? ' (`$ciRunId`)' : ''}. Pushed tag `$tag` — watching **$wfName**…',
        sessionId: sid,
      );
      final relWatchId = await ref.read(ciWatchProvider.notifier).watchLatestRun(
        cwd: cwd,
        sessionId: sid,
        branch: tag,
        headSha: targetSha,
        workflowNameFilter: profile.releaseWorkflowName,
        suppressDefaultAutoFix: true,
        onDone: (relWatch, relPassed, _) async {
          await _handleReleaseOutcome(
            epoch: epoch,
            watch: relWatch,
            passed: relPassed,
            tag: tag,
            version: version,
          );
        },
      );
      if (ref.mounted && _loopEpoch == epoch && state.phase == RsiPhase.releasing) {
        state = state.copyWith(activeWatchId: relWatchId);
      }
      return;
    }

    // Repo has no dedicated release workflow; create a standard GitHub release for the tag.
    await _exec(
      'gh release create "$tag" --generate-notes >/dev/null 2>&1 || true',
      cwd,
    );
    if (!ref.mounted || _loopEpoch != epoch) return;
    await _finalizeGitHubRelease(
      epoch: epoch,
      tag: tag,
      version: version,
      relRunId: '',
      fallbackUrl: null,
    );
  }

  Future<void> _handleReleaseOutcome({
    required int epoch,
    required CiWatchItem watch,
    required bool passed,
    required String tag,
    required String version,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch || state.phase != RsiPhase.releasing) {
      return;
    }
    final relRunId = watch.runId ?? '';

    state = state.copyWith(
      clearActiveWatchId: true,
      activeReleaseRunId: relRunId.isNotEmpty ? relRunId : null,
    );

    if (!passed) {
      await _failLoop(
        epoch: epoch,
        status: 'error',
        summary: 'Release workflow failed ($relRunId) for $tag',
        userMessage:
            '**RSI Loop halted** at Gen ${state.currentGeneration}: Release workflow `$relRunId` failed for `$tag`.',
      );
      return;
    }

    await _finalizeGitHubRelease(
      epoch: epoch,
      tag: tag,
      version: version,
      relRunId: relRunId,
      fallbackUrl: watch.htmlUrl,
    );
  }

  Future<void> _finalizeGitHubRelease({
    required int epoch,
    required String tag,
    required String version,
    required String relRunId,
    required String? fallbackUrl,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    final sid = state.sessionId ?? '';
    final cwd = state.cwd ?? '';
    final relJsonRaw = await _exec(
      'gh release view "$tag" --json url,assets 2>/dev/null || echo "{}"',
      cwd,
    );
    if (!ref.mounted || _loopEpoch != epoch) return;
    final parsedRel = RsiPromptBuilder.parseReleaseViewJson(relJsonRaw);

    await _recordArchive(
      RsiArchiveEntry(
        generation: state.currentGeneration,
        status: 'released',
        summary: _lastProposedSummary ?? 'Released $tag',
        version: version,
        tag: tag,
        commitSha: state.activeTargetSha,
        ciRunId: state.activeCiRunId,
        releaseRunId: relRunId.isEmpty ? null : relRunId,
        releaseUrl: parsedRel.url ?? fallbackUrl,
        artifactName: parsedRel.assetName,
        timestamp: DateTime.now().toUtc(),
      ),
    );

    final assetLabel =
        parsedRel.assetName != null ? ' · `${parsedRel.assetName}`' : '';
    final linkLabel =
        (parsedRel.url ?? fallbackUrl) != null
            ? ' ([GitHub Release](${parsedRel.url ?? fallbackUrl}))'
            : '';
    await _postFeedback(
      '**RSI Gen ${state.currentGeneration}/${state.config.maxGenerations} Complete**: Published `$tag`$assetLabel$linkLabel.',
      sessionId: sid,
    );

    await _advanceOrComplete(epoch: epoch);
  }

  Future<void> _advanceOrComplete({required int epoch}) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    final sid = state.sessionId ?? '';
    if (state.currentGeneration < state.config.maxGenerations) {
      final nextGen = state.currentGeneration + 1;
      state = state.copyWith(
        currentGeneration: nextGen,
        ciFixAttempts: 0,
        statusDetail:
            'Starting Generation $nextGen/${state.config.maxGenerations}…',
      );
      await _launchGeneration(epoch: epoch);
      return;
    }

    state = state.copyWith(
      phase: RsiPhase.completed,
      statusDetail:
          'Completed ${state.config.maxGenerations} generation(s) cleanly.',
    );
    await _postFeedback(
      '**RSI Loop finished** all ${state.config.maxGenerations} generation(s). Check `/rsi` to review the evolutionary archive or start another run.',
      sessionId: sid,
    );
  }

  Future<void> _failLoop({
    required int epoch,
    required String status,
    required String summary,
    required String userMessage,
  }) async {
    if (!ref.mounted || _loopEpoch != epoch) return;
    await _recordArchive(
      RsiArchiveEntry(
        generation: state.currentGeneration > 0 ? state.currentGeneration : 1,
        status: status,
        summary: summary,
        version: state.activeTargetVersion,
        commitSha: state.activeTargetSha,
        ciRunId: state.activeCiRunId,
        releaseRunId: state.activeReleaseRunId,
        timestamp: DateTime.now().toUtc(),
      ),
    );
    if (!ref.mounted || _loopEpoch != epoch) return;
    state = state.copyWith(
      phase: RsiPhase.failed,
      lastError: summary,
      statusDetail: summary,
      clearActiveWatchId: true,
    );
    await _postFeedback(userMessage, sessionId: state.sessionId);
  }

  Future<void> _recordArchive(RsiArchiveEntry entry) async {
    final next = [entry, ...state.archive];
    if (next.length > _maxArchiveEntries) {
      next.removeRange(_maxArchiveEntries, next.length);
    }
    state = state.copyWith(archive: next);
    await _savePersisted();
  }
}
