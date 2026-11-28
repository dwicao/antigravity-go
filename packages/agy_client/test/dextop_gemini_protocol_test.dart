import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAiProviderConfig Dextop transport', () {
    test('normalizes /mcp URL and round-trips transportKind', () {
      const bare = OpenAiProviderConfig(
        id: 'd1',
        name: 'Dextop Gemini Web',
        baseUrl: 'http://127.0.0.1:38901',
        modelId: 'gemini-web',
        transportKind: ProviderTransportKind.dextopMcpGeminiWeb,
      );
      expect(bare.isDextopGeminiWeb, isTrue);
      expect(bare.isLocalEndpoint, isTrue);
      expect(bare.mcpEndpointUri.toString(), 'http://127.0.0.1:38901/mcp');

      final roundtrip = OpenAiProviderConfig.fromJson(bare.toJson());
      expect(roundtrip.transportKind, ProviderTransportKind.dextopMcpGeminiWeb);
      expect(roundtrip.mcpEndpointUri.toString(), 'http://127.0.0.1:38901/mcp');
    });
  });

  group('DextopGeminiProtocol', () {
    test('parses <tool_call> and ```mcp_call``` blocks while keeping prose', () {
      const reply = '''
I will check the target file first.
<tool_call>{"name":"read_file","arguments":{"path":"lib/main.dart","start_line":1,"limit":40}}</tool_call>

And list tests:
```mcp_call
{"tool":"list_dir","arguments":{"path":"test"}}
```
Done scanning plan.
''';
      final parsed = DextopGeminiProtocol.parseToolCalls(reply);
      expect(parsed.calls.length, 2);
      expect(parsed.calls[0].name, 'read_file');
      expect(parsed.calls[0].arguments['path'], 'lib/main.dart');
      expect(parsed.calls[1].name, 'list_dir');
      expect(parsed.visibleText, contains('I will check the target file first.'));
      expect(parsed.visibleText, contains('Done scanning plan.'));
      expect(parsed.visibleText, isNot(contains('<tool_call>')));
    });

    test('extracts nested replyText from Dextop MCP tools/call result', () {
      final rpc = {
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'isError': false,
          'content': [
            {
              'type': 'text',
              'text':
                  '{"ok":true,"replyText":"Hello from Gemini Web","streamingComplete":true,"elapsedMs":1420}',
            },
          ],
        },
      };
      final parsed = DextopGeminiProtocol.parseDextopGeminiResponse(rpc);
      expect(parsed.ok, isTrue);
      expect(parsed.replyText, 'Hello from Gemini Web');
      expect(parsed.streamingComplete, isTrue);
    });
  });
}
