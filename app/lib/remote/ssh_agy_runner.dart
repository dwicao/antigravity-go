import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:dartssh2/dartssh2.dart';

import 'ssh_host.dart';

/// Executes Antigravity CLI (`agy`) remotely over SSH on a user's workstation or server.
class SshAgyRunner {
  SshAgyRunner._();
  static final SshAgyRunner instance = SshAgyRunner._();

  SSHSession? _activeSession;

  Future<SSHClient> connect(
    SshHostConfig host, {
    String? password,
    String? privateKeyPem,
  }) async {
    final socket = await SSHSocket.connect(
      host.hostname,
      host.port,
      timeout: const Duration(seconds: 12),
    );
    return SSHClient(
      socket,
      username: host.username,
      identities: privateKeyPem != null && privateKeyPem.trim().isNotEmpty
          ? SSHKeyPair.fromPem(privateKeyPem)
          : null,
      onPasswordRequest: password != null ? () => password : null,
    );
  }

  Future<String> testConnection(
    SshHostConfig host, {
    String? password,
    String? privateKeyPem,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    try {
      final agy = _shellQuote(host.agyBinary);
      final out = await client.run('$agy --version || which agy || echo connected');
      return utf8.decode(out, allowMalformed: true).trim();
    } finally {
      client.close();
    }
  }

  Stream<AgyChatEvent> runPrompt({
    required SshHostConfig host,
    required AgyPromptRequest request,
    String? password,
    String? privateKeyPem,
  }) async* {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
    );

    try {
      final cwd = request.workspacePath.isEmpty
          ? host.defaultWorkspace
          : request.workspacePath;
      final args = <String>[
        _shellQuote(host.agyBinary),
        '-p',
        _shellQuote(request.prompt),
        '--output-format',
        'stream-json',
        '--mode',
        _shellQuote(request.mode.cliValue),
        if (request.modelId != null && request.modelId!.isNotEmpty) ...[
          '--model',
          _shellQuote(request.modelId!),
        ],
        if (request.effortCliValue != null &&
            request.effortCliValue!.isNotEmpty &&
            !(request.modelId?.toLowerCase().contains('orchestrator') ?? false)) ...[
          '--effort',
          _shellQuote(request.effortCliValue!),
        ],
        if (request.conversationId != null &&
            request.conversationId!.isNotEmpty) ...[
          '--conversation',
          _shellQuote(request.conversationId!),
        ],
        if (request.agentName != null && request.agentName!.isNotEmpty) ...[
          '--agent',
          _shellQuote(request.agentName!),
        ],
        if (request.printTimeoutSeconds != null &&
            request.printTimeoutSeconds! > 0) ...[
          '--print-timeout',
          request.printTimeoutSeconds!.toString(),
        ],
        if (request.disableSlashCommands) '--disable-slash-commands',
        if (request.continueLast) '--continue',
        if (request.remoteAgent != null &&
            request.remoteAgent!.isNotEmpty) ...[
          '--remote-agent',
          _shellQuote(request.remoteAgent!),
        ],
        if (request.dangerouslySkipPermissions)
          '--dangerously-skip-permissions',
      ];

      final cmd = 'cd ${_shellQuote(cwd)} && ${args.join(' ')}';
      final session = await client.execute(cmd);
      _activeSession = session;

      final stdoutLines = session.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stdoutLines) {
        final evt = StreamJsonParser.parseLine(line);
        if (evt != null) {
          yield evt;
        }
      }

      final errBytes = await session.stderr.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      final errText = utf8.decode(errBytes, allowMalformed: true).trim();
      if (errText.isNotEmpty &&
          errText.toLowerCase().contains('authentication required')) {
        yield AgyErrorEvent(message: errText, requiresAuth: true);
      }

      await session.done;
    } finally {
      _activeSession = null;
      client.close();
    }
  }

  Future<void> cancelActive() async {
    _activeSession?.close();
    _activeSession = null;
  }

  Future<String> probeUsage({
    required SshHostConfig host,
    String? password,
    String? privateKeyPem,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    try {
      final agy = _shellQuote(host.agyBinary);
      final out = await client.run(
        '$agy models 2>/dev/null; $agy -p /usage --output-format text 2>/dev/null; $agy -p /credits --output-format text 2>/dev/null || true',
      );
      return utf8.decode(out, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  Future<String> runRemoteCommand({
    required SshHostConfig host,
    required String command,
    String? cwd,
    String? password,
    String? privateKeyPem,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
    );
    try {
      final dir = (cwd != null && cwd.isNotEmpty) ? cwd : host.defaultWorkspace;
      final cmd = dir.isNotEmpty ? 'cd ${_shellQuote(dir)} && $command' : command;
      final out = await client.run(cmd);
      return utf8.decode(out, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  static String _shellQuote(String value) {
    if (value == '~') return '~';
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
