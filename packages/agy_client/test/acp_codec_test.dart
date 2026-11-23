import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('AcpCodec', () {
    test('parses session/update chunks and tool calls', () {
      final codec = AcpCodec();

      final msg = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Working..."}}}}',
      );
      expect(msg, isA<AgyTextDeltaEvent>());
      expect((msg! as AgyTextDeltaEvent).delta, 'Working...');

      final thought = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Checking files"}}}}',
      );
      expect(thought, isA<AgyThoughtDeltaEvent>());
      expect((thought! as AgyThoughtDeltaEvent).delta, 'Checking files');

      final perm = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"toolCall":{"kind":"execute","title":"Run flutter test","rawInput":"flutter test"},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"reject_once","name":"Deny","kind":"reject_once"}]}}',
      );
      expect(perm, isA<AgyPermissionRequestEvent>());
      final p = perm! as AgyPermissionRequestEvent;
      expect(p.requestId, 42);
      expect(p.options, hasLength(2));
    });

    test('parses auth required error code -32000', () {
      final codec = AcpCodec();
      final err = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}',
      );
      expect(err, isA<AgyErrorEvent>());
      expect((err! as AgyErrorEvent).requiresAuth, isTrue);
    });

    test('parses session/new and session/prompt stopReason results', () {
      final codec = AcpCodec();
      final init = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"sess-99"}}',
      );
      expect(init, isA<AgyInitEvent>());
      expect((init! as AgyInitEvent).conversationId, 'sess-99');

      final res = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":3,"result":{"sessionId":"sess-99","stopReason":"end_turn","durationMs":2400,"numTurns":4,"usage":{"inputTokens":200,"outputTokens":145,"totalTokens":345}}}',
      );
      expect(res, isA<AgyTurnResultEvent>());
      final turn = res! as AgyTurnResultEvent;
      expect(turn.status, 'SUCCESS');
      expect(turn.durationSeconds, 2.4);
      expect(turn.numTurns, 4);
      expect(turn.usage.inputTokens, 200);
      expect(turn.usage.outputTokens, 145);
      expect(turn.usage.totalTokens, 345);
    });

    test('parses stepUsage on session/update chunks for accurate context occupancy', () {
      final codec = AcpCodec();
      final chunk = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"},"usage":{"inputTokens":12000,"cacheReadTokens":30000,"outputTokens":250}}}}',
      );
      expect(chunk, isA<AgyTextDeltaEvent>());
      final textEvt = chunk! as AgyTextDeltaEvent;
      expect(textEvt.stepUsage?.contextTokens, 42250);
    });

    test('androidSafe maps OS-sandbox-only auto mode/preset to mobile-safe defaults', () {
      expect(AgyExecutionMode.auto.androidSafe, AgyExecutionMode.standard);
      expect(AgyExecutionMode.plan.androidSafe, AgyExecutionMode.plan);
      expect(
        AntigravityPermissionPreset.auto.androidSafe,
        AntigravityPermissionPreset.turbo,
      );
      expect(
        AntigravityPermissionPreset.requestReview.androidSafe,
        AntigravityPermissionPreset.requestReview,
      );
    });

    test('parses rich tool_call, permission diffPreview, cancellation, and max effort', () {
      final codec = AcpCodec();
      final toolUpdate = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-9","title":"Edit file","status":"cancelled","rawInput":"{\\"path\\":\\"lib/a.dart\\"}","locations":[{"path":"lib/a.dart","line":10}],"content":[{"type":"diff","path":"lib/a.dart","oldText":"old","newText":"new"}]}}}',
      );
      expect(toolUpdate, isA<AgyToolCallEvent>());
      final tc = toolUpdate! as AgyToolCallEvent;
      expect(tc.callId, 'tc-9');
      expect(tc.state, ToolCallState.failed);
      expect(tc.parameters['path'], 'lib/a.dart');
      expect(tc.output, contains('-old'));
      expect(tc.output, contains('+new'));

      final perm = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"toolCall":{"kind":"edit","title":"Write file","rawInput":{"CommandLine":"rm -rf tmp"},"content":[{"type":"diff","path":"a.txt","oldText":"a","newText":"b"}]},"options":[]}}',
      );
      expect(perm, isA<AgyPermissionRequestEvent>());
      final permEvt = perm! as AgyPermissionRequestEvent;
      expect(permEvt.commandOrPath, 'rm -rf tmp');
      expect(permEvt.diffPreview, contains('+b'));

      final cancelled = codec.encodePermissionCancelled(requestId: 7);
      expect(cancelled, contains('"outcome":"cancelled"'));

      final refusal = codec.parseNotificationOrRequest(
        '{"jsonrpc":"2.0","id":8,"result":{"stopReason":"refusal"}}',
      );
      expect((refusal! as AgyTurnResultEvent).status, 'ERROR');
      expect(ReasoningEffort.fromString('max'), ReasoningEffort.max);
    });
  });
}
