import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:http/http.dart' as http;

import '../runtime/runtime_bridge.dart';
import 'ssh_agy_runner.dart';
import 'ssh_host.dart';

class _TurnControl {
  _TurnControl();
  http.Client? client;
  bool cancelled = false;
  final Map<Object, Completer<String?>> pendingPermissions = {};

  void cancel() {
    cancelled = true;
    try {
      client?.close();
    } catch (_) {}
    client = null;
    for (final c in pendingPermissions.values) {
      if (!c.isCompleted) c.complete('reject_once');
    }
    pendingPermissions.clear();
  }
}

/// Runs OpenAI-compatible `/v1/chat/completions` turns with SSE streaming,
/// reasoning/think-block extraction, vision image attachments, interactive
/// permission gating, and an agentic tool loop (`run_command`, `read_file`,
/// `write_file`, `list_dir`) against either the local Android workspace or an SSH host.
class OpenAiCompatRunner {
  OpenAiCompatRunner._();
  static final OpenAiCompatRunner instance = OpenAiCompatRunner._();

  final Map<String, _TurnControl> _activeTurns = {};
  int _nextReqId = 1000;

  static const int _maxToolRounds = 16;

  static List<Map<String, dynamic>> _toolDefinitions() => [
        {
          'type': 'function',
          'function': {
            'name': 'run_command',
            'description':
                'Run a shell command in the active project workspace directory.',
            'parameters': {
              'type': 'object',
              'properties': {
                'command': {
                  'type': 'string',
                  'description': 'Shell command to execute',
                },
                'cwd': {
                  'type': 'string',
                  'description': 'Optional working directory override',
                },
              },
              'required': ['command'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'read_file',
            'description': 'Read a text file in the workspace or device.',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': 'File path (absolute or workspace-relative)',
                },
              },
              'required': ['path'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'write_file',
            'description': 'Write full text content to a file (creating parent directories if needed).',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': 'Destination file path',
                },
                'content': {
                  'type': 'string',
                  'description': 'Complete text content to write',
                },
              },
              'required': ['path', 'content'],
            },
          },
        },
        {
          'type': 'function',
          'function': {
            'name': 'list_dir',
            'description': 'List files and folders inside a directory.',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': 'Directory path (defaults to workspace root)',
                },
              },
            },
          },
        },
      ];

  static Map<String, String> _headers(String? apiKey) => {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream, application/json',
        if (apiKey != null && apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${apiKey.trim()}',
      };

  Future<List<String>> fetchModels(
    OpenAiProviderConfig profile, {
    String? apiKey,
  }) async {
    final uri = profile.modelsUri;
    final res = await http
        .get(uri, headers: _headers(apiKey))
        .timeout(const Duration(seconds: 12));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    final decoded = jsonDecode(res.body);
    final rawList = decoded is Map ? (decoded['data'] ?? decoded['models']) : null;
    if (rawList is! List) return const [];
    final ids = <String>[];
    for (final item in rawList) {
      if (item is Map && item['id'] != null) {
        ids.add(item['id'].toString());
      } else if (item is String) {
        ids.add(item);
      }
    }
    ids.sort();
    return ids;
  }

  Future<String> testConnection(
    OpenAiProviderConfig profile, {
    String? apiKey,
  }) async {
    try {
      final models = await fetchModels(profile, apiKey: apiKey);
      if (models.isNotEmpty) {
        final hasSelected = models.contains(profile.modelId);
        return hasSelected
            ? 'Connected (${models.length} models; "${profile.modelId}" ready)'
            : 'Connected (${models.length} models found)';
      }
    } catch (_) {
      // Some proxies omit GET /models; verify via a minimal /chat/completions call.
    }

    final res = await http
        .post(
          profile.chatCompletionsUri,
          headers: _headers(apiKey),
          body: jsonEncode({
            'model': profile.modelId,
            'messages': const [
              {'role': 'user', 'content': 'ping'},
            ],
            'max_tokens': 4,
            'stream': false,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('HTTP ${res.statusCode}: ${res.body}');
    }
    return 'Connected to "${profile.modelId}" at ${profile.normalizedBaseUrl}';
  }

  Future<bool> resolvePermission({
    required String turnId,
    required Object requestId,
    required String optionId,
  }) async {
    final ctrl = _activeTurns[turnId];
    if (ctrl == null) return false;
    final completer = ctrl.pendingPermissions.remove(requestId);
    if (completer == null || completer.isCompleted) return false;
    completer.complete(optionId);
    return true;
  }

  Future<void> cancelActive({String? turnId}) async {
    if (turnId != null) {
      _activeTurns.remove(turnId)?.cancel();
      return;
    }
    for (final c in _activeTurns.values.toList()) {
      c.cancel();
    }
    _activeTurns.clear();
  }

  static String? _imageMimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return null;
  }

  Future<dynamic> _buildUserContent({
    required String prompt,
    required List<String> attachments,
    required bool supportsVision,
  }) async {
    if (!supportsVision || attachments.isEmpty) return prompt;
    final blocks = <Map<String, dynamic>>[
      {'type': 'text', 'text': prompt},
    ];
    var hasImage = false;
    for (final path in attachments) {
      final mime = _imageMimeForPath(path);
      if (mime == null) continue;
      final file = File(path);
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      final len = stat.size;
      if (len <= 0 || len > 4 * 1024 * 1024) continue;
      try {
        final b64 = base64Encode(await file.readAsBytes());
        blocks.add({
          'type': 'image_url',
          'image_url': {'url': 'data:$mime;base64,$b64'},
        });
        hasImage = true;
      } catch (_) {}
    }
    return hasImage ? blocks : prompt;
  }

  Stream<AgyChatEvent> runPrompt({
    required OpenAiProviderConfig profile,
    required String? apiKey,
    required String turnId,
    required String prompt,
    required String workspacePath,
    required bool dangerouslySkipPermissions,
    String systemInstructions = '',
    List<({String role, String text})> history = const [],
    List<String> attachments = const [],
    SshHostConfig? sshHost,
    String? sshPassword,
    String? sshPrivateKey,
    FutureOr<void> Function(String fp)? onTrustFirstKey,
  }) async* {
    final ctrl = _TurnControl();
    _activeTurns[turnId]?.cancel();
    _activeTurns[turnId] = ctrl;
    final startedAt = DateTime.now();

    try {
      final ws = workspacePath.trim();
      final sysParts = <String>[
        'You are Antigravity running inside Antigravity Go.',
        if (ws.isNotEmpty) 'Active workspace directory: $ws',
        if (profile.supportsTools)
          'You have tools (`run_command`, `read_file`, `write_file`, `list_dir`) to inspect and edit files.',
        if (systemInstructions.trim().isNotEmpty) systemInstructions.trim(),
        if (profile.systemPrompt.trim().isNotEmpty) profile.systemPrompt.trim(),
      ];

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': sysParts.join('\n')},
      ];
      final recent = history.length > 24
          ? history.sublist(history.length - 24)
          : history;
      for (final h in recent) {
        if (h.text.trim().isEmpty) continue;
        messages.add({
          'role': h.role == 'assistant' ? 'assistant' : 'user',
          'content': h.text,
        });
      }
      final userContent = await _buildUserContent(
        prompt: prompt,
        attachments: attachments,
        supportsVision: profile.supportsVision,
      );
      messages.add({'role': 'user', 'content': userContent});

      var totalIn = 0;
      var totalOut = 0;
      var totalCache = 0;
      var totalReasoning = 0;
      var lastCtxTokens = 0;
      final fullResponse = StringBuffer();
      var includeStreamOptions = true;
      final client = http.Client();
      ctrl.client = client;

      for (var round = 0; round < _maxToolRounds; round++) {
        if (ctrl.cancelled) break;

        final bodyMap = <String, dynamic>{
          'model': profile.modelId,
          'messages': messages,
          'stream': true,
          if (includeStreamOptions)
            'stream_options': const {'include_usage': true},
          if (profile.supportsTools) 'tools': _toolDefinitions(),
        };

        final req = http.Request('POST', profile.chatCompletionsUri)
          ..headers.addAll(_headers(apiKey))
          ..body = jsonEncode(bodyMap);

        http.StreamedResponse resp;
        try {
          resp = await client.send(req).timeout(const Duration(seconds: 45));
        } catch (e) {
          if (ctrl.cancelled) return;
          yield AgyErrorEvent(message: 'Network error calling ${profile.name}: $e');
          return;
        }

        if (resp.statusCode == 400 && includeStreamOptions) {
          final errBody = await resp.stream.bytesToString();
          if (errBody.toLowerCase().contains('stream_options')) {
            includeStreamOptions = false;
            round--;
            continue;
          }
          yield AgyErrorEvent(
            message: 'HTTP 400 from ${profile.name}: $errBody',
            code: 400,
          );
          return;
        }

        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          final errBody = await resp.stream.bytesToString();
          yield AgyErrorEvent(
            message: 'HTTP ${resp.statusCode} from ${profile.name}: $errBody',
            code: resp.statusCode,
          );
          return;
        }

        final parser = OpenAiSseParser();
        final roundText = StringBuffer();
        final ctype = (resp.headers['content-type'] ?? '').toLowerCase();

        if (ctype.contains('application/json')) {
          final rawJson = await resp.stream.bytesToString();
          final slice = parser.parseLine(rawJson);
          if (slice?.errorMessage != null) {
            yield AgyErrorEvent(message: slice!.errorMessage!);
            return;
          }
          if (slice != null) {
            if (slice.thoughtDelta.isNotEmpty) {
              yield AgyThoughtDeltaEvent(delta: slice.thoughtDelta);
            }
            if (slice.textDelta.isNotEmpty) {
              roundText.write(slice.textDelta);
              fullResponse.write(slice.textDelta);
              yield AgyTextDeltaEvent(delta: slice.textDelta);
            }
          }
        } else {
          final lines = resp.stream
              .transform(const Utf8Decoder(allowMalformed: true))
              .transform(const LineSplitter());
          await for (final line in lines) {
            if (ctrl.cancelled) break;
            final slice = parser.parseLine(line);
            if (slice == null) continue;
            if (slice.errorMessage != null) {
              yield AgyErrorEvent(message: slice.errorMessage!);
              return;
            }
            if (slice.thoughtDelta.isNotEmpty) {
              yield AgyThoughtDeltaEvent(
                delta: slice.thoughtDelta,
                stepUsage: slice.usage,
              );
            }
            if (slice.textDelta.isNotEmpty) {
              roundText.write(slice.textDelta);
              fullResponse.write(slice.textDelta);
              yield AgyTextDeltaEvent(
                delta: slice.textDelta,
                stepUsage: slice.usage,
              );
            }
          }
          final tail = parser.flushPendingTags();
          if (tail.thought.isNotEmpty) {
            yield AgyThoughtDeltaEvent(delta: tail.thought);
          }
          if (tail.text.isNotEmpty) {
            roundText.write(tail.text);
            fullResponse.write(tail.text);
            yield AgyTextDeltaEvent(delta: tail.text);
          }
        }

        final u = parser.latestUsage;
        if (u != null) {
          totalIn += u.inputTokens;
          totalOut += u.outputTokens;
          totalCache += u.cacheReadTokens;
          totalReasoning += u.thinkingTokens;
          lastCtxTokens = u.contextTokens > 0
              ? u.contextTokens
              : (u.inputTokens + u.outputTokens);
        }

        final pendingTools = parser.orderedToolCalls;
        if (!profile.supportsTools || pendingTools.isEmpty || ctrl.cancelled) {
          break;
        }

        messages.add({
          'role': 'assistant',
          if (roundText.isNotEmpty) 'content': roundText.toString(),
          'tool_calls': [
            for (final tc in pendingTools)
              {
                'id': tc.id.isNotEmpty ? tc.id : 'call_${tc.index}_$round',
                'type': 'function',
                'function': {
                  'name': tc.name,
                  'arguments': tc.argumentsBuffer.toString(),
                },
              },
          ],
        });

        for (final tc in pendingTools) {
          if (ctrl.cancelled) break;
          final callId =
              tc.id.isNotEmpty ? tc.id : 'call_${tc.index}_$round';
          final args = tc.parseArgumentsMap();
          yield AgyToolCallEvent(
            callId: callId,
            toolName: tc.name,
            state: ToolCallState.running,
            parameters: args,
          );

          final needsApproval = !dangerouslySkipPermissions &&
              (tc.name == 'run_command' || tc.name == 'write_file');
          var approved = true;
          if (needsApproval) {
            final reqId = 'perm-${_nextReqId++}';
            final completer = Completer<String?>();
            ctrl.pendingPermissions[reqId] = completer;
            yield AgyPermissionRequestEvent(
              requestId: reqId,
              toolName: tc.name,
              title: tc.name == 'run_command'
                  ? 'Approve shell command'
                  : 'Approve file write',
              commandOrPath: (args['command'] ?? args['path'] ?? '').toString(),
              options: const [
                PermissionOption(
                  optionId: 'allow_once',
                  name: 'Allow once',
                  kind: 'allow_once',
                ),
                PermissionOption(
                  optionId: 'reject_once',
                  name: 'Deny',
                  kind: 'reject_once',
                ),
              ],
            );
            final choice = await completer.future;
            approved = choice != null && !choice.startsWith('reject');
          }

          if (ctrl.cancelled) break;

          final tStart = DateTime.now();
          String toolResultText;
          var toolOk = true;
          if (!approved) {
            toolOk = false;
            toolResultText = 'Permission denied by user.';
          } else {
            final exec = await _executeTool(
              name: tc.name,
              args: args,
              workspacePath: ws,
              sshHost: sshHost,
              sshPassword: sshPassword,
              sshPrivateKey: sshPrivateKey,
              onTrustFirstKey: onTrustFirstKey,
            );
            toolOk = exec.ok;
            toolResultText = exec.output;
          }
          final tDur =
              DateTime.now().difference(tStart).inMilliseconds / 1000.0;

          yield AgyToolCallEvent(
            callId: callId,
            toolName: tc.name,
            state: toolOk ? ToolCallState.completed : ToolCallState.failed,
            parameters: args,
            output: toolOk ? toolResultText : null,
            errorMessage: toolOk ? null : toolResultText,
            durationSeconds: tDur,
          );

          messages.add({
            'role': 'tool',
            'tool_call_id': callId,
            'content': toolResultText.length > 24000
                ? '${toolResultText.substring(0, 24000)}\n...[truncated]'
                : toolResultText,
          });
        }
      }

      if (ctrl.cancelled) return;
      final durationSec =
          DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
      yield AgyTurnResultEvent(
        conversationId: '',
        status: 'SUCCESS',
        response: fullResponse.toString(),
        durationSeconds: durationSec,
        usage: TokenUsage(
          inputTokens: totalIn,
          outputTokens: totalOut,
          cacheReadTokens: totalCache,
          thinkingTokens: totalReasoning,
          totalTokens: totalIn + totalOut,
          contextTokens: lastCtxTokens,
        ),
      );
    } finally {
      if (_activeTurns[turnId] == ctrl) {
        _activeTurns.remove(turnId);
      }
      ctrl.cancel();
    }
  }

  static String _resolvePath(String rawPath, String workspacePath) {
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty) return workspacePath;
    if (trimmed.startsWith('/') || trimmed.startsWith('~')) return trimmed;
    if (workspacePath.isEmpty) return trimmed;
    return workspacePath.endsWith('/')
        ? '$workspacePath$trimmed'
        : '$workspacePath/$trimmed';
  }

  Future<({bool ok, String output})> _executeTool({
    required String name,
    required Map<String, dynamic> args,
    required String workspacePath,
    SshHostConfig? sshHost,
    String? sshPassword,
    String? sshPrivateKey,
    FutureOr<void> Function(String fp)? onTrustFirstKey,
  }) async {
    try {
      switch (name) {
        case 'run_command':
          final cmd = (args['command'] ?? '').toString().trim();
          if (cmd.isEmpty) return (ok: false, output: 'Empty command');
          final cwd = args['cwd']?.toString().trim();
          final effCwd =
              (cwd != null && cwd.isNotEmpty) ? cwd : workspacePath;
          if (sshHost != null) {
            final out = await SshAgyRunner.instance.runRemoteCommand(
              host: sshHost,
              command: cmd,
              cwd: effCwd,
              password: sshPassword,
              privateKeyPem: sshPrivateKey,
              onTrustFirstKey: onTrustFirstKey,
            );
            return (ok: true, output: out.isEmpty ? '(no output)' : out);
          }
          final out = await RuntimeBridge.instance.runShellCommand(
            command: cmd,
            cwd: effCwd.isEmpty ? null : effCwd,
          );
          return (ok: true, output: out.isEmpty ? '(no output)' : out);

        case 'read_file':
          final rawPath = (args['path'] ?? '').toString();
          final path = _resolvePath(rawPath, workspacePath);
          if (sshHost != null) {
            final quoted = "'${path.replaceAll("'", "'\\''")}'";
            final out = await SshAgyRunner.instance.runRemoteCommand(
              host: sshHost,
              command: 'sed -n "1,400p" $quoted',
              cwd: workspacePath,
              password: sshPassword,
              privateKeyPem: sshPrivateKey,
              onTrustFirstKey: onTrustFirstKey,
            );
            return (ok: true, output: out);
          }
          final content = await RuntimeBridge.instance.readWorkspaceFile(path);
          return (ok: true, output: content);

        case 'write_file':
          final rawPath = (args['path'] ?? '').toString();
          final content = (args['content'] ?? '').toString();
          final path = _resolvePath(rawPath, workspacePath);
          if (sshHost != null) {
            final quoted = "'${path.replaceAll("'", "'\\''")}'";
            final b64 = base64Encode(utf8.encode(content));
            await SshAgyRunner.instance.runRemoteCommand(
              host: sshHost,
              command:
                  'mkdir -p "\$(dirname $quoted)" && printf %s "$b64" | base64 -d > $quoted',
              cwd: workspacePath,
              password: sshPassword,
              privateKeyPem: sshPrivateKey,
              onTrustFirstKey: onTrustFirstKey,
            );
            return (ok: true, output: 'Wrote $path (${content.length} chars)');
          }
          final ok = await RuntimeBridge.instance.writeWorkspaceFile(path, content);
          return (
            ok: ok,
            output: ok ? 'Wrote $path (${content.length} chars)' : 'Failed writing $path',
          );

        case 'list_dir':
          final rawPath = (args['path'] ?? '').toString();
          final path = _resolvePath(rawPath, workspacePath);
          if (sshHost != null) {
            final quoted = "'${path.replaceAll("'", "'\\''")}'";
            final out = await SshAgyRunner.instance.runRemoteCommand(
              host: sshHost,
              command: 'ls -la $quoted | head -n 100',
              cwd: workspacePath,
              password: sshPassword,
              privateKeyPem: sshPrivateKey,
              onTrustFirstKey: onTrustFirstKey,
            );
            return (ok: true, output: out);
          }
          final entries =
              await RuntimeBridge.instance.listWorkspaceEntries(path);
          final text = entries
              .map((e) => '${e['type'] == 'dir' ? '[dir]' : '     '} ${e['name']} (${e['size']})')
              .join('\n');
          return (ok: true, output: text.isEmpty ? '(empty directory)' : text);

        default:
          return (ok: false, output: 'Unknown tool: $name');
      }
    } catch (e) {
      return (ok: false, output: 'Tool error: $e');
    }
  }
}
