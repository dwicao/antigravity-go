import 'dart:convert';

/// Lifecycle phase of a bounded Recursive Self-Improvement (RSI) loop.
enum RsiPhase {
  idle('Idle', false),
  proposing('Proposing & Applying', true),
  waitingCi('Watching CI / Verify', true),
  fixingCi('Self-Healing Failure', true),
  releasing('Releasing Artifact', true),
  completed('Completed', false),
  failed('Failed', false),
  stopped('Stopped', false);

  const RsiPhase(this.label, this.isActive);

  final String label;
  final bool isActive;
}

/// How the RSI loop handles releases after CI / local verification passes.
enum RsiReleaseMode {
  auto('auto', 'Auto (Detect Repo)', 'Runs tag/APK release when repo has a release workflow; otherwise finishes after CI/tests pass'),
  tagAndRelease('tag', 'Tag + Release', 'Always pushes vX.Y.Z tag and watches/creates a GitHub Release after green CI'),
  ciOnly('ci_only', 'CI / Verify Only', 'Verifies tests & CI without creating Git tags or GitHub Releases');

  const RsiReleaseMode(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static RsiReleaseMode fromId(String? value) {
    final norm = (value ?? '').trim().toLowerCase();
    for (final m in RsiReleaseMode.values) {
      if (m.id == norm) return m;
    }
    return RsiReleaseMode.auto;
  }
}

/// Detected version manifest format for a project workspace.
enum RsiVersionManifestKind {
  antigravitySync('app/pubspec.yaml + sync_version.py'),
  pubspec('pubspec.yaml'),
  packageJson('package.json'),
  cargoToml('Cargo.toml'),
  pyprojectToml('pyproject.toml'),
  gitTagOnly('git tags');

  const RsiVersionManifestKind(this.label);
  final String label;
}

/// Auto-detected project capabilities so `/rsi` adapts to any Git project.
class RsiProjectProfile {
  const RsiProjectProfile({
    this.branch = 'main',
    this.headSha = '',
    this.manifestKind = RsiVersionManifestKind.gitTagOnly,
    this.versionFilePath,
    this.currentVersion = '0.1.0',
    this.syncCommand,
    this.verifyCommand,
    this.hasGitHubRemote = false,
    this.hasGhCli = false,
    this.hasCiWorkflow = false,
    this.ciWorkflowName,
    this.hasReleaseWorkflow = false,
    this.releaseWorkflowName,
    this.releasesApk = false,
  });

  final String branch;
  final String headSha;
  final RsiVersionManifestKind manifestKind;
  final String? versionFilePath;
  final String currentVersion;
  final String? syncCommand;
  final String? verifyCommand;
  final bool hasGitHubRemote;
  final bool hasGhCli;
  final bool hasCiWorkflow;
  final String? ciWorkflowName;
  final bool hasReleaseWorkflow;
  final String? releaseWorkflowName;
  final bool releasesApk;

  bool get canWatchGitHubCi => hasGitHubRemote && hasGhCli && hasCiWorkflow;

  bool get shouldRunRelease =>
      hasGitHubRemote && hasGhCli && hasReleaseWorkflow;

