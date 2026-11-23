import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('OpenAiProviderConfig', () {
    test('normalizes varied /v1 base URLs accurately', () {
      expect(
        OpenAiProviderConfig.normalizeBaseUrl('https://api.openai.com/v1/'),
        'https://api.openai.com/v1',
      );
      expect(
        OpenAiProviderConfig.normalizeBaseUrl('http://127.0.0.1:11434'),
        'http://127.0.0.1:11434/v1',
      );
      expect(
        OpenAiProviderConfig.normalizeBaseUrl('https://openrouter.ai/api/v1'),
        'https://openrouter.ai/api/v1',
      );
      expect(
        OpenAiProviderConfig.normalizeBaseUrl('https://proxy.example.com/v1/chat/completions'),
        'https://proxy.example.com/v1',
      );
      final cfg = OpenAiProviderConfig(
        id: '1',
        name: 'Local',
        baseUrl: 'http://192.168.1.10:1234/v1',
        modelId: 'qwen2.5-coder:32b',
      );
      expect(
        cfg.chatCompletionsUri.toString(),
        'http://192.168.1.10:1234/v1/chat/completions',
      );
      expect(
        cfg.modelsUri.toString(),
        'http://192.168.1.10:1234/v1/models',
      );
    });
  });

  group('OpenAiSseParser', () {
    test('splits inline <think> tags cleanly across chunk boundaries', () {
      final parser = OpenAiSseParser();
      final s1 = parser.parseLine(
        'data: {"choices":[{"delta":{"content":"<thi"}}]}',
      );
      final s2 = parser.parseLine(
        'data: {"choices":[{"delta":{"content":"nk>plan steps</thi"}}]}',
      );
      final s3 = parser.parseLine(
        'data: {"choices":[{"delta":{"content":"nk>Final answer"}}]}',
      );
      expect(s1, isNull); // carried "<thi"
      expect(s2!.thoughtDelta, 'plan steps');
      expect(s2.textDelta, isEmpty);
      expect(s3!.textDelta, 'Final answer');
      expect(s3.thoughtDelta, isEmpty);
    });

    test('parses reasoning_content, incremental tool_calls, and token usage', () {
      final parser = OpenAiSseParser();
      final r1 = parser.parseLine(
        'data: {"choices":[{"delta":{"reasoning_content":"Checking file"}}]}',
      );
      expect(r1!.thoughtDelta, 'Checking file');

      parser.parseLine(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}',
      );
      final fin = parser.parseLine(
        'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"lib/main.dart\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":150,"completion_tokens":40,"total_tokens":190,"prompt_tokens_details":{"cached_tokens":50}}}',
      );

      expect(fin!.finishReason, 'tool_calls');
      expect(fin.usage?.inputTokens, 150);
      expect(fin.usage?.outputTokens, 40);
      expect(fin.usage?.cacheReadTokens, 50);
      expect(parser.orderedToolCalls, hasLength(1));
      expect(parser.orderedToolCalls.first.name, 'read_file');
      expect(
        parser.orderedToolCalls.first.parseArgumentsMap()['path'],
        'lib/main.dart',
      );
    });
  });
}
