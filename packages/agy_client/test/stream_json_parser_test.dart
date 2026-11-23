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

    test('parses standalone error, canceled tool_info call_id, glog lines, and quoted diffs', () {
      final err = StreamJsonParser.parseLine(
        '{"event":"error","error":{"message":"Quota exceeded"}}',
      );
      expect(err, isA<AgyErrorEvent>());
      expect((err! as AgyErrorEvent).message, 'Quota exceeded');

      final canceled = StreamJsonParser.parseLine(
        '{"event":"step_update","step_update":{"state":"CANCELED","step_type":"tool","tool_info":{"call_id":"call-42","name":"run_command","error":{"message":"Aborted"}}}}',
      );
      expect(canceled, isA<AgyToolCallEvent>());
      final tc = canceled! as AgyToolCallEvent;
      expect(tc.callId, 'call-42');
      expect(tc.state, ToolCallState.failed);
      expect(tc.errorMessage, 'Aborted');

      final report = UsageOutputParser.parseUsageText(
        'I0315 10:20:30.123456 12345 main.cc:1] log noise 50% remaining\nGemini 4 Argon\t90.0% left\tResets in 4h',
      );
      expect(report.overallFiveHourRemainingPct, 90.0);

      final attached = FileChangeEntry.attachUnifiedDiffs(
        [const FileChangeEntry(path: 'dir/with b/file name.dart', added: 1)],
        'diff --git "a/dir/with b/file name.dart" "b/dir/with b/file name.dart"\n--- "a/dir/with b/file name.dart"\n+++ "b/dir/with b/file name.dart"\n@@ -1 +1 @@\n+hello\n',
      );
      expect(attached.first.diff, contains('+hello'));
    });
  });
}
