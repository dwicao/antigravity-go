import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import 'chat_state.dart';
import 'custom_providers_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'sessions_state.dart';
import 'settings_state.dart';

class HarnessState {
  const HarnessState({
    this.loopBreakerEnabled = true,
    this.autoCheckpointEnabled = true,
    this.autoVerifyEnabled = false,
    this.guardrailsEnabled = true,
    this.autoCompactEnabled = true,
    this.repoMapEnabled = true,
    this.initialized = false,
    this.loading = false,
    this.workspacePath = '',
    this.detectedVerifyCommand,
    this.customVerifyCommand,
    this.features = const <HarnessFeatureItem>[],
    this.progressLog = '',
    this.repoMapPreview = '',
    this.hooksConfig = const LifecycleHooksConfig(
      rules: LifecycleHooksConfig.defaults,
    ),
  });

  final bool loopBreakerEnabled;
  final bool autoCheckpointEnabled;
  final bool autoVerifyEnabled;
  final bool guardrailsEnabled;
  final bool autoCompactEnabled;
  final bool repoMapEnabled;
  final bool initialized;
  final bool loading;
  final String workspacePath;
  final String? detectedVerifyCommand;
  final String? customVerifyCommand;
  final List<HarnessFeatureItem> features;
  final String progressLog;
  final String repoMapPreview;
  final LifecycleHooksConfig hooksConfig;

  String? get effectiveVerifyCommand {
    final custom = customVerifyCommand?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    return detectedVerifyCommand;
  }

  ({int passed, int total}) get progressCounts {
    var passed = 0;
    for (final f in features) {
      if (f.passes) passed++;
    }
    return (passed: passed, total: features.length);
  }

  HarnessFeatureItem? get nextPendingFeature {
    for (final f in features) {
      if (!f.passes) return f;
    }
    return null;
  }

  HarnessState copyWith({
    bool? loopBreakerEnabled,
    bool? autoCheckpointEnabled,
    bool? autoVerifyEnabled,
    bool? guardrailsEnabled,
    bool? autoCompactEnabled,
    bool? repoMapEnabled,
    bool? initialized,
    bool? loading,
    String? workspacePath,
    String? detectedVerifyCommand,
    bool clearDetectedVerify = false,
    String? customVerifyCommand,
    bool clearCustomVerify = false,
    List<HarnessFeatureItem>? features,
    String? progressLog,
    String? repoMapPreview,
    LifecycleHooksConfig? hooksConfig,
  }) {
    return HarnessState(
      loopBreakerEnabled: loopBreakerEnabled ?? this.loopBreakerEnabled,
      autoCheckpointEnabled:
          autoCheckpointEnabled ?? this.autoCheckpointEnabled,
      autoVerifyEnabled: autoVerifyEnabled ?? this.autoVerifyEnabled,
      guardrailsEnabled: guardrailsEnabled ?? this.guardrailsEnabled,
      autoCompactEnabled: autoCompactEnabled ?? this.autoCompactEnabled,
      repoMapEnabled: repoMapEnabled ?? this.repoMapEnabled,
      initialized: initialized ?? this.initialized,
      loading: loading ?? this.loading,
      workspacePath: workspacePath ?? this.workspacePath,
      detectedVerifyCommand: clearDetectedVerify
          ? null
          : (detectedVerifyCommand ?? this.detectedVerifyCommand),
      customVerifyCommand: clearCustomVerify
          ? null
          : (customVerifyCommand ?? this.customVerifyCommand),
      features: features ?? this.features,
      progressLog: progressLog ?? this.progressLog,
      repoMapPreview: repoMapPreview ?? this.repoMapPreview,
      hooksConfig: hooksConfig ?? this.hooksConfig,
    );
  }
}

final harnessProvider =
    NotifierProvider<HarnessNotifier, HarnessState>(HarnessNotifier.new);