  static final RegExp _pubspecVersionRe = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+[0-9]+)?',
    multiLine: true,
  );
  static final RegExp _jsonVersionRe = RegExp(
    r'"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
  );
  static final RegExp _tomlVersionRe = RegExp(
    r'^version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"',
    multiLine: true,
  );
  static final RegExp _tagVersionRe = RegExp(r'v?([0-9]+\.[0-9]+\.[0-9]+)');
  static final RegExp _workflowNameRe = RegExp(
    r'''^name:\s*['"]?(.+?)['"]?\s*$''',
    multiLine: true,
  );

  /// Parses the structured probe output produced in a workspace directory.
  static RsiProjectProfile parseProbeOutput(
    String raw, {
    String? customVerifyCommand,
  }) {
    final sections = <String, String>{};
    var currentKey = '';
    final buf = StringBuffer();
    for (final line in raw.split('\n')) {
      if (line.startsWith('===RSI:') && line.endsWith('===')) {
        if (currentKey.isNotEmpty) {
          sections[currentKey] = buf.toString().trimRight();
        }
        currentKey = line.substring(7, line.length - 3).trim();
        buf.clear();
      } else if (currentKey.isNotEmpty) {
        buf.writeln(line);
      }
    }
    if (currentKey.isNotEmpty) {
      sections[currentKey] = buf.toString().trimRight();
    }

    var branch = (sections['BRANCH'] ?? '').trim();
    if (branch.isEmpty || branch == 'HEAD') {
      final originHead = (sections['ORIGIN_HEAD'] ?? '').trim();
      if (originHead.startsWith('refs/remotes/origin/')) {
        branch = originHead.substring('refs/remotes/origin/'.length).trim();
      } else if (originHead.startsWith('origin/')) {
        branch = originHead.substring('origin/'.length).trim();
      }
    }
    if (branch.isEmpty || branch == 'HEAD') {
      branch = 'main';
    }

    final headSha = (sections['HEAD_SHA'] ?? '').trim();
    final originUrl = (sections['ORIGIN_URL'] ?? '').trim().toLowerCase();
    final hasGitHubRemote = originUrl.contains('github.com');
    final hasGhCli = (sections['HAS_GH'] ?? '').trim() == '1';
    final hasSync = (sections['HAS_SYNC'] ?? '').trim() == '1';
    final latestTag = (sections['LATEST_TAG'] ?? '').trim();

    final appPubspec = sections['APP_PUBSPEC'] ?? '';
    final rootPubspec = sections['ROOT_PUBSPEC'] ?? '';
    final pkgJson = sections['PACKAGE_JSON'] ?? '';
    final cargoToml = sections['CARGO_TOML'] ?? '';
    final pyprojectToml = sections['PYPROJECT_TOML'] ?? '';
    final hasGoMod = (sections['HAS_GOMOD'] ?? '').trim() == '1';
    final hasGradlew = (sections['HAS_GRADLEW'] ?? '').trim() == '1';

    var manifestKind = RsiVersionManifestKind.gitTagOnly;
    String? versionFilePath;
    String? currentVersion;
    String? syncCommand;
    String? detectedVerify;

    if (appPubspec.isNotEmpty) {
      final m = _pubspecVersionRe.firstMatch(appPubspec);
      if (m != null) {
        manifestKind = hasSync
            ? RsiVersionManifestKind.antigravitySync
            : RsiVersionManifestKind.pubspec;
        versionFilePath = 'app/pubspec.yaml';
        currentVersion = m.group(1)!;
        if (hasSync) syncCommand = 'python3 tooling/sync_version.py';
      }
    }
    if (currentVersion == null && rootPubspec.isNotEmpty) {
      final m = _pubspecVersionRe.firstMatch(rootPubspec);
      if (m != null) {
        manifestKind = RsiVersionManifestKind.pubspec;
        versionFilePath = 'pubspec.yaml';
        currentVersion = m.group(1)!;
      }
    }
    if (currentVersion == null && pkgJson.isNotEmpty) {
      final m = _jsonVersionRe.firstMatch(pkgJson);
      if (m != null) {
        manifestKind = RsiVersionManifestKind.packageJson;
        versionFilePath = 'package.json';
        currentVersion = m.group(1)!;
      }
    }
    if (currentVersion == null && cargoToml.isNotEmpty) {
      final m = _tomlVersionRe.firstMatch(cargoToml);
      if (m != null) {
        manifestKind = RsiVersionManifestKind.cargoToml;
        versionFilePath = 'Cargo.toml';
        currentVersion = m.group(1)!;
      }
    }
    if (currentVersion == null && pyprojectToml.isNotEmpty) {
      final m = _tomlVersionRe.firstMatch(pyprojectToml);
      if (m != null) {
        manifestKind = RsiVersionManifestKind.pyprojectToml;
        versionFilePath = 'pyproject.toml';
        currentVersion = m.group(1)!;
      }
    }
    if (currentVersion == null) {
      final tagMatch = _tagVersionRe.firstMatch(latestTag);
      currentVersion = tagMatch?.group(1) ?? '0.1.0';
    }

    // Detect default local verification command if available.
    if (appPubspec.isNotEmpty) {
      detectedVerify = appPubspec.contains('flutter:')
          ? 'cd app && flutter test'
          : 'cd app && dart test';
    } else if (rootPubspec.isNotEmpty) {
      detectedVerify =
          rootPubspec.contains('flutter:') ? 'flutter test' : 'dart test';
    } else if (pkgJson.isNotEmpty) {
      detectedVerify = 'npm test';
    } else if (cargoToml.isNotEmpty) {
      detectedVerify = 'cargo test';
    } else if (pyprojectToml.isNotEmpty) {
      detectedVerify = 'pytest';
    } else if (hasGoMod) {
      detectedVerify = 'go test ./...';
    } else if (hasGradlew) {
      detectedVerify = './gradlew test';
    }

    final effectiveVerify =
        (customVerifyCommand != null && customVerifyCommand.trim().isNotEmpty)
            ? customVerifyCommand.trim()
            : detectedVerify;

    // Parse GitHub Actions workflows.
    final workflowsRaw = sections['WORKFLOWS'] ?? '';
    var hasCiWorkflow = false;
    String? ciWorkflowName;
    var hasReleaseWorkflow = false;
    String? releaseWorkflowName;
    var releasesApk = false;

    for (final block in workflowsRaw.split('---WF_FILE:')) {
      final trimmed = block.trim();
      if (trimmed.isEmpty) continue;
      final nl = trimmed.indexOf('\n');
      final fileName = (nl >= 0 ? trimmed.substring(0, nl) : trimmed)
          .trim()
          .toLowerCase();
      final body = nl >= 0 ? trimmed.substring(nl + 1) : '';
      final bodyLower = body.toLowerCase();
      final wfName = _workflowNameRe.firstMatch(body)?.group(1)?.trim();

      final isReleaseWf = fileName.contains('release') ||
          fileName.contains('publish') ||
          RegExp(r'tags:\s*\n?\s*-\s*[''"]?v\*').hasMatch(bodyLower) ||
          bodyLower.contains('gh release create') ||
          bodyLower.contains('gh release upload');
      final isApkWf = bodyLower.contains('.apk') ||
          bodyLower.contains('flutter build apk') ||
          bodyLower.contains('assemblerelease') ||
          bodyLower.contains('build-apk');

      if (isReleaseWf) {
        hasReleaseWorkflow = true;
        releaseWorkflowName ??= wfName;
        if (isApkWf) releasesApk = true;
      } else if (body.isNotEmpty) {
        hasCiWorkflow = true;
        if (ciWorkflowName == null ||
            (wfName != null &&
                (wfName.toLowerCase() == 'ci' ||
                    wfName.toLowerCase().contains('test') ||
                    wfName.toLowerCase().contains('ci')))) {
          ciWorkflowName = wfName ?? ciWorkflowName;
        }
      }
    }

    return RsiProjectProfile(
      branch: branch,
      headSha: headSha,
      manifestKind: manifestKind,
      versionFilePath: versionFilePath,
      currentVersion: currentVersion,
      syncCommand: syncCommand,
      verifyCommand: effectiveVerify,
      hasGitHubRemote: hasGitHubRemote,
      hasGhCli: hasGhCli,
      hasCiWorkflow: hasCiWorkflow,
      ciWorkflowName: ciWorkflowName,
      hasReleaseWorkflow: hasReleaseWorkflow,
      releaseWorkflowName: releaseWorkflowName,
      releasesApk: releasesApk,
    );
  }
}

