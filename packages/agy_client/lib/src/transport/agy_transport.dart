import '../models/chat_event.dart';
import '../models/execution_mode.dart';

/// Request parameters for executing a prompt turn on an Antigravity runtime.
class AgyPromptRequest {
  const AgyPromptRequest({
    required this.prompt,
    required this.workspacePath,
    this.conversationId,
    this.modelId,
    this.effortCliValue,
    this.mode = AgyExecutionMode.auto,
    this.dangerouslySkipPermissions = false,
    this.geminiApiKey,
  });

  final String prompt;
  final String workspacePath;
  final String? conversationId;
  final String? modelId;
  final String? effortCliValue;
  final AgyExecutionMode mode;
  final bool dangerouslySkipPermissions;
  final String? geminiApiKey;
}

/// Abstract transport implemented by both on-device Android `agy` and remote SSH `agy`.
abstract class AgyTransport {
  Stream<AgyChatEvent> runPrompt(AgyPromptRequest request);

  Future<void> cancelCurrentTurn();

  Future<void> respondToPermission({
    required Object requestId,
    required String optionId,
  });
}
