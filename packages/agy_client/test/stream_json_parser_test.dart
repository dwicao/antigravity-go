import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('StreamJsonParser', () {
    test('parses init, step_update tool/agent_response, and result events', () {
      final initEvt = StreamJsonParser.parseLine(
        '{"event":"init","conversation_id":"c-1","init":{"cwd":"/home/u","tools":["run_command","edit_file"],"permission_mode":"auto","model":"gemini-4-argon"}}',
      );
      expect(initEvt, isA<AgyInitEvent>());
      final init = initEvt! as AgyInitEvent;
      expect(init.conversationId, 'c-1');
      expect(init.tools, containsAll(['run_command', 'edit_file']));
      expect(init.model, 'gemini-4-argon');

      final deltaEvt = StreamJsonParser.parseLine(
        '{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":2,"state":"ACTIVE","step_type":"agent_response","text_delta":"Hello "}}',
      );
      expect(deltaEvt, isA<AgyTextDeltaEvent>());
      final delta = deltaEvt! as AgyTextDeltaEvent;
      expect(delta.delta, 'Hello ');
      expect(delta.isDone, isFalse);

      final toolEvt = StreamJsonParser.parseLine(
        '{"event":"step_update","step_update":{"conversation_id":"c-1","step_index":3,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.25,"tool_info":{"name":"run_command","parameters":{"CommandLine":"ls"},"output":"README.md"}}}',
      );
      expect(toolEvt, isA<AgyToolCallEvent>());
      final tool = toolEvt! as AgyToolCallEvent;
      expect(tool.toolName, 'run_command');
      expect(tool.state, ToolCallState.completed);
      expect(tool.output, 'README.md');

      final resEvt = StreamJsonParser.parseLine(
        '{"event":"result","result":{"conversation_id":"c-1","status":"SUCCESS","response":"Hello world","duration_seconds":1.5,"num_turns":1,"usage":{"input_tokens":100,"output_tokens":20,"thinking_tokens":10,"cache_read_tokens":50,"total_tokens":120}}}',
      );
      expect(resEvt, isA<AgyTurnResultEvent>());
      final res = resEvt! as AgyTurnResultEvent;
      expect(res.status, 'SUCCESS');
      expect(res.usage.totalTokens, 120);
      expect(res.usage.thinkingTokens, 10);
    });

    test('detects authentication required error', () {
      final errEvt = StreamJsonParser.parseLine(
        '{"event":"result","result":{"conversation_id":"","status":"ERROR","response":"","error":"Authentication required: please sign in"}}',
      );
      expect(errEvt, isA<AgyErrorEvent>());
      expect((errEvt! as AgyErrorEvent).requiresAuth, isTrue);
    });

    test('encodes user prompt line', () {
      final encoded = StreamJsonParser.encodeUserMessage('Run tests');
      expect(encoded, contains('"event":"user"'));
      expect(encoded, contains('"content":"Run tests"'));
    });
  });
}
