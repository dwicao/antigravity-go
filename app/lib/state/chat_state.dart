import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_models.dart';
import '../ui/chat/secret_mask.dart';
import 'auth_state.dart';
import 'ci_watch_state.dart';
import 'harness_state.dart';
import 'hosts_state.dart';
import 'permissions_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'sessions_state.dart';
import 'settings_state.dart';
import 'usage_state.dart';

enum ChatRole { user, assistant, system }

class ChatToolStep {
  const ChatToolStep({
    required this.id,
    required this.toolName,
    required this.state,
    this.parameters = const {},
    this.output,
    this.error,
    this.durationSeconds,
    this.startedAt,
  });

  final String id;
  final String toolName;
  final ToolCallState state;
  final Map<String, dynamic> parameters;
  final String? output;
  final String? error;
  final double? durationSeconds;
  final DateTime? startedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'state': state.name,
        'parameters': parameters,
        if (output != null) 'output': AgySecretMask.mask(output!),
        if (error != null) 'error': AgySecretMask.mask(error!),
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
      };

  factory ChatToolStep.fromJson(Map<String, dynamic> json) {
    final stateStr = json['state'] as String? ?? 'completed';
    return ChatToolStep(
      id: json['id'] as String? ?? '',
      toolName: json['toolName'] as String? ?? 'tool',
      state: ToolCallState.values.firstWhere(
        (s) => s.name == stateStr,
        orElse: () => ToolCallState.completed,
      ),
      parameters: json['parameters'] as Map<String, dynamic>? ?? const {},
      output: json['output'] as String?,
      error: json['error'] as String?,
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
    this.thoughts = '',
    this.tools = const [],
    this.usage,
    this.attachments = const [],
    this.isStreaming = false,
    this.requiresAuth = false,
    this.durationSeconds,
    this.tokensPerSecond,
    this.modelId,
    this.reasoningEffort,
    this.completedAt,
    this.changedFiles = const [],
    this.steps = const [],
    this.checkpointRef,
    this.isCompactionSummary = false,
    this.contextTokens,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;
  final String thoughts;
  final List<ChatToolStep> tools;
  final TokenUsage? usage;
  final List<String> attachments;
  final bool isStreaming;
  final bool requiresAuth;
  final double? durationSeconds;
  final double? tokensPerSecond;
  final String? modelId;
  final String? reasoningEffort;
  final DateTime? completedAt;
  final List<FileChangeEntry> changedFiles;
  final List<ChatMilestoneStep> steps;
  final String? checkpointRef;
  final bool isCompactionSummary;
  final int? contextTokens;

  ChatMessage copyWith({
    String? text,
    String? thoughts,
    List<ChatToolStep>? tools,
    TokenUsage? usage,
    bool? isStreaming,
    bool? requiresAuth,
    double? durationSeconds,
    double? tokensPerSecond,
    String? modelId,
    String? reasoningEffort,
    DateTime? completedAt,
    List<FileChangeEntry>? changedFiles,
    List<ChatMilestoneStep>? steps,
    String? checkpointRef,
    bool? isCompactionSummary,
    int? contextTokens,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      text: text ?? this.text,
      createdAt: createdAt,
      thoughts: thoughts ?? this.thoughts,
      tools: tools ?? this.tools,
      usage: usage ?? this.usage,
      attachments: attachments,
      isStreaming: isStreaming ?? this.isStreaming,
      requiresAuth: requiresAuth ?? this.requiresAuth,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
      modelId: modelId ?? this.modelId,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      completedAt: completedAt ?? this.completedAt,
      changedFiles: changedFiles ?? this.changedFiles,
      steps: steps ?? this.steps,
      checkpointRef: checkpointRef ?? this.checkpointRef,
      isCompactionSummary: isCompactionSummary ?? this.isCompactionSummary,
      contextTokens: contextTokens ?? this.contextTokens,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'createdAt': createdAt.toIso8601String(),
        if (thoughts.isNotEmpty) 'thoughts': thoughts,
        if (tools.isNotEmpty) 'tools': tools.map((t) => t.toJson()).toList(),
        if (usage != null) 'usage': usage!.toJson(),
        if (attachments.isNotEmpty) 'attachments': attachments,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
        if (tokensPerSecond != null) 'tokensPerSecond': tokensPerSecond,
        if (modelId != null) 'modelId': modelId,
        if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
        if (changedFiles.isNotEmpty)
          'changedFiles': changedFiles.map((f) => f.toJson()).toList(),
        if (steps.isNotEmpty) 'steps': steps.map((s) => s.toJson()).toList(),
        'checkpointRef': ?checkpointRef,
        if (isCompactionSummary) 'isCompactionSummary': true,
        'contextTokens': ?contextTokens,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final roleName = json['role'] as String? ?? 'user';
    return ChatMessage(
      id: json['id'] as String? ?? const Uuid().v4(),
      role: ChatRole.values.firstWhere(
        (r) => r.name == roleName,
        orElse: () => ChatRole.user,
      ),
      text: json['text'] as String? ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      thoughts: json['thoughts'] as String? ?? '',
      tools: (json['tools'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChatToolStep.fromJson)
          .toList(),
      usage: json['usage'] is Map<String, dynamic>
          ? TokenUsage.fromJson(json['usage'] as Map<String, dynamic>)
          : null,
      attachments: (json['attachments'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      tokensPerSecond: (json['tokensPerSecond'] as num?)?.toDouble(),
      modelId: json['modelId'] as String?,
      reasoningEffort: json['reasoningEffort'] as String?,
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? ''),
      changedFiles: (json['changedFiles'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FileChangeEntry.fromJson)
          .toList(),
      steps: (json['steps'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ChatMilestoneStep.fromJson)
          .toList(),
      checkpointRef: json['checkpointRef'] as String?,
      isCompactionSummary: json['isCompactionSummary'] == true,
      contextTokens: (json['contextTokens'] as num?)?.toInt(),
    );
  }
}

class ChatThreadState {
  const ChatThreadState({
    this.messages = const [],
    this.isStreaming = false,
    this.queuedPrompts = const [],
    this.pendingPermission,
    this.activeTurnId,
    this.tokensPerSecond = 0,
    this.stallWarning,
    this.loopWarning,
    this.activeBackgroundSessionIds = const {},
    this.loadedSessionId,
  });

  final List<ChatMessage> messages;
  final bool isStreaming;
  final List<String> queuedPrompts;
  final AgyPermissionRequestEvent? pendingPermission;
  final String? activeTurnId;
  final double tokensPerSecond;
  final String? stallWarning;
  final LoopDetectionResult? loopWarning;
  final Set<String> activeBackgroundSessionIds;
  final String? loadedSessionId;

  ChatThreadState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    List<String>? queuedPrompts,
    AgyPermissionRequestEvent? pendingPermission,
    bool clearPermission = false,
    String? activeTurnId,
    bool clearActiveTurnId = false,
    double? tokensPerSecond,
    String? stallWarning,
    bool clearStallWarning = false,
    LoopDetectionResult? loopWarning,
    bool clearLoopWarning = false,
    Set<String>? activeBackgroundSessionIds,
    String? loadedSessionId,
  }) {
    return ChatThreadState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      queuedPrompts: queuedPrompts ?? this.queuedPrompts,
      pendingPermission: clearPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      activeTurnId:
          clearActiveTurnId ? null : (activeTurnId ?? this.activeTurnId),
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
      stallWarning:
          clearStallWarning ? null : (stallWarning ?? this.stallWarning),
      loopWarning:
          clearLoopWarning ? null : (loopWarning ?? this.loopWarning),
      activeBackgroundSessionIds:
          activeBackgroundSessionIds ?? this.activeBackgroundSessionIds,
      loadedSessionId: loadedSessionId ?? this.loadedSessionId,
    );
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, ChatThreadState>(ChatNotifier.new);

class ChatNotifier extends Notifier<ChatThreadState> {
  StreamSubscription<AgyChatEvent>? _activeSub;
  StreamSubscription<RuntimeEvent>? _wakeupSub;
  String? _loadedSessionId;
  final Map<String, String> _wakeupAssistantIds = {};
  final Map<String, Timer> _wakeupFinalizeTimers = {};
  final Set<String> _completedAssistantIds = <String>{};
  final AcpCodec _wakeupCodec = AcpCodec();
  final HarnessLoopDetector _loopDetector = HarnessLoopDetector();
  final Set<String> _seenLoopCallIds = <String>{};
  Timer? _stallWatchdog;
  bool _receivedTurnContent = false;
  bool _usedFallbackForTurn = false;
  AgyPromptRequest? _activeLocalRequest;
  DateTime? _streamBurstStart;
  final List<({DateTime at, double tokens})> _rateSamples = [];
  final Map<String, List<ChatMessage>> _inFlightMessages = {};
  final Map<String, DateTime> _turnStartedAt = {};
  final Map<String, DateTime> _firstOutputAt = {};
  final Map<String, String> _turnModelId = {};
  final Map<String, String> _turnEffort = {};
  final Map<String, AgyPermissionRequestEvent> _pendingPermissionsBySession =
      {};
  final Map<String, LoopDetectionResult> _sessionLoopWarnings = {};
  final Map<String, int> _sessionTurnTokens = {};
  final Map<String, List<({String prompt, List<String> attachments})>>
      _queuedItemsBySession = {};
  int _nextStreamToken = 0;
  final Map<
      String,
      ({
        List<HarnessCompactionTurn> turns,
        int compactCount,
        String? instructions,
        String? tempRemoteId,
      })> _pendingCompactions = {};
  String? _activeStreamingSessionId;

  static List<ChatToolStep> _finalizeTools(
    List<ChatToolStep> tools, {
    bool failed = false,
  }) {
    var changed = false;
    final out = tools.map((t) {
      if (t.state == ToolCallState.running || t.state == ToolCallState.pending) {
        changed = true;
        return ChatToolStep(
          id: t.id,
          toolName: t.toolName,
          state: failed ? ToolCallState.failed : ToolCallState.completed,
          parameters: t.parameters,
          output: t.output,
          error: t.error,
          durationSeconds: t.durationSeconds,
          startedAt: t.startedAt,
        );
      }
      return t;
    }).toList();
    return changed ? out : tools;
  }

  double _recordRateSample(String delta) {
    if (delta.isEmpty) return state.tokensPerSecond;
    final now = DateTime.now();
    // Same empirical estimate as DSH-go's run_pulse.dart (~0.35 tok/char).
    final est = delta.trim().length * 0.35;
    if (est <= 0) return state.tokensPerSecond;
    if (_rateSamples.isEmpty ||
        now.difference(_rateSamples.last.at).inMilliseconds > 1500) {
      _streamBurstStart = now;
    }
    _rateSamples.add((at: now, tokens: est));
    final cutoff = now.subtract(const Duration(milliseconds: 2500));
    _rateSamples.removeWhere((s) => s.at.isBefore(cutoff));
    final start =
        _streamBurstStart != null && _streamBurstStart!.isAfter(cutoff)
            ? _streamBurstStart!
            : cutoff;
    final elapsedMs = now.difference(start).inMilliseconds;
    final secs = (elapsedMs < 500 ? 500 : elapsedMs) / 1000.0;
    final sum = _rateSamples.fold<double>(0, (a, s) => a + s.tokens);
    return sum / secs;
  }

  void _resetWatchdog() {
    _stallWatchdog?.cancel();
    final activeSid = _activeStreamingSessionId;
    if (activeSid == null || _pendingPermissionsBySession[activeSid] != null) {
      return;
    }
    _stallWatchdog = Timer(const Duration(seconds: 180), () {
      final sid = _activeStreamingSessionId;
      if (sid != null &&
          _pendingPermissionsBySession[sid] == null &&
          ref.mounted) {
        state = state.copyWith(
          stallWarning:
              'Agent turn has had no output for 3 minutes — check connection or tap Stop & Regenerate.',
        );
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
    String preview = '';
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
      _stallWatchdog?.cancel();
      for (final timer in _wakeupFinalizeTimers.values) {
        timer.cancel();
      }
      _wakeupFinalizeTimers.clear();
      _wakeupAssistantIds.clear();
      _activeSub?.cancel();
      _wakeupSub?.cancel();
    });
    _wakeupSub?.cancel();
    _wakeupSub = RuntimeBridge.instance.events
        .where((e) => e.kind == 'acp_wakeup' && e.stdoutLine != null)
        .listen(_handleAcpWakeup);
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
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null && activeId != _loadedSessionId) {
      _loadedSessionId = activeId;
      Future.microtask(() => _loadMessages(activeId));
    }
    return const ChatThreadState();
  }

  void _finalizeWakeupMessage(String sessionId, String assistantId) {
    _wakeupFinalizeTimers.remove(sessionId)?.cancel();
    if (!ref.mounted) return;
    if (_wakeupAssistantIds[sessionId] == assistantId) {
      _wakeupAssistantIds.remove(sessionId);
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
    if (_activeStreamingSessionId != _loadedSessionId &&
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
    // Never create a duplicate wakeup bubble if this session already has an active foreground turn.
    if (_activeStreamingSessionId == target.id) return;

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

  Future<void> _loadMessages(String sessionId) async {
    final inFlight = _inFlightMessages[sessionId];
    if (inFlight != null) {
      if (!ref.mounted || _loadedSessionId != sessionId) return;
      final isSessionStreaming = _activeStreamingSessionId == sessionId;
      state = state.copyWith(
        messages: List<ChatMessage>.from(inFlight),
        isStreaming: isSessionStreaming,
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        clearPermission: _pendingPermissionsBySession[sessionId] == null,
        clearStallWarning: true,
        loopWarning: _sessionLoopWarnings[sessionId],
        clearLoopWarning: _sessionLoopWarnings[sessionId] == null,
        clearActiveTurnId: !isSessionStreaming,
        loadedSessionId: sessionId,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted || _loadedSessionId != sessionId) return;
    final raw = prefs.getString('agy_msgs_$sessionId');
    if (raw == null || raw.isEmpty) {
      state = ChatThreadState(
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        loopWarning: _sessionLoopWarnings[sessionId],
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
        loadedSessionId: sessionId,
      );
      return;
    }
    try {
      final rawList = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
      // Sanitize any stale streaming/running state persisted before an OS kill or restart.
      final list = rawList
          .map((m) => m.copyWith(
                isStreaming: false,
                tools: _finalizeTools(m.tools),
              ))
          .toList();
      state = ChatThreadState(
        messages: list,
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        loopWarning: _sessionLoopWarnings[sessionId],
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
        loadedSessionId: sessionId,
      );
    } catch (_) {
      state = ChatThreadState(
        queuedPrompts: _queuedPromptLabels(sessionId),
        pendingPermission: _pendingPermissionsBySession[sessionId],
        loopWarning: _sessionLoopWarnings[sessionId],
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
        loadedSessionId: sessionId,
      );
    }
  }

  Future<void> _persistMessages(String sessionId, List<ChatMessage> msgs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'agy_msgs_$sessionId',
      jsonEncode(msgs.map((m) => m.toJson()).toList()),
    );
  }

  List<ChatMessage> _messagesForSession(String sessionId) {
    if (_loadedSessionId == sessionId) {
      return state.messages;
    }
    return _inFlightMessages[sessionId] ?? const [];
  }

  void _updateSessionMessages(String sessionId, List<ChatMessage> next) {
    _inFlightMessages[sessionId] = next;
    if (_loadedSessionId == sessionId) {
      state = state.copyWith(messages: next);
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

  Future<void> sendPrompt(
    String rawText, {
    List<String> attachments = const [],
    bool force = false,
  }) async {
    final prompt = rawText.trim();
    if (prompt.isEmpty) return;

    final hasBackgroundWork = state.isStreaming ||
        _activeStreamingSessionId != null ||
        state.activeBackgroundSessionIds.isNotEmpty ||
        ref.read(runtimeProvider).backgroundTasks.isNotEmpty;
    if (!force && hasBackgroundWork) {
      final queueSid = ref.read(sessionsProvider).activeSessionId ??
          _loadedSessionId ??
          'default';
      final nextQueue = <({String prompt, List<String> attachments})>[
        ...(_queuedItemsBySession[queueSid] ?? const []),
        (prompt: prompt, attachments: List<String>.from(attachments)),
      ];
      _queuedItemsBySession[queueSid] = nextQueue;
      state = state.copyWith(
        queuedPrompts: nextQueue.map((e) => e.prompt).toList(),
      );
      return;
    }

    var session = ref.read(sessionsProvider).activeSession;
    session ??= await ref.read(sessionsProvider.notifier).createSession();
    if (!ref.mounted) return;

    final settings = ref.read(settingsProvider);
    final hosts = ref.read(hostsProvider);
    final sshHost = hosts.activeSshHost;
    final isImagePath = (String p) {
      final lower = p.toLowerCase();
      return lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.gif');
    };
    final textAttachments = sshHost != null
        ? attachments
        : attachments.where((p) => !isImagePath(p)).toList();
    final attachmentNote = textAttachments.isEmpty
        ? ''
        : '\n\n[Attached files: ${textAttachments.join(', ')}]';
    final effectivePrompt = '$prompt$attachmentNote';
    final now = DateTime.now();

    final priorMsgs = _messagesForSession(session.id);
    final prevCompactIdx = priorMsgs.lastIndexWhere((m) => m.isCompactionSummary);
    final hasPostCompactUserTurn = prevCompactIdx >= 0 &&
        priorMsgs.skip(prevCompactIdx + 1).any((m) => m.role == ChatRole.user);
    final carryCompactContext =
        (session.remoteConversationId == null ||
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
      modelId: settings.selectedModelId,
      reasoningEffort: settings.reasoningEffort,
      isStreaming: true,
    );

    final nextMessages = [...priorMsgs, userMsg, assistantMsg];
    final turnId = const Uuid().v4();
    final streamToken = ++_nextStreamToken;
    _sessionTurnTokens[session.id] = streamToken;
    _loadedSessionId = session.id;
    _activeStreamingSessionId = session.id;
    _turnStartedAt[assistantId] = now;
    _turnModelId[assistantId] = settings.selectedModelId;
    _turnEffort[assistantId] = settings.reasoningEffort;
    _inFlightMessages[session.id] = nextMessages;
    final bgIds = {...state.activeBackgroundSessionIds, session.id};
    state = state.copyWith(
      messages: nextMessages,
      isStreaming: true,
      activeTurnId: turnId,
      activeBackgroundSessionIds: bgIds,
      clearPermission: true,
      loadedSessionId: session.id,
    );

    // Auto-title new conversations from the first user prompt.
    if (session.messageCount == 0) {
      final title = prompt.length > 36 ? '${prompt.substring(0, 36)}…' : prompt;
      session = session.copyWith(title: title);
    }
    await ref.read(sessionsProvider.notifier).updateSession(
          session.copyWith(
            updatedAt: DateTime.now(),
            messageCount: nextMessages.length,
            lastPreview: prompt,
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

    final effectiveWorkspace = session.workspacePath.isNotEmpty
        ? session.workspacePath
        : (project.primaryFolder.isNotEmpty
            ? project.primaryFolder
            : (runtime.status.workspaceRoot ?? ''));

    final requestedMode = AgyExecutionMode.fromCli(settings.executionMode);
    final effectiveMode = sshHost != null
        ? requestedMode
        : requestedMode.androidSafe;

    final requestPrompt = carryCompactContext
        ? '[Compacted Session Context]\n${priorMsgs[prevCompactIdx].text.trim()}\n\n[User Request]\n$effectivePrompt'
        : effectivePrompt;

    final String? apiKey;
    final Stream<AgyChatEvent> stream;
    final AgyPromptRequest request;
    try {
      apiKey = await ref.read(authServiceProvider).readGeminiApiKey();
      if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) return;

      request = AgyPromptRequest(
        prompt: requestPrompt,
        workspacePath: effectiveWorkspace,
        extraDirs: [
          ...project.folders,
          if (perms.allFilesAccess) perms.externalStorageRoot,
          if (perms.allFilesAccess) '/sdcard',
        ],
        conversationId: session.remoteConversationId,
        modelId: settings.selectedModelId,
        effortCliValue: settings.reasoningEffort,
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
        remoteAgent: settings.remoteAgent.isEmpty ? null : settings.remoteAgent,
        attachments: attachments,
      );

      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
          return;
        }
        Future<void> saveFp(String fp) => ref
            .read(hostsProvider.notifier)
            .saveHostFingerprint(sshHost.id, fp);
        if (ref.read(harnessProvider).autoCheckpointEnabled) {
          try {
            final cp = await SshAgyRunner.instance.createCheckpoint(
              host: sshHost,
              cwd: effectiveWorkspace,
              password: pwd,
              privateKeyPem: key,
              onTrustFirstKey: saveFp,
            );
            if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
              return;
            }
            final refHash = cp['ref']?.toString() ?? '';
            if (cp['ok'] == true && refHash.isNotEmpty) {
              final currentMsgs = _messagesForSession(session.id);
              final uIdx = currentMsgs.indexWhere((m) => m.id == userMsgId);
              if (uIdx >= 0) {
                final updated = [...currentMsgs];
                updated[uIdx] = updated[uIdx].copyWith(checkpointRef: refHash);
                _updateSessionMessages(session.id, updated);
                unawaited(_persistMessages(session.id, updated));
              }
            }
          } catch (_) {}
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
                'On-device Antigravity CLI (`agy`) is not installed yet.\n\nTap **Setup Runtime** in Settings or the Quick Panel to install `agy` natively on your phone, or switch to an **SSH Remote Host** in the drawer.',
          );
          return;
        }
        if (ref.read(harnessProvider).autoCheckpointEnabled) {
          try {
            final cp = await RuntimeBridge.instance.createCheckpoint(
              cwd: effectiveWorkspace.isEmpty ? null : effectiveWorkspace,
            );
            if (!ref.mounted || _sessionTurnTokens[session.id] != streamToken) {
              return;
            }
            final refHash = cp['ref']?.toString() ?? '';
            if (cp['ok'] == true && refHash.isNotEmpty) {
              final currentMsgs = _messagesForSession(session.id);
              final uIdx = currentMsgs.indexWhere((m) => m.id == userMsgId);
              if (uIdx >= 0) {
                final updated = [...currentMsgs];
                updated[uIdx] = updated[uIdx].copyWith(checkpointRef: refHash);
                _updateSessionMessages(session.id, updated);
                unawaited(_persistMessages(session.id, updated));
              }
            }
          } catch (_) {}
        }
        stream = RuntimeBridge.instance.runPrompt(
          request,
          turnId,
          attachments: attachments,
        );
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
    _receivedTurnContent = false;
    _usedFallbackForTurn = false;
    _activeLocalRequest = sshHost == null ? request : null;
    _rateSamples.clear();
    _streamBurstStart = null;
    _loopDetector.reset();
    _seenLoopCallIds.clear();
    _sessionLoopWarnings.remove(currentSession.id);
    _pendingPermissionsBySession.remove(currentSession.id);
    state = state.copyWith(
      tokensPerSecond: 0,
      clearStallWarning: true,
      clearLoopWarning: true,
    );
    _resetWatchdog();

    await _activeSub?.cancel();
    _activeSub = stream.listen(
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

  static TokenUsage? _mergeStepUsage(TokenUsage? prev, TokenUsage? stepUsage) {
    if (stepUsage == null) return prev;
    if (prev == null) return stepUsage;
    return prev.copyWith(
      contextTokens:
          stepUsage.contextTokens > 0 ? stepUsage.contextTokens : prev.contextTokens,
    );
  }

  void _handleEvent(
    AgySessionSummary session,
    String assistantId,
    AgyChatEvent evt,
  ) {
    _resetWatchdog();
    if (state.stallWarning != null && _loadedSessionId == session.id) {
      state = state.copyWith(clearStallWarning: true);
    }
    final msgs = _messagesForSession(session.id);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final current = msgs[idx];
    // Completed turns are strictly immutable: ignore any late/replayed events.
    if (!current.isStreaming || current.completedAt != null) return;

    switch (evt) {
      case AgyInitEvent():
        ref.read(authProvider.notifier).markAuthenticatedFromTurn();
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
        _receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        if (_loadedSessionId == session.id) {
          final rate = _recordRateSample(evt.delta);
          state = state.copyWith(tokensPerSecond: rate);
        }
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
        final nextUsage = _mergeStepUsage(current.usage, evt.stepUsage);
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
        );
      case AgyTextDeltaEvent():
        _receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        if (_loadedSessionId == session.id) {
          final rate = _recordRateSample(evt.delta);
          state = state.copyWith(tokensPerSecond: rate);
        }
        final nextUsage = _mergeStepUsage(current.usage, evt.stepUsage);
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: '${current.text}${evt.delta}',
            usage: nextUsage,
            contextTokens: (evt.stepUsage?.contextTokens ?? 0) > 0
                ? evt.stepUsage!.contextTokens
                : current.contextTokens,
          ),
        );
      case AgyToolCallEvent():
        _receivedTurnContent = true;
        final tools = [...current.tools];
        final nextSteps = [...current.steps];
        final effCallId = evt.callId.isNotEmpty
            ? evt.callId
            : 'tool-${evt.toolName}-${tools.length}';
        final tIdx = tools.indexWhere((t) => t.id == effCallId);
        final resolvedToolName = evt.toolName != 'tool' || tIdx < 0
            ? evt.toolName
            : tools[tIdx].toolName;
        final mergedParams = tIdx >= 0 && evt.parameters.isEmpty
            ? tools[tIdx].parameters
            : evt.parameters;
        if (tIdx >= 0) {
          final prev = tools[tIdx];
          tools[tIdx] = ChatToolStep(
            id: effCallId,
            toolName: resolvedToolName,
            state: evt.state,
            parameters: mergedParams,
            output: evt.output ?? prev.output,
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
              output: evt.output,
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
        );
        // Harness Doom-Loop Circuit Breaker check on new or updated tool steps.
        if (ref.read(harnessProvider).loopBreakerEnabled) {
          final isFailed = evt.state == ToolCallState.failed ||
              (evt.errorMessage?.isNotEmpty ?? false);
          LoopDetectionResult loopHit = LoopDetectionResult.none;
          if (_seenLoopCallIds.add(effCallId) || evt.parameters.isNotEmpty) {
            loopHit = _loopDetector.recordToolCall(
              name: resolvedToolName,
              input: jsonEncode(mergedParams),
              isError: isFailed,
              callId: effCallId,
            );
          } else if (isFailed) {
            loopHit = _loopDetector.markLastFailed(
              toolName: resolvedToolName,
              callId: effCallId,
            );
          }
          if (loopHit.triggered) {
            _sessionLoopWarnings[session.id] = loopHit;
            if (_loadedSessionId == session.id) {
              state = state.copyWith(loopWarning: loopHit);
            }
          }
        }
        // Checkpoint completed tool steps mid-turn against OS process kills.
        if (evt.state != ToolCallState.running) {
          unawaited(_persistMessages(session.id, _messagesForSession(session.id)));
        }
      case AgyPermissionRequestEvent():
        _pendingPermissionsBySession[session.id] = evt;
        _stallWatchdog?.cancel();
        if (_loadedSessionId == session.id) {
          state = state.copyWith(pendingPermission: evt);
        }
      case AgyTurnResultEvent():
        _receivedTurnContent = true;
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
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: resolvedText,
            usage: resolvedUsage,
            contextTokens: resolvedUsage.contextTokens > 0
                ? resolvedUsage.contextTokens
                : current.contextTokens,
            tools: _finalizeTools(current.tools, failed: hasErrorResult),
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
        if (_activeStreamingSessionId == session.id) {
          unawaited(_completeStreaming(session, assistantId));
        }
      case AgyErrorEvent():
        _pendingPermissionsBySession.remove(session.id);
        if (evt.requiresAuth) {
          ref.read(authProvider.notifier).refresh();
        } else if (!_receivedTurnContent &&
            !_usedFallbackForTurn &&
            _activeLocalRequest != null &&
            !evt.message.toLowerCase().contains('auto mode is not available')) {
          // DSH-go style engine fallback: if ACP fails before producing any output,
          // automatically retry once via `-p --output-format stream-json`.
          _usedFallbackForTurn = true;
          final fallbackReq = _activeLocalRequest!;
          final fallbackTurnId = const Uuid().v4();
          final fallbackToken = ++_nextStreamToken;
          _sessionTurnTokens[session.id] = fallbackToken;
          if (_loadedSessionId == session.id) {
            state = state.copyWith(
              activeTurnId: fallbackTurnId,
              clearPermission: true,
            );
          }
          _activeSub?.cancel();
          _activeSub = RuntimeBridge.instance
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
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: errorOrFallback,
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
        if (_activeStreamingSessionId == session.id) {
          unawaited(_completeStreaming(session, assistantId));
        }
    }
  }

  void _replaceMessageInSession(
    String sessionId,
    int idx,
    ChatMessage updated,
  ) {
    final list = [..._messagesForSession(sessionId)];
    if (idx < 0 || idx >= list.length) return;
    list[idx] = updated;
    _updateSessionMessages(sessionId, list);
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
      _replaceMessageInSession(
        session.id,
        idx,
        cur.copyWith(
          text: text,
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

  static String? extractGitPushCwd(
    List<ChatToolStep> tools, {
    required String fallbackCwd,
  }) {
    for (final t in tools.reversed) {
      if (t.state == ToolCallState.failed ||
          (t.error != null && t.error!.isNotEmpty)) {
        continue;
      }
      final cmd = (t.parameters['CommandLine'] ??
              t.parameters['command'] ??
              '')
          .toString();
      final lower = cmd.toLowerCase();
      if (!lower.contains('git push') ||
          lower.contains('--dry-run') ||
          lower.contains('--help')) {
        continue;
      }
      final paramCwd = (t.parameters['Cwd'] ??
              t.parameters['cwd'] ??
              t.parameters['workdir'] ??
              '')
          .toString()
          .trim();
      if (paramCwd.isNotEmpty) return paramCwd;

      final cdMatch = RegExp(
        r'''(?:^|[;&|]\s*)cd\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))''',
      ).firstMatch(cmd);
      if (cdMatch != null) {
        final dir = (cdMatch.group(1) ??
                cdMatch.group(2) ??
                cdMatch.group(3) ??
                '')
            .trim();
        if (dir.isNotEmpty) return dir;
      }

      final gitCMatch = RegExp(
        r'''git\s+-C\s+(?:"([^"]+)"|'([^']+)'|([^\s;&|]+))''',
      ).firstMatch(cmd);
      if (gitCMatch != null) {
        final dir = (gitCMatch.group(1) ??
                gitCMatch.group(2) ??
                gitCMatch.group(3) ??
                '')
            .trim();
        if (dir.isNotEmpty) return dir;
      }

      if (fallbackCwd.isNotEmpty) return fallbackCwd;
    }
    return null;
  }

  Future<void> _completeStreaming(
    AgySessionSummary session,
    String assistantId,
  ) async {
    if (!_completedAssistantIds.add(assistantId)) return;
    _wakeupFinalizeTimers.remove(session.id)?.cancel();
    _wakeupAssistantIds.remove(session.id);
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    final subToCancel = _activeSub;
    _activeSub = null;
    if (subToCancel != null) {
      unawaited(subToCancel.cancel());
    }
    final hadLocalRequest = _activeLocalRequest != null;
    _activeLocalRequest = null;
    if (_activeStreamingSessionId == session.id) {
      _activeStreamingSessionId = null;
    }
    _sessionTurnTokens.remove(session.id);
    _pendingPermissionsBySession.remove(session.id);
    _sessionLoopWarnings.remove(session.id);
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

    final nextBgIds = {...state.activeBackgroundSessionIds}..remove(session.id);
    state = state.copyWith(
      isStreaming: _loadedSessionId == session.id ? false : state.isStreaming,
      tokensPerSecond: 0,
      activeBackgroundSessionIds: nextBgIds,
      clearPermission: true,
      clearStallWarning: true,
      clearLoopWarning: _loadedSessionId == session.id,
      clearActiveTurnId: true,
    );
    await _persistMessages(session.id, persisted);

    // If this turn ran a `git push` command, automatically watch CI in that repo.
    if (hadLocalRequest || persisted.any((m) => m.id == assistantId)) {
      final completedMsg =
          persisted.where((m) => m.id == assistantId).firstOrNull;
      final fallbackCwd = session.workspacePath.isNotEmpty
          ? session.workspacePath
          : ref.read(projectsProvider).activeProject.primaryFolder;
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
      );
    } else if (state.queuedPrompts.isNotEmpty) {
      final nextPrompt = state.queuedPrompts.first;
      state = state.copyWith(
        queuedPrompts: state.queuedPrompts.sublist(1),
      );
      await sendPrompt(nextPrompt, force: true);
    }
  }

  Future<void> stopStreaming() async {
    final turnId = state.activeTurnId;
    final streamingSid = _activeStreamingSessionId;
    final clearedSid = streamingSid ?? _loadedSessionId;
    if (clearedSid != null) {
      _sessionTurnTokens.remove(clearedSid);
      _wakeupFinalizeTimers.remove(clearedSid)?.cancel();
      _wakeupAssistantIds.remove(clearedSid);
      _pendingPermissionsBySession.remove(clearedSid);
      _sessionLoopWarnings.remove(clearedSid);
    }
    await _activeSub?.cancel();
    _activeSub = null;
    if (turnId != null) {
      try {
        await RuntimeBridge.instance.cancelTurn(turnId);
      } catch (_) {}
    }
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _activeLocalRequest = null;
    _activeStreamingSessionId = null;
    try {
      await SshAgyRunner.instance.cancelActive(turnId: turnId);
    } catch (_) {}
    final updated = state.messages
        .map((m) => m.isStreaming
            ? m.copyWith(
                isStreaming: false,
                tools: _finalizeTools(m.tools, failed: true),
                completedAt: DateTime.now(),
              )
            : m)
        .toList();
    if (streamingSid != null) {
      final bgMsgs = _inFlightMessages.remove(streamingSid);
      if (bgMsgs != null && streamingSid != _loadedSessionId) {
        final cleanedBg = bgMsgs
            .map((m) => m.isStreaming
                ? m.copyWith(
                    isStreaming: false,
                    tools: _finalizeTools(m.tools, failed: true),
                    completedAt: DateTime.now(),
                  )
                : m)
            .toList();
        await _persistMessages(streamingSid, cleanedBg);
      }
    }
    final nextBgIds = {...state.activeBackgroundSessionIds};
    if (clearedSid != null) {
      nextBgIds.remove(clearedSid);
    } else {
      nextBgIds.clear();
    }
    state = state.copyWith(
      messages: updated,
      isStreaming: false,
      tokensPerSecond: 0,
      activeBackgroundSessionIds: nextBgIds,
      clearPermission: true,
      clearStallWarning: true,
      clearLoopWarning: true,
      clearActiveTurnId: true,
    );
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      await _persistMessages(activeId, updated);
    }
  }

  static String? _buildToolDiff(
    String path,
    String? oldText,
    String? newText,
  ) {
    final oldLines = oldText == null || oldText.isEmpty
        ? const <String>[]
        : oldText.split('\n');
    final newLines = newText == null || newText.isEmpty
        ? const <String>[]
        : newText.split('\n');
    if (oldLines.isEmpty && newLines.isEmpty) return null;
    final buf = StringBuffer()
      ..writeln('--- a/$path')
      ..writeln('+++ b/$path')
      ..writeln('@@ -1,${oldLines.length} +1,${newLines.length} @@');
    for (final line in oldLines.take(80)) {
      buf.writeln('-$line');
    }
    if (oldLines.length > 80) buf.writeln('-... (${oldLines.length - 80} more)');
    for (final line in newLines.take(80)) {
      buf.writeln('+$line');
    }
    if (newLines.length > 80) buf.writeln('+... (${newLines.length - 80} more)');
    return buf.toString();
  }

  static List<FileChangeEntry> extractChangedFilesFromTools(
    List<ChatToolStep> tools,
  ) {
    final byPath = <String, FileChangeEntry>{};
    for (final step in tools) {
      if (step.state == ToolCallState.failed) continue;
      final nameLower = step.toolName.toLowerCase();
      final isFileEdit = nameLower.contains('write') ||
          nameLower.contains('edit') ||
          nameLower.contains('replace') ||
          nameLower.contains('patch') ||
          nameLower.contains('create_file');
      if (!isFileEdit) continue;
      final rawPath = step.parameters['TargetFile'] ??
          step.parameters['AbsolutePath'] ??
          step.parameters['path'] ??
          step.parameters['file'];
      final path = rawPath?.toString().trim() ?? '';
      if (path.isEmpty) continue;

      final replacement = step.parameters['Replacement'] ??
          step.parameters['ReplacementContent'] ??
          step.parameters['CodeContent'] ??
          step.parameters['content'];
      final target = step.parameters['TargetContent'];
      final repStr = replacement?.toString();
      final tgtStr = target?.toString();
      final added = repStr != null ? repStr.split('\n').length : 0;
      final removed = tgtStr != null ? tgtStr.split('\n').length : 0;
      final created = (step.parameters['Overwrite'] == false) ||
          nameLower.contains('create') ||
          (nameLower.contains('write_to_file') && removed == 0);
      final prev = byPath[path];
      final diffSnippet = _buildToolDiff(path, tgtStr, repStr) ?? prev?.diff;
      byPath[path] = FileChangeEntry(
        path: path,
        added: (prev?.added ?? 0) + added,
        removed: (prev?.removed ?? 0) + removed,
        created: prev?.created ?? created,
        diff: diffSnippet,
      );
    }
    return byPath.values.toList();
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
    if (nativeTaskId != null &&
        !nativeTaskId.startsWith('session:') &&
        !nativeTaskId.startsWith('tool:')) {
      await ref.read(runtimeProvider.notifier).cancelBackgroundTask(nativeTaskId);
      return;
    }
    if (kindName == 'session' && sessionId != null) {
      if (_activeStreamingSessionId == sessionId ||
          ref.read(sessionsProvider).activeSessionId == sessionId) {
        await stopStreaming();
      } else {
        _inFlightMessages.remove(sessionId);
        final nextBg = {...state.activeBackgroundSessionIds}..remove(sessionId);
        state = state.copyWith(activeBackgroundSessionIds: nextBg);
      }
      if (state.activeTurnId != null) {
        await ref
            .read(runtimeProvider.notifier)
            .cancelBackgroundTask('turn:${state.activeTurnId}');
      }
      return;
    }
    // Active tool / subagent step or fallback
    await stopStreaming();
    await ref.read(runtimeProvider.notifier).refresh();
  }

  Future<int> forceStopAllTasks() async {
    ref.read(ciWatchProvider.notifier).cancelAll();
    if (state.isStreaming || _activeStreamingSessionId != null) {
      await stopStreaming();
    }
    _inFlightMessages.clear();
    final stoppedNative =
        await ref.read(runtimeProvider.notifier).forceStopAllBackgroundTasks();
    state = state.copyWith(
      activeBackgroundSessionIds: const {},
      isStreaming: false,
      clearPermission: true,
      clearStallWarning: true,
    );
    return stoppedNative;
  }

  Future<void> appendSystemFeedback(
    String text, {
    List<FileChangeEntry> changedFiles = const [],
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
    if (state.isStreaming || _activeStreamingSessionId != null) {
      await stopStreaming();
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
    if (state.isStreaming || _activeStreamingSessionId != null) {
      await stopStreaming();
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
    final turnId = state.activeTurnId;
    final sid = _activeStreamingSessionId ?? _loadedSessionId;
    if (sid != null) {
      _pendingPermissionsBySession.remove(sid);
    }
    state = state.copyWith(clearPermission: true);
    _resetWatchdog();
    if (perm != null && turnId != null) {
      try {
        await RuntimeBridge.instance.respondPermission(
          turnId: turnId,
          requestId: perm.requestId,
          optionId: optionId,
        );
      } catch (err) {
        if (!ref.mounted) return;
        if (sid != null && _activeStreamingSessionId == sid) {
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
    _loopDetector.reset();
    _seenLoopCallIds.clear();
    _pendingCompactions.clear();
    if (activeId != null) {
      _pendingPermissionsBySession.remove(activeId);
      _sessionLoopWarnings.remove(activeId);
    }
    state = ChatThreadState(loadedSessionId: activeId);
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
      activeBackgroundSessionIds: state.activeBackgroundSessionIds,
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

  /// Compacts the active conversation window:
  /// 1. Closes and resets the old bloated backend ACP session (`remoteConversationId`).
  /// 2. Distills uncompacted turns into a fresh [ChatMessage] with
  ///    `isCompactionSummary: true` (via stateless LLM turn when online, or
  ///    deterministic extractive fallback when offline/error).
  /// 3. Keeps older messages visible in scrollback while excluding them from
  ///    `contextBudgetProvider` so context drops immediately and subsequent
  ///    prompts resume cleanly from the compacted handoff summary.
  Future<({bool ok, String message})> compactThread({
    String? instructions,
  }) async {
    final busy = state.isStreaming ||
        _activeStreamingSessionId != null ||
        state.activeBackgroundSessionIds.isNotEmpty;
    if (busy) {
      return (
        ok: false,
        message: 'Wait for or stop the active turn before compacting.',
      );
    }

    final session = ref.read(sessionsProvider).activeSession;
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

    // Close the old bloated backend session and detach it so the next prompt
    // starts from a clean context window seeded with the handoff summary.
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
    _loopDetector.reset();
    _seenLoopCallIds.clear();

    if (sshHost == null && !runtime.status.isReady) {
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
        modelId: settings.selectedModelId,
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
      modelId: settings.selectedModelId,
      reasoningEffort: settings.reasoningEffort,
      isStreaming: true,
      isCompactionSummary: true,
    );
    final nextMessages = [...msgs, summaryMsg];
    final turnId = const Uuid().v4();
    final streamToken = ++_nextStreamToken;
    _sessionTurnTokens[resetSession.id] = streamToken;
    _loadedSessionId = resetSession.id;
    _activeStreamingSessionId = resetSession.id;
    _turnStartedAt[assistantId] = now;
    _turnModelId[assistantId] = settings.selectedModelId;
    _turnEffort[assistantId] = settings.reasoningEffort;
    _inFlightMessages[resetSession.id] = nextMessages;
    _pendingCompactions[assistantId] = (
      turns: turns,
      compactCount: compactCount,
      instructions: cleanInstructions,
      tempRemoteId: null,
    );

    state = state.copyWith(
      messages: nextMessages,
      isStreaming: true,
      activeTurnId: turnId,
      activeBackgroundSessionIds: {
        ...state.activeBackgroundSessionIds,
        resetSession.id,
      },
      tokensPerSecond: 0,
      clearPermission: true,
      clearStallWarning: true,
      clearLoopWarning: true,
      loadedSessionId: resetSession.id,
    );

    final project = ref.read(projectsProvider).activeProject;
    final perms = ref.read(permissionsProvider);
    final apiKey = await ref.read(authServiceProvider).readGeminiApiKey();
    if (!ref.mounted || _sessionTurnTokens[resetSession.id] != streamToken) {
      return (ok: false, message: 'Cancelled');
    }

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

    final request = AgyPromptRequest(
      prompt: compactPrompt,
      workspacePath: effectiveWorkspace,
      extraDirs: [
        ...project.folders,
        if (perms.allFilesAccess) perms.externalStorageRoot,
        if (perms.allFilesAccess) '/sdcard',
      ],
      conversationId: null,
      modelId: settings.selectedModelId,
      effortCliValue: settings.reasoningEffort,
      mode: sshHost != null
          ? AgyExecutionMode.plan
          : AgyExecutionMode.plan.androidSafe,
      dangerouslySkipPermissions: true,
      allowNonWorkspaceAccess: true,
      geminiApiKey: apiKey,
      continueLast: false,
      remoteAgent: settings.remoteAgent.isEmpty ? null : settings.remoteAgent,
    );

    final Stream<AgyChatEvent> stream;
    if (sshHost != null) {
      final (pwd, key) =
          await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
      if (!ref.mounted || _sessionTurnTokens[resetSession.id] != streamToken) {
        return (ok: false, message: 'Cancelled');
      }
      stream = SshAgyRunner.instance.runPrompt(
        host: sshHost,
        request: request,
        password: pwd,
        privateKeyPem: key,
      );
    } else {
      stream = RuntimeBridge.instance.runPrompt(request, turnId);
    }

    _receivedTurnContent = false;
    _usedFallbackForTurn = false;
    _activeLocalRequest = sshHost == null ? request : null;
    _rateSamples.clear();
    _streamBurstStart = null;
    _resetWatchdog();

    await _activeSub?.cancel();
    _activeSub = stream.listen(
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
    state = state.copyWith(clearLoopWarning: true);
  }

  Future<void> breakLoopAndPivot() async {
    final hit = state.loopWarning;
    if (hit == null) return;
    final pivot = hit.pivotPrompt;
    _loopDetector.reset();
    _seenLoopCallIds.clear();
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) _sessionLoopWarnings.remove(activeId);
    state = state.copyWith(clearLoopWarning: true);
    if (state.isStreaming || _activeStreamingSessionId != null) {
      await stopStreaming();
    }
    if (!ref.mounted) return;
    await sendPrompt(pivot, force: true);
  }

  /// Deterministic `/rewind` rollback: restores workspace Git snapshot (when a
  /// checkpoint exists on the target user message) and prunes conversation
  /// history back to right before that message, returning the prompt text.
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
        gitNote = 'Workspace & conversation restored (${cpRef.substring(0, cpRef.length.clamp(0, 7))})';
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
    _loopDetector.reset();
    _seenLoopCallIds.clear();
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
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
