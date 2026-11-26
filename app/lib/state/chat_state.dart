import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../remote/openai_compat_runner.dart';
import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_models.dart';
import 'auth_state.dart';
import 'chat_message_store.dart';
import 'chat_models.dart';
import 'chat_turn_helpers.dart';
import 'ci_watch_state.dart';
import 'custom_providers_state.dart';
import 'customizations_state.dart';
import 'device_policy_state.dart';
import 'harness_state.dart';
import 'hosts_state.dart';
import 'permissions_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'sessions_state.dart';
import 'settings_state.dart';
import 'usage_state.dart';

export 'chat_message_store.dart';
export 'chat_models.dart';

final chatProvider =
    NotifierProvider<ChatNotifier, ChatThreadState>(ChatNotifier.new);

class _SessionTurnRuntime {
  _SessionTurnRuntime({
    required this.turnId,
    required this.isSsh,
    this.isCustomOpenAi = false,
  });

  StreamSubscription<AgyChatEvent>? sub;
  Timer? stallWatchdog;
  final HarnessLoopDetector loopDetector = HarnessLoopDetector();
  final Set<String> seenLoopCallIds = <String>{};
  bool receivedTurnContent = false;
  bool usedFallbackForTurn = false;
  AgyPromptRequest? activeLocalRequest;
  String turnId;
  bool isSsh;
  bool isCustomOpenAi;
  DateTime? streamBurstStart;
  final List<({DateTime at, double tokens})> rateSamples = [];
  Timer? uiEmitTimer;
  bool pendingUiEmit = false;
  double latestTokensPerSec = 0;

  void dispose() {
    uiEmitTimer?.cancel();
    uiEmitTimer = null;
    stallWatchdog?.cancel();
    stallWatchdog = null;
    final s = sub;
    sub = null;
    if (s != null) {
      unawaited(s.cancel());
    }
  }
}

class ChatNotifier extends Notifier<ChatThreadState> {
  StreamSubscription<RuntimeEvent>? _wakeupSub;
  StreamSubscription<RuntimeEvent>? _notifPermSub;
  final Set<String> _autoCompactingSessions = <String>{};
  String? _loadedSessionId;
  final Map<String, _SessionTurnRuntime> _sessionRuntimes = {};
  final Map<String, String> _wakeupAssistantIds = {};
  final Map<String, Timer> _wakeupFinalizeTimers = {};
  final Map<String, Timer> _persistTimers = {};
  final Set<String> _completedAssistantIds = <String>{};
  final List<String> _completedAssistantOrder = <String>[];
  static const int _maxCompletedAssistantHistory = 400;
  final AcpCodec _wakeupCodec = AcpCodec();
  final Map<String, List<ChatMessage>> _inFlightMessages = {};
  final Map<String, DateTime> _turnStartedAt = {};
  final Map<String, DateTime> _firstOutputAt = {};
  final Map<String, String> _turnModelId = {};
  final Map<String, String> _turnEffort = {};
  final Map<String, AgyPermissionRequestEvent> _pendingPermissionsBySession =
      {};
  final Map<String, LoopDetectionResult> _sessionLoopWarnings = {};
  final Map<String, String> _sessionStallWarnings = {};
  final Map<String, int> _sessionTurnTokens = {};
  final Map<String, List<({String prompt, List<String> attachments})>>
      _queuedItemsBySession = {};
  final Map<String, List<ActiveSubagent>> _activeSubagentsBySession = {};
  final Set<String> _wakeupSpawnedSubagentSessions = <String>{};
  int _nextStreamToken = 0;
  final Map<
      String,
      ({
        List<HarnessCompactionTurn> turns,
        int compactCount,
        String? instructions,
        String? tempRemoteId,
      })> _pendingCompactions = {};

  static List<ChatToolStep> _finalizeTools(
    List<ChatToolStep> tools, {
    bool failed = false,
  }) =>
      ChatTurnHelpers.finalizeTools(tools, failed: failed);

  static String? extractGitPushCwd(
    List<ChatToolStep> tools, {
    required String fallbackCwd,
  }) =>
      ChatTurnHelpers.extractGitPushCwd(tools, fallbackCwd: fallbackCwd);

  static List<FileChangeEntry> extractChangedFilesFromTools(
    List<ChatToolStep> tools,
  ) =>
      ChatTurnHelpers.extractChangedFilesFromTools(tools);

  double _recordRateSample(String sessionId, String delta) {
    final rt = _sessionRuntimes[sessionId];
    if (rt == null || delta.isEmpty) return state.tokensPerSecond;
    final now = DateTime.now();
    // Empirical estimate (~0.35 tok/char).
    final est = delta.trim().length * 0.35;
    if (est <= 0) return state.tokensPerSecond;
    if (rt.rateSamples.isEmpty ||
        now.difference(rt.rateSamples.last.at).inMilliseconds > 1500) {
      rt.streamBurstStart = now;
    }
    rt.rateSamples.add((at: now, tokens: est));
    final cutoff = now.subtract(const Duration(milliseconds: 2500));
    rt.rateSamples.removeWhere((s) => s.at.isBefore(cutoff));
    final start = rt.streamBurstStart != null && rt.streamBurstStart!.isAfter(cutoff)
        ? rt.streamBurstStart!
        : cutoff;
    final elapsedMs = now.difference(start).inMilliseconds;
    final secs = (elapsedMs < 500 ? 500 : elapsedMs) / 1000.0;
    final sum = rt.rateSamples.fold<double>(0, (a, s) => a + s.tokens);
    return sum / secs;
  }

  static List<ChatMilestoneStep> _appendTextStep(
    List<ChatMilestoneStep> currentSteps,
    String delta,
  ) {
    if (delta.isEmpty) return currentSteps;
    final nextSteps = [...currentSteps];
    if (nextSteps.isNotEmpty && nextSteps.last.kind == ChatMilestoneKind.text) {
      final last = nextSteps.last;
      nextSteps[nextSteps.length - 1] =
          last.copyWith(text: '${last.text}$delta');
      return nextSteps;
    }
    if (delta.trim().isEmpty) return currentSteps;
    nextSteps.add(
      ChatMilestoneStep(
        id: 'text-${nextSteps.length}',
        kind: ChatMilestoneKind.text,
        text: delta,
      ),
    );
    return nextSteps;
  }

  bool _hasActiveBackgroundWork(String sessionId) {
    final rt = _sessionRuntimes[sessionId];
    final msgs = _messagesForSession(sessionId);
    if (msgs.any(
      (m) => m.isStreaming && m.tools.any((t) => t.state == ToolCallState.running),
    )) {
      return true;
    }
    if (_activeSubagentsBySession[sessionId]?.any((s) => s.isActive) ?? false) {
      return true;
    }
    final rtTasks = ref.read(runtimeProvider).backgroundTasks;
    final hasNativeBgTask = rtTasks.any((t) {
      if (rt != null && t.turnId == rt.turnId) return true;
      if (t.turnId == sessionId) return true;
      if (t.kind == 'terminal') {
        final ownedElsewhere = _sessionRuntimes.entries.any(
          (e) =>
              e.key != sessionId &&
              (e.value.turnId == t.turnId || e.key == t.turnId),
        );
        return !ownedElsewhere;
      }
      return false;
    });
    if (hasNativeBgTask) return true;
    final ciWatches = ref.read(ciWatchProvider);
    return ciWatches.any(
      (w) => w.sessionId.isEmpty || w.sessionId == sessionId,
    );
  }

  void _refreshActiveWatchdogsForBackgroundWork() {
    for (final sid in _sessionRuntimes.keys.toList()) {
      if (_hasActiveBackgroundWork(sid)) {
        _resetWatchdog(sid);
        if (_sessionStallWarnings.remove(sid) != null &&
            _loadedSessionId == sid &&
            state.stallWarning != null) {
          state = state.copyWith(clearStallWarning: true);
        }
      }
    }
  }

  @visibleForTesting
  bool hasActiveBackgroundWorkForTest(String sessionId) =>
      _hasActiveBackgroundWork(sessionId);

  @visibleForTesting
  void seedStreamingTurnForTest({
    required String sessionId,
    required String turnId,
    List<ChatMessage> messages = const [],
  }) {
    _loadedSessionId = sessionId;
    _inFlightMessages[sessionId] = messages;
    _sessionRuntimes[sessionId]?.dispose();
    _sessionRuntimes[sessionId] = _SessionTurnRuntime(
      turnId: turnId,
      isSsh: false,
    );
    state = state.copyWith(
      messages: messages,
      isStreaming: true,
      activeTurnId: turnId,
      loadedSessionId: sessionId,
      clearStallWarning: true,
    );
    _resetWatchdog(sessionId);
  }

  void _resetWatchdog(String sessionId) {
    final rt = _sessionRuntimes[sessionId];
    if (rt == null) return;
    rt.stallWatchdog?.cancel();
    if (_pendingPermissionsBySession[sessionId] != null) {
      return;
    }
    rt.stallWatchdog = Timer(const Duration(seconds: 180), () {
      if (!_sessionRuntimes.containsKey(sessionId) ||
          _pendingPermissionsBySession[sessionId] != null ||
          !ref.mounted) {
        return;
      }
      // Do not falsely warn the user about being idle while background tasks,
      // running tools, subagents, or CI watches are still running for this turn.
      if (_hasActiveBackgroundWork(sessionId)) {
        if (_sessionStallWarnings.remove(sessionId) != null &&
            _loadedSessionId == sessionId &&
            state.stallWarning != null) {
          state = state.copyWith(clearStallWarning: true);
        }
        _resetWatchdog(sessionId);
        return;
      }
      const msg =
          'Agent turn has had no output for 3 minutes — check connection or tap Stop & Regenerate.';
      _sessionStallWarnings[sessionId] = msg;
      if (_loadedSessionId == sessionId) {
        state = state.copyWith(stallWarning: msg);
      }
    });
  }

  AgySessionSummary _latestSession(AgySessionSummary fallback) {
    final sessions = ref.read(sessionsProvider).sessions;
    for (final s in sessions) {
      if (s.id == fallback.id) return s;
    }
    return fallback;
  }

  Future<void> _syncSessionMeta(
    String sessionId,
    List<ChatMessage> msgs,
  ) async {
    if (!ref.mounted) return;
    final sessions = ref.read(sessionsProvider).sessions;
    AgySessionSummary? target;
    for (final s in sessions) {
      if (s.id == sessionId) {
        target = s;
        break;
      }
    }
    if (target == null) return;
    var preview = '';
    for (var i = msgs.length - 1; i >= 0; i--) {
      final t = msgs[i].text.trim();
      if (t.isNotEmpty) {
        preview = t;
        break;
      }
    }
    await ref.read(sessionsProvider.notifier).updateSession(
          target.copyWith(
            updatedAt: DateTime.now(),
            messageCount: msgs.length,
            lastPreview: preview,
          ),
        );
  }

