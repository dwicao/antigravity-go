import 'package:agy_client/agy_client.dart';
import 'package:uuid/uuid.dart';

import '../ui/chat/secret_mask.dart';

enum ChatRole { user, assistant, system }

Map<String, dynamic> _maskParameters(Map<String, dynamic> raw) {
  if (raw.isEmpty) return raw;
  return raw.map((k, v) {
    if (v is String) {
      return MapEntry(k, AgySecretMask.mask(v));
    }
    return MapEntry(k, v);
  });
}

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
        'parameters': _maskParameters(parameters),
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
        'text': AgySecretMask.mask(text),
        'createdAt': createdAt.toIso8601String(),
        if (thoughts.isNotEmpty) 'thoughts': AgySecretMask.mask(thoughts),
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
        if (steps.isNotEmpty)
          'steps': steps
              .map(
                (s) => s.text != null
                    ? s.copyWith(text: AgySecretMask.mask(s.text!)).toJson()
                    : s.toJson(),
              )
              .toList(),
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
