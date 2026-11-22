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
  });
}
