import '../models/chat_event.dart';
import '../models/execution_mode.dart';

/// Request parameters for executing a prompt turn on an Antigravity runtime.
class AgyPromptRequest {
  const AgyPromptRequest({
    required this.prompt,
    required this.workspacePath,
    this.extraDirs = const [],
    this.conversationId,
    this.modelId,
    this.effortCliValue,
    this.mode = AgyExecutionMode.auto,
    this.dangerouslySkipPermissions = false,
    this.allowNonWorkspaceAccess = true,
    this.geminiApiKey,
    this.agentName,
    this.printTimeoutSeconds,
    this.disableSlashCommands = false,
    this.continueLast = false,
    this.remoteAgent,
  });

  final String prompt;
  final String workspacePath;
  final List<String> extraDirs;
  final String? conversationId;
  final String? modelId;
  final String? effortCliValue;
  final AgyExecutionMode mode;
  final bool dangerouslySkipPermissions;
  final bool allowNonWorkspaceAccess;
  final String? geminiApiKey;
  final String? agentName;
  final int? printTimeoutSeconds;
  final bool disableSlashCommands;
  final bool continueLast;
  final String? remoteAgent;
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
