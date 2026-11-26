import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agy_client/agy_client.dart';
import 'package:dartssh2/dartssh2.dart';

import 'ssh_host.dart';

/// Executes Antigravity CLI (`agy`) remotely over SSH on a user's workstation or server,
/// preferring interactive ACP (`agy acp`) with live permission approvals & image attachments,
/// and falling back to `-p --output-format stream-json` for non-ACP options or older remote CLIs.
class SshAgyRunner {
  SshAgyRunner._();
  static final SshAgyRunner instance = SshAgyRunner._();

  final Map<String, SSHSession> _activeSessions = {};
  final Map<String, ({AcpCodec codec, String sessionId})> _activeAcpState = {};

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
      final out =
          await client.run('$agy --version || which agy || echo connected');
      return utf8.decode(out, allowMalformed: true).trim();
    } finally {
      client.close();
    }
  }

  static String? _imageMimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return null;
  }

  Future<({List<Map<String, dynamic>> imageBlocks, List<String> remoteFilePaths})>
      _prepareAttachments(
    SSHClient client,
    List<String> localPaths,
  ) async {
    final imageBlocks = <Map<String, dynamic>>[];
    final remoteFilePaths = <String>[];
    if (localPaths.isEmpty) {
      return (imageBlocks: imageBlocks, remoteFilePaths: remoteFilePaths);
    }

    SftpClient? sftp;
    final remoteCacheDir = '.cache/antigravity-go/attachments';
    var dirReady = false;

    for (final rawPath in localPaths) {
      final file = File(rawPath);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }
      final mime = _imageMimeForPath(rawPath);
      final len = stat.size;
      if (mime != null && len > 0 && len <= 4 * 1024 * 1024) {
        try {
          final bytes = await file.readAsBytes();
          imageBlocks.add({
            'type': 'image',
            'mimeType': mime,
            'data': base64Encode(bytes),
          });
          continue;
        } catch (_) {}
      }
      // Upload non-image attachments over SFTP so the remote host can read them.
      if (len > 0 && len <= 16 * 1024 * 1024) {
        try {
          sftp ??= await client.sftp();
          if (!dirReady) {
            await client.run('mkdir -p ~/$remoteCacheDir');
            dirReady = true;
          }
          final safeName = file.uri.pathSegments.last
              .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final relPath =
              '$remoteCacheDir/${DateTime.now().millisecondsSinceEpoch}_$safeName';
          final remoteFile = await sftp.open(
            relPath,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.write |
                SftpFileOpenMode.truncate,
          );
          await remoteFile.writeBytes(await file.readAsBytes());
          await remoteFile.close();
          remoteFilePaths.add('~/$relPath');
        } catch (_) {
          remoteFilePaths.add(rawPath);
        }
      }
    }
    sftp?.close();
    return (imageBlocks: imageBlocks, remoteFilePaths: remoteFilePaths);
  }

  Stream<AgyChatEvent> runPrompt({
    required SshHostConfig host,
    required AgyPromptRequest request,
    String? turnId,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
  }) async* {
    final useAcp = request.printTimeoutSeconds == null &&
        !request.disableSlashCommands &&
        !request.continueLast &&
        (request.remoteAgent == null || request.remoteAgent!.isEmpty);

    if (useAcp) {
      var receivedAnyEvent = false;
      var shouldFallback = false;
      await for (final evt in _runPromptAcp(
        host: host,
        request: request,
        turnId: turnId,
        password: password,
        privateKeyPem: privateKeyPem,
        onTrustFirstKey: onTrustFirstKey,
        onPreStartFailure: () => shouldFallback = true,
      )) {
        receivedAnyEvent = true;
        yield evt;
      }
      if (!shouldFallback || receivedAnyEvent) return;
    }

    yield* _runPromptStreamJson(
      host: host,
      request: request,
      turnId: turnId,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
    );
  }

  Stream<AgyChatEvent> _runPromptAcp({
    required SshHostConfig host,
    required AgyPromptRequest request,
    String? turnId,
    String? password,
    String? privateKeyPem,
    FutureOr<void> Function(String fingerprint)? onTrustFirstKey,
    required void Function() onPreStartFailure,
  }) async* {
    final client = await connect(
      host,
      password: password,
      privateKeyPem: privateKeyPem,
      onTrustFirstKey: onTrustFirstKey,
    );
    final sessionKey = turnId ?? 'default';

    try {
      final prepared = await _prepareAttachments(client, request.attachments);
      final effectivePrompt = prepared.remoteFilePaths.isEmpty
          ? request.prompt
          : '${request.prompt}\n\n[Uploaded remote attachments: ${prepared.remoteFilePaths.join(', ')}]';

      final cwd = request.workspacePath.isEmpty
          ? host.defaultWorkspace
          : request.workspacePath;
      final args = <String>[
        _shellQuote(host.agyBinary),
        'acp',
        if (request.agentName != null && request.agentName!.isNotEmpty) ...[
          '--agent',
          _shellQuote(request.agentName!),
        ],
        if (request.dangerouslySkipPermissions)
          '--dangerously-skip-permissions',
        for (final dir in request.extraDirs)
          if (dir.trim().isNotEmpty && !dir.startsWith('/sdcard')) ...[
            '--add-dir',
            _shellQuote(dir.trim()),
          ],
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

      final codec = AcpCodec();
      void sendLine(String jsonLine) {
        session.stdin.add(utf8.encode('$jsonLine\n'));
      }

      final initId = codec.nextRequestId();
      var sessionReqId = -1;
      var promptReqId = -1;
      var promptSent = false;
      var triedLoadFallback = false;
      var triedNewFallback = false;
      var receivedInitOk = false;
      String? acpSessionId;
      final pendingConfigIds = <int>{};

      sendLine(codec.encodeInitialize(id: initId, clientVersion: '1.0.16'));

      final stdoutLines = session.stdout
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

      await for (final raw in stdoutLines) {
        final trimmed = raw.trim();
        if (!trimmed.startsWith('{')) continue;
        Map<String, dynamic> msg;
        try {
          msg = (jsonDecode(trimmed) as Map).map(
            (k, v) => MapEntry(k.toString(), v),
          );
        } catch (_) {
          continue;
        }

        final msgId = msg['id'];
        final method = msg['method']?.toString() ?? '';

        if (msgId is num && msgId.toInt() == initId) {
          if (msg.containsKey('error')) {
            final evt = codec.parseDecodedMessage(msg);
            if (evt != null) yield evt;
            break;
          }
          receivedInitOk = true;
          sessionReqId = codec.nextRequestId();
          final existing = request.conversationId;
          final targetCwd = cwd.trim().isEmpty ? '.' : cwd.trim();
          if (existing != null && existing.isNotEmpty) {
            sendLine(
              codec.encodeResumeSession(
                id: sessionReqId,
                sessionId: existing,
                cwd: targetCwd,
              ),
            );
          } else {
            sendLine(
              codec.encodeNewSession(id: sessionReqId, cwd: targetCwd),
            );
          }
          continue;
        }

        if (msgId is num && msgId.toInt() == sessionReqId) {
          final targetCwd = cwd.trim().isEmpty ? '.' : cwd.trim();
          if (msg.containsKey('error') &&
              request.conversationId != null &&
              request.conversationId!.isNotEmpty &&
              !triedLoadFallback) {
            triedLoadFallback = true;
            final errCode =
                ((msg['error'] as Map?)?['code'] as num?)?.toInt() ?? 0;
            sessionReqId = codec.nextRequestId();
            if (errCode == -32601) {
              sendLine(
                codec.encodeLoadSession(
                  id: sessionReqId,
                  sessionId: request.conversationId!,
                  cwd: targetCwd,
                ),
              );
            } else {
              sendLine(
                codec.encodeNewSession(id: sessionReqId, cwd: targetCwd),
              );
            }
            continue;
          }
          if (msg.containsKey('error') &&
              triedLoadFallback &&
              !triedNewFallback &&
              acpSessionId == null) {
            triedNewFallback = true;
            sessionReqId = codec.nextRequestId();
            sendLine(
              codec.encodeNewSession(id: sessionReqId, cwd: targetCwd),
            );
            continue;
          }

          final evt = codec.parseDecodedMessage(msg);
          if (evt != null) yield evt;

          final res = msg['result'];
          if (res is Map) {
            acpSessionId = res['sessionId']?.toString();
            if (acpSessionId == null || acpSessionId.isEmpty) {
              acpSessionId = request.conversationId;
            }
          }
          if (acpSessionId != null && acpSessionId.isNotEmpty) {
            _activeAcpState[sessionKey] = (codec: codec, sessionId: acpSessionId);
            if (request.modelId != null && request.modelId!.isNotEmpty) {
              final cid = codec.nextRequestId();
              pendingConfigIds.add(cid);
              sendLine(
                codec.encodeSetSessionOption(
                  id: cid,
                  sessionId: acpSessionId,
                  optionId: 'model',
                  value: request.modelId!,
                ),
              );
            }
            if (request.effortCliValue != null &&
                request.effortCliValue!.isNotEmpty &&
                !(request.modelId?.toLowerCase().contains('orchestrator') ??
                    false)) {
              final cid = codec.nextRequestId();
              pendingConfigIds.add(cid);
              sendLine(
                codec.encodeSetSessionOption(
                  id: cid,
                  sessionId: acpSessionId,
                  optionId: 'effort',
                  value: request.effortCliValue!,
                ),
              );
            }
            final cliMode = request.mode.cliValue;
            if (cliMode.isNotEmpty) {
              final cid = codec.nextRequestId();
              pendingConfigIds.add(cid);
              sendLine(
                codec.encodeSetSessionOption(
                  id: cid,
                  sessionId: acpSessionId,
                  optionId: 'mode',
                  value: cliMode,
                ),
              );
            }
            if (pendingConfigIds.isEmpty) {
              promptReqId = codec.nextRequestId();
              promptSent = true;
              sendLine(
                codec.encodePrompt(
                  id: promptReqId,
                  sessionId: acpSessionId,
                  text: effectivePrompt,
                  imageBlocks: prepared.imageBlocks,
                ),
              );
            }
          } else {
            break;
          }
          continue;
        }

        if (msgId is num && pendingConfigIds.remove(msgId.toInt())) {
          if (pendingConfigIds.isEmpty &&
              !promptSent &&
              acpSessionId != null) {
            promptReqId = codec.nextRequestId();
            promptSent = true;
            sendLine(
              codec.encodePrompt(
                id: promptReqId,
                sessionId: acpSessionId,
                text: effectivePrompt,
                imageBlocks: prepared.imageBlocks,
              ),
            );
          }
          continue;
        }

        if (!promptSent && method == 'session/update') {
          continue;
        }

        final evt = codec.parseDecodedMessage(msg);
        if (evt != null) {
          yield evt;
        }

        if (msgId is num && msgId.toInt() == promptReqId) {
          break;
        }
      }

      const maxErrBytes = 65536;
      final errBytes = <int>[];
      await for (final chunk in session.stderr) {
        if (errBytes.length >= maxErrBytes) continue;
        final remaining = maxErrBytes - errBytes.length;
        if (chunk.length <= remaining) {
          errBytes.addAll(chunk);
        } else {
          errBytes.addAll(chunk.take(remaining));
        }
      }
      final errText = utf8.decode(errBytes, allowMalformed: true).trim();
      await session.done;
      final exitCode = session.exitCode ?? 0;

      if (!receivedInitOk && !promptSent) {
        onPreStartFailure();
        return;
      }

      if (errText.isNotEmpty &&
          errText.toLowerCase().contains('authentication required')) {
        yield AgyErrorEvent(message: errText, requiresAuth: true);
      } else if (exitCode != 0 && !promptSent) {
        yield AgyErrorEvent(
          message: errText.isNotEmpty
              ? 'Remote agy exited ($exitCode): $errText'
              : 'Remote agy exited with code $exitCode',
          code: exitCode,
        );
      }
    } finally {
      _activeAcpState.remove(sessionKey);
      _activeSessions.remove(sessionKey);
      client.close();
    }
  }

  Stream<AgyChatEvent> _runPromptStreamJson({
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
      final prepared = await _prepareAttachments(client, request.attachments);
      final effectivePrompt = prepared.remoteFilePaths.isEmpty
          ? request.prompt
          : '${request.prompt}\n\n[Uploaded remote attachments: ${prepared.remoteFilePaths.join(', ')}]';

      final cwd = request.workspacePath.isEmpty
          ? host.defaultWorkspace
          : request.workspacePath;
      final args = <String>[
        _shellQuote(host.agyBinary),
        '-p',
        _shellQuote(effectivePrompt),
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
            !(request.modelId?.toLowerCase().contains('orchestrator') ??
                false)) ...[
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
          request.printTimeoutSeconds.toString(),
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
          if (dir.trim().isNotEmpty && !dir.startsWith('/sdcard')) ...[
            '--add-dir',
            _shellQuote(dir.trim()),
          ],
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

  Future<bool> respondToPermission({
    required String turnId,
    required Object requestId,
    required String optionId,
  }) async {
    final session = _activeSessions[turnId];
    final acp = _activeAcpState[turnId];
    if (session == null || acp == null) return false;
    final line = acp.codec.encodePermissionResponse(
      requestId: requestId,
      optionId: optionId,
    );
    session.stdin.add(utf8.encode('$line\n'));
    return true;
  }

  Future<void> cancelActive({String? turnId}) async {
    if (turnId != null) {
      final acp = _activeAcpState.remove(turnId);
      final session = _activeSessions.remove(turnId);
      if (session != null && acp != null) {
        try {
          session.stdin.add(
            utf8.encode('${acp.codec.encodeCancel(sessionId: acp.sessionId)}\n'),
          );
        } catch (_) {}
      }
      session?.close();
      return;
    }
    for (final s in _activeSessions.values.toList()) {
      s.close();
    }
    _activeAcpState.clear();
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
        '$agy models 2>/dev/null; ($agy -p /usage --output-format json 2>/dev/null || $agy -p /usage --output-format text 2>/dev/null); ($agy -p /credits --output-format json 2>/dev/null || $agy -p /credits --output-format text 2>/dev/null) || true',
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