  @override
  ChatThreadState build() {
    ref.onDispose(() {
      for (final rt in _sessionRuntimes.values) {
        rt.dispose();
      }
      _sessionRuntimes.clear();
      for (final timer in _wakeupFinalizeTimers.values) {
        timer.cancel();
      }
      _wakeupFinalizeTimers.clear();
      for (final timer in _persistTimers.values) {
        timer.cancel();
      }
      _persistTimers.clear();
      _wakeupAssistantIds.clear();
      _wakeupSub?.cancel();
      _notifPermSub?.cancel();
    });
    _wakeupSub?.cancel();
    _wakeupSub = RuntimeBridge.instance.events
        .where((e) => e.kind == 'acp_wakeup' && e.stdoutLine != null)
        .listen(_handleAcpWakeup);
    _notifPermSub?.cancel();
    _notifPermSub = RuntimeBridge.instance.events
        .where(
          (e) =>
              e.kind == 'notification_permission_action' ||
              e.kind == 'notification_cancel_turn',
        )
        .listen(_handleNotificationPermissionEvent);
    Future.microtask(() {
      if (!ref.mounted) return;
      ref.read(ciWatchProvider.notifier).onCompletedCallback =
          _handleCiWatchCompleted;
    });
    ref.listen<String?>(
      sessionsProvider.select((s) => s.activeSessionId),
      (prev, next) {
        if (next != null && next != _loadedSessionId) {
          _loadedSessionId = next;
          Future.microtask(() => _loadMessages(next));
        }
      },
    );
    ref.listen<List<NativeBackgroundTask>>(
      runtimeProvider.select((r) => r.backgroundTasks),
      (prev, next) {
        if (next.isNotEmpty) _refreshActiveWatchdogsForBackgroundWork();
      },
    );
    ref.listen<List<CiWatchItem>>(
      ciWatchProvider,
      (prev, next) {
        if (next.isNotEmpty) _refreshActiveWatchdogsForBackgroundWork();
      },
    );
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null && activeId != _loadedSessionId) {
      _loadedSessionId = activeId;
      Future.microtask(() => _loadMessages(activeId));
    }
    return const ChatThreadState();
  }

  void _handleNotificationPermissionEvent(RuntimeEvent evt) {
    if (!ref.mounted) return;
    if (evt.kind == 'notification_cancel_turn') {
      unawaited(forceStopAllTasks());
      return;
    }
    final turnId = evt.turnId ?? '';
    final optionId = evt.optionId ?? '';
    final comment = evt.comment?.trim() ?? '';
    if (turnId.isEmpty || optionId.isEmpty) return;
    String? matchingSessionId;
    for (final entry in _sessionRuntimes.entries) {
      if (entry.value.turnId == turnId) {
        matchingSessionId = entry.key;
        break;
      }
    }
    if (matchingSessionId != null) {
      final rt = _sessionRuntimes[matchingSessionId];
      final perm = _pendingPermissionsBySession.remove(matchingSessionId);
      _resetWatchdog(matchingSessionId);
      if (perm != null && rt != null) {
        if (rt.isCustomOpenAi) {
          unawaited(
            OpenAiCompatRunner.instance.resolvePermission(
              turnId: turnId,
              requestId: perm.requestId,
              optionId: optionId,
            ),
          );
        } else if (rt.isSsh) {
          unawaited(
            SshAgyRunner.instance.respondToPermission(
              turnId: turnId,
              requestId: perm.requestId,
              optionId: optionId,
            ),
          );
        }
      }
      if (_loadedSessionId == matchingSessionId) {
        state = state.copyWith(clearPermission: true);
      }
    } else if (state.activeTurnId == turnId) {
      state = state.copyWith(clearPermission: true);
    }

    if (evt.approved == false && comment.isNotEmpty) {
      unawaited(sendPrompt('Tool action denied. Instruction: $comment'));
    }
  }

  void _finalizeWakeupMessage(String sessionId, String assistantId) {
    _wakeupFinalizeTimers.remove(sessionId)?.cancel();
    if (!ref.mounted) return;
    if (_wakeupAssistantIds[sessionId] == assistantId) {
      _wakeupAssistantIds.remove(sessionId);
    }
    if (!_wakeupSpawnedSubagentSessions.remove(sessionId)) {
      _completeRunningSubagents(sessionId);
    }
    final msgs = _messagesForSession(sessionId);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx >= 0 && msgs[idx].isStreaming) {
      final cur = msgs[idx];
      final finalizedTools = _finalizeTools(cur.tools);
      final stats = _computeTurnStats(
        assistantId: assistantId,
        text: cur.text,
        thoughts: cur.thoughts,
        usage: cur.usage,
      );
      _replaceMessageInSession(
        sessionId,
        idx,
        cur.copyWith(
          isStreaming: false,
          tools: finalizedTools,
          durationSeconds: cur.durationSeconds ?? stats.durationSec,
          tokensPerSecond: cur.tokensPerSecond ?? stats.tokPerSec,
          modelId: _turnModelId[assistantId] ?? cur.modelId,
          reasoningEffort: _turnEffort[assistantId] ?? cur.reasoningEffort,
          completedAt: cur.completedAt ?? DateTime.now(),
          changedFiles: cur.changedFiles.isNotEmpty
              ? cur.changedFiles
              : extractChangedFilesFromTools(finalizedTools),
        ),
      );
    }
    _turnStartedAt.remove(assistantId);
    _firstOutputAt.remove(assistantId);
    _turnModelId.remove(assistantId);
    _turnEffort.remove(assistantId);
    if (!_sessionRuntimes.containsKey(sessionId) &&
        _loadedSessionId == sessionId) {
      state = state.copyWith(tokensPerSecond: 0);
    }
    unawaited(_persistMessages(sessionId, _messagesForSession(sessionId)));
  }

  void _handleAcpWakeup(RuntimeEvent evt) {
    if (!ref.mounted || evt.stdoutLine == null) return;
    final parsed = _wakeupCodec.parseNotificationOrRequest(evt.stdoutLine!);
    if (parsed == null) return;
    if (parsed is! AgyTextDeltaEvent &&
        parsed is! AgyThoughtDeltaEvent &&
        parsed is! AgyToolCallEvent &&
        parsed is! AgyPermissionRequestEvent &&
        parsed is! AgyTurnResultEvent &&
        parsed is! AgyErrorEvent) {
      return;
    }

    final sessionsState = ref.read(sessionsProvider);
    AgySessionSummary? target;
    final evtSid = evt.sessionId;
    if (evtSid != null && evtSid.isNotEmpty) {
      for (final s in sessionsState.sessions) {
        if (s.remoteConversationId == evtSid || s.id == evtSid) {
          target = s;
          break;
        }
      }
      if (target == null) return;
    } else {
      target = sessionsState.activeSession;
    }
    if (target == null) return;
    if (_sessionRuntimes.containsKey(target.id)) return;

    final msgs = _messagesForSession(target.id);
    var assistantId = _wakeupAssistantIds[target.id];
    var idx = assistantId == null
        ? -1
        : msgs.indexWhere((m) => m.id == assistantId && m.isStreaming);
    if (idx < 0) {
      if (parsed is AgyTurnResultEvent || parsed is AgyErrorEvent) {
        return;
      }
      if (parsed is AgyTextDeltaEvent && parsed.delta.trim().isEmpty) return;
      if (parsed is AgyThoughtDeltaEvent && parsed.delta.trim().isEmpty) return;
      assistantId = const Uuid().v4();
      _wakeupAssistantIds[target.id] = assistantId;
      _turnStartedAt[assistantId] = DateTime.now();
      final msg = ChatMessage(
        id: assistantId,
        role: ChatRole.assistant,
        text: '',
        createdAt: DateTime.now(),
        modelId: ref.read(settingsProvider).selectedModelId,
        reasoningEffort: ref.read(settingsProvider).reasoningEffort,
        isStreaming: true,
      );
      _updateSessionMessages(target.id, [...msgs, msg]);
    }
    _handleEvent(target, assistantId!, parsed);
    if (parsed is AgyTurnResultEvent || parsed is AgyErrorEvent) {
      _finalizeWakeupMessage(target.id, assistantId);
    } else {
      final targetId = target.id;
      final aid = assistantId;
      _wakeupFinalizeTimers.remove(targetId)?.cancel();
      _wakeupFinalizeTimers[targetId] = Timer(
        const Duration(seconds: 2),
        () => _finalizeWakeupMessage(targetId, aid),
      );
    }
  }

  Future<void> _handleCiWatchCompleted({
    required CiWatchItem watch,
    required bool passed,
    required String summaryMarkdown,
    String? autoFixPrompt,
  }) async {
    if (!ref.mounted) return;
    await appendSystemFeedback(summaryMarkdown);
    if (!passed && autoFixPrompt != null && ref.mounted) {
      await sendPrompt(autoFixPrompt, force: false);
    }
  }

  List<String> _queuedPromptLabels(String sessionId) {
    return (_queuedItemsBySession[sessionId] ?? const [])
        .map((e) => e.prompt)
        .toList();
  }

  void _completeRunningSubagents(String sessionId) {
    final existing = _activeSubagentsBySession[sessionId];
    if (existing == null || existing.isEmpty) return;
    var changed = false;
    final next = existing.map((s) {
      if (s.isActive) {
        changed = true;
        return s.copyWith(status: SubagentStatus.completed);
      }
      return s;
    }).toList();
    if (!changed) return;
    _activeSubagentsBySession[sessionId] = next;
    if (_loadedSessionId == sessionId) {
      state = state.copyWith(activeSubagents: next);
    }
  }

  void dismissSubagents({String? sessionId}) {
    final targetSid = sessionId ?? _loadedSessionId;
    if (targetSid != null) {
      _activeSubagentsBySession.remove(targetSid);
      _wakeupSpawnedSubagentSessions.remove(targetSid);
    }
    if (targetSid == null || _loadedSessionId == targetSid) {
      state = state.copyWith(activeSubagents: const []);
    }
  }

  Set<String> _computeActiveBgIds() {
    return <String>{..._sessionRuntimes.keys};
  }

  Future<void> _loadMessages(String sessionId) async {
    final inFlight = _inFlightMessages[sessionId];
    final activeRt = _sessionRuntimes[sessionId];
    final sessionSubagents =
        _activeSubagentsBySession[sessionId] ?? const <ActiveSubagent>[];
    if (inFlight != null) {
      if (!ref.mounted || _loadedSessionId != sessionId) return;
      final isSessionStreaming = activeRt != null;
      state = state.copyWith(
        messages: List<ChatMessage>.from(inFlight),
        isStreaming: isSessionStreaming,
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        clearPermission: _pendingPermissionsBySession[sessionId] == null,
        stallWarning: _sessionStallWarnings[sessionId],
        clearStallWarning: _sessionStallWarnings[sessionId] == null,
        loopWarning: _sessionLoopWarnings[sessionId],
        clearLoopWarning: _sessionLoopWarnings[sessionId] == null,
        activeTurnId: activeRt?.turnId,
        clearActiveTurnId: activeRt == null,
        activeBackgroundSessionIds: _computeActiveBgIds(),
        activeSubagents: sessionSubagents,
        loadedSessionId: sessionId,
      );
      return;
    }

    final rawList = await ChatMessageStore.instance.load(sessionId);
    if (!ref.mounted || _loadedSessionId != sessionId) return;
    // Re-check in case a background turn completed or started while awaiting I/O.
    final latestInFlight = _inFlightMessages[sessionId];
    final latestRt = _sessionRuntimes[sessionId];
    final latestSubagents =
        _activeSubagentsBySession[sessionId] ?? const <ActiveSubagent>[];
    if (latestInFlight != null) {
      state = state.copyWith(
        messages: List<ChatMessage>.from(latestInFlight),
        isStreaming: latestRt != null,
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        clearPermission: _pendingPermissionsBySession[sessionId] == null,
        stallWarning: _sessionStallWarnings[sessionId],
        clearStallWarning: _sessionStallWarnings[sessionId] == null,
        loopWarning: _sessionLoopWarnings[sessionId],
        clearLoopWarning: _sessionLoopWarnings[sessionId] == null,
        activeTurnId: latestRt?.turnId,
        clearActiveTurnId: latestRt == null,
        activeBackgroundSessionIds: _computeActiveBgIds(),
        activeSubagents: latestSubagents,
        loadedSessionId: sessionId,
      );
      return;
    }

    final list = rawList
        .map((m) => m.copyWith(
              isStreaming: false,
              tools: _finalizeTools(m.tools),
            ))
        .toList();
    state = ChatThreadState(
      messages: list,
      isStreaming: latestRt != null,
      activeTurnId: latestRt?.turnId,
      queuedPrompts: _queuedPromptLabels(sessionId),
      pendingPermission: _pendingPermissionsBySession[sessionId],
      stallWarning: _sessionStallWarnings[sessionId],
      loopWarning: _sessionLoopWarnings[sessionId],
      activeBackgroundSessionIds: _computeActiveBgIds(),
      activeSubagents: latestSubagents,
      loadedSessionId: sessionId,
    );
  }

  Future<void> _persistMessages(String sessionId, List<ChatMessage> msgs) {
    _persistTimers.remove(sessionId)?.cancel();
    return ChatMessageStore.instance.save(sessionId, msgs);
  }

  void _schedulePersistMessages(String sessionId) {
    if (_persistTimers[sessionId]?.isActive == true) return;
    _persistTimers[sessionId] = Timer(const Duration(seconds: 2), () {
      _persistTimers.remove(sessionId);
      if (!ref.mounted) return;
      final latest = _messagesForSession(sessionId);
      if (latest.isNotEmpty) {
        unawaited(ChatMessageStore.instance.save(sessionId, latest));
      }
    });
  }

  static String? _boundToolOutput(String? raw) {
    if (raw == null ||
        raw.length <= 8192 ||
        ChatTurnHelpers.hasDiffOutput(raw)) {
      return raw;
    }
    return '${raw.substring(0, 8192)}\n… [truncated ${raw.length - 8192} chars]';
  }

  static String _compactLoopParamsJson(Map<String, dynamic> params) {
    if (params.isEmpty) return '{}';
    final compact = <String, dynamic>{};
    for (final entry in params.entries) {
      final v = entry.value;
      if (v is String && v.length > 240) {
        compact[entry.key] =
            '${v.substring(0, 120)}...[len=${v.length},h=${v.hashCode}]';
      } else {
        compact[entry.key] = v;
      }
    }
    return jsonEncode(compact);
  }

  List<ChatMessage> _messagesForSession(String sessionId) {
    return _inFlightMessages[sessionId] ??
        (_loadedSessionId == sessionId ? state.messages : const []);
  }

  void _updateSessionMessages(
    String sessionId,
    List<ChatMessage> next, {
    double? tokensPerSecond,
    bool coalesceUi = false,
  }) {
    _inFlightMessages[sessionId] = next;
    if (_loadedSessionId != sessionId) return;

    final rt = _sessionRuntimes[sessionId];
    if (tokensPerSecond != null && rt != null) {
      rt.latestTokensPerSec = tokensPerSecond;
    }

    if (!coalesceUi || rt == null) {
      rt?.uiEmitTimer?.cancel();
      rt?.uiEmitTimer = null;
      rt?.pendingUiEmit = false;
      state = state.copyWith(
        messages: next,
        tokensPerSecond: tokensPerSecond ?? state.tokensPerSecond,
      );
      return;
    }

    // Leading-edge immediate emit + 48ms trailing coalesce (~21fps) so rapid
    // streaming token and tool bursts never choke Markdown/milestone layout.
    if (rt.uiEmitTimer == null) {
      state = state.copyWith(
        messages: next,
        tokensPerSecond: tokensPerSecond ?? rt.latestTokensPerSec,
      );
      rt.pendingUiEmit = false;
      rt.uiEmitTimer = Timer(const Duration(milliseconds: 48), () {
        rt.uiEmitTimer = null;
        if (!ref.mounted || _loadedSessionId != sessionId) return;
        if (rt.pendingUiEmit) {
          rt.pendingUiEmit = false;
          final latest = _inFlightMessages[sessionId];
          if (latest != null) {
            state = state.copyWith(
              messages: latest,
              tokensPerSecond: rt.latestTokensPerSec,
            );
          }
        }
      });
    } else {
      rt.pendingUiEmit = true;
    }
  }

  ({double? durationSec, double? tokPerSec}) _computeTurnStats({
    required String assistantId,
    required String text,
    required String thoughts,
    TokenUsage? usage,
    double reportedDurationSeconds = 0,
  }) {
    final now = DateTime.now();
    final startedAt = _turnStartedAt[assistantId];
    final wallSec = startedAt != null
        ? now.difference(startedAt).inMilliseconds / 1000.0
        : 0.0;
    final durationSec = reportedDurationSeconds > 0
        ? reportedDurationSeconds
        : (wallSec > 0 ? wallSec : null);

    final genStart = _firstOutputAt[assistantId] ?? startedAt;
    final genSec = genStart != null
        ? now.difference(genStart).inMilliseconds / 1000.0
        : (durationSec ?? 0.0);
    final safeGenSec = genSec < 0.1 ? 0.1 : genSec;

    double? tokPerSec;
    final outTokens = (usage?.outputTokens ?? 0) + (usage?.thinkingTokens ?? 0);
    if (outTokens > 0) {
      tokPerSec = outTokens / safeGenSec;
    } else {
      final charLen = text.trim().length + thoughts.trim().length;
      if (charLen > 0) {
        tokPerSec = (charLen * 0.35) / safeGenSec;
      }
    }
    return (durationSec: durationSec, tokPerSec: tokPerSec);
  }

  void _attachCheckpointAsync({
    required String sessionId,
    required String userMsgId,
    required int streamToken,
    required Future<Map<String, Object?>> Function() createFn,
  }) {
    unawaited(() async {
      try {
        final cp = await createFn();
        if (!ref.mounted || _sessionTurnTokens[sessionId] != streamToken) return;
        final refHash = cp['ref']?.toString() ?? '';
        if (cp['ok'] == true && refHash.isNotEmpty) {
          final currentMsgs = _messagesForSession(sessionId);
          final uIdx = currentMsgs.indexWhere((m) => m.id == userMsgId);
          if (uIdx >= 0) {
            final updated = [...currentMsgs];
            updated[uIdx] = updated[uIdx].copyWith(checkpointRef: refHash);
            _updateSessionMessages(sessionId, updated);
            unawaited(_persistMessages(sessionId, updated));
          }
        }
      } catch (_) {}
    }());
  }

  Future<void> _runDeterministicAutoVerify({
    required String sessionId,
    required String command,
    required String cwd,
  }) async {
    try {
      final raw = await RuntimeBridge.instance.runShellCommand(
        command: '$command; echo "__AGY_VERIFY_EXIT=\$?__"',
        cwd: cwd.isEmpty ? null : cwd,
      );
      if (!ref.mounted || _loadedSessionId != sessionId) return;
      final match = RegExp(r'__AGY_VERIFY_EXIT=(\d+)__').firstMatch(raw);
      final code = int.tryParse(match?.group(1) ?? '');
      final cleaned = raw.replaceAll(RegExp(r'__AGY_VERIFY_EXIT=\d+__'), '').trim();
      if (code == 0) {
        await appendSystemFeedback('**Auto-Verify Passed** (`$command`)');
      } else if (code != null) {
        final tail = cleaned.length > 600
            ? cleaned.substring(cleaned.length - 600)
            : cleaned;
        await appendSystemFeedback(
          '**Auto-Verify Failed (exit $code)** (`$command`)\n```\n$tail\n```',
        );
      }
    } catch (_) {}
  }

  Future<void> sendPrompt(
    String rawText, {
    List<String> attachments = const [],
    bool force = false,
    AgySessionSummary? targetSession,
  }) async {
    final prompt = rawText.trim();
    if (prompt.isEmpty && attachments.isEmpty) return;

    var session = targetSession ?? ref.read(sessionsProvider).activeSession;
    final targetSid = session?.id ?? _loadedSessionId;
    final rtTasks = ref.read(runtimeProvider).backgroundTasks;
    final hasBgTaskForTarget = rtTasks.any((t) {
      if (targetSid != null &&
          t.turnId == _sessionRuntimes[targetSid]?.turnId) {
        return true;
      }
      final belongsToOtherSession = _sessionRuntimes.entries.any(
        (e) =>
            e.key != targetSid &&
            (e.value.turnId == t.turnId || e.key == t.turnId),
      );
      return !belongsToOtherSession;
    });
    final sessionBusy =
        (targetSid != null && _sessionRuntimes.containsKey(targetSid)) ||
            hasBgTaskForTarget;
    if (!force && sessionBusy) {
      final queueSid = targetSid ?? 'default';
      final nextQueue = <({String prompt, List<String> attachments})>[
        ...(_queuedItemsBySession[queueSid] ?? const []),
        (prompt: prompt, attachments: List<String>.from(attachments)),
      ];
      _queuedItemsBySession[queueSid] = nextQueue;
      if (_loadedSessionId == queueSid) {
        state = state.copyWith(
          queuedPrompts: nextQueue.map((e) => e.prompt).toList(),
        );
      }
      return;
    }

    session ??= await ref.read(sessionsProvider.notifier).createSession();
    if (!ref.mounted) return;

    final settings = ref.read(settingsProvider);
    final harness = ref.read(harnessProvider);
    final activeCustom = ref.read(activeCustomProviderProvider);
    final turnRoute = activeCustom == null
        ? HarnessTurnRouter.routeTurn(
            prompt: prompt,
            selectedModelId: settings.selectedModelId,
            selectedEffort: settings.reasoningEffort,
            speedTierName: settings.speedTier.name,
            smartRoutingEnabled: harness.smartRoutingEnabled,
            quotaSaverEnabled: harness.quotaSaverEnabled,
            hasAttachments: attachments.isNotEmpty,
          )
        : (
            modelId: activeCustom.modelId,
            effort: '',
            skipRepoMap: false,
            downgraded: false,
          );
    final activeModelId = turnRoute.modelId;
    final activeEffort = turnRoute.effort;
    final hosts = ref.read(hostsProvider);
    final sshHost = hosts.activeSshHost;
    final textAttachments =
        attachments.where((p) => !ChatTurnHelpers.isImagePath(p)).toList();
    final attachmentNote = textAttachments.isEmpty
        ? ''
        : '\n\n[Attached files: ${textAttachments.join(', ')}]';
    final effectivePrompt = prompt.isNotEmpty
        ? '$prompt$attachmentNote'
        : (attachmentNote.trim().isNotEmpty
            ? attachmentNote.trim()
            : 'Analyze the attached image(s).');
    final now = DateTime.now();

    final priorMsgs = _messagesForSession(session.id);
    final prevCompactIdx =
        priorMsgs.lastIndexWhere((m) => m.isCompactionSummary);
    final hasPostCompactUserTurn = prevCompactIdx >= 0 &&
        priorMsgs.skip(prevCompactIdx + 1).any((m) => m.role == ChatRole.user);
    final carryCompactContext =
        (activeCustom != null ||
                session.remoteConversationId == null ||
                session.remoteConversationId!.isEmpty) &&
            prevCompactIdx >= 0 &&
            !hasPostCompactUserTurn &&
            priorMsgs[prevCompactIdx].text.trim().isNotEmpty;

    final userMsgId = const Uuid().v4();
    final userMsg = ChatMessage(
      id: userMsgId,
      role: ChatRole.user,
      text: prompt,
      createdAt: now,
      attachments: attachments,
    );

    final assistantId = const Uuid().v4();
    final assistantMsg = ChatMessage(
      id: assistantId,
      role: ChatRole.assistant,
      text: '',
      createdAt: now,
      modelId: activeModelId,
      reasoningEffort: activeEffort,
      isStreaming: true,
    );

    final nextMessages = [...priorMsgs, userMsg, assistantMsg];
    final turnId = const Uuid().v4();
    final streamToken = ++_nextStreamToken;
    _sessionTurnTokens[session.id] = streamToken;
    if (_loadedSessionId == null || targetSession == null) {
      _loadedSessionId = session.id;
    }
    _turnStartedAt[assistantId] = now;
    _turnModelId[assistantId] = activeModelId;
    _turnEffort[assistantId] = activeEffort;
    _inFlightMessages[session.id] = nextMessages;
    _sessionLoopWarnings.remove(session.id);
    _sessionStallWarnings.remove(session.id);
    _pendingPermissionsBySession.remove(session.id);

    final rt = _SessionTurnRuntime(
      turnId: turnId,
      isSsh: activeCustom == null && sshHost != null,
      isCustomOpenAi: activeCustom != null,
    );
    _sessionRuntimes.remove(session.id)?.dispose();
    _sessionRuntimes[session.id] = rt;

    final retainedSubagents = (_activeSubagentsBySession[session.id] ?? const [])
        .where((s) => s.isActive)
        .toList();
    if (retainedSubagents.isEmpty) {
      _activeSubagentsBySession.remove(session.id);
    } else {
      _activeSubagentsBySession[session.id] = retainedSubagents;
    }

    final isViewingSession = _loadedSessionId == session.id;
    state = state.copyWith(
      messages: isViewingSession ? nextMessages : state.messages,
      isStreaming: isViewingSession ? true : state.isStreaming,
      activeTurnId: isViewingSession ? turnId : state.activeTurnId,
      activeBackgroundSessionIds: _computeActiveBgIds(),
      activeSubagents: isViewingSession ? retainedSubagents : state.activeSubagents,
      clearPermission: isViewingSession,
      clearStallWarning: isViewingSession,
      clearLoopWarning: isViewingSession,
      tokensPerSecond: isViewingSession ? 0 : state.tokensPerSecond,
      loadedSessionId: isViewingSession ? session.id : state.loadedSessionId,
    );

    if (session.messageCount == 0) {
      final baseTitle = prompt.isNotEmpty ? prompt : 'Image attachment';
      final title = baseTitle.length > 36
          ? '${baseTitle.substring(0, 36)}…'
          : baseTitle;
      session = session.copyWith(title: title);
    }
    await ref.read(sessionsProvider.notifier).updateSession(
          session.copyWith(
            updatedAt: DateTime.now(),
            messageCount: nextMessages.length,
            lastPreview: prompt.isNotEmpty ? prompt : '[Image attachment]',
          ),
        );
    if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) return;

    final runtime = ref.read(runtimeProvider);
    final project = ref.read(projectsProvider).activeProject;
    final perms = ref.read(permissionsProvider);
    final effectivePreset = project.permissionPreset ?? settings.permissionPreset;
    final skipPerms = effectivePreset == AntigravityPermissionPreset.turbo;
    final allowNonWorkspace = project.allowNonWorkspaceAccess ??
        (settings.allowNonWorkspaceAccess || perms.allFilesAccess);

    var customizations = ref.read(customizationsProvider);
    if (!runtime.status.safeMode && customizations.isEmpty) {
      try {
        await ref.read(customizationsProvider.notifier).refresh();
        if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
          return;
        }
        customizations = ref.read(customizationsProvider);
      } catch (_) {}
    }

    final effectiveWorkspace = session.workspacePath.isNotEmpty
        ? session.workspacePath
        : (project.primaryFolder.isNotEmpty
            ? project.primaryFolder
            : (runtime.status.workspaceRoot ?? ''));

    final requestedMode = AgyExecutionMode.fromCli(settings.executionMode);
    final effectiveMode =
        sshHost != null ? requestedMode : requestedMode.androidSafe;

    final firstSlash = prompt.startsWith('/')
        ? prompt.split(RegExp(r'\s+')).first.toLowerCase()
        : '';
    final isBuiltInSlash = firstSlash.isNotEmpty &&
        AgyCliCatalog.slashCommands.any(
          (c) => c.command == firstSlash || c.aliases.contains(firstSlash),
        );
    final skillExpandedPrompt = (!runtime.status.safeMode && !isBuiltInSlash)
        ? AgentCustomizationHelper.resolveInvokedSkillPrompt(
            prompt,
            customizations,
          )
        : null;
    final promptWithSkill = skillExpandedPrompt != null
        ? '$skillExpandedPrompt$attachmentNote'
        : effectivePrompt;

    final isNewRemoteSession = session.remoteConversationId == null ||
        session.remoteConversationId!.isEmpty;
    // Native `agy` already reads GEMINI.md / AGENTS.md from disk; only inject
    // `<agents_instructions>` when Quota Saver is off or on `/v1` OpenAI providers.
    final agentsContext = (!runtime.status.safeMode &&
            activeCustom == null &&
            !harness.quotaSaverEnabled &&
            isNewRemoteSession)
        ? AgentCustomizationHelper.buildAgentsContextBlock(customizations)
        : '';
    var repoMapContext = '';
    if (!runtime.status.safeMode &&
        activeCustom == null &&
        sshHost == null &&
        isNewRemoteSession &&
        harness.repoMapEnabled &&
        !turnRoute.skipRepoMap &&
        effectiveWorkspace.isNotEmpty) {
      try {
        repoMapContext = await RepoMapBuilder.buildFromDirectory(
          effectiveWorkspace,
          maxTokens: harness.quotaSaverEnabled ? 600 : 1000,
          maxFiles: harness.quotaSaverEnabled ? 80 : 120,
        );
      } catch (_) {}
      if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) return;
    }
    final contextPrefix = [agentsContext, repoMapContext]
        .where((s) => s.trim().isNotEmpty)
        .join('\n\n');
    final promptWithAgents = contextPrefix.isNotEmpty
        ? '$contextPrefix\n\n$promptWithSkill'
        : promptWithSkill;

    final requestPrompt = carryCompactContext
        ? '[Compacted Session Context]\n${priorMsgs[prevCompactIdx].text.trim()}\n\n[User Request]\n$promptWithAgents'
        : promptWithAgents;

    // Hybrid Cloud + Local LLM Offline Fallback:
    final customState = ref.read(customProvidersProvider);
    final policyState = ref.read(devicePolicyProvider);
    final hybridFallbackProfile = (activeCustom == null &&
            sshHost == null &&
            policyState.isOffline &&
            customState.hybridOfflineFallbackEnabled)
        ? customState.fallbackProfile
        : null;
    final effectiveOpenAiProfile = activeCustom ?? hybridFallbackProfile;

    final Stream<AgyChatEvent> stream;
    AgyPromptRequest? localRequest;
    try {
      if (effectiveOpenAiProfile != null) {
        final systemCustomizations = runtime.status.safeMode
            ? ''
            : AgentCustomizationHelper.buildOpenAiSystemCustomizations(
                customizations,
              );
        final customKey = await ref
            .read(customProvidersProvider.notifier)
            .readApiKey(effectiveOpenAiProfile.id);
        if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
          return;
        }
        String? sshPwd;
        String? sshKey;
        Future<void> saveFp(String fp) => sshHost == null
            ? Future.value()
            : ref.read(hostsProvider.notifier).saveHostFingerprint(sshHost.id, fp);
        if (sshHost != null) {
          final creds = await ref
              .read(hostsProvider.notifier)
              .readCredentials(sshHost.id);
          if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
            return;
          }
          sshPwd = creds.$1;
          sshKey = creds.$2;
        }
        if (harness.autoCheckpointEnabled &&
            (sshHost != null || runtime.status.isReady)) {
          _attachCheckpointAsync(
            sessionId: session.id,
            userMsgId: userMsgId,
            streamToken: streamToken,
            createFn: () => sshHost != null
                ? SshAgyRunner.instance.createCheckpoint(
                    host: sshHost,
                    cwd: effectiveWorkspace,
                    password: sshPwd,
                    privateKeyPem: sshKey,
                    onTrustFirstKey: saveFp,
                  )
                : RuntimeBridge.instance.createCheckpoint(
                    cwd: effectiveWorkspace.isEmpty ? null : effectiveWorkspace,
                  ),
          );
        }
        final historySlice = prevCompactIdx >= 0
            ? priorMsgs.skip(prevCompactIdx + (carryCompactContext ? 1 : 0))
            : priorMsgs;
        final historyTurns = historySlice
            .where((m) => !m.isStreaming && m.text.trim().isNotEmpty)
            .map((m) => (
                  role: m.role == ChatRole.assistant ? 'assistant' : 'user',
                  text: m.text,
                ))
            .toList();
        stream = OpenAiCompatRunner.instance.runPrompt(
          profile: effectiveOpenAiProfile,
          apiKey: customKey,
          turnId: turnId,
          prompt: requestPrompt,
          workspacePath: effectiveWorkspace,
          dangerouslySkipPermissions: skipPerms,
          systemInstructions: systemCustomizations,
          history: historyTurns,
          attachments: attachments,
          sshHost: sshHost,
          sshPassword: sshPwd,
          sshPrivateKey: sshKey,
          onTrustFirstKey: sshHost == null ? null : saveFp,
        );
      } else {
        final apiKey = await ref.read(authServiceProvider).readGeminiApiKey();
        if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
          return;
        }

        final request = AgyPromptRequest(
          prompt: requestPrompt,
          workspacePath: effectiveWorkspace,
          extraDirs: [
            ...project.folders,
            if (perms.allFilesAccess) perms.externalStorageRoot,
            if (perms.allFilesAccess) '/sdcard',
          ],
          conversationId: session.remoteConversationId,
          modelId: activeModelId,
          effortCliValue: activeEffort,
          mode: effectiveMode,
          dangerouslySkipPermissions: skipPerms,
          allowNonWorkspaceAccess: allowNonWorkspace,
          geminiApiKey: apiKey,
          agentName: settings.activeAgent.isEmpty ? null : settings.activeAgent,
          printTimeoutSeconds: settings.printTimeoutSeconds > 0
              ? settings.printTimeoutSeconds
              : null,
          disableSlashCommands: settings.disableSlashCommands,
          continueLast: settings.continueLast &&
              !carryCompactContext &&
              (session.remoteConversationId == null ||
                  session.remoteConversationId!.isEmpty),
          remoteAgent:
              settings.remoteAgent.isEmpty ? null : settings.remoteAgent,
          attachments: attachments,
        );

        if (sshHost != null) {
          final (pwd, key) = await ref
              .read(hostsProvider.notifier)
              .readCredentials(sshHost.id);
          if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
            return;
          }
          Future<void> saveFp(String fp) => ref
              .read(hostsProvider.notifier)
              .saveHostFingerprint(sshHost.id, fp);
          if (harness.autoCheckpointEnabled &&
              effectiveMode != AgyExecutionMode.plan) {
            _attachCheckpointAsync(
              sessionId: session.id,
              userMsgId: userMsgId,
              streamToken: streamToken,
              createFn: () => SshAgyRunner.instance.createCheckpoint(
                host: sshHost,
                cwd: effectiveWorkspace,
                password: pwd,
                privateKeyPem: key,
                onTrustFirstKey: saveFp,
              ),
            );
          }
          stream = SshAgyRunner.instance.runPrompt(
            host: sshHost,
            request: request,
            turnId: turnId,
            password: pwd,
            privateKeyPem: key,
            onTrustFirstKey: saveFp,
          );
        } else {
          if (!runtime.status.isReady) {
            _finishAssistantMessage(
              session: session,
              assistantId: assistantId,
              text:
                  'On-device Antigravity CLI (`agy`) is not installed yet.\n\nTap **Setup Runtime** in Settings or the Quick Panel to install `agy` natively on your phone, switch to an **SSH Remote Host**, or configure an **External /v1 Model** in Settings.',
            );
            return;
          }
          if (harness.autoCheckpointEnabled &&
              effectiveMode != AgyExecutionMode.plan) {
            _attachCheckpointAsync(
              sessionId: session.id,
              userMsgId: userMsgId,
              streamToken: streamToken,
              createFn: () => RuntimeBridge.instance.createCheckpoint(
                cwd: effectiveWorkspace.isEmpty ? null : effectiveWorkspace,
              ),
            );
          }
          localRequest = request;
          stream = RuntimeBridge.instance.runPrompt(
            request,
            turnId,
            attachments: attachments,
          );
        }
      }
    } catch (err) {
      if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) return;
      _finishAssistantMessage(
        session: session,
        assistantId: assistantId,
        text: 'Failed to start agent turn: $err',
      );
      return;
    }

    final currentSession = _latestSession(session);
    rt.activeLocalRequest = localRequest;
    _resetWatchdog(currentSession.id);

    rt.sub = stream.listen(
      (evt) {
        if (!ref.mounted ||
            _sessionTurnTokens[currentSession.id] != streamToken) {
          return;
        }
        _handleEvent(currentSession, assistantId, evt);
      },
      onError: (Object err) {
        if (!ref.mounted ||
            _sessionTurnTokens[currentSession.id] != streamToken) {
          return;
        }
        _finishAssistantMessage(
          session: currentSession,
          assistantId: assistantId,
          text: 'Agent error: $err',
        );
      },
      onDone: () {
        if (!ref.mounted ||
            _sessionTurnTokens[currentSession.id] != streamToken) {
          return;
        }
        _completeStreaming(currentSession, assistantId);
      },
    );
  }

  void _handleEvent(
    AgySessionSummary session,
    String assistantId,
    AgyChatEvent evt,
  ) {
    final rt = _sessionRuntimes[session.id];
    _resetWatchdog(session.id);
    if (_sessionStallWarnings.remove(session.id) != null &&
        _loadedSessionId == session.id &&
        state.stallWarning != null) {
      state = state.copyWith(clearStallWarning: true);
    }
    final msgs = _messagesForSession(session.id);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final current = msgs[idx];
    if (!current.isStreaming || current.completedAt != null) return;

    switch (evt) {
      case AgyInitEvent():
        if (rt?.isCustomOpenAi != true) {
          ref.read(authProvider.notifier).markAuthenticatedFromTurn();
        }
        if (evt.model != null && evt.model!.isNotEmpty) {
          _turnModelId[assistantId] = evt.model!;
        }
        if (current.isCompactionSummary) {
          final pending = _pendingCompactions[assistantId];
          if (pending != null && evt.conversationId.isNotEmpty) {
            _pendingCompactions[assistantId] = (
              turns: pending.turns,
              compactCount: pending.compactCount,
              instructions: pending.instructions,
              tempRemoteId: evt.conversationId,
            );
          }
        } else if (evt.conversationId.isNotEmpty) {
          final latest = _latestSession(session);
          ref.read(sessionsProvider.notifier).updateSession(
                latest.copyWith(remoteConversationId: evt.conversationId),
              );
        }
      case AgyThoughtDeltaEvent():
        rt?.receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        final rate = _loadedSessionId == session.id
            ? _recordRateSample(session.id, evt.delta)
            : null;
        final nextSteps = [...current.steps];
        if (evt.delta.isNotEmpty) {
          if (nextSteps.isNotEmpty &&
              nextSteps.last.kind == ChatMilestoneKind.thought) {
            final last = nextSteps.last;
            nextSteps[nextSteps.length - 1] =
                last.copyWith(text: '${last.text}${evt.delta}');
          } else {
            nextSteps.add(
              ChatMilestoneStep(
                id: 'thought-${nextSteps.length}',
                kind: ChatMilestoneKind.thought,
                text: evt.delta,
              ),
            );
          }
        }
        final nextUsage =
            ChatTurnHelpers.mergeStepUsage(current.usage, evt.stepUsage);
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            thoughts: '${current.thoughts}${evt.delta}',
            steps: nextSteps,
            usage: nextUsage,
            contextTokens: (evt.stepUsage?.contextTokens ?? 0) > 0
                ? evt.stepUsage!.contextTokens
                : current.contextTokens,
          ),
          tokensPerSecond: rate,
          coalesceUi: true,
        );
      case AgyTextDeltaEvent():
        rt?.receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        final rate = _loadedSessionId == session.id
            ? _recordRateSample(session.id, evt.delta)
            : null;
        final nextSteps = _appendTextStep(current.steps, evt.delta);
        final nextUsage =
            ChatTurnHelpers.mergeStepUsage(current.usage, evt.stepUsage);
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: '${current.text}${evt.delta}',
            steps: nextSteps,
            usage: nextUsage,
            contextTokens: (evt.stepUsage?.contextTokens ?? 0) > 0
                ? evt.stepUsage!.contextTokens
                : current.contextTokens,
          ),
          tokensPerSecond: rate,
          coalesceUi: true,
        );
      case AgyToolCallEvent():
        rt?.receivedTurnContent = true;
        final tools = [...current.tools];
        final nextSteps = [...current.steps];
        final effCallId = evt.callId.isNotEmpty
            ? evt.callId
            : 'tool-${evt.toolName}-${tools.length}';
        final tIdx = tools.indexWhere((t) => t.id == effCallId);
        final resolvedToolName = evt.toolName != 'tool' || tIdx < 0
            ? evt.toolName
            : tools[tIdx].toolName;
        final mergedParams = tIdx < 0
            ? evt.parameters
            : (evt.parameters.isEmpty
                ? tools[tIdx].parameters
                : <String, dynamic>{
                    ...tools[tIdx].parameters,
                    ...evt.parameters,
                  });
        if (tIdx >= 0) {
          final prev = tools[tIdx];
          final prevOut = prev.output;
          final nextOut = _boundToolOutput(evt.output);
          final prevHasDiff = ChatTurnHelpers.hasDiffOutput(prevOut);
          final nextHasDiff = ChatTurnHelpers.hasDiffOutput(nextOut);
          final mergedOutput = switch ((prevHasDiff, nextOut)) {
            (_, null) => prevOut,
            (true, final String nxt) when !nextHasDiff =>
              nxt.trim().isEmpty ? prevOut : '${nxt.trim()}\n\n$prevOut',
            _ => nextOut,
          };
          tools[tIdx] = ChatToolStep(
            id: effCallId,
            toolName: resolvedToolName,
            state: evt.state,
            parameters: mergedParams,
            output: _boundToolOutput(mergedOutput),
            error: evt.errorMessage ?? prev.error,
            durationSeconds: evt.durationSeconds ?? prev.durationSeconds,
            startedAt: prev.startedAt,
          );
        } else {
          tools.add(
            ChatToolStep(
              id: effCallId,
              toolName: resolvedToolName,
              state: evt.state,
              parameters: evt.parameters,
              output: _boundToolOutput(evt.output),
              error: evt.errorMessage,
              durationSeconds: evt.durationSeconds,
              startedAt:
                  evt.state == ToolCallState.running ? DateTime.now() : null,
            ),
          );
          nextSteps.add(
            ChatMilestoneStep(
              id: 'tool-$effCallId',
              kind: ChatMilestoneKind.tool,
              toolId: effCallId,
            ),
          );
        }
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(tools: tools, steps: nextSteps),
          coalesceUi: true,
        );
        final prevSubagents = _activeSubagentsBySession[session.id] ?? const [];
        final nextSubagents = ChatTurnHelpers.applySubagentToolEvent(
          prevSubagents,
          callId: effCallId,
          toolName: resolvedToolName,
          state: evt.state,
          parameters: mergedParams,
          output: evt.output,
          errorMessage: evt.errorMessage,
        );
        if (!identical(nextSubagents, prevSubagents)) {
          if (nextSubagents.isEmpty) {
            _activeSubagentsBySession.remove(session.id);
          } else {
            _activeSubagentsBySession[session.id] = nextSubagents;
          }
          if (_wakeupAssistantIds[session.id] == assistantId &&
              ChatTurnHelpers.isSubagentSpawnTool(resolvedToolName)) {
            _wakeupSpawnedSubagentSessions.add(session.id);
          }
          if (_loadedSessionId == session.id) {
            state = state.copyWith(activeSubagents: nextSubagents);
          }
        }
        if (ref.read(harnessProvider).loopBreakerEnabled && rt != null) {
          final isFailed = evt.state == ToolCallState.failed ||
              (evt.errorMessage?.isNotEmpty ?? false);
          LoopDetectionResult loopHit = LoopDetectionResult.none;
          if (rt.seenLoopCallIds.add(effCallId) || evt.parameters.isNotEmpty) {
            loopHit = rt.loopDetector.recordToolCall(
              name: resolvedToolName,
              input: _compactLoopParamsJson(mergedParams),
              isError: isFailed,
              callId: effCallId,
            );
          } else if (isFailed) {
            loopHit = rt.loopDetector.markLastFailed(
              toolName: resolvedToolName,
              callId: effCallId,
            );
          }
          if (loopHit.triggered) {
            _sessionLoopWarnings[session.id] = loopHit;
            if (_loadedSessionId == session.id) {
              state = state.copyWith(loopWarning: loopHit);
              if (ref.read(harnessProvider).autoPivotLoopEnabled) {
                Future.microtask(breakLoopAndPivot);
              }
            }
          }
        }
        if (evt.state != ToolCallState.running) {
          _schedulePersistMessages(session.id);
        }
      case AgyPermissionRequestEvent():
        _pendingPermissionsBySession[session.id] = evt;
        rt?.stallWatchdog?.cancel();
        if (_loadedSessionId == session.id) {
          state = state.copyWith(pendingPermission: evt);
        }
      case AgyTurnResultEvent():
        rt?.receivedTurnContent = true;
        _pendingPermissionsBySession.remove(session.id);
        final statusUpper = evt.status.toUpperCase();
        final errText = evt.error?.trim() ?? '';
        final hasErrorResult = statusUpper == 'ERROR' || errText.isNotEmpty;
        if (statusUpper == 'SUCCESS' && errText.isEmpty) {
          ref.read(authProvider.notifier).markAuthenticatedFromTurn();
        }
        var finalText = current.text.isEmpty ? evt.response : current.text;
        if (finalText.trim().isEmpty && errText.isNotEmpty) {
          finalText = errText;
        }
        final resolvedText = current.isCompactionSummary &&
                finalText.trim().isEmpty
            ? _compactionFallbackText(assistantId)
            : finalText;
        final resolvedUsage = evt.usage.contextTokens > 0
            ? evt.usage
            : ((current.usage?.contextTokens ?? 0) > 0
                ? evt.usage.copyWith(
                    contextTokens: current.usage!.contextTokens,
                  )
                : evt.usage);
        final stats = _computeTurnStats(
          assistantId: assistantId,
          text: resolvedText,
          thoughts: current.thoughts,
          usage: resolvedUsage,
          reportedDurationSeconds: evt.durationSeconds,
        );
        final nextSteps = current.text.isEmpty && resolvedText.trim().isNotEmpty
            ? _appendTextStep(current.steps, resolvedText)
            : current.steps;
        final finalizedTools =
            _finalizeTools(current.tools, failed: hasErrorResult);
        final resolvedChangedFiles = current.changedFiles.isNotEmpty
            ? current.changedFiles
            : extractChangedFilesFromTools(finalizedTools);
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: resolvedText,
            steps: nextSteps,
            usage: resolvedUsage,
            contextTokens: resolvedUsage.contextTokens > 0
                ? resolvedUsage.contextTokens
                : current.contextTokens,
            tools: finalizedTools,
            changedFiles: resolvedChangedFiles,
            durationSeconds: stats.durationSec,
            tokensPerSecond: stats.tokPerSec,
            modelId: _turnModelId[assistantId] ?? current.modelId,
            reasoningEffort: _turnEffort[assistantId] ?? current.reasoningEffort,
            completedAt: DateTime.now(),
            isStreaming: false,
          ),
        );
        if (current.isCompactionSummary) {
          final pending = _pendingCompactions[assistantId];
          if (pending != null && evt.conversationId.isNotEmpty) {
            _pendingCompactions[assistantId] = (
              turns: pending.turns,
              compactCount: pending.compactCount,
              instructions: pending.instructions,
              tempRemoteId: evt.conversationId,
            );
          }
        } else if (evt.conversationId.isNotEmpty) {
          final latest = _latestSession(session);
          ref.read(sessionsProvider.notifier).updateSession(
                latest.copyWith(
                  remoteConversationId: evt.conversationId,
                  updatedAt: DateTime.now(),
                  lastPreview: resolvedText,
                ),
              );
        }
        ref.read(usageProvider.notifier).recordTurn(
              modelId: _turnModelId[assistantId] ??
                  ref.read(settingsProvider).selectedModelId,
              usage: evt.usage,
              sessionId: session.id,
            );
        if (_sessionRuntimes.containsKey(session.id)) {
          unawaited(_completeStreaming(session, assistantId));
        }
      case AgyErrorEvent():
        _pendingPermissionsBySession.remove(session.id);
        if (evt.requiresAuth) {
          ref.read(authProvider.notifier).refresh();
        } else if (rt != null &&
            !rt.receivedTurnContent &&
            !rt.usedFallbackForTurn &&
            rt.activeLocalRequest != null &&
            !evt.message.toLowerCase().contains('auto mode is not available')) {
          rt.usedFallbackForTurn = true;
          final fallbackReq = rt.activeLocalRequest!;
          final fallbackTurnId = const Uuid().v4();
          final fallbackToken = ++_nextStreamToken;
          _sessionTurnTokens[session.id] = fallbackToken;
          rt.turnId = fallbackTurnId;
          if (_loadedSessionId == session.id) {
            state = state.copyWith(
              activeTurnId: fallbackTurnId,
              clearPermission: true,
            );
          }
          rt.sub?.cancel();
          rt.sub = RuntimeBridge.instance
              .runPrompt(fallbackReq, fallbackTurnId, useAcp: false)
              .listen(
                (e) {
                  if (!ref.mounted ||
                      _sessionTurnTokens[session.id] != fallbackToken) {
                    return;
                  }
                  _handleEvent(session, assistantId, e);
                },
                onError: (Object err) {
                  if (!ref.mounted ||
                      _sessionTurnTokens[session.id] != fallbackToken) {
                    return;
                  }
                  _finishAssistantMessage(
                    session: session,
                    assistantId: assistantId,
                    text: current.isCompactionSummary
                        ? _compactionFallbackText(assistantId)
                        : 'Agent error: $err',
                  );
                },
                onDone: () {
                  if (!ref.mounted ||
                      _sessionTurnTokens[session.id] != fallbackToken) {
                    return;
                  }
                  _completeStreaming(session, assistantId);
                },
              );
          return;
        }
        final stats = _computeTurnStats(
          assistantId: assistantId,
          text: current.text,
          thoughts: current.thoughts,
          usage: current.usage,
        );
        final errorOrFallback = current.isCompactionSummary
            ? (current.text.trim().isNotEmpty
                ? current.text
                : _compactionFallbackText(assistantId))
            : (current.text.isEmpty
                ? evt.message
                : '${current.text}\n\n${evt.message}');
        final addedErrorText = current.isCompactionSummary
            ? (current.text.trim().isNotEmpty
                ? ''
                : _compactionFallbackText(assistantId))
            : (current.text.isEmpty ? evt.message : '\n\n${evt.message}');
        final nextSteps = addedErrorText.trim().isNotEmpty
            ? _appendTextStep(current.steps, addedErrorText)
            : current.steps;
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: errorOrFallback,
            steps: nextSteps,
            tools: _finalizeTools(current.tools, failed: true),
            durationSeconds: current.durationSeconds ?? stats.durationSec,
            tokensPerSecond: current.tokensPerSecond ?? stats.tokPerSec,
            modelId: _turnModelId[assistantId] ?? current.modelId,
            reasoningEffort: _turnEffort[assistantId] ?? current.reasoningEffort,
            completedAt: current.completedAt ?? DateTime.now(),
            isStreaming: false,
            requiresAuth: !current.isCompactionSummary && evt.requiresAuth,
          ),
        );
        if (_sessionRuntimes.containsKey(session.id)) {
          unawaited(_completeStreaming(session, assistantId));
        }
    }
  }

  void _replaceMessageInSession(
    String sessionId,
    int idx,
    ChatMessage updated, {
    double? tokensPerSecond,
    bool coalesceUi = false,
  }) {
    final list = [..._messagesForSession(sessionId)];
    if (idx < 0 || idx >= list.length) return;
    list[idx] = updated;
    _updateSessionMessages(
      sessionId,
      list,
      tokensPerSecond: tokensPerSecond,
      coalesceUi: coalesceUi,
    );
  }

  void _finishAssistantMessage({
    required AgySessionSummary session,
    required String assistantId,
    required String text,
  }) {
    final msgs = _messagesForSession(session.id);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx >= 0) {
      final cur = msgs[idx];
      final stats = _computeTurnStats(
        assistantId: assistantId,
        text: text,
        thoughts: cur.thoughts,
        usage: cur.usage,
      );
      final nextSteps = cur.text.isEmpty && text.trim().isNotEmpty
          ? _appendTextStep(cur.steps, text)
          : cur.steps;
      _replaceMessageInSession(
        session.id,
        idx,
        cur.copyWith(
          text: text,
          steps: nextSteps,
          tools: _finalizeTools(cur.tools),
          durationSeconds: cur.durationSeconds ?? stats.durationSec,
          tokensPerSecond: cur.tokensPerSecond ?? stats.tokPerSec,
          modelId: _turnModelId[assistantId] ?? cur.modelId,
          reasoningEffort: _turnEffort[assistantId] ?? cur.reasoningEffort,
          completedAt: cur.completedAt ?? DateTime.now(),
          isStreaming: false,
        ),
      );
    }
    _completeStreaming(session, assistantId);
  }

  bool _markCompletedAssistant(String assistantId) {
    if (!_completedAssistantIds.add(assistantId)) return false;
    _completedAssistantOrder.add(assistantId);
    while (_completedAssistantOrder.length > _maxCompletedAssistantHistory) {
      final oldest = _completedAssistantOrder.removeAt(0);
      _completedAssistantIds.remove(oldest);
    }
    return true;
  }

  Future<void> _completeStreaming(
    AgySessionSummary session,
    String assistantId,
  ) async {
    if (!_markCompletedAssistant(assistantId)) return;
    _wakeupFinalizeTimers.remove(session.id)?.cancel();
    _wakeupAssistantIds.remove(session.id);
    final rt = _sessionRuntimes.remove(session.id);
    final hadLocalRequest = rt?.activeLocalRequest != null;
    rt?.dispose();

    _sessionTurnTokens.remove(session.id);
    _pendingPermissionsBySession.remove(session.id);
    _sessionLoopWarnings.remove(session.id);
    _sessionStallWarnings.remove(session.id);

    final msgs = _messagesForSession(session.id);
    var updatedMsgs = msgs;
    var changed = false;
    final now = DateTime.now();
    for (var i = 0; i < msgs.length; i++) {
      final cur = msgs[i];
      if (cur.id != assistantId && !cur.isStreaming) continue;
      final finalizedTools = _finalizeTools(cur.tools);
      final resolvedText = cur.id == assistantId &&
              cur.isCompactionSummary &&
              cur.text.trim().isEmpty
          ? _compactionFallbackText(assistantId)
          : cur.text;
      if (cur.isStreaming ||
          cur.durationSeconds == null ||
          cur.completedAt == null ||
          resolvedText != cur.text ||
          !identical(finalizedTools, cur.tools)) {
        if (!changed) {
          updatedMsgs = [...msgs];
          changed = true;
        }
        final stats = _computeTurnStats(
          assistantId: cur.id,
          text: resolvedText,
          thoughts: cur.thoughts,
          usage: cur.usage,
        );
        updatedMsgs[i] = cur.copyWith(
          text: resolvedText,
          isStreaming: false,
          tools: finalizedTools,
          durationSeconds: cur.durationSeconds ?? stats.durationSec,
          tokensPerSecond: cur.tokensPerSecond ?? stats.tokPerSec,
          modelId: _turnModelId[cur.id] ?? cur.modelId,
          reasoningEffort: _turnEffort[cur.id] ?? cur.reasoningEffort,
          completedAt: cur.completedAt ?? now,
          changedFiles: cur.changedFiles.isNotEmpty
              ? cur.changedFiles
              : extractChangedFilesFromTools(finalizedTools),
        );
      }
    }
    if (changed) {
      _updateSessionMessages(session.id, updatedMsgs);
    }
    final pendingCompact = _pendingCompactions.remove(assistantId);
    if (pendingCompact?.tempRemoteId != null &&
        pendingCompact!.tempRemoteId!.isNotEmpty) {
      unawaited(
        RuntimeBridge.instance.closeSessionWorker(pendingCompact.tempRemoteId!),
      );
    }
    final persisted = _messagesForSession(session.id);
    _inFlightMessages.remove(session.id);
    _turnStartedAt.remove(assistantId);
    _firstOutputAt.remove(assistantId);
    _turnModelId.remove(assistantId);
    _turnEffort.remove(assistantId);

    final isViewingSession = _loadedSessionId == session.id;
    state = state.copyWith(
      isStreaming: isViewingSession ? false : state.isStreaming,
      tokensPerSecond: isViewingSession ? 0 : state.tokensPerSecond,
      activeBackgroundSessionIds: _computeActiveBgIds(),
      clearPermission: isViewingSession,
      clearStallWarning: isViewingSession,
      clearLoopWarning: isViewingSession,
      clearActiveTurnId: isViewingSession,
    );
    await _persistMessages(session.id, persisted);

    if (hadLocalRequest || persisted.any((m) => m.id == assistantId)) {
      final completedMsg =
          persisted.where((m) => m.id == assistantId).firstOrNull;
      final fallbackCwd = session.workspacePath.isNotEmpty
          ? session.workspacePath
          : ref.read(projectsProvider).activeProject.primaryFolder;
      if (completedMsg != null && completedMsg.changedFiles.isNotEmpty) {
        RepoMapBuilder.invalidateCache(fallbackCwd);
      }
      final pushCwd = extractGitPushCwd(
        completedMsg?.tools ?? const [],
        fallbackCwd: fallbackCwd,
      );
      if (pushCwd != null && pushCwd.isNotEmpty && ref.mounted) {
        unawaited(
          ref.read(ciWatchProvider.notifier).watchLatestRun(
                cwd: pushCwd,
                sessionId: session.id,
              ),
        );
      }
      final harnessSnap = ref.read(harnessProvider);
      final verifyCmd = harnessSnap.effectiveVerifyCommand?.trim() ?? '';
      if (hadLocalRequest &&
          isViewingSession &&
          harnessSnap.autoVerifyEnabled &&
          verifyCmd.isNotEmpty &&
          completedMsg != null &&
          !completedMsg.isCompactionSummary &&
          completedMsg.changedFiles.isNotEmpty) {
        final alreadyRan = completedMsg.tools.any((t) {
          final cmd =
              (t.parameters['CommandLine'] ?? t.parameters['command'] ?? '')
                  .toString();
          return cmd.contains(verifyCmd);
        });
        if (!alreadyRan) {
          unawaited(
            _runDeterministicAutoVerify(
              sessionId: session.id,
              command: verifyCmd,
              cwd: fallbackCwd,
            ),
          );
        }
      }
    }

    final sessionQueue = _queuedItemsBySession[session.id];
    if (sessionQueue != null && sessionQueue.isNotEmpty) {
      final nextItem = sessionQueue.first;
      final rest = sessionQueue.sublist(1);
      if (rest.isEmpty) {
        _queuedItemsBySession.remove(session.id);
      } else {
        _queuedItemsBySession[session.id] = rest;
      }
      if (_loadedSessionId == session.id) {
        state = state.copyWith(
          queuedPrompts: rest.map((e) => e.prompt).toList(),
        );
      }
      await sendPrompt(
        nextItem.prompt,
        attachments: nextItem.attachments,
        force: true,
        targetSession: _latestSession(session),
      );
    } else if (isViewingSession && state.queuedPrompts.isNotEmpty) {
      final nextPrompt = state.queuedPrompts.first;
      state = state.copyWith(
        queuedPrompts: state.queuedPrompts.sublist(1),
      );
      await sendPrompt(
        nextPrompt,
        force: true,
        targetSession: _latestSession(session),
      );
    } else if (isViewingSession &&
        pendingCompact == null &&
        ref.read(harnessProvider).autoCompactEnabled &&
        !_autoCompactingSessions.contains(session.id) &&
        ref.read(contextBudgetProvider).shouldCompact) {
      _autoCompactingSessions.add(session.id);
      Future.microtask(() async {
        try {
          if (!ref.mounted || state.isStreaming) return;
          await compactThread(
            instructions:
                'Auto-compact triggered at high context usage. Summarize decisions, touched files, and pending checks concisely.',
          );
        } finally {
          _autoCompactingSessions.remove(session.id);
        }
      });
    }
  }

  Future<void> stopStreaming({String? sessionId}) async {
    final targetSid =
        sessionId ?? _loadedSessionId ?? state.activeBackgroundSessionIds.firstOrNull;
    final rt = targetSid != null ? _sessionRuntimes.remove(targetSid) : null;
    final turnId = rt?.turnId ??
        ((targetSid == null || targetSid == _loadedSessionId)
            ? state.activeTurnId
            : null);

    if (targetSid != null) {
      _sessionTurnTokens.remove(targetSid);
      _wakeupFinalizeTimers.remove(targetSid)?.cancel();
      _wakeupAssistantIds.remove(targetSid);
      _wakeupSpawnedSubagentSessions.remove(targetSid);
      _activeSubagentsBySession.remove(targetSid);
      _pendingPermissionsBySession.remove(targetSid);
      _sessionLoopWarnings.remove(targetSid);
      _sessionStallWarnings.remove(targetSid);
    }
    rt?.dispose();

    if (turnId != null) {
      try {
        await RuntimeBridge.instance.cancelTurn(turnId);
      } catch (_) {}
      try {
        await SshAgyRunner.instance.cancelActive(turnId: turnId);
      } catch (_) {}
      try {
        await OpenAiCompatRunner.instance.cancelActive(turnId: turnId);
      } catch (_) {}
    }

    final isViewingTarget = targetSid == null || targetSid == _loadedSessionId;
    if (isViewingTarget) {
      final updated = state.messages
          .map((m) => m.isStreaming
              ? m.copyWith(
                  isStreaming: false,
                  tools: _finalizeTools(m.tools, failed: true),
                  completedAt: DateTime.now(),
                )
              : m)
          .toList();
      if (targetSid != null) {
        _inFlightMessages.remove(targetSid);
      }
      state = state.copyWith(
        messages: updated,
        isStreaming: false,
        tokensPerSecond: 0,
        activeBackgroundSessionIds: _computeActiveBgIds(),
        activeSubagents: const [],
        clearPermission: true,
        clearStallWarning: true,
        clearLoopWarning: true,
        clearActiveTurnId: true,
      );
      final saveSid = targetSid ?? ref.read(sessionsProvider).activeSessionId;
      if (saveSid != null) {
        await _persistMessages(saveSid, updated);
      }
    } else {
      final bgMsgs = _inFlightMessages.remove(targetSid);
      if (bgMsgs != null) {
        final cleanedBg = bgMsgs
            .map((m) => m.isStreaming
                ? m.copyWith(
                    isStreaming: false,
                    tools: _finalizeTools(m.tools, failed: true),
                    completedAt: DateTime.now(),
                  )
                : m)
            .toList();
        await _persistMessages(targetSid, cleanedBg);
      }
      state = state.copyWith(
        activeBackgroundSessionIds: _computeActiveBgIds(),
      );
    }
  }

  Future<void> forceStopTask({
    required String kindName,
    String? nativeTaskId,
    String? sessionId,
    int? queuedIndex,
  }) async {
    if (kindName == 'queued' && queuedIndex != null) {
      removeQueuedPrompt(queuedIndex);
      return;
    }
    if (kindName == 'ci' && nativeTaskId != null) {
      ref.read(ciWatchProvider.notifier).cancelWatch(nativeTaskId);
      return;
    }
    if (kindName == 'subagent' ||
        (nativeTaskId != null && nativeTaskId.startsWith('subagent:'))) {
      final sid = sessionId ?? _loadedSessionId;
      if (sid != null) {
        final rtTurn = _sessionRuntimes[sid]?.turnId;
        await stopStreaming(sessionId: sid);
        if (rtTurn != null) {
          await ref
              .read(runtimeProvider.notifier)
              .cancelBackgroundTask('turn:$rtTurn');
        }
        dismissSubagents(sessionId: sid);
      } else {
        await forceStopAllTasks();
      }
      return;
    }
    if (nativeTaskId != null &&
        !nativeTaskId.startsWith('session:') &&
        !nativeTaskId.startsWith('tool:') &&
        !nativeTaskId.startsWith('subagent:')) {
      await ref.read(runtimeProvider.notifier).cancelBackgroundTask(nativeTaskId);
      return;
    }
    if (kindName == 'session' && sessionId != null) {
      await stopStreaming(sessionId: sessionId);
      final rtTurn = _sessionRuntimes[sessionId]?.turnId;
      if (rtTurn != null) {
        await ref
            .read(runtimeProvider.notifier)
            .cancelBackgroundTask('turn:$rtTurn');
      }
      return;
    }
    await stopStreaming();
    await ref.read(runtimeProvider.notifier).refresh();
  }

  Future<int> forceStopAllTasks() async {
    ref.read(ciWatchProvider.notifier).cancelAll();
    for (final sid in _sessionRuntimes.keys.toList()) {
      await stopStreaming(sessionId: sid);
    }
    if (state.isStreaming) {
      await stopStreaming();
    }
    _inFlightMessages.clear();
    _activeSubagentsBySession.clear();
    _wakeupSpawnedSubagentSessions.clear();
    final stoppedNative =
        await ref.read(runtimeProvider.notifier).forceStopAllBackgroundTasks();
    state = state.copyWith(
      activeBackgroundSessionIds: const {},
      activeSubagents: const [],
      isStreaming: false,
      clearPermission: true,
      clearStallWarning: true,
      clearLoopWarning: true,
      clearActiveTurnId: true,
    );
    return stoppedNative;
  }

  Future<void> appendSystemFeedback(
    String text, {
    List<FileChangeEntry> changedFiles = const [],
    bool isCompactionSummary = false,
    List<ChatToolStep> tools = const [],
  }) async {
    var session = ref.read(sessionsProvider).activeSession;
    session ??= await ref.read(sessionsProvider.notifier).createSession();
    final msg = ChatMessage(
      id: const Uuid().v4(),
      role: ChatRole.assistant,
      text: text,
      createdAt: DateTime.now(),
      completedAt: DateTime.now(),
      changedFiles: changedFiles,
      isCompactionSummary: isCompactionSummary,
      tools: tools,
    );
    final updated = [..._messagesForSession(session.id), msg];
    _updateSessionMessages(session.id, updated);
    await _persistMessages(session.id, updated);
  }

  Future<void> sendQueuedNow() async {
    final sid = ref.read(sessionsProvider).activeSessionId ?? _loadedSessionId;
    final sessionQueue = sid == null ? null : _queuedItemsBySession[sid];
    if ((sessionQueue == null || sessionQueue.isEmpty) &&
        state.queuedPrompts.isEmpty) {
      return;
    }
    if (state.isStreaming || (sid != null && _sessionRuntimes.containsKey(sid))) {
      await stopStreaming(sessionId: sid);
      if (!ref.mounted) return;
    }
    if (sessionQueue != null && sessionQueue.isNotEmpty) {
      final nextItem = sessionQueue.first;
      final rest = sessionQueue.sublist(1);
      if (rest.isEmpty) {
        _queuedItemsBySession.remove(sid);
      } else {
        _queuedItemsBySession[sid!] = rest;
      }
      state = state.copyWith(
        queuedPrompts: rest.map((e) => e.prompt).toList(),
      );
      await sendPrompt(
        nextItem.prompt,
        attachments: nextItem.attachments,
        force: true,
      );
      return;
    }
    final nextPrompt = state.queuedPrompts.first;
    state = state.copyWith(
      queuedPrompts: state.queuedPrompts.sublist(1),
    );
    await sendPrompt(nextPrompt, force: true);
  }

  void removeQueuedPrompt(int index) {
    final sid = ref.read(sessionsProvider).activeSessionId ?? _loadedSessionId;
    if (sid != null && _queuedItemsBySession.containsKey(sid)) {
      final list = [...?_queuedItemsBySession[sid]];
      if (index >= 0 && index < list.length) {
        list.removeAt(index);
        if (list.isEmpty) {
          _queuedItemsBySession.remove(sid);
        } else {
          _queuedItemsBySession[sid] = list;
        }
        state = state.copyWith(
          queuedPrompts: list.map((e) => e.prompt).toList(),
        );
        return;
      }
    }
    if (index < 0 || index >= state.queuedPrompts.length) return;
    final updated = [...state.queuedPrompts]..removeAt(index);
    state = state.copyWith(queuedPrompts: updated);
  }

  Future<void> steerNow(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    final sid = _loadedSessionId ?? ref.read(sessionsProvider).activeSessionId;
    if (state.isStreaming || (sid != null && _sessionRuntimes.containsKey(sid))) {
      await stopStreaming(sessionId: sid);
      if (!ref.mounted) return;
    }
    await sendPrompt(trimmed, attachments: attachments, force: true);
  }

  Future<void> regenerateLastTurn() async {
    if (state.isStreaming || state.messages.isEmpty) return;
    final lastUserIdx =
        state.messages.lastIndexWhere((m) => m.role == ChatRole.user);
    if (lastUserIdx < 0) return;
    final lastUser = state.messages[lastUserIdx];
    final trimmedHistory = state.messages.sublist(0, lastUserIdx);
    state = state.copyWith(messages: trimmedHistory);
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      await _persistMessages(activeId, trimmedHistory);
      await _syncSessionMeta(activeId, trimmedHistory);
    }
    await sendPrompt(lastUser.text, attachments: lastUser.attachments);
  }

  Future<void> editAndResend(String userMessageId, String newText) async {
    final trimmed = newText.trim();
    if (trimmed.isEmpty || state.isStreaming) return;
    final idx = state.messages.indexWhere((m) => m.id == userMessageId);
    if (idx < 0) return;
    final original = state.messages[idx];
    final prefix = state.messages.sublist(0, idx);
    state = state.copyWith(messages: prefix);
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      await _persistMessages(activeId, prefix);
      await _syncSessionMeta(activeId, prefix);
    }
    await sendPrompt(trimmed, attachments: original.attachments);
  }

  Future<void> resolvePermission(String optionId) async {
    final perm = state.pendingPermission;
    final sid = _loadedSessionId ?? ref.read(sessionsProvider).activeSessionId;
    final rt = sid != null ? _sessionRuntimes[sid] : null;
    final turnId = rt?.turnId ?? state.activeTurnId;
    if (sid != null) {
      _pendingPermissionsBySession.remove(sid);
      _resetWatchdog(sid);
    }
    state = state.copyWith(clearPermission: true);
    if (perm != null && turnId != null) {
      try {
        if (rt?.isCustomOpenAi == true) {
          await OpenAiCompatRunner.instance.resolvePermission(
            turnId: turnId,
            requestId: perm.requestId,
            optionId: optionId,
          );
        } else if (rt?.isSsh == true) {
          await SshAgyRunner.instance.respondToPermission(
            turnId: turnId,
            requestId: perm.requestId,
            optionId: optionId,
          );
        } else {
          await RuntimeBridge.instance.respondPermission(
            turnId: turnId,
            requestId: perm.requestId,
            optionId: optionId,
          );
        }
      } catch (err) {
        if (!ref.mounted) return;
        if (sid != null && _sessionRuntimes.containsKey(sid)) {
          _pendingPermissionsBySession[sid] = perm;
          if (_loadedSessionId == sid) {
            state = state.copyWith(pendingPermission: perm);
          }
        }
        await appendSystemFeedback('Permission response failed: $err');
      }
    }
  }

  Future<void> clearCurrentThread() async {
    final activeId = ref.read(sessionsProvider).activeSessionId;
    _pendingCompactions.clear();
    if (activeId != null) {
      _sessionRuntimes[activeId]?.loopDetector.reset();
      _sessionRuntimes[activeId]?.seenLoopCallIds.clear();
      _pendingPermissionsBySession.remove(activeId);
      _sessionLoopWarnings.remove(activeId);
      _sessionStallWarnings.remove(activeId);
    }
    state = ChatThreadState(
      activeBackgroundSessionIds: _computeActiveBgIds(),
      loadedSessionId: activeId,
    );
    if (activeId != null) {
      await _persistMessages(activeId, const []);
      await _syncSessionMeta(activeId, const []);
    }
  }

  Future<AgySessionSummary> forkCurrentSession() async {
    final prev = ref.read(sessionsProvider).activeSession;
    final currentMsgs = state.messages
        .map(
          (m) => m.isStreaming
              ? m.copyWith(
                  isStreaming: false,
                  tools: _finalizeTools(m.tools),
                  completedAt: m.completedAt ?? DateTime.now(),
                )
              : m,
        )
        .toList();
    final branched = await ref.read(sessionsProvider.notifier).createSession(
          title: prev != null ? '${prev.title} (fork)' : 'Forked session',
        );
    final updatedSession = prev == null
        ? branched
        : branched.copyWith(
            workspacePath: prev.workspacePath,
            projectId: prev.projectId,
            modelId: prev.modelId,
            messageCount: currentMsgs.length,
            lastPreview: prev.lastPreview,
            clearRemoteConversationId: true,
          );
    _loadedSessionId = branched.id;
    _inFlightMessages[branched.id] = currentMsgs;
    state = ChatThreadState(
      messages: currentMsgs,
      activeBackgroundSessionIds: _computeActiveBgIds(),
      loadedSessionId: branched.id,
    );
    await _persistMessages(branched.id, currentMsgs);
    await ref.read(sessionsProvider.notifier).updateSession(updatedSession);
    return updatedSession;
  }

  String _compactionFallbackText(String assistantId) {
    final info = _pendingCompactions[assistantId];
    if (info == null) {
      return '### Context Compacted\nConversation context reset for a fresh window.';
    }
    return HarnessContextMonitor.buildFallbackCompactionSummary(
      info.turns,
      compactedMessages: info.compactCount,
      focusInstructions: info.instructions,
    );
  }

  Future<({bool ok, String message})> compactThread({
    String? instructions,
  }) async {
    final session = ref.read(sessionsProvider).activeSession;
    final busy = state.isStreaming ||
        (session != null && _sessionRuntimes.containsKey(session.id));
    if (busy) {
      return (
        ok: false,
        message: 'Wait for or stop the active turn before compacting.',
      );
    }

    final msgs = state.messages;
    if (session == null || msgs.isEmpty) {
      return (ok: false, message: 'Nothing to compact yet.');
    }

    final lastCompactIdx = msgs.lastIndexWhere((m) => m.isCompactionSummary);
    if (lastCompactIdx == msgs.length - 1) {
      return (
        ok: false,
        message: 'Context was just compacted — no new turns since compaction.',
      );
    }

    final activeSlice = lastCompactIdx >= 0 ? msgs.sublist(lastCompactIdx) : msgs;
    final turns = activeSlice
        .map(
          (m) => HarnessCompactionTurn(
            role: m.role.name,
            text: m.text,
            toolSummaries: m.tools
                .map((t) {
                  final out = (t.error != null && t.error!.isNotEmpty)
                      ? 'ERR: ${t.error}'
                      : (t.output ?? '');
                  final clipped =
                      out.length > 240 ? '${out.substring(0, 240)}…' : out;
                  return clipped.isEmpty ? t.toolName : '${t.toolName} ($clipped)';
                })
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    final compactCount = msgs.length;
    final cleanInstructions = instructions?.trim();

    final hosts = ref.read(hostsProvider);
    final sshHost = hosts.activeSshHost;
    final runtime = ref.read(runtimeProvider);
    final oldRemoteId = session.remoteConversationId;

    if (sshHost == null && oldRemoteId != null && oldRemoteId.isNotEmpty) {
      try {
        await RuntimeBridge.instance.closeSessionWorker(oldRemoteId);
      } catch (_) {}
      if (!ref.mounted) return (ok: false, message: 'Cancelled');
    }

    final resetSession = session.copyWith(
      clearRemoteConversationId: true,
      updatedAt: DateTime.now(),
    );
    await ref.read(sessionsProvider.notifier).updateSession(resetSession);
    if (!ref.mounted) return (ok: false, message: 'Cancelled');

    final settings = ref.read(settingsProvider);
    final harness = ref.read(harnessProvider);
    final activeCustom = ref.read(activeCustomProviderProvider);
    final compactRoute = (activeCustom == null &&
            sshHost == null &&
            harness.quotaSaverEnabled)
        ? HarnessTurnRouter.resolveCompactionRoute()
        : null;
    final activeModelId =
        activeCustom?.modelId ?? compactRoute?.modelId ?? settings.selectedModelId;
    final activeEffort = activeCustom != null
        ? ''
        : (compactRoute?.effort ?? settings.reasoningEffort);

    if (activeCustom == null && sshHost == null && !runtime.status.isReady) {
      final fallback = HarnessContextMonitor.buildFallbackCompactionSummary(
        turns,
        compactedMessages: compactCount,
        focusInstructions: cleanInstructions,
      );
      final summaryMsg = ChatMessage(
        id: const Uuid().v4(),
        role: ChatRole.assistant,
        text: fallback,
        createdAt: DateTime.now(),
        completedAt: DateTime.now(),
        modelId: activeModelId,
        isCompactionSummary: true,
      );
      final updated = [...msgs, summaryMsg];
      _loadedSessionId = resetSession.id;
      _updateSessionMessages(resetSession.id, updated);
      await _persistMessages(resetSession.id, updated);
      return (
        ok: true,
        message: 'Compacted $compactCount messages into a fresh context.',
      );
    }

    final assistantId = const Uuid().v4();
    final now = DateTime.now();
    final summaryMsg = ChatMessage(
      id: assistantId,
      role: ChatRole.assistant,
      text: '',
      createdAt: now,
      modelId: activeModelId,
      reasoningEffort: activeEffort,
      isStreaming: true,
      isCompactionSummary: true,
    );
    final nextMessages = [...msgs, summaryMsg];
    final turnId = const Uuid().v4();
    final streamToken = ++_nextStreamToken;
    _sessionTurnTokens[resetSession.id] = streamToken;
    _loadedSessionId = resetSession.id;
    _turnStartedAt[assistantId] = now;
    _turnModelId[assistantId] = activeModelId;
    _turnEffort[assistantId] = activeEffort;
    _inFlightMessages[resetSession.id] = nextMessages;
    _pendingCompactions[assistantId] = (
      turns: turns,
      compactCount: compactCount,
      instructions: cleanInstructions,
      tempRemoteId: null,
    );

    final rt = _SessionTurnRuntime(
      turnId: turnId,
      isSsh: activeCustom == null && sshHost != null,
      isCustomOpenAi: activeCustom != null,
    );
    _sessionRuntimes.remove(resetSession.id)?.dispose();
    _sessionRuntimes[resetSession.id] = rt;

    state = state.copyWith(
      messages: nextMessages,
      isStreaming: true,
      activeTurnId: turnId,
      activeBackgroundSessionIds: _computeActiveBgIds(),
      tokensPerSecond: 0,
      clearPermission: true,
      clearStallWarning: true,
      clearLoopWarning: true,
      loadedSessionId: resetSession.id,
    );

    final project = ref.read(projectsProvider).activeProject;
    final perms = ref.read(permissionsProvider);
    final effectiveWorkspace = resetSession.workspacePath.isNotEmpty
        ? resetSession.workspacePath
        : (project.primaryFolder.isNotEmpty
            ? project.primaryFolder
            : (runtime.status.workspaceRoot ?? ''));

    final compactPrompt = HarnessContextMonitor.buildCompactionPrompt(
      turns,
      compactedMessages: compactCount,
      focusInstructions: cleanInstructions,
    );

    final Stream<AgyChatEvent> stream;
    if (activeCustom != null) {
      final customKey = await ref
          .read(customProvidersProvider.notifier)
          .readApiKey(activeCustom.id);
      if (!ref.mounted || _sessionTurnTokens[resetSession.id] != streamToken) {
        return (ok: false, message: 'Cancelled');
      }
      stream = OpenAiCompatRunner.instance.runPrompt(
        profile: activeCustom.copyWith(supportsTools: false),
        apiKey: customKey,
        turnId: turnId,
        prompt: compactPrompt,
        workspacePath: effectiveWorkspace,
        dangerouslySkipPermissions: true,
      );
      rt.activeLocalRequest = null;
    } else {
      final apiKey = await ref.read(authServiceProvider).readGeminiApiKey();
      if (!ref.mounted || _sessionTurnTokens[resetSession.id] != streamToken) {
        return (ok: false, message: 'Cancelled');
      }

      final request = AgyPromptRequest(
        prompt: compactPrompt,
        workspacePath: effectiveWorkspace,
        extraDirs: [
          ...project.folders,
          if (perms.allFilesAccess) perms.externalStorageRoot,
          if (perms.allFilesAccess) '/sdcard',
        ],
        conversationId: null,
        modelId: activeModelId,
        effortCliValue: activeEffort,
        mode: sshHost != null
            ? AgyExecutionMode.plan
            : AgyExecutionMode.plan.androidSafe,
        dangerouslySkipPermissions: true,
        allowNonWorkspaceAccess: true,
        geminiApiKey: apiKey,
        continueLast: false,
        remoteAgent: settings.remoteAgent.isEmpty ? null : settings.remoteAgent,
      );

      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        if (!ref.mounted ||
            _sessionTurnTokens[resetSession.id] != streamToken) {
          return (ok: false, message: 'Cancelled');
        }
        stream = SshAgyRunner.instance.runPrompt(
          host: sshHost,
          request: request,
          turnId: turnId,
          password: pwd,
          privateKeyPem: key,
        );
      } else {
        stream = RuntimeBridge.instance.runPrompt(request, turnId);
      }
      rt.activeLocalRequest = sshHost == null ? request : null;
    }
    _resetWatchdog(resetSession.id);

    rt.sub = stream.listen(
      (evt) {
        if (!ref.mounted ||
            _sessionTurnTokens[resetSession.id] != streamToken) {
          return;
        }
        _handleEvent(resetSession, assistantId, evt);
      },
      onError: (_) {
        if (!ref.mounted ||
            _sessionTurnTokens[resetSession.id] != streamToken) {
          return;
        }
        _finishAssistantMessage(
          session: resetSession,
          assistantId: assistantId,
          text: _compactionFallbackText(assistantId),
        );
      },
      onDone: () {
        if (!ref.mounted ||
            _sessionTurnTokens[resetSession.id] != streamToken) {
          return;
        }
        _completeStreaming(resetSession, assistantId);
      },
    );

    return (ok: true, message: 'Compacting $compactCount messages…');
  }

  void dismissLoopWarning() {
    final sid = _loadedSessionId;
    if (sid != null) _sessionLoopWarnings.remove(sid);
    state = state.copyWith(clearLoopWarning: true);
  }

  Future<void> breakLoopAndPivot() async {
    final hit = state.loopWarning;
    if (hit == null) return;
    final pivot = hit.pivotPrompt;
    final activeId = _loadedSessionId ?? ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      _sessionRuntimes[activeId]?.loopDetector.reset();
      _sessionRuntimes[activeId]?.seenLoopCallIds.clear();
      _sessionLoopWarnings.remove(activeId);
    }
    state = state.copyWith(clearLoopWarning: true);
    if (state.isStreaming ||
        (activeId != null && _sessionRuntimes.containsKey(activeId))) {
      await stopStreaming(sessionId: activeId);
    }
    if (!ref.mounted) return;
    await sendPrompt(pivot, force: true);
  }

  Future<({bool ok, String message, String? restoredPrompt})> rewindToMessage(
    String userMessageId,
  ) async {
    if (state.isStreaming || state.messages.isEmpty) {
      return (
        ok: false,
        message: 'Stop active streaming before rewinding.',
        restoredPrompt: null,
      );
    }
    final targetIdx = userMessageId == '__latest__'
        ? state.messages.lastIndexWhere((m) => m.role == ChatRole.user)
        : state.messages.indexWhere((m) => m.id == userMessageId);
    if (targetIdx < 0) {
      return (
        ok: false,
        message: 'No user turn found to rewind to.',
        restoredPrompt: null,
      );
    }
    final targetMsg = state.messages[targetIdx];
    final session = ref.read(sessionsProvider).activeSession;
    var gitNote = 'Conversation pruned';
    final cpRef = targetMsg.checkpointRef;
    if (cpRef != null && cpRef.isNotEmpty) {
      final project = ref.read(projectsProvider).activeProject;
      final runtime = ref.read(runtimeProvider);
      final cwd = (session != null && session.workspacePath.isNotEmpty)
          ? session.workspacePath
          : (project.primaryFolder.isNotEmpty
              ? project.primaryFolder
              : (runtime.status.workspaceRoot ?? ''));
      final sshHost = ref.read(hostsProvider).activeSshHost;
      final Map<String, Object?> res;
      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        res = await SshAgyRunner.instance.restoreCheckpoint(
          host: sshHost,
          cwd: cwd,
          ref: cpRef,
          password: pwd,
          privateKeyPem: key,
          onTrustFirstKey: (fp) => ref
              .read(hostsProvider.notifier)
              .saveHostFingerprint(sshHost.id, fp),
        );
      } else {
        res = await RuntimeBridge.instance.restoreCheckpoint(
          cwd: cwd.isEmpty ? null : cwd,
          ref: cpRef,
        );
      }
      if (!ref.mounted) {
        return (ok: false, message: 'Cancelled', restoredPrompt: null);
      }
      if (res['ok'] == true) {
        gitNote =
            'Workspace & conversation restored (${cpRef.substring(0, cpRef.length.clamp(0, 7))})';
      } else {
        gitNote = 'Conversation rewound (${res['message'] ?? 'no git snapshot'})';
      }
    }
    if (session?.remoteConversationId != null &&
        session!.remoteConversationId!.isNotEmpty) {
      unawaited(
        RuntimeBridge.instance
            .closeSessionWorker(session.remoteConversationId!),
      );
      await ref.read(sessionsProvider.notifier).updateSession(
            session.copyWith(clearRemoteConversationId: true),
          );
      if (!ref.mounted) {
        return (ok: false, message: 'Cancelled', restoredPrompt: null);
      }
    }
    final prefix = state.messages.sublist(0, targetIdx);
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      _sessionRuntimes[activeId]?.loopDetector.reset();
      _sessionRuntimes[activeId]?.seenLoopCallIds.clear();
      _sessionLoopWarnings.remove(activeId);
    }
    state = state.copyWith(
      messages: prefix,
      clearLoopWarning: true,
    );
    if (activeId != null) {
      await _persistMessages(activeId, prefix);
      await _syncSessionMeta(activeId, prefix);
    }
    return (
      ok: true,
      message: gitNote,
      restoredPrompt: targetMsg.text,
    );
  }

  String exportMarkdown() {
    final buf = StringBuffer('# Antigravity Go Transcript\n\n');
    for (final m in state.messages) {
      final roleLabel = m.role == ChatRole.user ? 'User' : 'Antigravity';
      buf.writeln('## $roleLabel');
      if (m.thoughts.isNotEmpty) {
        buf.writeln('> Thinking: ${m.thoughts.trim()}\n');
      }
      buf.writeln('${m.text}\n');
    }
    return buf.toString();
  }
}
