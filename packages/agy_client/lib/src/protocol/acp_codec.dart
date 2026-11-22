import 'dart:convert';

import '../models/chat_event.dart';
import '../models/usage_quota.dart';

/// JSON-RPC 2.0 codec for Antigravity CLI's Agent Client Protocol (`agy acp`).
class AcpCodec {
  int _nextId = 1;

  int nextRequestId() => _nextId++;

  String encodeInitialize({
    required int id,
    String clientName = 'antigravity-go',
    String clientVersion = '1.0.0',
    bool terminalAuth = true,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': 1,
        'clientInfo': {
          'name': clientName,
          'version': clientVersion,
        },
        'clientCapabilities': {
          'fs': {'readTextFile': true, 'writeTextFile': true},
          'terminal': true,
          if (terminalAuth) 'terminal-auth': true,
        },
      },
    });
  }

  String encodeAuthenticate({
    required int id,
    required String methodId,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'authenticate',
      'params': {'methodId': methodId},
    });
  }

  String encodeNewSession({
    required int id,
    required String cwd,
    List<Map<String, dynamic>> mcpServers = const [],
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/new',
      'params': {
        'cwd': cwd,
        'mcpServers': mcpServers,
      },
    });
  }

  String encodeLoadSession({
    required int id,
    required String sessionId,
    required String cwd,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/load',
      'params': {
        'sessionId': sessionId,
        'cwd': cwd,
      },
    });
  }

  String encodePrompt({
    required int id,
    required String sessionId,
    required String text,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/prompt',
      'params': {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
        ],
      },
    });
  }

  String encodeCancel({required String sessionId}) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'method': 'session/cancel',
      'params': {'sessionId': sessionId},
    });
  }

  String encodeSetSessionOption({
    required int id,
    required String sessionId,
    required String optionId,
    required String value,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/set_config_option',
      'params': {
        'sessionId': sessionId,
        'configId': optionId,
        'value': value,
      },
    });
  }

  String encodePermissionResponse({
    required Object requestId,
    required String optionId,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': requestId,
      'result': {
        'outcome': {
          'outcome': 'selected',
          'optionId': optionId,
        },
      },
    });
  }

  /// Parses an incoming JSON-RPC message line from `agy acp`.
  AgyChatEvent? parseNotificationOrRequest(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) return null;

    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final error = decoded['error'] as Map<String, dynamic>?;
    if (error != null) {
      final code = (error['code'] as num?)?.toInt();
      final msg = error['message']?.toString() ?? 'Unknown ACP error';
      return AgyErrorEvent(
        message: msg,
        code: code,
        requiresAuth: code == -32000 ||
            msg.toLowerCase().contains('authentication required'),
      );
    }

    final method = decoded['method'] as String?;
    final params = decoded['params'] as Map<String, dynamic>? ?? const {};

    if (method == 'session/update') {
      final update = params['update'] as Map<String, dynamic>? ?? const {};
      final kind = update['sessionUpdate'] as String? ?? '';
      switch (kind) {
        case 'agent_message_chunk':
          final content = update['content'] as Map<String, dynamic>? ?? const {};
          final text = content['text'] as String? ?? '';
          return AgyTextDeltaEvent(delta: text);
        case 'agent_thought_chunk':
          final content = update['content'] as Map<String, dynamic>? ?? const {};
          final text = content['text'] as String? ?? '';
          return AgyThoughtDeltaEvent(delta: text);
        case 'tool_call':
          return AgyToolCallEvent(
            callId: update['toolCallId']?.toString() ?? '',
            toolName: update['title']?.toString() ??
                update['kind']?.toString() ??
                'tool',
            state: _mapToolStatus(update['status'] as String?),
            parameters: update['rawInput'] is Map<String, dynamic>
                ? update['rawInput'] as Map<String, dynamic>
                : const {},
          );
        case 'tool_call_update':
          return AgyToolCallEvent(
            callId: update['toolCallId']?.toString() ?? '',
            toolName: update['title']?.toString() ?? 'tool',
            state: _mapToolStatus(update['status'] as String?),
            output: update['rawOutput']?.toString(),
          );
        default:
          return null;
      }
    }

    if (method == 'session/request_permission') {
      final id = decoded['id'];
      if (id == null) return null;
      final toolCall = params['toolCall'] as Map<String, dynamic>? ?? const {};
      final rawOptions = params['options'] as List<dynamic>? ?? const [];
      return AgyPermissionRequestEvent(
        requestId: id,
        toolName: toolCall['kind']?.toString() ?? 'tool',
        title: toolCall['title']?.toString() ?? 'Approve tool action',
        commandOrPath: toolCall['rawInput']?.toString(),
        options: rawOptions
            .whereType<Map<String, dynamic>>()
            .map(
              (o) => PermissionOption(
                optionId: o['optionId']?.toString() ?? '',
                name: o['name']?.toString() ?? 'Allow',
                kind: o['kind']?.toString() ?? 'allow_once',
              ),
            )
            .toList(),
      );
    }

    final result = decoded['result'] as Map<String, dynamic>?;
    if (result != null) {
      if (result.containsKey('sessionId') && !result.containsKey('stopReason')) {
        return AgyInitEvent(
          conversationId: result['sessionId']?.toString() ?? '',
          cwd: '',
        );
      }
      if (result.containsKey('stopReason')) {
        final usageMap = result['usage'] as Map<String, dynamic>? ?? const {};
        return AgyTurnResultEvent(
          conversationId: result['sessionId']?.toString() ?? '',
          status: result['stopReason']?.toString() == 'cancelled'
              ? 'CANCELED'
              : 'SUCCESS',
          response: '',
          usage: TokenUsage.fromJson(usageMap),
        );
      }
    }

    return null;
  }

  static ToolCallState _mapToolStatus(String? status) {
    return switch (status) {
      'completed' => ToolCallState.completed,
      'failed' => ToolCallState.failed,
      'in_progress' => ToolCallState.running,
      _ => ToolCallState.pending,
    };
  }
}
