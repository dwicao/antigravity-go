import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/remote/openai_compat_runner.dart';
import 'package:antigravity_go/state/chat_state.dart';
import 'package:antigravity_go/state/custom_providers_state.dart';
import 'package:antigravity_go/state/harness_state.dart';
import 'package:antigravity_go/ui/remote/custom_providers_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class _QueuedHttpClient extends http.BaseClient {
  _QueuedHttpClient(this._responder);

  final Future<http.StreamedResponse> Function(http.BaseRequest req, String body)
      _responder;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    return _responder(request, utf8.decode(bodyBytes));
  }
}

http.StreamedResponse _sseResponse(List<String> payloads) {
  final sseText = payloads.map((p) => 'data: $p\n\n').join();
  final stream = Stream<List<int>>.fromIterable([utf8.encode(sseText)]);
  return http.StreamedResponse(
    stream,
    200,
    headers: const {'content-type': 'text/event-stream'},
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomProvidersNotifier add, activate, read key, select null, and remove', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(customProvidersProvider.notifier);
    final saved = await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: '',
        name: 'Local Ollama',
        baseUrl: 'http://127.0.0.1:11434/',
        modelId: 'qwen2.5-coder:14b',
        contextWindowTokens: 131072,
      ),
      apiKey: 'test-key-123',
      activate: true,
    );

    expect(saved.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(container.read(activeCustomProviderProvider)?.id, saved.id);
    expect(await notifier.readApiKey(saved.id), 'test-key-123');

    await notifier.selectProvider(null);
    expect(container.read(activeCustomProviderProvider), isNull);

    await notifier.selectProvider(saved.id);
    expect(container.read(activeCustomProviderProvider)?.modelId, 'qwen2.5-coder:14b');

    await notifier.removeProfile(saved.id);
    expect(container.read(customProvidersProvider).profiles, isEmpty);
    expect(container.read(activeCustomProviderProvider), isNull);
  });

  test('contextBudgetProvider respects custom provider contextWindowTokens', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(customProvidersProvider.notifier);
    await notifier.addOrUpdateProfile(
      const OpenAiProviderConfig(
        id: 'p-custom-ctx',
        name: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com/v1',
        modelId: 'deepseek-chat',
        contextWindowTokens: 256000,
      ),
      activate: true,
    );

    final snap = container.read(contextBudgetProvider);
    expect(snap.budgetTokens, 256000);
  });

  test('ChatMessageStore.delete removes persisted session history cleanly', () async {
    final msg = ChatMessage(
      id: 'm-del-1',
      role: ChatRole.user,
      text: 'Temporary prompt',
      createdAt: DateTime(2026, 11, 23, 20, 0),
    );
    await ChatMessageStore.instance.save('sess-del-1', [msg]);
    expect(await ChatMessageStore.instance.load('sess-del-1'), hasLength(1));

    await ChatMessageStore.instance.delete('sess-del-1');
    expect(await ChatMessageStore.instance.load('sess-del-1'), isEmpty);
  });

  testWidgets('CustomProvidersPage renders on narrow 320px phone viewport without overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: CustomProvidersPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('External /v1 Models'), findsOneWidget);
    expect(find.text('Antigravity CLI (Built-in)'), findsOneWidget);
    expect(find.text('OpenAI'), findsOneWidget);
    expect(find.text('Ollama (Local)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('HarnessNotifier persists toolVariablesEnabled toggle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(harnessProvider).toolVariablesEnabled, isTrue);
    await container.read(harnessProvider.notifier).setToolVariablesEnabled(false);
    expect(container.read(harnessProvider).toolVariablesEnabled, isFalse);

    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    reloaded.read(harnessProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(reloaded.read(harnessProvider).toolVariablesEnabled, isFalse);
  });

  test('OpenAiCompatRunner saves large tool outputs as \$vars, resolves tool args, fans out subagents, and expands streamed text', () async {
    final hugeRows = List.generate(
      150,
      (i) => {'id': 'u_$i', 'visited': '2026-11-27', 'duration': 100 + i},
    );
    final hugeJson = jsonEncode(hugeRows);
    String? writtenContent;
    final subagentContexts = <String>[];
    var requestTurn = 0;

    final fakeClient = _QueuedHttpClient((req, body) async {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final msgs = (decoded['messages'] as List).cast<Map<String, dynamic>>();
      final userPrompt = msgs.last['content']?.toString() ?? '';

      // Subagent HTTP turns (contain "focused subagent")
      final sysMsg = msgs.first['content']?.toString() ?? '';
      if (sysMsg.contains('focused subagent')) {
        subagentContexts.add(userPrompt);
        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {'content': 'Verified ${hugeRows.length} rows'},
                'finish_reason': 'stop',
              },
            ],
          }),
          '[DONE]',
        ]);
      }

      requestTurn++;
      if (requestTurn == 1) {
        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_query',
                      'type': 'function',
                      'function': {
                        'name': 'run_command',
                        'arguments': jsonEncode({
                          'command': 'query_visits',
                          'save_as': 'weekly_visits',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': 'tool_calls'},
            ],
          }),
          '[DONE]',
        ]);
      }

      if (requestTurn == 2) {
        // Confirm the tool message given to the LLM was compact (< 1400 chars), not 7000+ chars
        final toolMsg = msgs.lastWhere((m) => m['role'] == 'tool');
        final contentStr = toolMsg['content']?.toString() ?? '';
        expect(contentStr.length, lessThan(1400));
        expect(contentStr, contains('[VAR STORED: \$weekly_visits'));

        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_write',
                      'type': 'function',
                      'function': {
                        'name': 'write_file',
                        'arguments': jsonEncode({
                          'path': 'export.json',
                          'content': r'$weekly_visits',
                        }),
                      },
                    },
                    {
                      'index': 1,
                      'id': 'call_sub_1',
                      'type': 'function',
                      'function': {
                        'name': 'delegate_subagent',
                        'arguments': jsonEncode({
                          'role': 'Cohort Analyst A',
                          'task': 'Count records',
                          'context': r'$weekly_visits',
                        }),
                      },
                    },
                    {
                      'index': 2,
                      'id': 'call_sub_2',
                      'type': 'function',
                      'function': {
                        'name': 'delegate_subagent',
                        'arguments': jsonEncode({
                          'role': 'Cohort Analyst B',
                          'task': 'Audit first row',
                          'context': r'${weekly_visits[0].id}',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': 'tool_calls'},
            ],
          }),
          '[DONE]',
        ]);
      }

      return _sseResponse([
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Saved count: '},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'content': r'$weekly_vi'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'sits.length, first='},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'delta': {'content': r'${weekly_visits[0].id}.'},
              'finish_reason': 'stop',
            },
          ],
        }),
        '[DONE]',
      ]);
    });

    final store = ToolVariableStore();
    final streamedText = StringBuffer();
    AgyTurnResultEvent? resultEvt;

    await for (final evt in OpenAiCompatRunner.instance.runPrompt(
      profile: const OpenAiProviderConfig(
        id: 'mock',
        name: 'Mock OpenAI',
        baseUrl: 'https://mock.local/v1',
        modelId: 'gpt-4o-mini',
      ),
      apiKey: 'k',
      turnId: 'turn-var-test',
      prompt: 'Export and analyze cohort',
      workspacePath: '/tmp/ws',
      dangerouslySkipPermissions: true,
      variableStore: store,
      httpClient: fakeClient,
      toolExecutorOverride: (name, args) async {
        if (name == 'run_command') {
          return (ok: true, output: hugeJson);
        }
        if (name == 'write_file') {
          writtenContent = args['content']?.toString();
          return (ok: true, output: 'Wrote export.json');
        }
        if (name == 'delegate_subagent') {
          subagentContexts.add(args['context']?.toString() ?? '');
          return (ok: true, output: 'OK from ${args['role']}');
        }
        return (ok: false, output: 'Unexpected $name');
      },
    )) {
      if (evt is AgyTextDeltaEvent) {
        streamedText.write(evt.delta);
      } else if (evt is AgyTurnResultEvent) {
        resultEvt = evt;
      }
    }

    expect(writtenContent, hugeJson);
    expect(subagentContexts, hasLength(2));
    expect(subagentContexts[0], hugeJson);
    expect(subagentContexts[1], 'u_0');
    expect(streamedText.toString(), 'Saved count: 150, first=u_0.');
    expect(resultEvt?.response, 'Saved count: 150, first=u_0.');
    expect(store.savedOutputChars, greaterThan(5000));
  });

  test('OpenAiCompatRunner.trimHistoryForBudget caps older turns and total chars', () {
    final longOld = 'X' * 5000;
    final longRecent = 'Y' * 8000;
    final history = [
      (role: 'user', text: 'first prompt $longOld'),
      (role: 'assistant', text: 'first reply $longOld'),
      (role: 'user', text: 'latest prompt'),
      (role: 'assistant', text: 'latest reply $longRecent'),
    ];
    final trimmed = OpenAiCompatRunner.trimHistoryForBudget(
      history,
      quotaSaverEnabled: true,
      contextWindowTokens: 128000,
    );
    expect(trimmed, isNotEmpty);
    final total = trimmed.fold<int>(0, (s, m) => s + m['content']!.length);
    expect(total, lessThanOrEqualTo(20000));
    expect(trimmed.first['content'], contains('[trimmed in history]'));
    expect(trimmed.last['content']!.length, lessThanOrEqualTo(6050));
  });

  test('OpenAiCompatRunner preserves static system prompt, injects tail vars note, and folds older tool outputs', () async {
    final sysPromptsSeen = <String>[];
    final userMsgsSeen = <String>[];
    String? fourthRoundFirstToolMsg;
    var reqCount = 0;

    final fakeClient = _QueuedHttpClient((req, body) async {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final msgs = (decoded['messages'] as List).cast<Map<String, dynamic>>();
      sysPromptsSeen.add(msgs.first['content']?.toString() ?? '');
      userMsgsSeen.add(
        msgs.firstWhere((m) => m['role'] == 'user')['content']?.toString() ?? '',
      );
      reqCount++;
      if (reqCount <= 3) {
        return _sseResponse([
          jsonEncode({
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'c_$reqCount',
                      'type': 'function',
                      'function': {
                        'name': 'read_file',
                        'arguments': jsonEncode({
                          'path': 'file_$reqCount.txt',
                          'save_as': 'f_$reqCount',
                        }),
                      },
                    },
                  ],
                },
              },
            ],
          }),
          jsonEncode({
            'choices': [
              {'delta': {}, 'finish_reason': 'tool_calls'},
            ],
          }),
          '[DONE]',
        ]);
      }
      if (reqCount == 4) {
        final toolMsgs = msgs.where((m) => m['role'] == 'tool').toList();
        fourthRoundFirstToolMsg = toolMsgs.first['content']?.toString();
      }
      return _sseResponse([
        jsonEncode({
          'choices': [
            {
              'delta': {'content': 'Done'},
              'finish_reason': 'stop',
            },
          ],
        }),
        '[DONE]',
      ]);
    });

    final store = ToolVariableStore();
    store.save(
      toolName: 'run_command',
      explicitName: 'seed_var',
      rawOutput: 'seed data',
    );
    final hugeChunk = List.generate(300, (i) => 'row_$i=val_$i').join('\n');

    await OpenAiCompatRunner.instance
        .runPrompt(
          profile: const OpenAiProviderConfig(
            id: 'local',
            name: 'Local',
            baseUrl: 'http://127.0.0.1:11434/v1',
            modelId: 'qwen',
          ),
          apiKey: '',
          turnId: 'turn-fold',
          prompt: 'Inspect multiple files ${'P' * 18500}',
          workspacePath: '/tmp',
          dangerouslySkipPermissions: true,
          quotaSaverEnabled: true,
          variableStore: store,
          httpClient: fakeClient,
          toolExecutorOverride: (name, args) async {
            return (ok: true, output: 'X' * 9000 + hugeChunk);
          },
        )
        .drain<void>();

    expect(sysPromptsSeen.toSet(), hasLength(1));
    expect(sysPromptsSeen.first, isNot(contains('seed_var')));
    expect(userMsgsSeen.first, contains(r'$seed_var'));
    expect(fourthRoundFirstToolMsg, startsWith('[older tool result collapsed'));
  });
}
