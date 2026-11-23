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

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {};
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
    if (decoded is! Map) return null;
    final root = _asMap(decoded);

    final eventName = root['event']?.toString();
    switch (eventName) {
      case 'init':
        final payload = _asMap(root['init']);
        final rawTools = payload['tools'];
        return AgyInitEvent(
          conversationId: root['conversation_id']?.toString() ?? '',
          cwd: payload['cwd']?.toString() ?? '',
          tools: rawTools is List
              ? rawTools.map((e) => e.toString()).toList()
              : const [],
          permissionMode:
              payload['permission_mode']?.toString() ?? 'request-review',
          model: payload['model']?.toString(),
          agent: payload['agent']?.toString(),
        );

      case 'step_update':
        final step = _asMap(root['step_update']);
        final stepType = step['step_type']?.toString() ?? '';
        final stateStr = step['state']?.toString() ?? '';
        final stateUpper = stateStr.toUpperCase().trim();
        final isDone = stateUpper == 'DONE' || stateUpper == 'COMPLETED';
        final stepIndex = (step['step_index'] as num?)?.toInt() ?? 0;

        TokenUsage? parseStepUsage() {
          final rawUsage = _asMap(step['usage']);
          if (rawUsage.isEmpty) return null;
          final parsed = TokenUsage.fromJson(rawUsage);
          final ctx = parsed.contextTokens > 0
              ? parsed.contextTokens
              : (parsed.inputTokens +
                  parsed.cacheReadTokens +
                  parsed.outputTokens);
          if (ctx <= 0) return null;
          return TokenUsage(
            inputTokens: parsed.inputTokens,
            outputTokens: parsed.outputTokens,
            thinkingTokens: parsed.thinkingTokens,
            cacheReadTokens: parsed.cacheReadTokens,
            totalTokens: parsed.totalTokens,
            contextTokens: ctx,
          );
        }

        if (stepType == 'agent_response') {
          final delta = step['text_delta']?.toString() ??
              step['delta']?.toString() ??
              step['text']?.toString() ??
              '';
          return AgyTextDeltaEvent(
            delta: delta,
            stepIndex: stepIndex,
            isDone: isDone,
            stepUsage: parseStepUsage(),
          );
        }

        if (stepType == 'thinking' || stepType == 'thought') {
          final delta = step['text_delta']?.toString() ??
              step['delta']?.toString() ??
              step['text']?.toString() ??
              '';
          return AgyThoughtDeltaEvent(
            delta: delta,
            stepIndex: stepIndex,
            isDone: isDone,
            stepUsage: parseStepUsage(),
          );
        }

        if (stepType == 'tool') {
          final info = _asMap(step['tool_info']);
          final toolName = step['tool_name']?.toString() ??
              info['name']?.toString() ??
              'tool';
          final rawErr = info['error'] ?? step['error'];
          final errMap = _asMap(rawErr);
          final errMsg = errMap.isNotEmpty
              ? errMap['message']?.toString()
              : (rawErr is String && rawErr.isNotEmpty ? rawErr : null);
          final isFailed = errMsg != null ||
              rawErr != null ||
              stateUpper == 'FAILED' ||
              stateUpper == 'ERROR' ||
              stateUpper == 'CANCELED' ||
              stateUpper == 'CANCELLED';
          final callState = isFailed
              ? ToolCallState.failed
              : isDone
                  ? ToolCallState.completed
                  : stateUpper == 'PENDING'
                      ? ToolCallState.pending
                      : ToolCallState.running;
          final callId = info['call_id']?.toString() ??
              info['id']?.toString() ??
              step['call_id']?.toString() ??
              'step-$stepIndex-$toolName';
          return AgyToolCallEvent(
            callId: callId,
            toolName: toolName,
            state: callState,
            parameters: _asMap(info['parameters']),
            output: info['output']?.toString(),
            errorMessage: errMsg,
            durationSeconds: (step['duration_seconds'] as num?)?.toDouble(),
            stepIndex: stepIndex,
          );
        }
        return null;

      case 'error':
        final errMap = _asMap(root['error']);
        final msg = errMap.isNotEmpty
            ? (errMap['message']?.toString() ?? root['error'].toString())
            : (root['error']?.toString() ??
                root['message']?.toString() ??
                'Agent error');
        return AgyErrorEvent(
          message: msg,
          code: (errMap['code'] as num?)?.toInt(),
          requiresAuth: msg.toLowerCase().contains('authentication required'),
        );

      case 'result':
        final result = _asMap(root['result']);
        final usageMap = _asMap(result['usage']);
        final status = result['status']?.toString() ?? 'SUCCESS';
        final rawErr = result['error'];
        final error = rawErr is Map
            ? _asMap(rawErr)['message']?.toString() ?? rawErr.toString()
            : rawErr?.toString();
        if (error != null &&
            error.toLowerCase().contains('authentication required')) {
          return AgyErrorEvent(message: error, requiresAuth: true);
        }
        return AgyTurnResultEvent(
          conversationId: result['conversation_id']?.toString() ?? '',
          status: status,
          response: result['response']?.toString() ?? '',
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
