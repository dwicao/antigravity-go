import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/ci_watch_state.dart';
import 'package:antigravity_go/state/rsi_loop_state.dart';
import 'package:antigravity_go/ui/chat/rsi_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _buildProbe({
  required String branch,
  required String sha,
  required String originUrl,
  required String hasGh,
  String? appPubspecVersion,
  String? packageJsonVersion,
  String? pyprojectVersion,
  String workflows = '',
  bool hasSync = false,
}) {
  return '''
===RSI:BRANCH===
$branch
===RSI:HEAD_SHA===
$sha
===RSI:ORIGIN_URL===
$originUrl
===RSI:HAS_GH===
$hasGh
===RSI:LATEST_TAG===
===RSI:HAS_SYNC===
${hasSync ? '1' : '0'}
===RSI:HAS_GOMOD===
0
===RSI:HAS_GRADLEW===
0
===RSI:APP_PUBSPEC===
${appPubspecVersion != null ? 'name: antigravity_go\nversion: $appPubspecVersion+1\n' : ''}
===RSI:ROOT_PUBSPEC===
===RSI:PACKAGE_JSON===
${packageJsonVersion != null ? '{"name":"webapp","version":"$packageJsonVersion"}\n' : ''}
===RSI:CARGO_TOML===
===RSI:PYPROJECT_TOML===
${pyprojectVersion != null ? '[project]\nname = "svc"\nversion = "$pyprojectVersion"\n' : ''}
===RSI:WORKFLOWS===
$workflows
''';
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('RsiLoopNotifier orchestrates propose -> CI fail -> self-heal -> CI green -> APK release -> next gen', () async {
    var currentSha = 'aaaa1111';
    var currentVersion = '1.0.59';
    final sentPrompts = <String>[];
    final feedbackLogs = <String>[];
    final pushedTags = <String>[];

    final ciRuns = <Map<String, dynamic>>[];
    final ciNotifier = CiWatchNotifier()
      ..shellRunnerOverride = (cmd, cwd) async {
        if (cmd.contains('gh run list')) {
          return jsonEncode(ciRuns);
        }
        if (cmd.contains('--log-failed')) {
          return 'dart test failed in rsi_engine_test.dart';
        }
        return '{}';
      };

    final rsiNotifier = RsiLoopNotifier()
      ..shellRunnerOverride = (cmd, cwd) async {
        if (cmd.contains('--is-inside-work-tree')) return 'true';
        if (cmd.contains('===RSI:BRANCH===')) {
          return _buildProbe(
            branch: 'main',
            sha: currentSha,
            originUrl: 'https://github.com/dwicao/antigravity-go.git',
            hasGh: '1',
            hasSync: true,
            appPubspecVersion: currentVersion,
            workflows: '''
---WF_FILE:.github/workflows/ci.yml
name: CI
on: [push]
---WF_FILE:.github/workflows/release-apk.yml
name: Release APK (AOSP release key)
on:
  push:
    tags:
      - 'v*'
''',
          );
        }
        if (cmd.contains('git rev-parse HEAD')) return currentSha;
        if (cmd.contains('git rev-parse "origin/main"')) return currentSha;
        if (cmd.contains('git status --porcelain')) return '';
        if (cmd.contains('git tag')) {
          pushedTags.add(cmd);
          return '';
        }
        if (cmd.contains('push origin')) {
          if (cmd.contains('v1.0.60')) {
            ciRuns.insert(0, {
              'databaseId': 2001,
              'workflowName': 'Release APK (AOSP release key)',
              'status': 'completed',
              'conclusion': 'success',
              'url': 'https://github.com/o/r/actions/runs/2001',
              'headBranch': 'v1.0.60',
              'headSha': 'bbbb2222b',
            });
          } else if (cmd.contains('v1.0.61')) {
            ciRuns.insert(0, {
              'databaseId': 2002,
              'workflowName': 'Release APK (AOSP release key)',
              'status': 'completed',
              'conclusion': 'success',
              'url': 'https://github.com/o/r/actions/runs/2002',
              'headBranch': 'v1.0.61',
              'headSha': 'cccc3333',
            });
          }
          return 'PUSH_OK';
        }
        if (cmd.contains('gh release view')) {
          return '{"url":"https://github.com/o/r/releases/tag/v$currentVersion","assets":[{"name":"antigravity-go-$currentVersion-arm64.apk"}]}';
        }
        return '';
      }
      ..feedbackOverride = (md, {sessionId}) async {
        feedbackLogs.add(md);
      }
      ..sendPromptOverride = (prompt, {sessionId}) async {
        sentPrompts.add(prompt);
      };

    final container = ProviderContainer(
      overrides: [
        ciWatchProvider.overrideWith(() => ciNotifier),
        rsiLoopProvider.overrideWith(() => rsiNotifier),
      ],
    );
    addTearDown(container.dispose);

    final started = await container.read(rsiLoopProvider.notifier).start(
          sessionId: 'sess-rsi',
          cwd: '/tmp/repo',
          config: const RsiConfig(
            objective: 'Improve test coverage',
            maxGenerations: 2,
            maxCiFixAttemptsPerGen: 1,
            releaseMode: RsiReleaseMode.auto,
          ),
        );
    expect(started, isTrue);
    expect(sentPrompts, hasLength(1));
    expect(sentPrompts.first, contains('Generation 1/2'));
    expect(container.read(rsiLoopProvider).phase, RsiPhase.proposing);

    // Gen 1 proposer commits & pushes bbbb2222 (1.0.60); CI #1 fails -> self-heal triggers!
    currentSha = 'bbbb2222';
    currentVersion = '1.0.60';
    ciRuns.insert(0, {
      'databaseId': 1001,
      'workflowName': 'CI',
      'status': 'completed',
      'conclusion': 'failure',
      'url': 'https://github.com/o/r/actions/runs/1001',
      'headBranch': 'main',
      'headSha': 'bbbb2222',
    });
    await container.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 'sess-rsi',
          assistantText: 'RSI_SUMMARY: Improved test coverage for v1.0.60',
        );
    expect(sentPrompts, hasLength(2));
    expect(sentPrompts[1], contains('Self-Heal 1/1'));
    expect(sentPrompts[1], contains('dart test failed'));
    expect(container.read(rsiLoopProvider).phase, RsiPhase.fixingCi);

    // Gen 1 CI self-heal pushes bbbb2222b -> CI passes -> tag v1.0.60 -> Release APK passes -> starts Gen 2!
    currentSha = 'bbbb2222b';
    ciRuns.insert(0, {
      'databaseId': 1002,
      'workflowName': 'CI',
      'status': 'completed',
      'conclusion': 'success',
      'url': 'https://github.com/o/r/actions/runs/1002',
      'headBranch': 'main',
      'headSha': 'bbbb2222b',
    });
    await container.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 'sess-rsi',
          assistantText: 'RSI_SUMMARY: Fixed test failure cleanly',
        );
    expect(sentPrompts, hasLength(3));
    expect(sentPrompts[2], contains('Generation 2/2'));
    expect(container.read(rsiLoopProvider).currentGeneration, 2);
    expect(container.read(rsiLoopProvider).archive, hasLength(1));
    expect(container.read(rsiLoopProvider).archive.first.tag, 'v1.0.60');
    expect(
      container.read(rsiLoopProvider).archive.first.apkAssetName,
      'antigravity-go-1.0.60-arm64.apk',
    );

    // Gen 2 proposer pushes cccc3333 (1.0.61) -> CI passes -> tag v1.0.61 -> Release APK passes -> Completed!
    currentSha = 'cccc3333';
    currentVersion = '1.0.61';
    ciRuns.insert(0, {
      'databaseId': 1003,
      'workflowName': 'CI',
      'status': 'completed',
      'conclusion': 'success',
      'url': 'https://github.com/o/r/actions/runs/1003',
      'headBranch': 'main',
      'headSha': 'cccc3333',
    });
    await container.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 'sess-rsi',
          assistantText: 'RSI_SUMMARY: Added telemetry tests for v1.0.61',
        );
    final finalState = container.read(rsiLoopProvider);
    expect(finalState.phase, RsiPhase.completed);
    expect(finalState.archive, hasLength(2));
    expect(finalState.archive.first.tag, 'v1.0.61');
    expect(pushedTags, hasLength(2));
    expect(feedbackLogs.any((m) => m.contains('finished')), isTrue);
  });

  test('RsiLoopNotifier adapts to generic Node CI-only project without APK release', () async {
    // Node.js project on `master` branch with CI workflow and NO release workflow
    var nodeSha = '1111aaaa';
    final nodePrompts = <String>[];
    final nodeCiNotifier = CiWatchNotifier()
      ..shellRunnerOverride = (cmd, cwd) async {
        return jsonEncode([
          {
            'databaseId': 555,
            'workflowName': 'Web Tests',
            'status': 'completed',
            'conclusion': 'success',
            'url': 'https://github.com/org/web/actions/runs/555',
            'headBranch': 'master',
            'headSha': '2222bbbb',
          },
        ]);
      };
    final nodeRsi = RsiLoopNotifier()
      ..shellRunnerOverride = (cmd, cwd) async {
        if (cmd.contains('--is-inside-work-tree')) return 'true';
        if (cmd.contains('===RSI:BRANCH===')) {
          return _buildProbe(
            branch: 'master',
            sha: nodeSha,
            originUrl: 'git@github.com:org/web.git',
            hasGh: '1',
            packageJsonVersion: '2.4.1',
            workflows: '''
---WF_FILE:.github/workflows/tests.yml
name: Web Tests
on: [push]
''',
          );
        }
        if (cmd.contains('git rev-parse HEAD')) return nodeSha;
        if (cmd.contains('git rev-parse "origin/master"')) return nodeSha;
        if (cmd.contains('git status --porcelain')) return '';
        return '';
      }
      ..feedbackOverride = (md, {sessionId}) async {}
      ..sendPromptOverride = (p, {sessionId}) async => nodePrompts.add(p);

    final nodeContainer = ProviderContainer(
      overrides: [
        ciWatchProvider.overrideWith(() => nodeCiNotifier),
        rsiLoopProvider.overrideWith(() => nodeRsi),
      ],
    );
    addTearDown(nodeContainer.dispose);

    await nodeContainer.read(rsiLoopProvider.notifier).start(
          sessionId: 's-node',
          cwd: '/tmp/web',
          config: const RsiConfig(
            objective: 'Optimize bundle size',
            maxGenerations: 1,
            releaseMode: RsiReleaseMode.auto,
          ),
        );
    expect(nodePrompts.single, contains('master'));
    expect(nodePrompts.single, contains('package.json'));

    nodeSha = '2222bbbb';
    await nodeContainer.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 's-node',
          assistantText: 'RSI_SUMMARY: Tree-shook unused icons',
        );
    final nodeDone = nodeContainer.read(rsiLoopProvider);
    expect(nodeDone.phase, RsiPhase.completed);
    expect(nodeDone.archive.single.status, 'ci_passed');
    expect(nodeDone.archive.single.tag, isNull);
  });

  test('RsiLoopNotifier adapts to local-only Python project with pytest self-heal', () async {
    // Local-only Python project without GitHub remote -> runs `pytest`, self-heals on failure, then completes!
    var pySha = 'aa00';
    var pytestAttempt = 0;
    final pyPrompts = <String>[];
    final pyRsi = RsiLoopNotifier()
      ..shellRunnerOverride = (cmd, cwd) async {
        if (cmd.contains('--is-inside-work-tree')) return 'true';
        if (cmd.contains('===RSI:BRANCH===')) {
          return _buildProbe(
            branch: 'dev',
            sha: pySha,
            originUrl: '',
            hasGh: '0',
            pyprojectVersion: '0.3.0',
          );
        }
        if (cmd.contains('git rev-parse HEAD')) return pySha;
        if (cmd.contains('git status --porcelain')) return '';
        if (cmd.contains('pytest')) {
          pytestAttempt++;
          if (pytestAttempt == 1) {
            return 'FAILED tests/test_api.py\n__RSI_EXIT=1__\n';
          }
          return '3 passed\n__RSI_EXIT=0__\n';
        }
        return '';
      }
      ..feedbackOverride = (md, {sessionId}) async {}
      ..sendPromptOverride = (p, {sessionId}) async => pyPrompts.add(p);

    final pyContainer = ProviderContainer(
      overrides: [rsiLoopProvider.overrideWith(() => pyRsi)],
    );
    addTearDown(pyContainer.dispose);

    await pyContainer.read(rsiLoopProvider.notifier).start(
          sessionId: 's-py',
          cwd: '/tmp/py',
          config: const RsiConfig(
            objective: 'Speed up parser',
            maxGenerations: 1,
            maxCiFixAttemptsPerGen: 1,
          ),
        );
    pySha = 'bb11';
    await pyContainer.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 's-py',
          assistantText: 'RSI_SUMMARY: Initial parser optimization',
        );
    expect(pyContainer.read(rsiLoopProvider).phase, RsiPhase.fixingCi);
    expect(pyPrompts[1], contains('FAILED tests/test_api.py'));

    pySha = 'cc22';
    await pyContainer.read(rsiLoopProvider.notifier).onChatTurnFinished(
          sessionId: 's-py',
          assistantText: 'RSI_SUMMARY: Fixed edge case in parser',
        );
    final pyDone = pyContainer.read(rsiLoopProvider);
    expect(pyDone.phase, RsiPhase.completed);
    expect(pyDone.archive.single.status, 'verified_local');
  });

  testWidgets('RsiControlSheet and RsiStatusBanner render cleanly on 360px phone viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                RsiStatusBanner(onOpenSheet: () {}),
                const Expanded(child: RsiControlSheet()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recursive Self-Improvement (RSI)'), findsOneWidget);
    expect(find.text('Post-Verification Release Mode'), findsOneWidget);
    expect(find.text('Auto (Detect Repo)'), findsOneWidget);
    expect(find.text('Start RSI Loop (3 gen)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
