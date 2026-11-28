import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/remote/openai_compat_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('OpenAiCompatRunner drives Dextop MCP gemini_web_prompt agentic loop', () async {
    final prevOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = prevOverrides);
    final tmpDir = await Directory.systemTemp.createTemp('dextop_gemini_test_');
    addTearDown(() => tmpDir.delete(recursive: true));

    final sampleFile = File('${tmpDir.path}/hello.txt');
    await sampleFile.writeAsString('status=draft\n');

    final capturedPrompts = <Map<String, dynamic>>[];
    var turnCount = 0;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));

    server.listen((req) async {
      expect(req.headers.value('authorization'), 'Bearer test-token-123');
      final body = await utf8.decodeStream(req);
      final rpc = jsonDecode(body) as Map<String, dynamic>;
      final method = rpc['method'] as String?;
      final id = rpc['id'];

      req.response.headers.set('Content-Type', 'application/json');
      req.response.headers.set('Mcp-Session-Id', 'sess-test-1');

      if (method == 'initialize') {
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': '2025-03-26',
            'serverInfo': {'name': 'dextop-browser', 'version': '1.0.18'},
          },
        }));
      } else if (method == 'tools/list') {
        req.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': [
              {'name': 'gemini_web_status'},
              {'name': 'gemini_web_prompt'},
            ],
          },
        }));
      } else if (method == 'tools/call') {
        final params = rpc['params'] as Map<String, dynamic>;
        final toolName = params['name'] as String;
        final args = (params['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
        if (toolName == 'gemini_web_status') {
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': false,
              'content': [
                {
                  'type': 'text',
                  'text': jsonEncode({'ok': true, 'composerReady': true}),
                },
              ],
            },
          }));
        } else if (toolName == 'gemini_web_prompt') {
          capturedPrompts.add(args);
          turnCount++;
          final replyText = turnCount == 1
              ? 'Checking file...\n<tool_call>{"name":"read_file","arguments":{"path":"hello.txt"}}</tool_call>'
              : 'Read confirmed: status is draft.';
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'isError': false,
              'content': [
                {
                  'type': 'text',
                  'text': jsonEncode({
                    'ok': true,
                    'replyText': replyText,
                    'streamingComplete': true,
                  }),
                },
              ],
            },
          }));
        }
      }
      await req.response.close();
    });

    final profile = OpenAiProviderConfig(
      id: 'dextop-gw',
      name: 'Dextop Gemini Web',
      baseUrl: 'http://127.0.0.1:${server.port}/mcp',
      modelId: 'gemini-web',
      transportKind: ProviderTransportKind.dextopMcpGeminiWeb,
    );

    final testMsg = await OpenAiCompatRunner.instance.testConnection(
      profile,
      apiKey: 'test-token-123',
    );
    expect(testMsg, contains('Gemini Web ready'));

    final events = await OpenAiCompatRunner.instance
        .runPrompt(
          profile: profile,
          apiKey: 'test-token-123',
          workspacePath: tmpDir.path,
          prompt: 'Check hello.txt',
          turnId: 'turn-gw-1',
          dangerouslySkipPermissions: true,
          toolExecutorOverride: (name, args) async {
            if (name == 'read_file') {
              final target = File('${tmpDir.path}/${args['path']}');
              return (ok: true, output: await target.readAsString());
            }
            return (ok: false, output: 'Unsupported $name');
          },
        )
        .toList();

    expect(turnCount, 2);
    expect(capturedPrompts[0]['newChat'], isTrue);
    expect(capturedPrompts[1]['newChat'], isFalse);
    expect(capturedPrompts[1]['prompt'].toString(), contains('status=draft'));

    final toolCompleted = events.whereType<AgyToolCallEvent>().where(
          (e) => e.toolName == 'read_file' && e.state == ToolCallState.completed,
        );
    expect(toolCompleted, isNotEmpty);

    final done = events.whereType<AgyTurnResultEvent>().single;
    expect(done.status, 'SUCCESS');
    expect(done.response, contains('Read confirmed: status is draft.'));
  });
}
