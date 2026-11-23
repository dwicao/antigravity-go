import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'auth_state.dart';
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
        if (output != null) 'output': output,
        if (error != null) 'error': error,
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
    this.activeBackgroundSessionIds = const {},
  });

  final List<ChatMessage> messages;
  final bool isStreaming;
  final List<String> queuedPrompts;
  final AgyPermissionRequestEvent? pendingPermission;
  final String? activeTurnId;
  final double tokensPerSecond;
  final String? stallWarning;
  final Set<String> activeBackgroundSessionIds;

  ChatThreadState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    List<String>? queuedPrompts,
    AgyPermissionRequestEvent? pendingPermission,
    bool clearPermission = false,
    String? activeTurnId,
    double? tokensPerSecond,
    String? stallWarning,
    bool clearStallWarning = false,
    Set<String>? activeBackgroundSessionIds,
  }) {
    return ChatThreadState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      queuedPrompts: queuedPrompts ?? this.queuedPrompts,
      pendingPermission: clearPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      activeTurnId: activeTurnId ?? this.activeTurnId,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
      stallWarning:
          clearStallWarning ? null : (stallWarning ?? this.stallWarning),
      activeBackgroundSessionIds:
          activeBackgroundSessionIds ?? this.activeBackgroundSessionIds,
    );
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, ChatThreadState>(ChatNotifier.new);