/// Bounded safety, budget, and automation settings for an RSI loop,
/// inspired by DeepMind AlphaEvolve and Anthropic Evaluator-Optimizer / RSP.
class RsiConfig {
  const RsiConfig({
    this.objective = defaultObjective,
    this.maxGenerations = 3,
    this.maxCiFixAttemptsPerGen = 2,
    this.releaseMode = RsiReleaseMode.auto,
  });

  static const String defaultObjective =
      'Audit the codebase, select the highest-impact verifiable improvement '
      '(reliability, UX, performance, or test coverage), implement it cleanly, '
      'verify it passes checks, and ship the iteration.';

  final String objective;
  final int maxGenerations;
  final int maxCiFixAttemptsPerGen;
  final RsiReleaseMode releaseMode;

  bool get autoReleaseApk => releaseMode != RsiReleaseMode.ciOnly;

  RsiConfig normalized() {
    final cleanObj =
        objective.trim().isEmpty ? defaultObjective : objective.trim();
    return RsiConfig(
      objective: cleanObj,
      maxGenerations: maxGenerations.clamp(1, 20),
      maxCiFixAttemptsPerGen: maxCiFixAttemptsPerGen.clamp(0, 5),
      releaseMode: releaseMode,
    );
  }

  RsiConfig copyWith({
    String? objective,
    int? maxGenerations,
    int? maxCiFixAttemptsPerGen,
    RsiReleaseMode? releaseMode,
  }) {
    return RsiConfig(
      objective: objective ?? this.objective,
      maxGenerations: maxGenerations ?? this.maxGenerations,
      maxCiFixAttemptsPerGen:
          maxCiFixAttemptsPerGen ?? this.maxCiFixAttemptsPerGen,
      releaseMode: releaseMode ?? this.releaseMode,
    ).normalized();
  }

