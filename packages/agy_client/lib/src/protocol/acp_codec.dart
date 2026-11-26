import 'dart:convert';

import '../models/chat_event.dart';
import '../models/unified_line_diff.dart';
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

  String encodeResumeSession({
    required int id,
    required String sessionId,
    required String cwd,
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/resume',
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
    List<Map<String, dynamic>> imageBlocks = const [],
  }) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'session/prompt',
      'params': {
        'sessionId': sessionId,
        'prompt': [
          {'type': 'text', 'text': text},
          ...imageBlocks,
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

  String encodePermissionCancelled({required Object requestId}) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': requestId,
      'result': {
        'outcome': {'outcome': 'cancelled'},
      },
    });
  }

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), v));
    }
    if (value is String) {
      final t = value.trim();
      if (t.startsWith('{')) {
        try {
          final decoded = jsonDecode(t);
          if (decoded is Map) {
            return decoded.map((k, v) => MapEntry(k.toString(), v));
          }
        } catch (_) {}
      }
    }
    return const {};
  }

  static List<dynamic> _asList(Object? value) {
    return value is List<dynamic> ? value : const [];
  }

  static String _extractContentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      final buf = StringBuffer();
      for (final item in content) {
        final m = _asMap(item);
        final txt = m['text']?.toString();
        if (txt != null && txt.isNotEmpty) buf.write(txt);
      }
      return buf.toString();
    }
    final m = _asMap(content);
    return m['text']?.toString() ?? '';
  }

  static ({String? output, String? diffPreview}) _extractToolContent(
    Object? rawContent,
  ) {
    final items = _asList(rawContent);
    if (items.isEmpty) return (output: null, diffPreview: null);
    final outParts = <String>[];
    final diffParts = <String>[];
    for (final item in items) {
      final m = _asMap(item);
      final type = m['type']?.toString() ?? '';
      if (type == 'diff') {
        final path = m['path']?.toString() ?? '';
        final oldText = m['oldText']?.toString() ?? '';
        final newText = m['newText']?.toString() ?? '';
        final computed = UnifiedLineDiff.compute(
          path: path,
          oldText: oldText,
          newText: newText,
        );
        if (computed.diff.isNotEmpty) {
          diffParts.add(computed.diff);
        }
      } else if (type == 'content') {
        final txt = _extractContentText(m['content']);
        if (txt.isNotEmpty) outParts.add(txt);
      } else if (type == 'terminal') {
        final termId = m['terminalId']?.toString() ?? '';
        if (termId.isNotEmpty) outParts.add('[terminal: $termId]');
      } else {
        final txt = m['text']?.toString() ?? _extractContentText(m['content']);
        if (txt.isNotEmpty) outParts.add(txt);
      }
    }
    return (
      output: outParts.isNotEmpty ? outParts.join('\n') : null,
      diffPreview: diffParts.isNotEmpty ? diffParts.join('\n\n') : null,
    );
  }

  static String? _formatCommandOrPath(
    Object? rawInput,
    Object? locations,
  ) {
    if (rawInput is String && rawInput.trim().isNotEmpty) {
      return rawInput.trim();
    }
    final map = _asMap(rawInput);
    if (map.isNotEmpty) {
      final direct = map['CommandLine'] ??
          map['command'] ??
          map['cmd'] ??
          map['TargetFile'] ??
          map['AbsolutePath'] ??
          map['path'] ??
          map['file_path'] ??
          map['filePath'];
      if (direct != null && direct.toString().trim().isNotEmpty) {
        return direct.toString().trim();
      }
      return const JsonEncoder.withIndent('  ').convert(map);
    }
    final locs = _asList(locations);
    if (locs.isNotEmpty) {
      final first = _asMap(locs.first);
      final p = first['path']?.toString();
      if (p != null && p.isNotEmpty) {
        final line = first['line'];
        return line != null ? '$p:$line' : p;
      }
    }
    return null;
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
    if (decoded is! Map) return null;
    final root = _asMap(decoded);

    final error = _asMap(root['error']);
    if (error.isNotEmpty) {
      final code = (error['code'] as num?)?.toInt();
      final msg = error['message']?.toString() ?? 'Unknown ACP error';
      return AgyErrorEvent(
        message: msg,
        code: code,
        requiresAuth: code == -32000 ||
            msg.toLowerCase().contains('authentication required'),
      );
    }

    final method = root['method']?.toString();
    final params = _asMap(root['params']);

    if (method == 'session/update') {
      final update = _asMap(params['update']);
      final kind = update['sessionUpdate']?.toString() ?? '';
      TokenUsage? parseUpdateUsage() {
        final meta = _asMap(update['_meta']);
        final rawUsage = _asMap(
          update['usage'] ??
              update['tokenUsage'] ??
              meta['usage'] ??
              params['usage'],
        );
        if (rawUsage.isEmpty) return null;
        final parsed = TokenUsage.fromJson(rawUsage);
        final ctx = parsed.contextTokens > 0
            ? parsed.contextTokens
            : (parsed.inputTokens +
                parsed.cacheReadTokens +
                parsed.outputTokens);
        if (ctx <= 0) return null;
        return parsed.copyWith(contextTokens: ctx);
      }

      switch (kind) {
        case 'agent_message_chunk':
          return AgyTextDeltaEvent(
            delta: _extractContentText(update['content']),
            stepUsage: parseUpdateUsage(),
          );
        case 'agent_thought_chunk':
          return AgyThoughtDeltaEvent(
            delta: _extractContentText(update['content']),
            stepUsage: parseUpdateUsage(),
          );
        case 'tool_call':
        case 'tool_call_update':
          final rawOut = update['rawOutput'];
          final extracted = _extractToolContent(update['content']);
          final errMap = _asMap(update['error']);
          final status = update['status']?.toString();
          final errMsg = errMap['message']?.toString() ??
              (update['error'] is String ? update['error'] as String : null) ??
              (_mapToolStatus(status) == ToolCallState.failed
                  ? (rawOut?.toString() ?? extracted.output)
                  : null);
          final baseOut = rawOut is String
              ? rawOut
              : (rawOut != null ? jsonEncode(rawOut) : extracted.output);
          final outStr = (extracted.diffPreview != null &&
                  extracted.diffPreview!.trim().isNotEmpty)
              ? [
                  if (baseOut != null &&
                      baseOut.trim().isNotEmpty &&
                      !baseOut.contains('@@ '))
                    baseOut.trim(),
                  extracted.diffPreview!,
                ].join('\n\n')
              : baseOut;
          final rawParams = _asMap(update['rawInput']);
          final locs = _asList(update['locations']);
          final locPath = locs.isNotEmpty
              ? _asMap(locs.first)['path']?.toString() ?? ''
              : '';
          final hasExplicitPath = rawParams.containsKey('TargetFile') ||
              rawParams.containsKey('AbsolutePath') ||
              rawParams.containsKey('Path') ||
              rawParams.containsKey('path') ||
              rawParams.containsKey('file_path') ||
              rawParams.containsKey('DirectoryPath');
          final paramsWithLoc = !hasExplicitPath && locPath.isNotEmpty
              ? <String, dynamic>{...rawParams, 'path': locPath}
              : rawParams;
          return AgyToolCallEvent(
            callId: update['toolCallId']?.toString() ?? '',
            toolName: update['title']?.toString() ??
                update['kind']?.toString() ??
                'tool',
            state: _mapToolStatus(status),
            parameters: paramsWithLoc,
            output: outStr,
            errorMessage: errMsg,
          );
        default:
          return null;
      }
    }

    if (method == 'session/request_permission') {
      final id = root['id'];
      if (id == null) return null;
      final toolCall = _asMap(params['toolCall']);
      final rawOptions = _asList(params['options']);
      final extracted = _extractToolContent(toolCall['content']);
      return AgyPermissionRequestEvent(
        requestId: id,
        toolName: toolCall['kind']?.toString() ?? 'tool',
        title: toolCall['title']?.toString() ?? 'Approve tool action',
        commandOrPath: _formatCommandOrPath(
          toolCall['rawInput'],
          toolCall['locations'],
        ),
        diffPreview: extracted.diffPreview,
        options: rawOptions
            .map(_asMap)
            .where((o) => o.isNotEmpty)
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

    final result = _asMap(root['result']);
    if (result.isNotEmpty) {
      if (result.containsKey('sessionId') && !result.containsKey('stopReason')) {
        return AgyInitEvent(
          conversationId: result['sessionId']?.toString() ?? '',
          cwd: result['cwd']?.toString() ?? '',
        );
      }
      if (result.containsKey('stopReason')) {
        final meta = _asMap(result['_meta']);
        final usageMap = _asMap(
          result['usage'] ?? result['tokenUsage'] ?? meta['usage'],
        );
        final durationSec = (result['durationSeconds'] as num?)?.toDouble() ??
            (result['duration_seconds'] as num?)?.toDouble() ??
            (meta['durationSeconds'] as num?)?.toDouble() ??
            (((result['durationMs'] as num?)?.toDouble() ?? 0) / 1000.0);
        final stopReason = result['stopReason']?.toString() ?? '';
        final status = switch (stopReason) {
          'cancelled' || 'canceled' => 'CANCELED',
          'refusal' || 'error' => 'ERROR',
          _ => 'SUCCESS',
        };
        final numTurns = (result['numTurns'] as num?)?.toInt() ??
            (result['num_turns'] as num?)?.toInt() ??
            (meta['numTurns'] as num?)?.toInt() ??
            1;
        return AgyTurnResultEvent(
          conversationId: result['sessionId']?.toString() ?? '',
          status: status,
          response: '',
          durationSeconds: durationSec,
          numTurns: numTurns,
          usage: TokenUsage.fromJson(usageMap),
          error: status == 'ERROR' ? 'Turn stopped: $stopReason' : null,
        );
      }
    }

    return null;
  }

  static ToolCallState _mapToolStatus(String? status) {
    return switch (status?.toLowerCase().trim()) {
      'completed' || 'done' => ToolCallState.completed,
      'failed' || 'error' || 'cancelled' || 'canceled' || 'rejected' =>
        ToolCallState.failed,
      'in_progress' || 'running' => ToolCallState.running,
      _ => ToolCallState.pending,
    };
  }
}
