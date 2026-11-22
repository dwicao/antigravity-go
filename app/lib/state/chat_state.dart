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
  });

  final String id;
  final String toolName;
  final ToolCallState state;
  final Map<String, dynamic> parameters;
  final String? output;
  final String? error;
  final double? durationSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'toolName': toolName,
        'state': state.name,
        'parameters': parameters,
        if (output != null) 'output': output,
        if (error != null) 'error': error,
        if (durationSeconds != null) 'durationSeconds': durationSeconds,
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

  ChatMessage copyWith({
    String? text,
    String? thoughts,
    List<ChatToolStep>? tools,
    TokenUsage? usage,
    bool? isStreaming,
    bool? requiresAuth,
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
  });

  final List<ChatMessage> messages;
  final bool isStreaming;
  final List<String> queuedPrompts;
  final AgyPermissionRequestEvent? pendingPermission;
  final String? activeTurnId;

  ChatThreadState copyWith({
    List<ChatMessage>? messages,
    bool? isStreaming,
    List<String>? queuedPrompts,
    AgyPermissionRequestEvent? pendingPermission,
    bool clearPermission = false,
    String? activeTurnId,
  }) {
    return ChatThreadState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      queuedPrompts: queuedPrompts ?? this.queuedPrompts,
      pendingPermission: clearPermission
          ? null
          : (pendingPermission ?? this.pendingPermission),
      activeTurnId: activeTurnId ?? this.activeTurnId,
    );
  }
}

final chatProvider =
    NotifierProvider<ChatNotifier, ChatThreadState>(ChatNotifier.new);

class ChatNotifier extends Notifier<ChatThreadState> {
  StreamSubscription<AgyChatEvent>? _activeSub;
  String? _loadedSessionId;