  Map<String, dynamic> toJson() => {
        'objective': objective,
        'maxGenerations': maxGenerations,
        'maxCiFixAttemptsPerGen': maxCiFixAttemptsPerGen,
        'releaseMode': releaseMode.id,
      };

  factory RsiConfig.fromJson(Map<String, dynamic> json) {
    final modeRaw = json['releaseMode']?.toString();
    final legacyBool = json['autoReleaseApk'];
    final mode = modeRaw != null && modeRaw.isNotEmpty
        ? RsiReleaseMode.fromId(modeRaw)
        : (legacyBool == false ? RsiReleaseMode.ciOnly : RsiReleaseMode.auto);
    return RsiConfig(
      objective: json['objective']?.toString() ?? defaultObjective,
      maxGenerations: (json['maxGenerations'] as num?)?.toInt() ?? 3,
      maxCiFixAttemptsPerGen:
          (json['maxCiFixAttemptsPerGen'] as num?)?.toInt() ?? 2,
      releaseMode: mode,
    ).normalized();
  }
}

/// One generation record in the AlphaEvolve-style evolutionary lineage archive.
class RsiArchiveEntry {
  const RsiArchiveEntry({
    required this.generation,
    required this.status,
    required this.summary,
    required this.timestamp,
    this.version,
    this.tag,
    this.commitSha,
    this.ciRunId,
    this.releaseRunId,
    this.releaseUrl,
    this.artifactName,
  });

  final int generation;
  final String status;
  final String summary;
  final DateTime timestamp;
  final String? version;
  final String? tag;
  final String? commitSha;
  final String? ciRunId;
  final String? releaseRunId;
  final String? releaseUrl;
  final String? artifactName;

  /// Backward-compatible alias for APK-based releases.
  String? get apkAssetName => artifactName;

  bool get isSuccess =>
      status == 'released' ||
      status == 'ci_passed' ||
      status == 'verified_local';

  String get shortSha {
    final s = commitSha?.trim() ?? '';
    if (s.length <= 7) return s;
    return s.substring(0, 7);
  }

  Map<String, dynamic> toJson() => {
        'generation': generation,
        'status': status,
        'summary': summary,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (version != null) 'version': version,
        if (tag != null) 'tag': tag,
        if (commitSha != null) 'commitSha': commitSha,
        if (ciRunId != null) 'ciRunId': ciRunId,
        if (releaseRunId != null) 'releaseRunId': releaseRunId,
        if (releaseUrl != null) 'releaseUrl': releaseUrl,
        if (artifactName != null) 'artifactName': artifactName,
      };

  factory RsiArchiveEntry.fromJson(Map<String, dynamic> json) {
    return RsiArchiveEntry(
      generation: (json['generation'] as num?)?.toInt() ?? 1,
      status: json['status']?.toString() ?? 'unknown',
      summary: json['summary']?.toString() ?? '',
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      version: json['version']?.toString(),
      tag: json['tag']?.toString(),
      commitSha: json['commitSha']?.toString(),
      ciRunId: json['ciRunId']?.toString(),
      releaseRunId: json['releaseRunId']?.toString(),
      releaseUrl: json['releaseUrl']?.toString(),
      artifactName:
          (json['artifactName'] ?? json['apkAssetName'])?.toString(),
    );
  }
}

/// Pure prompt assembly and version/release parsing helpers for RSI loops.
class RsiPromptBuilder {
  const RsiPromptBuilder._();

