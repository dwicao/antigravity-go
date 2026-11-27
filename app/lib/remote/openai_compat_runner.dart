import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
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
/// permission gating, pass-by-reference tool output variables (`$v_*`), and an
/// agentic tool loop (`run_command`, `read_file`, `write_file`, `list_dir`,
/// `inspect_var`, `delegate_subagent`) against either the local Android
/// workspace or an SSH host.
class OpenAiCompatRunner {
  OpenAiCompatRunner._();
  static final OpenAiCompatRunner instance = OpenAiCompatRunner._();

  final Map<String, _TurnControl> _activeTurns = {};
  int _nextReqId = 1000;

  static const int _maxToolRounds = 16;

  static List<Map<String, dynamic>> _toolDefinitions({
    bool includeVariables = true,
    bool includeSubagent = true,
  }) =>
      [
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
                if (includeVariables)
                  'stdin': {
                    'type': 'string',
                    'description':
                        'Optional stdin payload (can reference \$var directly, e.g. "\$v_cmd_1")',
                  },
                if (includeVariables)
                  'save_as': {
                    'type': 'string',
                    'description': 'Optional custom variable name to store output',
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
                if (includeVariables)
                  'save_as': {
                    'type': 'string',
                    'description': 'Optional custom variable name to store file content',
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
            'description':
                'Write full text content to a file (creating parent directories if needed).',
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {
                  'type': 'string',
                  'description': 'Destination file path',
                },
                'content': {
                  'type': 'string',
                  'description':
                      'Complete text content to write (can reference \$var variables directly)',
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
                if (includeVariables)
                  'save_as': {
                    'type': 'string',
                    'description': 'Optional custom variable name',
                  },
              },
            },
          },
        },
        if (includeVariables)
          {
            'type': 'function',
            'function': {
              'name': 'inspect_var',
              'description':
                  'Inspect a line slice, JSON field/path, or regex grep on a stored \$v_* variable without loading all data into context.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'name': {
                    'type': 'string',
                    'description':
                        'Variable name or path expression (e.g. "\$v_cmd_1", "\$v_cmd_1.items[0]")',
                  },
                  'start_line': {
                    'type': 'integer',
                    'description': '1-based start line for text slicing',
                  },
                  'limit': {
                    'type': 'integer',
                    'description': 'Max lines to return (default 120)',
                  },
                  'grep': {
                    'type': 'string',
                    'description': 'Optional case-insensitive regex filter',
                  },
                },
                'required': ['name'],
              },
            },
          },
        if (includeSubagent)
          {
            'type': 'function',
            'function': {
              'name': 'delegate_subagent',
              'description':
                  'Run a focused subagent task (parallelizable in batches). Pass large docs/data via \$v_* variable references.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'role': {
                    'type': 'string',
                    'description': 'Short role name (e.g. "Security Auditor")',
                  },
                  'task': {
                    'type': 'string',
                    'description': 'Specific objective for this subagent',
                  },
                  'context': {
                    'type': 'string',
                    'description':
                        'Optional large payload or \$v_* variable reference passed to subagent',
                  },
                  if (includeVariables)
                    'save_as': {
                      'type': 'string',
                      'description': 'Optional variable name for subagent output',
                    },
                },
                'required': ['role', 'task'],
              },
            },
          },
        {
          'type': 'function',
          'function': {
            'name': 'search_files',
            'description':
                'Search text/regex pattern across project source files (ignores .git, build, node_modules).',
            'parameters': {
              'type': 'object',
              'properties': {
                'pattern': {
                  'type': 'string',
                  'description': 'Regex or literal pattern to search for',
                },
                'path': {
                  'type': 'string',
                  'description': 'Optional subdirectory or file path (defaults to workspace root)',
                },
                if (includeVariables)
                  'save_as': {
                    'type': 'string',
                    'description': 'Optional variable name to store matches',
                  },
              },
              'required': ['pattern'],
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

  @visibleForTesting
  static List<Map<String, String>> trimHistoryForBudget(
    List<({String role, String text})> history, {
    bool quotaSaverEnabled = false,
    int contextWindowTokens = 128000,
  }) {
    if (history.isEmpty) return const [];
    final nonEmpty = history.where((h) => h.text.trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) return const [];

    final maxTurns = nonEmpty.length > 24
        ? nonEmpty.sublist(nonEmpty.length - 24)
        : nonEmpty;
    final defaultBudget = quotaSaverEnabled ? 20000 : 48000;
    final budgetChars = math.min(
      defaultBudget,
      math.max(4000, contextWindowTokens * 2),
    );

    final reversedOut = <Map<String, String>>[];
    var usedChars = 0;
    for (var i = maxTurns.length - 1; i >= 0; i--) {
      final h = maxTurns[i];
      final distanceFromEnd = maxTurns.length - 1 - i;
      final perMsgCap = distanceFromEnd < 2 ? 6000 : 1200;
      var text = h.text.trim();
      if (text.length > perMsgCap) {
        text = '${text.substring(0, perMsgCap)}\n...[trimmed in history]';
      }
      if (reversedOut.isNotEmpty && usedChars + text.length > budgetChars) {
        break;
      }
      reversedOut.add({
        'role': h.role == 'assistant' ? 'assistant' : 'user',
        'content': text,
      });
      usedChars += text.length;
    }
    return reversedOut.reversed.toList();
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
    ToolVariableStore? variableStore,
    bool toolVariablesEnabled = true,
    bool quotaSaverEnabled = false,
    bool allowSubagentDelegation = true,
    http.Client? httpClient,
    Future<({bool ok, String output})> Function(
      String name,
      Map<String, dynamic> args,
    )? toolExecutorOverride,
  }) async* {
    final ctrl = _TurnControl();
    _activeTurns[turnId]?.cancel();
    _activeTurns[turnId] = ctrl;
    final startedAt = DateTime.now();
    final ownsHttpClient = httpClient == null;
    final client = httpClient ?? http.Client();
    ctrl.client = ownsHttpClient ? client : null;
    final varStore = variableStore ??
        ToolVariableStore(
          enabled: toolVariablesEnabled,
          inlineThresholdChars: quotaSaverEnabled ? 900 : 1200,
        );
    varStore.enabled = toolVariablesEnabled;

    try {
      final ws = workspacePath.trim();
      final sysParts = <String>[
        'You are Antigravity running inside Antigravity Go.',
        if (ws.isNotEmpty) 'Active workspace directory: $ws',
        if (quotaSaverEnabled)
          'Be concise; omit filler and redundant code restatements.',
        if (profile.supportsTools)
          'You have tools (`run_command`, `read_file`, `write_file`, `list_dir`, `search_files`'
              '${toolVariablesEnabled ? ', `inspect_var`' : ''}'
              '${allowSubagentDelegation ? ', `delegate_subagent`' : ''}'
              ') to inspect, search, and edit files.',
        if (profile.supportsTools && toolVariablesEnabled)
          varStore.systemPromptInstructions(
            hasSubagentTool: allowSubagentDelegation,
          ),
        if (systemInstructions.trim().isNotEmpty) systemInstructions.trim(),
        if (profile.systemPrompt.trim().isNotEmpty) profile.systemPrompt.trim(),
      ];

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': sysParts.join('\n')},
        ...trimHistoryForBudget(
          history,
          quotaSaverEnabled: quotaSaverEnabled,
          contextWindowTokens: profile.contextWindowTokens,
        ),
      ];
      final varsTail = (profile.supportsTools && toolVariablesEnabled)
          ? varStore.dynamicVarsContextNote()
          : '';
      final promptWithVarsTail =
          varsTail.isNotEmpty ? '$prompt\n\n$varsTail' : prompt;
      final userContent = await _buildUserContent(
        prompt: promptWithVarsTail,
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
      final toolMsgMeta =
          <({int msgIndex, int round, String? varName, int rawChars})>[];

      for (var round = 0; round < _maxToolRounds; round++) {
        if (ctrl.cancelled) break;

        if (round >= 3 && toolMsgMeta.isNotEmpty) {
          final totalChars = messages.fold<int>(
            0,
            (sum, m) => sum + (m['content']?.toString().length ?? 0),
          );
          final foldLimit =
              (profile.isLocalEndpoint || quotaSaverEnabled) ? 20000 : 64000;
          if (totalChars > foldLimit) {
            for (final meta in toolMsgMeta) {
              if (meta.round < round - 2 && meta.rawChars > 360) {
                final cur = messages[meta.msgIndex]['content']?.toString() ?? '';
                if (!cur.startsWith('[older tool result collapsed')) {
                  final refNote = meta.varName != null
                      ? ' -> stored in \$${meta.varName} (use inspect_var)'
                      : '';
                  messages[meta.msgIndex] = {
                    ...messages[meta.msgIndex],
                    'content':
                        '[older tool result collapsed (${meta.rawChars} chars)$refNote]',
                  };
                }
              }
            }
          }
        }

        final bodyMap = <String, dynamic>{
          'model': profile.modelId,
          'messages': messages,
          'stream': true,
          if (includeStreamOptions)
            'stream_options': const {'include_usage': true},
          if (profile.supportsTools)
            'tools': _toolDefinitions(
              includeVariables: toolVariablesEnabled,
              includeSubagent: allowSubagentDelegation,
            ),
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
        final textExpander = StreamingVariableExpander(varStore);
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
              final expanded = textExpander.addDelta(slice.textDelta);
              if (expanded.isNotEmpty) {
                fullResponse.write(expanded);
                yield AgyTextDeltaEvent(delta: expanded);
              }
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
              final expanded = textExpander.addDelta(slice.textDelta);
              if (expanded.isNotEmpty) {
                fullResponse.write(expanded);
                yield AgyTextDeltaEvent(
                  delta: expanded,
                  stepUsage: slice.usage,
                );
              }
            }
          }
          final tail = parser.flushPendingTags();
          if (tail.thought.isNotEmpty) {
            yield AgyThoughtDeltaEvent(delta: tail.thought);
          }
          if (tail.text.isNotEmpty) {
            roundText.write(tail.text);
            final expandedTail = textExpander.addDelta(tail.text);
            if (expandedTail.isNotEmpty) {
              fullResponse.write(expandedTail);
              yield AgyTextDeltaEvent(delta: expandedTail);
            }
          }
        }

        final flushedText = textExpander.flush();
        if (flushedText.isNotEmpty) {
          fullResponse.write(flushedText);
          yield AgyTextDeltaEvent(delta: flushedText);
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

        final preparedCalls = <({
          String callId,
          String name,
          Map<String, dynamic> displayArgs,
          Map<String, dynamic> resolvedArgs,
          bool needsApproval,
        })>[];

        for (final tc in pendingTools) {
          final callId =
              tc.id.isNotEmpty ? tc.id : 'call_${tc.index}_$round';
          final rawArgs = tc.parseArgumentsMap();
          final resolvedArgs = toolVariablesEnabled
              ? varStore.resolveArguments(rawArgs)
              : rawArgs;
          final needsApproval = !dangerouslySkipPermissions &&
              (tc.name == 'run_command' || tc.name == 'write_file');
          preparedCalls.add((
            callId: callId,
            name: tc.name,
            displayArgs: rawArgs,
            resolvedArgs: resolvedArgs,
            needsApproval: needsApproval,
          ));
          yield AgyToolCallEvent(
            callId: callId,
            toolName: tc.name,
            state: ToolCallState.running,
            parameters: rawArgs,
          );
        }

        Future<({bool ok, String output, double durationSeconds})> runPrepared(
          ({
            String callId,
            String name,
            Map<String, dynamic> displayArgs,
            Map<String, dynamic> resolvedArgs,
            bool needsApproval,
          }) call,
        ) async {
          if (ctrl.cancelled) {
            return (ok: false, output: 'Cancelled', durationSeconds: 0.0);
          }
          final tStart = DateTime.now();
          final exec = toolExecutorOverride != null
              ? await toolExecutorOverride(call.name, call.resolvedArgs)
              : await _executeTool(
                  name: call.name,
                  args: call.resolvedArgs,
                  workspacePath: ws,
                  profile: profile,
                  apiKey: apiKey,
                  dangerouslySkipPermissions: dangerouslySkipPermissions,
                  varStore: varStore,
                  sshHost: sshHost,
                  sshPassword: sshPassword,
                  sshPrivateKey: sshPrivateKey,
                  onTrustFirstKey: onTrustFirstKey,
                  httpClient: ownsHttpClient ? null : client,
                );
          return (
            ok: exec.ok,
            output: exec.output,
            durationSeconds:
                DateTime.now().difference(tStart).inMilliseconds / 1000.0,
          );
        }

        final anyNeedsApproval = preparedCalls.any((c) => c.needsApproval);
        final List<({bool ok, String output, double durationSeconds})> results;

        if (!anyNeedsApproval && preparedCalls.length > 1) {
          // Execute independent read/inspect/subagent batch concurrently.
          results = await Future.wait([
            for (final c in preparedCalls) runPrepared(c),
          ]);
        } else {
          results = [];
          for (final c in preparedCalls) {
            if (ctrl.cancelled) break;
            if (c.needsApproval) {
              final tStart = DateTime.now();
              final reqId = 'perm-${_nextReqId++}';
              final completer = Completer<String?>();
              ctrl.pendingPermissions[reqId] = completer;
              yield AgyPermissionRequestEvent(
                requestId: reqId,
                toolName: c.name,
                title: c.name == 'run_command'
                    ? 'Approve shell command'
                    : 'Approve file write',
                commandOrPath: (c.resolvedArgs['command'] ??
                        c.resolvedArgs['path'] ??
                        '')
                    .toString(),
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
              if (ctrl.cancelled) break;
              final approved = choice != null && !choice.startsWith('reject');
              if (!approved) {
                results.add((
                  ok: false,
                  output: 'Permission denied by user.',
                  durationSeconds:
                      DateTime.now().difference(tStart).inMilliseconds / 1000.0,
                ));
                continue;
              }
              final exec = toolExecutorOverride != null
                  ? await toolExecutorOverride(c.name, c.resolvedArgs)
                  : await _executeTool(
                      name: c.name,
                      args: c.resolvedArgs,
                      workspacePath: ws,
                      profile: profile,
                      apiKey: apiKey,
                      dangerouslySkipPermissions: dangerouslySkipPermissions,
                      varStore: varStore,
                      sshHost: sshHost,
                      sshPassword: sshPassword,
                      sshPrivateKey: sshPrivateKey,
                      onTrustFirstKey: onTrustFirstKey,
                      httpClient: ownsHttpClient ? null : client,
                    );
              results.add((
                ok: exec.ok,
                output: exec.output,
                durationSeconds:
                    DateTime.now().difference(tStart).inMilliseconds / 1000.0,
              ));
            } else {
              results.add(await runPrepared(c));
            }
          }
        }

        for (var i = 0; i < preparedCalls.length && i < results.length; i++) {
          final call = preparedCalls[i];
          final res = results[i];
          final saveAs = call.displayArgs['save_as']?.toString().trim();
          var messageContent = res.output;
          var displayOutput = res.output;
          String? savedVarName;

          if (toolVariablesEnabled &&
              res.ok &&
              call.name != 'inspect_var' &&
              call.name != 'write_file') {
            final target = (call.resolvedArgs['path'] ??
                    call.resolvedArgs['pattern'] ??
                    call.resolvedArgs['command'] ??
                    call.resolvedArgs['role'] ??
                    '')
                .toString();
            final entry = varStore.save(
              toolName: call.name,
              target: target,
              rawOutput: res.output,
              explicitName: (saveAs != null && saveAs.isNotEmpty) ? saveAs : null,
            );
            savedVarName = entry.name;
            messageContent = varStore.formatToolResponse(
              entry,
              previewHead: quotaSaverEnabled ? 320 : 450,
              previewTail: quotaSaverEnabled ? 200 : 300,
            );
            displayOutput =
                '[var: \$${entry.name} · ${entry.summary}]\n${res.output}';
          } else if (messageContent.length > 24000) {
            messageContent =
                '${messageContent.substring(0, 24000)}\n...[truncated]';
          }

          yield AgyToolCallEvent(
            callId: call.callId,
            toolName: call.name,
            state: res.ok ? ToolCallState.completed : ToolCallState.failed,
            parameters: call.displayArgs,
            output: res.ok ? displayOutput : null,
            errorMessage: res.ok ? null : res.output,
            durationSeconds: res.durationSeconds,
          );

          final msgIdx = messages.length;
          messages.add({
            'role': 'tool',
            'tool_call_id': call.callId,
            'content': messageContent,
          });
          toolMsgMeta.add((
            msgIndex: msgIdx,
            round: round,
            varName: savedVarName,
            rawChars: messageContent.length,
          ));
        }
      }

      if (ctrl.cancelled) return;
      final durationSec =
          DateTime.now().difference(startedAt).inMilliseconds / 1000.0;
      final uncachedIn =
          totalCache > 0 && totalIn >= totalCache ? totalIn - totalCache : totalIn;
      yield AgyTurnResultEvent(
        conversationId: '',
        status: 'SUCCESS',
        response: fullResponse.toString(),
        durationSeconds: durationSec,
        usage: TokenUsage(
          inputTokens: uncachedIn,
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
    required OpenAiProviderConfig profile,
    required String? apiKey,
    required bool dangerouslySkipPermissions,
    required ToolVariableStore varStore,
    SshHostConfig? sshHost,
    String? sshPassword,
    String? sshPrivateKey,
    FutureOr<void> Function(String fp)? onTrustFirstKey,
    http.Client? httpClient,
  }) async {
    try {
      switch (name) {
        case 'search_files':
          final pattern = (args['pattern'] ?? '').toString().trim();
          if (pattern.isEmpty) {
            return (ok: false, output: 'Empty search pattern');
          }
          final rawPath = (args['path'] ?? '').toString().trim();
          final targetPath = rawPath.isEmpty
              ? (workspacePath.isEmpty ? '.' : workspacePath)
              : _resolvePath(rawPath, workspacePath);
          final qPattern = "'${pattern.replaceAll("'", "'\\''")}'";
          final qPath = "'${targetPath.replaceAll("'", "'\\''")}'";
          final grepCmd =
              'grep -rnI --exclude-dir=.git --exclude-dir=.dart_tool --exclude-dir=build --exclude-dir=node_modules --exclude-dir=.gradle -e $qPattern $qPath 2>/dev/null | head -n 120';
          final out = sshHost != null
              ? await SshAgyRunner.instance.runRemoteCommand(
                  host: sshHost,
                  command: grepCmd,
                  cwd: workspacePath,
                  password: sshPassword,
                  privateKeyPem: sshPrivateKey,
                  onTrustFirstKey: onTrustFirstKey,
                )
              : await RuntimeBridge.instance.runShellCommand(
                  command: grepCmd,
                  cwd: workspacePath.isEmpty ? null : workspacePath,
                );
          return (
            ok: true,
            output: out.trim().isEmpty ? '(no matches for /$pattern/)' : out.trim(),
          );

        case 'inspect_var':
          final varName = (args['name'] ?? '').toString().trim();
          if (varName.isEmpty) {
            return (ok: false, output: 'Missing variable name');
          }
          final startLine = (args['start_line'] as num?)?.toInt();
          final limit = (args['limit'] as num?)?.toInt();
          final grep = args['grep']?.toString();
          return (
            ok: true,
            output: varStore.inspect(
              varName,
              startLine: startLine,
              limit: limit,
              grep: grep,
            ),
          );

        case 'delegate_subagent':
          final role = (args['role'] ?? 'Subagent').toString().trim();
          final task = (args['task'] ?? '').toString().trim();
          final ctx = (args['context'] ?? '').toString().trim();
          if (task.isEmpty) {
            return (ok: false, output: 'Subagent task cannot be empty');
          }
          final subPrompt = ctx.isEmpty ? task : '$task\n\n[Context]\n$ctx';
          final subOut = StringBuffer();
          String? subErr;
          await for (final evt in runPrompt(
            profile: profile,
            apiKey: apiKey,
            turnId: 'sub-${_nextReqId++}',
            prompt: subPrompt,
            workspacePath: workspacePath,
            dangerouslySkipPermissions: dangerouslySkipPermissions,
            systemInstructions:
                'You are a focused subagent playing role "$role". '
                'Complete the assigned task concisely and return only verified findings/results.',
            variableStore: varStore,
            toolVariablesEnabled: varStore.enabled,
            allowSubagentDelegation: false,
            sshHost: sshHost,
            sshPassword: sshPassword,
            sshPrivateKey: sshPrivateKey,
            onTrustFirstKey: onTrustFirstKey,
            httpClient: httpClient,
          )) {
            if (evt is AgyTextDeltaEvent) {
              subOut.write(evt.delta);
            } else if (evt is AgyErrorEvent) {
              subErr = evt.message;
            }
          }
          if (subErr != null && subOut.isEmpty) {
            return (ok: false, output: 'Subagent [$role] error: $subErr');
          }
          final finalSub = subOut.toString().trim();
          return (
            ok: true,
            output: finalSub.isEmpty ? '(subagent returned no text)' : finalSub,
          );

        case 'run_command':
          var cmd = (args['command'] ?? '').toString().trim();
          if (cmd.isEmpty) return (ok: false, output: 'Empty command');
          final stdinPayload = args['stdin']?.toString();
          if (stdinPayload != null && stdinPayload.isNotEmpty) {
            final b64 = base64Encode(utf8.encode(stdinPayload));
            cmd = 'printf %s "$b64" | base64 -d | ( $cmd )';
          }
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
