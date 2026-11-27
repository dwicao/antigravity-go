import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  group('RsiEngine', () {
    test('parses pubspec versions and bumps patch cleanly', () {
      const pubspec = '''
name: antigravity_go
version: 1.0.59+1
''';
      final parsed = RsiPromptBuilder.parsePubspecVersion(pubspec);
      expect(parsed, isNotNull);
      expect(parsed!.version, '1.0.59');
      expect(parsed.buildNumber, 1);
      expect(RsiPromptBuilder.nextPatchVersion(parsed.version), '1.0.60');
    });

    test('parses GitHub release view JSON for URL and APK or generic assets', () {
      const apkRaw = '''
{"assets":[{"name":"SHA256SUMS","size":98},{"name":"antigravity-go-1.0.60-arm64.apk","size":16400000}],"url":"https://github.com/dwicao/antigravity-go/releases/tag/v1.0.60"}
''';
      final parsedApk = RsiPromptBuilder.parseReleaseViewJson(apkRaw);
      expect(
        parsedApk.url,
        'https://github.com/dwicao/antigravity-go/releases/tag/v1.0.60',
      );
      expect(parsedApk.assetName, 'antigravity-go-1.0.60-arm64.apk');

      const cliRaw = '''
{"assets":[{"name":"mytool-linux-x64.tar.gz","size":2048}],"url":"https://github.com/o/r/releases/tag/v0.2.1"}
''';
      final parsedCli = RsiPromptBuilder.parseReleaseViewJson(cliRaw);
      expect(parsedCli.assetName, 'mytool-linux-x64.tar.gz');
    });

    test('RsiProjectProfile auto-detects Antigravity Go, Node CI-only, and local Python repos', () {
      const agyProbe = '''
===RSI:BRANCH===
main
===RSI:HEAD_SHA===
abcdef123456
===RSI:ORIGIN_URL===
https://github.com/dwicao/antigravity-go.git
===RSI:HAS_GH===
1
===RSI:HAS_SYNC===
1
===RSI:APP_PUBSPEC===
name: antigravity_go
version: 1.0.59+1
dependencies:
  flutter:
    sdk: flutter
===RSI:WORKFLOWS===
---WF_FILE:.github/workflows/ci.yml
name: CI
on: [push]
---WF_FILE:.github/workflows/release-apk.yml
name: Release APK (AOSP release key)
on:
  push:
    tags:
      - 'v*'
jobs:
  build:
    steps:
      - run: bash tooling/build-apk.sh
''';
      final agyProfile = RsiProjectProfile.parseProbeOutput(agyProbe);
      expect(agyProfile.branch, 'main');
      expect(agyProfile.manifestKind, RsiVersionManifestKind.antigravitySync);
      expect(agyProfile.currentVersion, '1.0.59');
      expect(agyProfile.syncCommand, 'python3 tooling/sync_version.py');
      expect(agyProfile.canWatchGitHubCi, isTrue);
      expect(agyProfile.ciWorkflowName, 'CI');
      expect(agyProfile.shouldRunRelease, isTrue);
      expect(agyProfile.releasesApk, isTrue);

      const nodeProbe = '''
===RSI:BRANCH===
master
===RSI:HEAD_SHA===
11223344
===RSI:ORIGIN_URL===
git@github.com:org/webapp.git
===RSI:HAS_GH===
1
===RSI:PACKAGE_JSON===
{
  "name": "webapp",
  "version": "2.4.1"
}
===RSI:WORKFLOWS===
---WF_FILE:.github/workflows/tests.yml
name: Web Tests
on: [push, pull_request]
''';
      final nodeProfile = RsiProjectProfile.parseProbeOutput(nodeProbe);
      expect(nodeProfile.branch, 'master');
      expect(nodeProfile.manifestKind, RsiVersionManifestKind.packageJson);
      expect(nodeProfile.versionFilePath, 'package.json');
      expect(nodeProfile.currentVersion, '2.4.1');
      expect(nodeProfile.verifyCommand, 'npm test');
      expect(nodeProfile.canWatchGitHubCi, isTrue);
      expect(nodeProfile.ciWorkflowName, 'Web Tests');
      expect(nodeProfile.shouldRunRelease, isFalse);
      expect(nodeProfile.releasesApk, isFalse);

      const pyProbe = '''
===RSI:BRANCH===
dev
===RSI:HEAD_SHA===
99887766
===RSI:ORIGIN_URL===
===RSI:HAS_GH===
0
===RSI:PYPROJECT_TOML===
[project]
name = "ml-service"
version = "0.8.3"
''';
      final pyProfile = RsiProjectProfile.parseProbeOutput(pyProbe);
      expect(pyProfile.branch, 'dev');
      expect(pyProfile.manifestKind, RsiVersionManifestKind.pyprojectToml);
      expect(pyProfile.currentVersion, '0.8.3');
      expect(pyProfile.verifyCommand, 'pytest');
      expect(pyProfile.canWatchGitHubCi, isFalse);
      expect(pyProfile.shouldRunRelease, isFalse);
    });

    test('builds adapted AlphaEvolve proposer and failure-fix prompts across stacks', () {
      const config = RsiConfig(
        objective: 'Optimize API latency',
        maxGenerations: 4,
        maxCiFixAttemptsPerGen: 2,
      );
      const nodeProfile = RsiProjectProfile(
        branch: 'master',
        headSha: 'abcdef123456',
        manifestKind: RsiVersionManifestKind.packageJson,
        versionFilePath: 'package.json',
        currentVersion: '2.4.1',
        verifyCommand: 'npm test',
        hasGitHubRemote: true,
        hasGhCli: true,
        hasCiWorkflow: true,
        ciWorkflowName: 'Web Tests',
      );
      final archive = [
        RsiArchiveEntry(
          generation: 1,
          status: 'ci_passed',
          summary: 'Added response compression',
          version: '2.4.1',
          commitSha: 'abcdef123456',
          timestamp: DateTime.utc(2026, 11, 27, 9, 0),
        ),
      ];

      final proposer = RsiPromptBuilder.buildProposerPrompt(
        generation: 2,
        maxGenerations: 4,
        config: config,
        profile: nodeProfile,
        archive: archive,
      );
      expect(proposer, contains('Generation 2/4'));
      expect(proposer, contains('Workspace branch: `master`'));
      expect(proposer, contains('package.json'));
      expect(proposer, contains('"2.4.2"'));
      expect(proposer, contains('npm test'));
      expect(proposer, contains('Added response compression'));

      final fix = RsiPromptBuilder.buildFailureFixPrompt(
        generation: 2,
        attempt: 1,
        maxAttempts: 2,
        branch: 'master',
        sourceLabel: 'Local verification (`pytest`)',
        failedLog: 'AssertionError: expected 200',
        pushToRemote: false,
      );
      expect(fix, contains('Self-Heal 1/2'));
      expect(fix, contains('AssertionError: expected 200'));
      expect(fix, contains('Commit the fix cleanly on `master`'));
    });

    test('RsiConfig clamps bounds and migrates legacy autoReleaseApk JSON', () {
      const raw = RsiConfig(
        objective: '   ',
        maxGenerations: 99,
        maxCiFixAttemptsPerGen: -2,
        releaseMode: RsiReleaseMode.ciOnly,
      );
      final norm = raw.normalized();
      expect(norm.objective, RsiConfig.defaultObjective);
      expect(norm.maxGenerations, 20);
      expect(norm.maxCiFixAttemptsPerGen, 0);
      expect(norm.releaseMode, RsiReleaseMode.ciOnly);
      expect(norm.autoReleaseApk, isFalse);

      final roundTrip = RsiConfig.fromJson(norm.toJson());
      expect(roundTrip.maxGenerations, 20);
      expect(roundTrip.releaseMode, RsiReleaseMode.ciOnly);

      final legacyFalse = RsiConfig.fromJson(const {'autoReleaseApk': false});
      expect(legacyFalse.releaseMode, RsiReleaseMode.ciOnly);
    });
  });
}