  @override
  ChatThreadState build() {
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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('agy_msgs_$sessionId');
    if (raw == null || raw.isEmpty) {
      state = const ChatThreadState();
      return;
    }
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
      state = ChatThreadState(messages: list);
    } catch (_) {
      state = const ChatThreadState();
    }
  }

  Future<void> _persistMessages(String sessionId, List<ChatMessage> msgs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'agy_msgs_$sessionId',
      jsonEncode(msgs.map((m) => m.toJson()).toList()),
    );
  }

  Future<void> sendPrompt(
    String rawText, {
    List<String> attachments = const [],
  }) async {
    final prompt = rawText.trim();
    if (prompt.isEmpty) return;

    if (state.isStreaming) {
      state = state.copyWith(
        queuedPrompts: [...state.queuedPrompts, prompt],
      );
      return;
    }

    var session = ref.read(sessionsProvider).activeSession;
    session ??= await ref.read(sessionsProvider.notifier).createSession();

    final attachmentNote = attachments.isEmpty
        ? ''
        : '\n\n[Attached files: ${attachments.join(', ')}]';
    final effectivePrompt = '$prompt$attachmentNote';

    final userMsg = ChatMessage(
      id: const Uuid().v4(),
      role: ChatRole.user,
      text: prompt,
      createdAt: DateTime.now(),
      attachments: attachments,
    );

    final assistantId = const Uuid().v4();
    final assistantMsg = ChatMessage(
      id: assistantId,
      role: ChatRole.assistant,
      text: '',
      createdAt: DateTime.now(),
      isStreaming: true,
    );

    final nextMessages = [...state.messages, userMsg, assistantMsg];
    final turnId = const Uuid().v4();
    state = state.copyWith(
      messages: nextMessages,
      isStreaming: true,
      activeTurnId: turnId,
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

    final settings = ref.read(settingsProvider);
    final hosts = ref.read(hostsProvider);
    final runtime = ref.read(runtimeProvider);
    final apiKey = await ref.read(authServiceProvider).readGeminiApiKey();

    final request = AgyPromptRequest(
      prompt: effectivePrompt,
      workspacePath: session.workspacePath.isNotEmpty
          ? session.workspacePath
          : (runtime.status.workspaceRoot ?? ''),
      conversationId: session.remoteConversationId,
      modelId: settings.selectedModelId,
      effortCliValue: settings.reasoningEffort,
      mode: AgyExecutionMode.fromCli(settings.executionMode),
      dangerouslySkipPermissions: settings.dangerouslySkipPermissions,
      geminiApiKey: apiKey,
    );

    Stream<AgyChatEvent> stream;
    final sshHost = hosts.activeSshHost;
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
    final idx = state.messages.indexWhere((m) => m.id == assistantId);
    if (idx < 0) return;
    final current = state.messages[idx];

    switch (evt) {
      case AgyInitEvent():
        if (evt.conversationId.isNotEmpty) {
          ref.read(sessionsProvider.notifier).updateSession(
                session.copyWith(remoteConversationId: evt.conversationId),
              );
        }
      case AgyThoughtDeltaEvent():
        _replaceMessage(
          idx,
          current.copyWith(thoughts: '${current.thoughts}${evt.delta}'),
        );
      case AgyTextDeltaEvent():
        _replaceMessage(
          idx,
          current.copyWith(text: '${current.text}${evt.delta}'),
        );
      case AgyToolCallEvent():
        final tools = [...current.tools];
        final tIdx = tools.indexWhere((t) => t.id == evt.callId);
        final step = ChatToolStep(
          id: evt.callId,
          toolName: evt.toolName,
          state: evt.state,
          parameters: evt.parameters,
          output: evt.output,
          error: evt.errorMessage,
          durationSeconds: evt.durationSeconds,
        );
        if (tIdx >= 0) {
          tools[tIdx] = step;
        } else {
          tools.add(step);
        }
        _replaceMessage(idx, current.copyWith(tools: tools));
      case AgyPermissionRequestEvent():
        state = state.copyWith(pendingPermission: evt);
      case AgyTurnResultEvent():
        final finalText = current.text.isEmpty ? evt.response : current.text;
        _replaceMessage(
          idx,
          current.copyWith(
            text: finalText,
            usage: evt.usage,
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
              modelId: ref.read(settingsProvider).selectedModelId,
              usage: evt.usage,
              sessionId: session.id,
            );
      case AgyErrorEvent():
        if (evt.requiresAuth) {
          ref.read(authProvider.notifier).refresh();
        }
        _replaceMessage(
          idx,
          current.copyWith(
            text: current.text.isEmpty
                ? evt.message
                : '${current.text}\n\n${evt.message}',
            isStreaming: false,
            requiresAuth: evt.requiresAuth,
          ),
        );
    }
  }

  void _replaceMessage(int idx, ChatMessage updated) {
    final list = [...state.messages];
    list[idx] = updated;
    state = state.copyWith(messages: list);
  }

  void _finishAssistantMessage({
    required AgySessionSummary session,
    required String assistantId,
    required String text,
  }) {
    final idx = state.messages.indexWhere((m) => m.id == assistantId);
    if (idx >= 0) {
      _replaceMessage(
        idx,
        state.messages[idx].copyWith(text: text, isStreaming: false),
      );
    }
    _completeStreaming(session, assistantId);
  }

  Future<void> _completeStreaming(
    AgySessionSummary session,
    String assistantId,
  ) async {
    final idx = state.messages.indexWhere((m) => m.id == assistantId);
    if (idx >= 0 && state.messages[idx].isStreaming) {
      _replaceMessage(
        idx,
        state.messages[idx].copyWith(isStreaming: false),
      );
    }
    state = state.copyWith(isStreaming: false, clearPermission: true);
    await _persistMessages(session.id, state.messages);

    if (state.queuedPrompts.isNotEmpty) {
      final nextPrompt = state.queuedPrompts.first;
      state = state.copyWith(
        queuedPrompts: state.queuedPrompts.sublist(1),
      );
      await sendPrompt(nextPrompt);
    }
  }

  Future<void> stopStreaming() async {
    final turnId = state.activeTurnId;
    await _activeSub?.cancel();
    _activeSub = null;
    if (turnId != null) {
      try {
        await RuntimeBridge.instance.cancelTurn(turnId);
      } catch (_) {}
    }
    try {
      await SshAgyRunner.instance.cancelActive();
    } catch (_) {}
    state = state.copyWith(isStreaming: false, clearPermission: true);
  }

  Future<void> sendQueuedNow() async {
    if (state.queuedPrompts.isEmpty) return;
    await stopStreaming();
    final nextPrompt = state.queuedPrompts.first;
    state = state.copyWith(
      queuedPrompts: state.queuedPrompts.sublist(1),
    );
    await sendPrompt(nextPrompt);
  }

  void resolvePermission(String optionId) {
    state = state.copyWith(clearPermission: true);
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
