import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/phone/phone_bridge.dart';
import 'package:antigravity_go/remote/ssh_host.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ChatMessage.toJson redacts secrets in text, thoughts, and tool parameters before persistence', () {
    final msg = ChatMessage(
      id: 'm-secret',
      role: ChatRole.assistant,
      text: 'Using token ghp_1234567890abcdefghijklmnop and key sk-abcdef1234567890abcdef',
      thoughts: 'Bearer my_super_secret_token_value',
      createdAt: DateTime(2026, 11, 23, 19, 0),
      tools: const [
        ChatToolStep(
          id: 't1',
          toolName: 'run_command',
          state: ToolCallState.completed,
          parameters: {'CommandLine': 'curl -H "Authorization: Bearer super_secret_header_value" https://example.com'},
          output: 'Token: AIzaSyDummySecretValue1234567890abcdef',
        ),
      ],
    );

    final encoded = msg.toJson();
    expect(encoded['text'] as String, isNot(contains('1234567890abcdefghijklmnop')));
    expect(encoded['text'] as String, isNot(contains('abcdef1234567890abcdef')));
    expect(encoded['thoughts'] as String, isNot(contains('my_super_secret_token_value')));
    final toolsJson = encoded['tools'] as List<dynamic>;
    final toolMap = toolsJson.first as Map<String, dynamic>;
    final paramsMap = toolMap['parameters'] as Map<String, dynamic>;
    expect(paramsMap['CommandLine'] as String, isNot(contains('super_secret_header_value')));
    expect(toolMap['output'] as String, isNot(contains('DummySecretValue1234567890abcdef')));
  });

  test('ChatMessageStore save and load roundtrip works cleanly via fallback', () async {
    final msg = ChatMessage(
      id: 'm1',
      role: ChatRole.user,
      text: 'Hello world',
      createdAt: DateTime(2026, 11, 23, 19, 5),
    );
    await ChatMessageStore.instance.save('sess-store-1', [msg]);
    final loaded = await ChatMessageStore.instance.load('sess-store-1');
    expect(loaded, hasLength(1));
    expect(loaded.first.text, 'Hello world');
  });

  test('SshHostConfig.copyWith(clearFingerprint: true) resets pinned key cleanly', () {
    const host = SshHostConfig(
      id: 'h1',
      name: 'Workstation',
      hostname: '10.0.0.5',
      username: 'dev',
      hostKeyFingerprint: 'ssh-ed25519:aa:bb:cc',
    );
    final cleared = host.copyWith(clearFingerprint: true);
    expect(cleared.hostKeyFingerprint, isNull);
    expect(cleared.hostname, '10.0.0.5');
  });

  test('PhoneControlStatus parses mcpPort and mcpToken cleanly', () {
    final status = PhoneControlStatus.fromMap({
      'enabled': true,
      'accessibilityConnected': true,
      'safetyGateStrict': true,
      'mcpPort': 43210,
      'mcpToken': 'tok123',
    });
    expect(status.enabled, isTrue);
    expect(status.mcpPort, 43210);
    expect(status.mcpToken, 'tok123');
  });
}