  static final RegExp _pubspecVersionRe = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?',
    multiLine: true,
  );

  /// Parses `version: X.Y.Z+B` from `pubspec.yaml`.
  static ({String version, int buildNumber})? parsePubspecVersion(
    String pubspecContent,
  ) {
    final match = _pubspecVersionRe.firstMatch(pubspecContent);
    if (match == null) return null;
    final version = match.group(1)!.trim();
    final buildNumber = int.tryParse(match.group(2) ?? '1') ?? 1;
    return (version: version, buildNumber: buildNumber);
  }

  /// Computes the next patch version (`1.0.59` -> `1.0.60`).
  static String nextPatchVersion(String currentVersion) {
    final parts = currentVersion.trim().split('.');
    if (parts.length != 3) return currentVersion;
    final major = int.tryParse(parts[0]) ?? 1;
    final minor = int.tryParse(parts[1]) ?? 0;
    final patch = int.tryParse(parts[2]) ?? 0;
    return '$major.$minor.${patch + 1}';
  }

  /// Extracts release URL and primary downloadable asset name from `gh release view --json url,assets`.
  static ({String? url, String? assetName}) parseReleaseViewJson(String raw) {
    final trimmed = raw.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end <= start) return (url: null, assetName: null);
    try {
      final decoded = jsonDecode(trimmed.substring(start, end + 1));
      if (decoded is! Map<String, dynamic>) {
        return (url: null, assetName: null);
      }
      final url = decoded['url']?.toString();
      String? firstAsset;
      String? apkAsset;
      final assets = decoded['assets'];
      if (assets is List) {
        for (final item in assets) {
          if (item is Map) {
            final name = item['name']?.toString() ?? '';
            if (name.isEmpty) continue;
            firstAsset ??= name;
            if (name.endsWith('.apk')) {
              apkAsset = name;
              break;
            }
          }
        }
      }
      return (url: url, assetName: apkAsset ?? firstAsset);
    } catch (_) {
      return (url: null, assetName: null);
    }
  }

  /// Builds the AlphaEvolve + Evaluator-Optimizer Proposer prompt adapted to [profile].
  static String buildProposerPrompt({
    required int generation,
    required int maxGenerations,
    required RsiConfig config,
    required RsiProjectProfile profile,
    required List<RsiArchiveEntry> archive,
  }) {
    final currentVersion = profile.currentVersion;
    final targetVersion = nextPatchVersion(currentVersion);
    final shortSha = profile.headSha.length > 7
        ? profile.headSha.substring(0, 7)
        : (profile.headSha.isEmpty ? 'HEAD' : profile.headSha);
    final recentArchive =
        archive.length > 6 ? archive.sublist(archive.length - 6) : archive;
    final lineageBlock = recentArchive.isEmpty
        ? '- None yet (seed generation).'
        : recentArchive
            .map(
              (e) =>
                  '- Gen ${e.generation} [${e.status}]${e.version != null ? ' v${e.version}' : ''}${e.shortSha.isNotEmpty ? ' (${e.shortSha})' : ''}: ${e.summary}',
            )
            .join('\n');

    final willRelease = config.releaseMode == RsiReleaseMode.tagAndRelease ||
        (config.releaseMode == RsiReleaseMode.auto && profile.shouldRunRelease);

    final versionStep = switch (profile.manifestKind) {
      RsiVersionManifestKind.antigravitySync =>
        'Update `app/pubspec.yaml` to `version: $targetVersion+1`, add a `## [$targetVersion]` entry to `CHANGELOG.md` (if present), and run `python3 tooling/sync_version.py`.',
      RsiVersionManifestKind.pubspec =>
        'Update `${profile.versionFilePath}` to `version: $targetVersion` (or `$targetVersion+1`), and update `CHANGELOG.md` if present.',
      RsiVersionManifestKind.packageJson =>
        'Update `version` in `${profile.versionFilePath}` to `"$targetVersion"` (preserving formatting), and update `CHANGELOG.md` if present.',
      RsiVersionManifestKind.cargoToml || RsiVersionManifestKind.pyprojectToml =>
        'Update `version = "$targetVersion"` in `${profile.versionFilePath}`, and update `CHANGELOG.md` if present.',
      RsiVersionManifestKind.gitTagOnly =>
        willRelease
            ? 'No version manifest file detected — the harness will tag `v$targetVersion` after verification; update `CHANGELOG.md` if present.'
            : 'No version manifest bump required for this repository.',
    };

    final verifyStep = (profile.verifyCommand != null &&
            profile.verifyCommand!.trim().isNotEmpty)
        ? 'Run available local verification (e.g. `${profile.verifyCommand!.trim()}`${profile.syncCommand != null ? ' and `${profile.syncCommand} --check`' : ''}) before committing.'
        : 'Run any relevant local tests, builds, or linters available in this workspace before committing.';

    final pushStep = profile.hasGitHubRemote
        ? 'Stage, commit on `${profile.branch}`, and push to `origin ${profile.branch}` (if `git push` hits a credential helper issue, leave the clean commit on `${profile.branch}` and the harness will push it).'
        : 'Stage and commit your verified changes cleanly on branch `${profile.branch}`.';

    final releaseRule = willRelease
        ? '4. Do NOT push a git tag `v$targetVersion` yourself — the RSI Evaluator harness will deterministically verify CI is green on `${profile.branch}` first and then trigger the release (`v$targetVersion`).'
        : '4. Do NOT push any release tags yourself — focus purely on clean, verified changes on `${profile.branch}`.';

    return '''[RSI Loop · Generation $generation/$maxGenerations · AlphaEvolve Proposer]
Workspace branch: `${profile.branch}` · Baseline: `$currentVersion` (`$shortSha`) → Next: `$targetVersion`
Detected stack: `${profile.manifestKind.label}`${profile.canWatchGitHubCi ? ' · CI: `${profile.ciWorkflowName ?? "GitHub Actions"}`' : ' · Mode: Local verification'}

## Objective
${config.objective}

## Evolutionary Lineage (Do Not Repeat Past Work)
$lineageBlock

## Constitutional & RSP Safety Constraints (Strict)
1. Pick ONE high-leverage, verifiable improvement per generation — keep edits focused, clean, and well-tested.
2. NEVER skip, relax, mock away, or delete existing tests or analyzer/linter checks to make verification pass.
3. NEVER fabricate command output, file paths, or test results.
$releaseRule

## Execution Steps
1. Inspect recent commits (`git log -n 5 --oneline`) and relevant source/test files to choose the best next improvement aligned with the objective.
2. Implement the improvement cleanly and add/update unit, integration, or widget tests covering the behavior.
3. $versionStep
4. $verifyStep
5. $pushStep
6. End with a concise 1-line summary starting with `RSI_SUMMARY:` describing what changed and which files/tests were updated.''';
  }

  /// Builds the Evaluator-Optimizer self-heal prompt when CI or local verification fails.
  static String buildFailureFixPrompt({
    required int generation,
    required int attempt,
    required int maxAttempts,
    required String branch,
    required String sourceLabel,
    required String failedLog,
    required bool pushToRemote,
  }) {
    final trimmedLog = failedLog.trim().isEmpty
        ? 'Inspect the failure details in the workspace.'
        : failedLog.trim();
    final commitStep = pushToRemote
        ? 'Commit and push the fix to `origin $branch` (do NOT create a git tag — the RSI Evaluator will re-verify automatically).'
        : 'Commit the fix cleanly on `$branch` so the RSI Evaluator can re-run verification.';
    return '''[RSI Loop · Generation $generation · Self-Heal $attempt/$maxAttempts]
$sourceLabel failed after your latest iteration on `$branch`.

## Failure Output
```
$trimmedLog
```

## Instructions
1. Diagnose the exact root cause from the failure output above.
2. Fix the issue cleanly without weakening or skipping any tests, linters, or analyzer rules.
3. Re-run local checks where available.
4. $commitStep
5. End with a concise 1-line summary starting with `RSI_SUMMARY:`.''';
  }

  /// Extracts a clean summary line from the assistant's final response.
  static String extractSummary(String responseText, {required String fallback}) {
    for (final line in responseText.split('\n').reversed) {
      final t = line.trim();
      if (t.startsWith('RSI_SUMMARY:')) {
        final body = t.substring('RSI_SUMMARY:'.length).trim();
        if (body.isNotEmpty) return body;
      }
    }
    for (final line in responseText.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty && !t.startsWith('#') && !t.startsWith('```')) {
        return t.length > 160 ? '${t.substring(0, 157)}...' : t;
      }
    }
    return fallback;
  }
}
