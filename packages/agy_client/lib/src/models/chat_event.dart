import 'usage_quota.dart';

/// Unified event stream produced by both `agy --output-format stream-json` and `agy acp`.
sealed class AgyChatEvent {
  const AgyChatEvent();
}

class AgyInitEvent extends AgyChatEvent {
  const AgyInitEvent({
    required this.conversationId,
    required this.cwd,
    this.tools = const [],
    this.permissionMode = 'request-review',
    this.model,
    this.agent,
  });

  final String conversationId;
  final String cwd;
  final List<String> tools;
  final String permissionMode;
  final String? model;
  final String? agent;
}

class AgyThoughtDeltaEvent extends AgyChatEvent {
  const AgyThoughtDeltaEvent({
    required this.delta,
    this.stepIndex = 0,
    this.isDone = false,
  });

  final String delta;
  final int stepIndex;
  final bool isDone;
}

class AgyTextDeltaEvent extends AgyChatEvent {
  const AgyTextDeltaEvent({
    required this.delta,
    this.stepIndex = 0,
    this.isDone = false,
  });

  final String delta;
  final int stepIndex;
  final bool isDone;
}

enum ToolCallState { pending, running, completed, failed }

class AgyToolCallEvent extends AgyChatEvent {
  const AgyToolCallEvent({
    required this.callId,
    required this.toolName,
    required this.state,
    this.parameters = const {},
    this.output,
    this.errorMessage,
    this.durationSeconds,
    this.stepIndex = 0,
  });

  final String callId;
  final String toolName;
  final ToolCallState state;
  final Map<String, dynamic> parameters;
  final String? output;
  final String? errorMessage;
  final double? durationSeconds;
  final int stepIndex;
}

class PermissionOption {
  const PermissionOption({
    required this.optionId,
    required this.name,
    required this.kind,
  });

  final String optionId;
  final String name;
  final String kind;
}

class AgyPermissionRequestEvent extends AgyChatEvent {
  const AgyPermissionRequestEvent({
    required this.requestId,
    required this.toolName,
    required this.title,
    this.commandOrPath,
    this.diffPreview,
    this.options = const [],
  });

  final Object requestId;
  final String toolName;
  final String title;
  final String? commandOrPath;
  final String? diffPreview;
  final List<PermissionOption> options;
}

class AgyTurnResultEvent extends AgyChatEvent {
  const AgyTurnResultEvent({
    required this.conversationId,
    required this.status,
    required this.response,
    this.durationSeconds = 0,
    this.numTurns = 1,
    this.usage = const TokenUsage(),
    this.error,
  });

  final String conversationId;
  final String status;
  final String response;
  final double durationSeconds;
  final int numTurns;
  final TokenUsage usage;
  final String? error;
}

class AgyErrorEvent extends AgyChatEvent {
  const AgyErrorEvent({
    required this.message,
    this.code,
    this.requiresAuth = false,
  });

  final String message;
  final int? code;
  final bool requiresAuth;
}