final contextBudgetProvider = Provider<HarnessContextSnapshot>((ref) {
  final messages = ref.watch(chatProvider.select((s) => s.messages));
  final selectedModelId =
      ref.watch(settingsProvider.select((s) => s.selectedModelId));
  final activeCustom = ref.watch(activeCustomProviderProvider);
  final lastCompactIdx = messages.lastIndexWhere((m) => m.isCompactionSummary);
  final activeMessages =
      lastCompactIdx >= 0 ? messages.sublist(lastCompactIdx) : messages;
  final compactedCount = lastCompactIdx >= 0 ? lastCompactIdx : 0;
  final threadModelId = activeMessages
          .where((m) => m.modelId != null && m.modelId!.isNotEmpty)
          .lastOrNull
          ?.modelId ??
      selectedModelId;
  final overrideBudget = (activeCustom != null &&
          (threadModelId == activeCustom.modelId ||
              activeMessages.isEmpty ||
              threadModelId == selectedModelId))
      ? activeCustom.contextWindowTokens
      : null;
  const monitor = HarnessContextMonitor();
  final estimated = monitor.evaluate(
    // Historical completed turns' internal thoughts are excluded from
    // subsequent API prompt windows; only include thoughts while streaming.
    messageTexts: activeMessages.map(
      (m) => m.isStreaming && m.thoughts.isNotEmpty
          ? '${m.text}\n${m.thoughts}'
          : m.text,
    ),
    toolOutputs: activeMessages.expand((m) => m.tools).map((t) {
      final params = t.parameters.isEmpty ? '' : jsonEncode(t.parameters);
      return '${t.toolName} $params ${t.output ?? ''} ${t.error ?? ''}';
    }),
    modelId: threadModelId,
    overrideBudgetTokens: overrideBudget,
    compactedMessages: compactedCount,
    activeMessages: activeMessages.length,
  );
  // When the backend reported real usage for an active turn, prefer the
  // single-step context occupancy (`contextTokens`) when known, or bound
  // cumulative multi-step turn `inputTokens` so tool loops don't inflate 10x.
  final lastUsageIdx = activeMessages.lastIndexWhere(
    (m) =>
        (m.contextTokens ?? 0) > 0 ||
        (m.usage?.contextTokens ?? 0) > 0 ||
        (m.usage?.inputTokens ?? 0) > 0,
  );
  if (lastUsageIdx >= 0) {
    final usageMsg = activeMessages[lastUsageIdx];
    final stepCtx =
        (usageMsg.contextTokens ?? 0) > 0
            ? usageMsg.contextTokens!
            : (usageMsg.usage?.contextTokens ?? 0);
    final int baseTokens;
    if (stepCtx > 0) {
      baseTokens = stepCtx;
    } else {
      final rawTurnTokens =
          (usageMsg.usage?.inputTokens ?? 0) + (usageMsg.usage?.outputTokens ?? 0);
      if (usageMsg.tools.isEmpty) {
        baseTokens = rawTurnTokens;
      } else {
        final prefixSnap = monitor.evaluate(
          messageTexts: activeMessages.take(lastUsageIdx + 1).map((m) => m.text),
          toolOutputs: activeMessages
              .take(lastUsageIdx + 1)
              .expand((m) => m.tools)
              .map((t) {
                final params =
                    t.parameters.isEmpty ? '' : jsonEncode(t.parameters);
                return '${t.toolName} $params ${t.output ?? ''} ${t.error ?? ''}';
              }),
          modelId: threadModelId,
        );
        baseTokens = math.min(rawTurnTokens, prefixSnap.usedTokens + 16000);
      }
    }
    final tailSnap = monitor.evaluate(
      messageTexts: activeMessages.skip(lastUsageIdx + 1).map((m) => m.text),
      toolOutputs: activeMessages
          .skip(lastUsageIdx + 1)
          .expand((m) => m.tools)
          .map((t) => '${t.toolName} ${t.output ?? ''} ${t.error ?? ''}'),
      modelId: threadModelId,
    );
    final combinedTokens = baseTokens + tailSnap.usedTokens;
    if (combinedTokens > estimated.usedTokens) {
      final budget = estimated.budgetTokens;
      final ratio = (combinedTokens / budget).clamp(0.0, 1.0);
      final shouldCompact = ratio >= monitor.compactThreshold;
      final needsWarning = ratio >= monitor.warningThreshold;
      return HarnessContextSnapshot(
        usedTokens: combinedTokens,
        budgetTokens: budget,
        ratio: ratio,
        needsWarning: needsWarning,
        shouldCompact: shouldCompact,
        statusLabel: shouldCompact
            ? 'High — compact recommended'
            : needsWarning
                ? 'Warming — watch context'
                : 'Healthy',
        compactedMessages: compactedCount,
        activeMessages: activeMessages.length,
      );
    }
  }
  return estimated;
});

class HarnessNotifier extends Notifier<HarnessState> {
  static const _kLoopBreaker = 'agy_harness_loop_breaker';
  static const _kAutoCheckpoint = 'agy_harness_auto_checkpoint';
  static const _kAutoVerify = 'agy_harness_auto_verify';
  static const _kGuardrails = 'agy_harness_guardrails';
  static const _kAutoCompact = 'agy_harness_auto_compact';
  static const _kRepoMap = 'agy_harness_repo_map';
  static const _kHooksJson = 'agy_harness_lifecycle_hooks';
  static const _kCustomVerify = 'agy_harness_custom_verify';

  @override
  HarnessState build() {
    unawaited(_loadPrefs());
    return const HarnessState();
  }