class ChatNotifier extends Notifier<ChatThreadState> {
  StreamSubscription<AgyChatEvent>? _activeSub;
  String? _loadedSessionId;
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
    if (_activeStreamingSessionId == null) return;
    _stallWatchdog = Timer(const Duration(seconds: 180), () {
      if (_activeStreamingSessionId != null && ref.mounted) {
        state = state.copyWith(
          stallWarning:
              'Agent turn has had no output for 3 minutes — check connection or tap Stop & Regenerate.',
        );
      }
    });
  }

  @override
  ChatThreadState build() {
    ref.onDispose(() {
      _stallWatchdog?.cancel();
      _activeSub?.cancel();
    });
    final activeId = ref.watch(
      sessionsProvider.select((s) => s.activeSessionId),
    );
    if (activeId != null && activeId != _loadedSessionId) {
      _loadedSessionId = activeId;
      Future.microtask(() => _loadMessages(activeId));
    }
    return const ChatThreadState();
  }

  Future<void> _loadMessages(String sessionId) async {
    final inFlight = _inFlightMessages[sessionId];
    if (inFlight != null) {
      state = state.copyWith(
        messages: List<ChatMessage>.from(inFlight),
        isStreaming: _activeStreamingSessionId == sessionId,
        clearPermission: true,
        clearStallWarning: true,
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('agy_msgs_$sessionId');
    if (raw == null || raw.isEmpty) {
      state = ChatThreadState(
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
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
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
      );
    } catch (_) {
      state = ChatThreadState(
        activeBackgroundSessionIds: state.activeBackgroundSessionIds,
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
      state = state.copyWith(
        queuedPrompts: [...state.queuedPrompts, prompt],
      );
      return;
    }

    var session = ref.read(sessionsProvider).activeSession;
    session ??= await ref.read(sessionsProvider.notifier).createSession();

    final settings = ref.read(settingsProvider);
    final attachmentNote = attachments.isEmpty
        ? ''
        : '\n\n[Attached files: ${attachments.join(', ')}]';
    final effectivePrompt = '$prompt$attachmentNote';
    final now = DateTime.now();

    final userMsg = ChatMessage(
      id: const Uuid().v4(),
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

    final nextMessages = [...state.messages, userMsg, assistantMsg];
    final turnId = const Uuid().v4();
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

    final hosts = ref.read(hostsProvider);
    final runtime = ref.read(runtimeProvider);
    final project = ref.read(projectsProvider).activeProject;
    final perms = ref.read(permissionsProvider);
    final apiKey = await ref.read(authServiceProvider).readGeminiApiKey();

    final effectivePreset = project.permissionPreset ?? settings.permissionPreset;
    final skipPerms = effectivePreset == AntigravityPermissionPreset.turbo;
    final allowNonWorkspace = project.allowNonWorkspaceAccess ??
        (settings.allowNonWorkspaceAccess || perms.allFilesAccess);

    final effectiveWorkspace = session.workspacePath.isNotEmpty
        ? session.workspacePath
        : (project.primaryFolder.isNotEmpty
            ? project.primaryFolder
            : (runtime.status.workspaceRoot ?? ''));

    final sshHost = hosts.activeSshHost;
    final requestedMode = AgyExecutionMode.fromCli(settings.executionMode);
    final effectiveMode = sshHost != null
        ? requestedMode
        : requestedMode.androidSafe;

    final request = AgyPromptRequest(
      prompt: effectivePrompt,
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
      continueLast: settings.continueLast,
      remoteAgent: settings.remoteAgent.isEmpty ? null : settings.remoteAgent,
    );

    Stream<AgyChatEvent> stream;
    if (sshHost != null) {
      final (pwd, key) =
          await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
      stream = SshAgyRunner.instance.runPrompt(
        host: sshHost,
        request: request,
        password: pwd,
        privateKeyPem: key,
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
      stream = RuntimeBridge.instance.runPrompt(request, turnId);
    }

    final currentSession = session;
    _receivedTurnContent = false;
    _usedFallbackForTurn = false;
    _activeLocalRequest = sshHost == null ? request : null;
    _rateSamples.clear();
    _streamBurstStart = null;
    state = state.copyWith(tokensPerSecond: 0, clearStallWarning: true);
    _resetWatchdog();

    await _activeSub?.cancel();
    _activeSub = stream.listen(
      (evt) => _handleEvent(currentSession, assistantId, evt),
      onError: (Object err) {
        _finishAssistantMessage(
          session: currentSession,
          assistantId: assistantId,
          text: 'Agent error: $err',
        );
      },
      onDone: () => _completeStreaming(currentSession, assistantId),
    );
  }

  void _handleEvent(
    AgySessionSummary session,
    String assistantId,
    AgyChatEvent evt,
  ) {
    _resetWatchdog();
    if (state.stallWarning != null) {
      state = state.copyWith(clearStallWarning: true);
    }
    final msgs = _messagesForSession(session.id);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final current = msgs[idx];

    switch (evt) {
      case AgyInitEvent():
        ref.read(authProvider.notifier).markAuthenticatedFromTurn();
        if (evt.model != null && evt.model!.isNotEmpty) {
          _turnModelId[assistantId] = evt.model!;
        }
        if (evt.conversationId.isNotEmpty) {
          ref.read(sessionsProvider.notifier).updateSession(
                session.copyWith(remoteConversationId: evt.conversationId),
              );
        }
      case AgyThoughtDeltaEvent():
        _receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        if (_loadedSessionId == session.id) {
          final rate = _recordRateSample(evt.delta);
          state = state.copyWith(tokensPerSecond: rate);
        }
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(thoughts: '${current.thoughts}${evt.delta}'),
        );
      case AgyTextDeltaEvent():
        _receivedTurnContent = true;
        _firstOutputAt.putIfAbsent(assistantId, DateTime.now);
        if (_loadedSessionId == session.id) {
          final rate = _recordRateSample(evt.delta);
          state = state.copyWith(tokensPerSecond: rate);
        }
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(text: '${current.text}${evt.delta}'),
        );
      case AgyToolCallEvent():
        _receivedTurnContent = true;
        final tools = [...current.tools];
        final tIdx = tools.indexWhere((t) => t.id == evt.callId);
        if (tIdx >= 0) {
          final prev = tools[tIdx];
          tools[tIdx] = ChatToolStep(
            id: evt.callId,
            toolName: evt.toolName != 'tool' ? evt.toolName : prev.toolName,
            state: evt.state,
            parameters:
                evt.parameters.isNotEmpty ? evt.parameters : prev.parameters,
            output: evt.output ?? prev.output,
            error: evt.errorMessage ?? prev.error,
            durationSeconds: evt.durationSeconds ?? prev.durationSeconds,
            startedAt: prev.startedAt,
          );
        } else {
          tools.add(
            ChatToolStep(
              id: evt.callId,
              toolName: evt.toolName,
              state: evt.state,
              parameters: evt.parameters,
              output: evt.output,
              error: evt.errorMessage,
              durationSeconds: evt.durationSeconds,
              startedAt:
                  evt.state == ToolCallState.running ? DateTime.now() : null,
            ),
          );
        }
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(tools: tools),
        );
        // Checkpoint completed tool steps mid-turn against OS process kills.
        if (evt.state != ToolCallState.running) {
          unawaited(_persistMessages(session.id, _messagesForSession(session.id)));
        }
      case AgyPermissionRequestEvent():
        state = state.copyWith(pendingPermission: evt);
      case AgyTurnResultEvent():
        _receivedTurnContent = true;
        if (evt.status.toUpperCase() == 'SUCCESS') {
          ref.read(authProvider.notifier).markAuthenticatedFromTurn();
        }
        final finalText = current.text.isEmpty ? evt.response : current.text;
        final stats = _computeTurnStats(
          assistantId: assistantId,
          text: finalText,
          thoughts: current.thoughts,
          usage: evt.usage,
          reportedDurationSeconds: evt.durationSeconds,
        );
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: finalText,
            usage: evt.usage,
            tools: _finalizeTools(current.tools),
            durationSeconds: stats.durationSec,
            tokensPerSecond: stats.tokPerSec,
            modelId: _turnModelId[assistantId] ?? current.modelId,
            reasoningEffort: _turnEffort[assistantId] ?? current.reasoningEffort,
            completedAt: DateTime.now(),
            isStreaming: false,
          ),
        );
        if (evt.conversationId.isNotEmpty) {
          ref.read(sessionsProvider.notifier).updateSession(
                session.copyWith(
                  remoteConversationId: evt.conversationId,
                  updatedAt: DateTime.now(),
                  lastPreview: finalText,
                ),
              );
        }
        ref.read(usageProvider.notifier).recordTurn(
              modelId: _turnModelId[assistantId] ??
                  ref.read(settingsProvider).selectedModelId,
              usage: evt.usage,
              sessionId: session.id,
            );
      case AgyErrorEvent():
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
          state = state.copyWith(activeTurnId: fallbackTurnId);
          _activeSub?.cancel();
          _activeSub = RuntimeBridge.instance
              .runPrompt(fallbackReq, fallbackTurnId, useAcp: false)
              .listen(
                (e) => _handleEvent(session, assistantId, e),
                onError: (Object err) => _finishAssistantMessage(
                  session: session,
                  assistantId: assistantId,
                  text: 'Agent error: $err',
                ),
                onDone: () => _completeStreaming(session, assistantId),
              );
          return;
        }
        final stats = _computeTurnStats(
          assistantId: assistantId,
          text: current.text,
          thoughts: current.thoughts,
          usage: current.usage,
        );
        _replaceMessageInSession(
          session.id,
          idx,
          current.copyWith(
            text: current.text.isEmpty
                ? evt.message
                : '${current.text}\n\n${evt.message}',
            tools: _finalizeTools(current.tools, failed: true),
            durationSeconds: current.durationSeconds ?? stats.durationSec,
            tokensPerSecond: current.tokensPerSecond ?? stats.tokPerSec,
            modelId: _turnModelId[assistantId] ?? current.modelId,
            reasoningEffort: _turnEffort[assistantId] ?? current.reasoningEffort,
            completedAt: current.completedAt ?? DateTime.now(),
            isStreaming: false,
            requiresAuth: evt.requiresAuth,
          ),
        );
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

  Future<void> _completeStreaming(
    AgySessionSummary session,
    String assistantId,
  ) async {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _activeLocalRequest = null;
    if (_activeStreamingSessionId == session.id) {
      _activeStreamingSessionId = null;
    }
    final msgs = _messagesForSession(session.id);
    final idx = msgs.indexWhere((m) => m.id == assistantId);
    if (idx >= 0) {
      final cur = msgs[idx];
      final finalizedTools = _finalizeTools(cur.tools);
      if (cur.isStreaming ||
          cur.durationSeconds == null ||
          cur.completedAt == null ||
          !identical(finalizedTools, cur.tools)) {
        final stats = _computeTurnStats(
          assistantId: assistantId,
          text: cur.text,
          thoughts: cur.thoughts,
          usage: cur.usage,
        );
        _replaceMessageInSession(
          session.id,
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
    );
    await _persistMessages(session.id, persisted);

    if (state.queuedPrompts.isNotEmpty) {
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
      await SshAgyRunner.instance.cancelActive();
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
    state = state.copyWith(
      messages: updated,
      isStreaming: false,
      tokensPerSecond: 0,
      activeBackgroundSessionIds: const {},
      clearPermission: true,
      clearStallWarning: true,
    );
    final activeId = ref.read(sessionsProvider).activeSessionId;
    if (activeId != null) {
      await _persistMessages(activeId, updated);
    }
  }

  static List<FileChangeEntry> extractChangedFilesFromTools(
    List<ChatToolStep> tools,
  ) {
    final byPath = <String, FileChangeEntry>{};
    for (final step in tools) {
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
      final added = replacement != null
          ? replacement.toString().split('\n').length
          : 0;
      final removed = target != null ? target.toString().split('\n').length : 0;
      final created = (step.parameters['Overwrite'] == false) ||
          nameLower.contains('create') ||
          (nameLower.contains('write_to_file') && removed == 0);
      final prev = byPath[path];
      byPath[path] = FileChangeEntry(
        path: path,
        added: (prev?.added ?? 0) + added,
        removed: (prev?.removed ?? 0) + removed,
        created: prev?.created ?? created,
      );
    }
    return byPath.values.toList();
  }

  Future<void> _cancelAllBackgroundWork() async {
    if (state.isStreaming || _activeStreamingSessionId != null) {
      await stopStreaming();
    }
    await ref.read(runtimeProvider.notifier).forceStopAllBackgroundTasks();
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
    if (state.queuedPrompts.isEmpty) return;
    await _cancelAllBackgroundWork();
    final nextPrompt = state.queuedPrompts.first;
    state = state.copyWith(
      queuedPrompts: state.queuedPrompts.sublist(1),
    );
    await sendPrompt(nextPrompt, force: true);
  }

  void removeQueuedPrompt(int index) {
    if (index < 0 || index >= state.queuedPrompts.length) return;
    final updated = [...state.queuedPrompts]..removeAt(index);
    state = state.copyWith(queuedPrompts: updated);
  }

  Future<void> steerNow(String prompt) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) return;
    await _cancelAllBackgroundWork();
    await sendPrompt(trimmed, force: true);
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
    }
    await sendPrompt(trimmed, attachments: original.attachments);
  }

  Future<void> resolvePermission(String optionId) async {
    final perm = state.pendingPermission;
    final turnId = state.activeTurnId;
    state = state.copyWith(clearPermission: true);
    if (perm != null && turnId != null) {
      try {
        await RuntimeBridge.instance.respondPermission(
          turnId: turnId,
          requestId: perm.requestId,
          optionId: optionId,
        );
      } catch (_) {}
    }
  }

  Future<void> clearCurrentThread() async {
    final activeId = ref.read(sessionsProvider).activeSessionId;
    state = const ChatThreadState();
    if (activeId != null) {
      await _persistMessages(activeId, const []);
    }
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
