import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import 'chat_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'settings_state.dart';

class HarnessState {
  const HarnessState({
    this.loopBreakerEnabled = true,
    this.autoCheckpointEnabled = true,
    this.autoVerifyEnabled = false,
    this.guardrailsEnabled = true,
    this.initialized = false,
    this.loading = false,
    this.workspacePath = '',
    this.detectedVerifyCommand,
    this.customVerifyCommand,
    this.features = const <HarnessFeatureItem>[],
    this.progressLog = '',
  });

  final bool loopBreakerEnabled;
  final bool autoCheckpointEnabled;
  final bool autoVerifyEnabled;
  final bool guardrailsEnabled;
  final bool initialized;
  final bool loading;
  final String workspacePath;
  final String? detectedVerifyCommand;
  final String? customVerifyCommand;
  final List<HarnessFeatureItem> features;
  final String progressLog;

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
    bool? initialized,
    bool? loading,
    String? workspacePath,
    String? detectedVerifyCommand,
    bool clearDetectedVerify = false,
    String? customVerifyCommand,
    bool clearCustomVerify = false,
    List<HarnessFeatureItem>? features,
    String? progressLog,
  }) {
    return HarnessState(
      loopBreakerEnabled: loopBreakerEnabled ?? this.loopBreakerEnabled,
      autoCheckpointEnabled:
          autoCheckpointEnabled ?? this.autoCheckpointEnabled,
      autoVerifyEnabled: autoVerifyEnabled ?? this.autoVerifyEnabled,
      guardrailsEnabled: guardrailsEnabled ?? this.guardrailsEnabled,
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
    );
  }
}

final harnessProvider =
    NotifierProvider<HarnessNotifier, HarnessState>(HarnessNotifier.new);

final contextBudgetProvider = Provider<HarnessContextSnapshot>((ref) {
  final messages = ref.watch(chatProvider.select((s) => s.messages));
  final modelId = ref.watch(settingsProvider.select((s) => s.selectedModelId));
  const monitor = HarnessContextMonitor();
  return monitor.evaluate(
    messageTexts: messages.map((m) => '${m.text}\n${m.thoughts}'),
    toolOutputs: messages
        .expand((m) => m.tools)
        .map((t) => '${t.toolName} ${t.output ?? ''} ${t.error ?? ''}'),
    modelId: modelId,
  );
});

class HarnessNotifier extends Notifier<HarnessState> {
  static const _kLoopBreaker = 'agy_harness_loop_breaker';
  static const _kAutoCheckpoint = 'agy_harness_auto_checkpoint';
  static const _kAutoVerify = 'agy_harness_auto_verify';
  static const _kGuardrails = 'agy_harness_guardrails';
  static const _kCustomVerify = 'agy_harness_custom_verify';

  @override
  HarnessState build() {
    unawaited(_loadPrefs());
    return const HarnessState();
  }

  String _activeWorkspace() {
    final projectDir = ref.read(projectsProvider).activeProject.primaryFolder;
    if (projectDir.isNotEmpty) return projectDir;
    return ref.read(runtimeProvider).status.workspaceRoot ?? '';
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = state.copyWith(
        loopBreakerEnabled: prefs.getBool(_kLoopBreaker) ?? true,
        autoCheckpointEnabled: prefs.getBool(_kAutoCheckpoint) ?? true,
        autoVerifyEnabled: prefs.getBool(_kAutoVerify) ?? false,
        guardrailsEnabled: prefs.getBool(_kGuardrails) ?? true,
        customVerifyCommand: prefs.getString(_kCustomVerify),
      );
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGuardrails, value);
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
    final raw = await RuntimeBridge.instance.readHarnessFiles(
      cwd: cwd.isEmpty ? null : cwd,
    );
    if (!ref.mounted) return;
    _applyWorkspacePayload(raw, fallbackWorkspace: cwd);
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
    final nextNum = state.features.length + 1;
    final id = 'F-${nextNum.toString().padLeft(3, '0')}';
    final next = <HarnessFeatureItem>[
      ...state.features,
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
    final cwd = _activeWorkspace();
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
