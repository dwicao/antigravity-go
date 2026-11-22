import 'dart:convert';

import '../models/chat_event.dart';
import '../models/usage_quota.dart';

/// Parses NDJSON lines emitted by `agy --output-format stream-json` into [AgyChatEvent]s.
class StreamJsonParser {
  const StreamJsonParser._();

  /// Encodes a prompt turn for `agy --input-format stream-json`.
  static String encodeUserMessage(String prompt) {
    return jsonEncode({
      'event': 'user',
      'message': {'content': prompt},
    });
  }

  /// Parses a single line of NDJSON stdout. Returns `null` for blank or unrecognized lines.
  static AgyChatEvent? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) {
      return null;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final eventName = decoded['event'] as String?;
    switch (eventName) {
      case 'init':
        final payload = decoded['init'] as Map<String, dynamic>? ?? const {};
        return AgyInitEvent(
          conversationId: decoded['conversation_id'] as String? ?? '',
          cwd: payload['cwd'] as String? ?? '',
          tools: (payload['tools'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList(),
          permissionMode:
              payload['permission_mode'] as String? ?? 'request-review',
          model: payload['model'] as String?,
          agent: payload['agent'] as String?,
        );

      case 'step_update':
        final step =
            decoded['step_update'] as Map<String, dynamic>? ?? const {};
        final stepType = step['step_type'] as String? ?? '';
        final state = step['state'] as String? ?? '';
        final isDone = state.toUpperCase() == 'DONE';
        final stepIndex = (step['step_index'] as num?)?.toInt() ?? 0;

        if (stepType == 'agent_response') {
          final delta = step['text_delta'] as String? ?? '';
          return AgyTextDeltaEvent(
            delta: delta,
            stepIndex: stepIndex,
            isDone: isDone,
          );
        }

        if (stepType == 'thinking' || stepType == 'thought') {
          final delta = step['text_delta'] as String? ?? '';
          return AgyThoughtDeltaEvent(
            delta: delta,
            stepIndex: stepIndex,
            isDone: isDone,
          );
        }

        if (stepType == 'tool') {
          final info = step['tool_info'] as Map<String, dynamic>? ?? const {};
          final toolName = step['tool_name'] as String? ??
              info['name'] as String? ??
              'tool';
          final err = info['error'] as Map<String, dynamic>?;
          final callState = err != null
              ? ToolCallState.failed
              : (isDone ? ToolCallState.completed : ToolCallState.running);
          return AgyToolCallEvent(
            callId: 'step-$stepIndex-$toolName',
            toolName: toolName,
            state: callState,
            parameters: info['parameters'] as Map<String, dynamic>? ?? const {},
            output: info['output']?.toString(),
            errorMessage: err?['message']?.toString(),
            durationSeconds: (step['duration_seconds'] as num?)?.toDouble(),
            stepIndex: stepIndex,
          );
        }
        return null;

      case 'result':
        final result = decoded['result'] as Map<String, dynamic>? ?? const {};
        final usageMap =
            result['usage'] as Map<String, dynamic>? ?? const {};
        final status = result['status'] as String? ?? 'SUCCESS';
        final error = result['error'] as String?;
        if (error != null &&
            error.toLowerCase().contains('authentication required')) {
          return AgyErrorEvent(message: error, requiresAuth: true);
        }
        return AgyTurnResultEvent(
          conversationId: result['conversation_id'] as String? ?? '',
          status: status,
          response: result['response'] as String? ?? '',
          durationSeconds: (result['duration_seconds'] as num?)?.toDouble() ?? 0,
          numTurns: (result['num_turns'] as num?)?.toInt() ?? 1,
          usage: TokenUsage.fromJson(usageMap),
          error: error,
        );

      default:
        return null;
    }
  }
}
