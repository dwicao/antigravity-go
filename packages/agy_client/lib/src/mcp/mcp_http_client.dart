import 'dart:convert';
import 'dart:io';

/// Tool descriptor returned by an MCP server's `tools/list`.
class McpToolDescriptor {
  const McpToolDescriptor({
    required this.name,
    this.description = '',
    this.inputSchema = const {},
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  factory McpToolDescriptor.fromJson(Map<String, dynamic> json) {
    return McpToolDescriptor(
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      inputSchema: (json['inputSchema'] as Map?)?.cast<String, dynamic>() ??
          const {},
    );
  }
}

/// Result of probing or invoking an HTTP/SSE MCP server.
class McpProbeResult {
  const McpProbeResult({
    required this.ok,
    this.serverName,
    this.serverVersion,
    this.protocolVersion,
    this.sessionId,
    this.tools = const [],
    this.error,
  });

  final bool ok;
  final String? serverName;
  final String? serverVersion;
  final String? protocolVersion;
  final String? sessionId;
  final List<McpToolDescriptor> tools;
  final String? error;
}

/// Lightweight Streamable HTTP & SSE JSON-RPC 2.0 MCP client.
class McpHttpClient {
  McpHttpClient({HttpClient? httpClient})
      : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  int _nextId = 1;

  /// Parses `text/event-stream` SSE payloads and extracts JSON-RPC response maps.
  static List<Map<String, dynamic>> parseSseBody(String body) {
    final results = <Map<String, dynamic>>[];
    final dataLines = <String>[];

    void flushEvent() {
      if (dataLines.isEmpty) return;
      final joined = dataLines.join('\n').trim();
      dataLines.clear();
      if (joined.isEmpty || joined == '[DONE]') return;
      try {
        final decoded = jsonDecode(joined);
        if (decoded is Map<String, dynamic>) {
          results.add(decoded);
        } else if (decoded is Map) {
          results.add(decoded.cast<String, dynamic>());
        }
      } catch (_) {}
    }

    for (final rawLine in body.replaceAll('\r\n', '\n').split('\n')) {
      if (rawLine.trim().isEmpty) {
        flushEvent();
        continue;
      }
      if (rawLine.startsWith('data:')) {
        dataLines.add(rawLine.substring(5).trimLeft());
      }
    }
    flushEvent();
    return results;
  }

  Future<({Map<String, dynamic> json, String? sessionId})> sendRpc(
    Uri url, {
    required String method,
    Map<String, dynamic> params = const {},
    Map<String, String> headers = const {},
    String? sessionId,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final req = await _httpClient.postUrl(url).timeout(timeout);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/event-stream',
    );
    if (sessionId != null && sessionId.isNotEmpty) {
      req.headers.set('Mcp-Session-Id', sessionId);
    }
    headers.forEach((k, v) {
      if (k.trim().isNotEmpty) req.headers.set(k.trim(), v);
    });

    final id = _nextId++;
    req.write(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );

    final resp = await req.close().timeout(timeout);
    final respBody = await resp.transform(utf8.decoder).join().timeout(timeout);
    final respSessionId = resp.headers.value('mcp-session-id') ?? sessionId;

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException(
        'MCP HTTP ${resp.statusCode}: ${respBody.trim()}',
        uri: url,
      );
    }

    final ctype = resp.headers.contentType?.mimeType.toLowerCase() ?? '';
    if (ctype.contains('text/event-stream') || respBody.trimLeft().startsWith('event:') || respBody.trimLeft().startsWith('data:')) {
      final events = parseSseBody(respBody);
      for (final evt in events) {
        if (evt['id'] == id || evt.containsKey('result') || evt.containsKey('error')) {
          return (json: evt, sessionId: respSessionId);
        }
      }
      if (events.isNotEmpty) {
        return (json: events.last, sessionId: respSessionId);
      }
      throw FormatException('Empty SSE response from MCP server');
    }

    final decoded = jsonDecode(respBody);
    if (decoded is Map<String, dynamic>) {
      return (json: decoded, sessionId: respSessionId);
    }
    if (decoded is Map) {
      return (json: decoded.cast<String, dynamic>(), sessionId: respSessionId);
    }
    throw FormatException('Unexpected non-object JSON from MCP server');
  }

  /// Performs `initialize` + `tools/list` against an HTTP/SSE MCP endpoint.
  Future<McpProbeResult> probeServer(
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    try {
      final initResp = await sendRpc(
        url,
        method: 'initialize',
        params: {
          'protocolVersion': '2025-03-26',
          'capabilities': <String, dynamic>{},
          'clientInfo': {
            'name': 'antigravity-go',
            'version': '1.0.34',
          },
        },
        headers: headers,
      );
      if (initResp.json['error'] != null) {
        return McpProbeResult(
          ok: false,
          error: initResp.json['error'].toString(),
        );
      }
      final initResult =
          (initResp.json['result'] as Map?)?.cast<String, dynamic>() ??
              const {};
      final serverInfo =
          (initResult['serverInfo'] as Map?)?.cast<String, dynamic>() ??
              const {};
      final toolsResp = await sendRpc(
        url,
        method: 'tools/list',
        headers: headers,
        sessionId: initResp.sessionId,
      );
      final toolsResult =
          (toolsResp.json['result'] as Map?)?.cast<String, dynamic>() ??
              const {};
      final rawTools = toolsResult['tools'] as List? ?? const [];
      final tools = rawTools
          .whereType<Map>()
          .map((m) => McpToolDescriptor.fromJson(m.cast<String, dynamic>()))
          .where((t) => t.name.isNotEmpty)
          .toList();

      return McpProbeResult(
        ok: true,
        serverName: serverInfo['name']?.toString(),
        serverVersion: serverInfo['version']?.toString(),
        protocolVersion: initResult['protocolVersion']?.toString(),
        sessionId: initResp.sessionId,
        tools: tools,
      );
    } catch (e) {
      return McpProbeResult(ok: false, error: e.toString());
    }
  }

  Future<Map<String, dynamic>> callTool(
    Uri url, {
    required String name,
    Map<String, dynamic> arguments = const {},
    Map<String, String> headers = const {},
    String? sessionId,
  }) async {
    final res = await sendRpc(
      url,
      method: 'tools/call',
      params: {
        'name': name,
        'arguments': arguments,
      },
      headers: headers,
      sessionId: sessionId,
    );
    return res.json;
  }

  void close() => _httpClient.close(force: true);
}
