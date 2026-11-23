import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agy_client/agy_client.dart';
import 'package:dartssh2/dartssh2.dart';

import 'ssh_host.dart';

/// Executes Antigravity CLI (`agy`) remotely over SSH on a user's workstation or server.
class SshAgyRunner {
  SshAgyRunner._();
  static final SshAgyRunner instance = SshAgyRunner._();

  final Map<String, SSHSession> _activeSessions = {};

  static String formatFingerprint(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  Future<SSHClient> connect(
    SshHostConfig host, {
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
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
      onVerifyHostKey: (type, fingerprint) async {
        final hex = '$type:${formatFingerprint(fingerprint)}';
        final pinned = host.hostKeyFingerprint?.trim();
        if (pinned != null && pinned.isNotEmpty) {
          return pinned == hex || pinned == formatFingerprint(fingerprint);
        }
        if (onTrustFirstKey != null) {
          await onTrustFirstKey(hex);
        }
        return true;
      },
    );
  }

  Future<String> testConnection(
    SshHostConfig host, {
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
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
    String? turnId,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async* {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
    );
    final sessionKey = turnId ?? 'default';

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
        for (final dir in request.extraDirs)
          if (dir.trim().isNotEmpty) ...['--add-dir', _shellQuote(dir.trim())],
      ];

      final envPrefix = (request.geminiApiKey != null &&
              request.geminiApiKey!.trim().isNotEmpty)
          ? 'GEMINI_API_KEY=${_shellQuote(request.geminiApiKey!.trim())} '
          : '';
      final cmd = cwd.trim().isNotEmpty
          ? 'cd ${_shellQuote(cwd)} && $envPrefix${args.join(' ')}'
          : '$envPrefix${args.join(' ')}';
      final session = await client.execute(cmd);
      _activeSessions[sessionKey] = session;

      final stdoutLines = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

      var yieldedTurnResult = false;
      await for (final line in stdoutLines) {
        final evt = StreamJsonParser.parseLine(line);
        if (evt != null) {
          if (evt is AgyTurnResultEvent || evt is AgyErrorEvent) {
            yieldedTurnResult = true;
          }
          yield evt;
        }
      }

      final errBytes = await session.stderr.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      final errText = utf8.decode(errBytes, allowMalformed: true).trim();
      await session.done;
      final exitCode = session.exitCode ?? 0;

      if (errText.isNotEmpty &&
          errText.toLowerCase().contains('authentication required')) {
        yield AgyErrorEvent(message: errText, requiresAuth: true);
      } else if (exitCode != 0 && !yieldedTurnResult) {
        final detail = errText.isNotEmpty ? ': $errText' : '';
        yield AgyErrorEvent(
          message: 'Remote agy exited with code $exitCode$detail',
          code: exitCode,
        );
      }
    } finally {
      _activeSessions.remove(sessionKey);
      client.close();
    }
  }

  Future<void> cancelActive({String? turnId}) async {
    if (turnId != null) {
      _activeSessions.remove(turnId)?.close();
      return;
    }
    for (final s in _activeSessions.values.toList()) {
      s.close();
    }
    _activeSessions.clear();
  }

  Future<Map<String, Object?>> createCheckpoint({
    required SshHostConfig host,
    required String cwd,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async {
    final dir = cwd.trim().isEmpty ? host.defaultWorkspace : cwd.trim();
    const script =
        'if [ "\$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then echo "NOT_GIT"; exit 0; fi; '
        'H=\$(git rev-parse --verify HEAD 2>/dev/null || true); '
        'if [ -z "\$H" ]; then echo "NO_HEAD"; exit 0; fi; '
        'IDX=\$(mktemp /tmp/agy-cp-XXXXXX); '
        'GIT_INDEX_FILE="\$IDX" git read-tree "\$H" && '
        'GIT_INDEX_FILE="\$IDX" git add -A && '
        'T=\$(GIT_INDEX_FILE="\$IDX" git write-tree) && '
        'HT=\$(git rev-parse "\${H}^{tree}"); '
        'rm -f "\$IDX"; '
        'if [ "\$T" = "\$HT" ]; then echo "REF:\$H"; else C=\$(git commit-tree "\$T" -p "\$H" -m "agy-checkpoint"); echo "REF:\${C:-\$H}"; fi';
    final out = await runRemoteCommand(
      host: host,
      command: script,
      cwd: dir,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
    );
    final refLine = out
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.startsWith('REF:'))
        .firstOrNull;
    if (refLine == null) {
      return const {'ok': false, 'reason': 'Not a git repository'};
    }
    final sha = refLine.substring(4).trim();
    return {'ok': sha.isNotEmpty, 'ref': sha};
  }

  Future<Map<String, Object?>> restoreCheckpoint({
    required SshHostConfig host,
    required String cwd,
    required String ref,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async {
    final cleanRef = ref.trim();
    if (!RegExp(r'^[0-9a-fA-F]{7,64}$').hasMatch(cleanRef)) {
      return const {'ok': false, 'message': 'Invalid checkpoint ref'};
    }
    final dir = cwd.trim().isEmpty ? host.defaultWorkspace : cwd.trim();
    final script =
        'SUBJ=\$(git log -1 --format=%s "$cleanRef" 2>/dev/null || true); '
        'if [ "\$SUBJ" = "agy-checkpoint" ]; then '
        'BASE=\$(git rev-parse --verify "$cleanRef^1" 2>/dev/null || echo "$cleanRef"); '
        'git reset --hard "\$BASE" && git read-tree --reset -u "$cleanRef" && git reset --mixed "\$BASE" && echo "OK"; '
        'else git reset --hard "$cleanRef" && git clean -fd && echo "OK"; fi';
    final out = await runRemoteCommand(
      host: host,
      command: script,
      cwd: dir,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
    );
    return {
      'ok': out.contains('OK'),
      'ref': cleanRef,
      'message': out.trim(),
    };
  }

  Future<String> probeUsage({
    required SshHostConfig host,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
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
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
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
    if (value.startsWith('~/')) {
      final rest = value.substring(2).replaceAll("'", "'\\''");
      return "~/'$rest'";
    }
    return "'${value.replaceAll("'", "'\\''")}'";
  }
}