  String _activeWorkspace() {
    final sessionWs =
        ref.read(sessionsProvider).activeSession?.workspacePath.trim() ?? '';
    if (sessionWs.isNotEmpty) return sessionWs;
    final projectDir = ref.read(projectsProvider).activeProject.primaryFolder;
    if (projectDir.isNotEmpty) return projectDir;
    return ref.read(runtimeProvider).status.workspaceRoot ?? '';
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final guardrails = prefs.getBool(_kGuardrails) ?? true;
      final hooksRaw = prefs.getString(_kHooksJson) ?? '';
      final hooks = LifecycleHooksConfig.decodeJson(hooksRaw);
      state = state.copyWith(
        loopBreakerEnabled: prefs.getBool(_kLoopBreaker) ?? true,
        autoCheckpointEnabled: prefs.getBool(_kAutoCheckpoint) ?? true,
        autoVerifyEnabled: prefs.getBool(_kAutoVerify) ?? false,
        guardrailsEnabled: guardrails,
        autoCompactEnabled: prefs.getBool(_kAutoCompact) ?? true,
        repoMapEnabled: prefs.getBool(_kRepoMap) ?? true,
        customVerifyCommand: prefs.getString(_kCustomVerify),
        hooksConfig: hooks,
      );
      unawaited(RuntimeBridge.instance.setGuardrailsEnabled(guardrails));
      unawaited(RuntimeBridge.instance.setLifecycleHooks(hooks.encodeJson()));
    } catch (_) {}
  }

  Future<void> setLoopBreaker(bool value) async {
    state = state.copyWith(loopBreakerEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kLoopBreaker, value);
  }

  Future<void> setAutoCheckpoint(bool value) async {
    state = state.copyWith(autoCheckpointEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCheckpoint, value);
  }

  Future<void> setAutoVerify(bool value) async {
    state = state.copyWith(autoVerifyEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoVerify, value);
  }

  Future<void> setGuardrails(bool value) async {
    state = state.copyWith(guardrailsEnabled: value);
    unawaited(RuntimeBridge.instance.setGuardrailsEnabled(value));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGuardrails, value);
  }

  Future<void> setAutoCompact(bool value) async {
    state = state.copyWith(autoCompactEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoCompact, value);
  }

  Future<void> setRepoMapEnabled(bool value) async {
    state = state.copyWith(repoMapEnabled: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRepoMap, value);
  }

  Future<void> toggleHookRule(String ruleId, bool enabled) async {
    final nextRules = state.hooksConfig.rules
        .map((r) => r.id == ruleId ? r.copyWith(enabled: enabled) : r)
        .toList(growable: false);
    final next = LifecycleHooksConfig(rules: nextRules);
    await _saveHooks(next);
  }

  Future<void> addCustomHookRule(LifecycleHookRule rule) async {
    final next = LifecycleHooksConfig(rules: [...state.hooksConfig.rules, rule]);
    await _saveHooks(next);
  }

  Future<void> removeHookRule(String ruleId) async {
    final next = LifecycleHooksConfig(
      rules: state.hooksConfig.rules.where((r) => r.id != ruleId).toList(),
    );
    await _saveHooks(next);
  }

  Future<void> _saveHooks(LifecycleHooksConfig config) async {
    state = state.copyWith(hooksConfig: config);
    final encoded = config.encodeJson();
    unawaited(RuntimeBridge.instance.setLifecycleHooks(encoded));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHooksJson, encoded);
  }

  Future<String> refreshRepoMap({int maxTokens = 1400}) async {
    final cwd = _activeWorkspace();
    if (cwd.isEmpty) return '';
    final mapText = await RepoMapBuilder.buildFromDirectory(
      cwd,
      maxTokens: maxTokens,
    );
    if (ref.mounted) {
      state = state.copyWith(repoMapPreview: mapText);
    }
    return mapText;
  }

  Future<void> setCustomVerifyCommand(String? command) async {
    final clean = command?.trim() ?? '';
    state = state.copyWith(
      customVerifyCommand: clean.isEmpty ? null : clean,
      clearCustomVerify: clean.isEmpty,
    );
    final prefs = await SharedPreferences.getInstance();
    if (clean.isEmpty) {
      await prefs.remove(_kCustomVerify);
    } else {
      await prefs.setString(_kCustomVerify, clean);
    }
  }

  Future<void> refreshWorkspace() async {
    final cwd = _activeWorkspace();
    state = state.copyWith(loading: true, workspacePath: cwd);
    try {
      final raw = await RuntimeBridge.instance.readHarnessFiles(
        cwd: cwd.isEmpty ? null : cwd,
      );
      if (!ref.mounted) return;
      _applyWorkspacePayload(raw, fallbackWorkspace: cwd);
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(loading: false);
      }
    }
  }

  Future<void> initializeWorkspace(String goal) async {
    final cwd = _activeWorkspace();
    state = state.copyWith(loading: true, workspacePath: cwd);
    final pre = await RuntimeBridge.instance.readHarnessFiles(
      cwd: cwd.isEmpty ? null : cwd,
    );
    if (!ref.mounted) return;
    final detected = HarnessWorkspaceTemplates.detectVerifyCommand(
      isFlutter: pre['isFlutter'] == true,
      hasPubspec: pre['hasPubspec'] == true,
      hasPackageJson: pre['hasPackageJson'] == true,
      hasPyproject: pre['hasPyproject'] == true,
      hasCargoToml: pre['hasCargoToml'] == true,
      hasGradlew: pre['hasGradlew'] == true,
      gradlewCommand: pre['gradlewCommand']?.toString(),
    );
    final verify = state.customVerifyCommand?.trim().isNotEmpty == true
        ? state.customVerifyCommand!.trim()
        : detected;
    final raw = await RuntimeBridge.instance.initHarnessFiles(
      cwd: cwd.isEmpty ? null : cwd,
      featureJson: HarnessWorkspaceTemplates.defaultFeatureListJson(
        goal,
        verifyCommand: verify,
      ),
      progressTxt: HarnessWorkspaceTemplates.defaultProgressTxt(
        goal,
        verifyCommand: verify,
      ),
    );
    if (!ref.mounted) return;
    _applyWorkspacePayload(raw, fallbackWorkspace: cwd);
  }

  Future<void> toggleFeaturePasses(String featureId) async {
    final next = state.features
        .map(
          (f) => f.id == featureId
              ? f.copyWith(
                  passes: !f.passes,
                  verifiedAt:
                      !f.passes ? DateTime.now().toUtc().toIso8601String() : null,
                  clearVerifiedAt: f.passes,
                )
              : f,
        )
        .toList(growable: false);
    state = state.copyWith(features: next);
    final cwd = _activeWorkspace();
    await RuntimeBridge.instance.writeHarnessFile(
      cwd: cwd.isEmpty ? null : cwd,
      name: 'feature_list.json',
      content: HarnessFeatureItem.encodeFeatureList(next),
    );
  }

  Future<void> addFeature(
    String description, {
    String category = 'core',
  }) async {
    final clean = description.trim();
    if (clean.isEmpty) return;
    final cwd = _activeWorkspace();
    // Avoid overwriting corrupted feature_list.json if disk has parse errors.
    var base = state.features;
    try {
      final raw = await RuntimeBridge.instance.readHarnessFiles(
        cwd: cwd.isEmpty ? null : cwd,
      );
      if (!ref.mounted) return;
      final parsed = HarnessFeatureItem.parseFeatureListStrict(
        raw['featureList']?.toString() ?? '',
      );
      if (parsed.hasParseError) return;
      if (parsed.items.isNotEmpty) base = parsed.items;
    } catch (_) {}

    var maxNum = base.length;
    for (final f in base) {
      final m = RegExp(r'(\d+)$').firstMatch(f.id);
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    final id = 'F-${(maxNum + 1).toString().padLeft(3, '0')}';
    final next = <HarnessFeatureItem>[
      ...base,
      HarnessFeatureItem(
        id: id,
        category: category,
        description: clean,
        steps: <String>[
          if (state.effectiveVerifyCommand != null)
            'Verify with `${state.effectiveVerifyCommand}`',
        ],
      ),
    ];
    state = state.copyWith(initialized: true, features: next);
    await RuntimeBridge.instance.writeHarnessFile(
      cwd: cwd.isEmpty ? null : cwd,
      name: 'feature_list.json',
      content: HarnessFeatureItem.encodeFeatureList(next),
    );
  }

  void _applyWorkspacePayload(
    Map<String, Object?> raw, {
    required String fallbackWorkspace,
  }) {
    final detected = HarnessWorkspaceTemplates.detectVerifyCommand(
      isFlutter: raw['isFlutter'] == true,
      hasPubspec: raw['hasPubspec'] == true,
      hasPackageJson: raw['hasPackageJson'] == true,
      hasPyproject: raw['hasPyproject'] == true,
      hasCargoToml: raw['hasCargoToml'] == true,
      hasGradlew: raw['hasGradlew'] == true,
      gradlewCommand: raw['gradlewCommand']?.toString(),
    );
    final featRaw = raw['featureList']?.toString() ?? '';
    final features = HarnessFeatureItem.parseFeatureList(featRaw);
    state = state.copyWith(
      loading: false,
      initialized: raw['initialized'] == true || features.isNotEmpty,
      workspacePath: raw['workspace']?.toString().isNotEmpty == true
          ? raw['workspace'].toString()
          : fallbackWorkspace,
      detectedVerifyCommand: detected,
      clearDetectedVerify: detected == null,
      features: features,
      progressLog: raw['progressLog']?.toString() ?? '',
    );
  }
}
