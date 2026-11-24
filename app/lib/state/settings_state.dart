import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import '../theme/app_theme.dart';

enum DesktopLayoutOverride {
  auto('Auto'),
  desktop('Desktop'),
  mobile('Mobile');

  const DesktopLayoutOverride(this.label);

  final String label;
}

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accent = AgyAccentPreset.indigo,
    this.localeCode = 'en',
    this.useG1Credits = false,
    this.permissionPreset = AntigravityPermissionPreset.turbo,
    this.allowNonWorkspaceAccess = true,
    this.layoutMode = AntigravityLayoutMode.softwareEngineering,
    this.desktopLayout = DesktopLayoutOverride.auto,
    this.hapticOnComplete = true,
    this.selectedModelId = 'Orchestrator (Neon)',
    this.reasoningEffort = 'medium',
    this.executionMode = 'default',
    this.activeAgent = '',
    this.printTimeoutSeconds = 0,
    this.disableSlashCommands = false,
    this.continueLast = false,
    this.remoteAgent = '',
  });

  final ThemeMode themeMode;
  final AgyAccentPreset accent;
  final String localeCode;
  final bool useG1Credits;
  final AntigravityPermissionPreset permissionPreset;
  final bool allowNonWorkspaceAccess;
  final AntigravityLayoutMode layoutMode;
  final DesktopLayoutOverride desktopLayout;
  final bool hapticOnComplete;
  final String selectedModelId;
  final String reasoningEffort;
  final String executionMode;
  final String activeAgent;
  final int printTimeoutSeconds;
  final bool disableSlashCommands;
  final bool continueLast;
  final String remoteAgent;

  bool get dangerouslySkipPermissions =>
      permissionPreset == AntigravityPermissionPreset.turbo;

  AppSettings copyWith({
    ThemeMode? themeMode,
    AgyAccentPreset? accent,
    String? localeCode,
    bool? useG1Credits,
    AntigravityPermissionPreset? permissionPreset,
    bool? allowNonWorkspaceAccess,
    AntigravityLayoutMode? layoutMode,
    DesktopLayoutOverride? desktopLayout,
    bool? hapticOnComplete,
    String? selectedModelId,
    String? reasoningEffort,
    String? executionMode,
    String? activeAgent,
    int? printTimeoutSeconds,
    bool? disableSlashCommands,
    bool? continueLast,
    String? remoteAgent,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      localeCode: localeCode ?? this.localeCode,
      useG1Credits: useG1Credits ?? this.useG1Credits,
      permissionPreset: permissionPreset ?? this.permissionPreset,
      allowNonWorkspaceAccess:
          allowNonWorkspaceAccess ?? this.allowNonWorkspaceAccess,
      layoutMode: layoutMode ?? this.layoutMode,
      desktopLayout: desktopLayout ?? this.desktopLayout,
      hapticOnComplete: hapticOnComplete ?? this.hapticOnComplete,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      executionMode: executionMode ?? this.executionMode,
      activeAgent: activeAgent ?? this.activeAgent,
      printTimeoutSeconds: printTimeoutSeconds ?? this.printTimeoutSeconds,
      disableSlashCommands:
          disableSlashCommands ?? this.disableSlashCommands,
      continueLast: continueLast ?? this.continueLast,
      remoteAgent: remoteAgent ?? this.remoteAgent,
    );
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  final Set<String> _dirtyKeys = <String>{};

  @override
  AppSettings build() {
    Future.microtask(_load);
    return const AppSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final themeName = prefs.getString('agy_theme_mode');
    final accentName = prefs.getString('agy_accent');
    final presetName = prefs.getString('agy_permission_preset');
    final layoutName = prefs.getString('agy_layout_mode');
    final legacySkip = prefs.getBool('agy_skip_permissions');

    // DSH-go style repair: older versions persisted `auto`, which requires a
    // desktop OS terminal sandbox unavailable on Android.
    var resolvedPreset = presetName != null
        ? AntigravityPermissionPreset.fromString(presetName).androidSafe
        : (legacySkip == false
            ? AntigravityPermissionPreset.standard
            : AntigravityPermissionPreset.turbo);
    if (presetName == 'auto') {
      await prefs.setString('agy_permission_preset', resolvedPreset.name);
      await prefs.setBool(
        'agy_skip_permissions',
        resolvedPreset == AntigravityPermissionPreset.turbo,
      );
    }

    var savedExecMode = prefs.getString('agy_exec_mode') ?? 'default';
    if (savedExecMode == 'auto') {
      savedExecMode = 'default';
      await prefs.setString('agy_exec_mode', savedExecMode);
    }

    if (!ref.mounted) return;
    final desktopName = prefs.getString('agy_desktop_layout');
    state = state.copyWith(
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == themeName,
        orElse: () => ThemeMode.dark,
      ),
      accent: AgyAccentPreset.values.firstWhere(
        (a) => a.name == accentName,
        orElse: () => AgyAccentPreset.indigo,
      ),
      localeCode: prefs.getString('agy_locale') ?? 'en',
      useG1Credits: prefs.getBool('agy_use_g1_credits') ?? false,
      permissionPreset: resolvedPreset,
      allowNonWorkspaceAccess:
          prefs.getBool('agy_allow_non_workspace') ?? true,
      layoutMode: AntigravityLayoutMode.values.firstWhere(
        (l) => l.name == layoutName,
        orElse: () => AntigravityLayoutMode.softwareEngineering,
      ),
      desktopLayout: _dirtyKeys.contains('agy_desktop_layout')
          ? state.desktopLayout
          : DesktopLayoutOverride.values.firstWhere(
              (d) => d.name == desktopName,
              orElse: () => DesktopLayoutOverride.auto,
            ),
      hapticOnComplete: _dirtyKeys.contains('agy_haptic_on_complete')
          ? state.hapticOnComplete
          : (prefs.getBool('agy_haptic_on_complete') ?? true),
      selectedModelId:
          prefs.getString('agy_selected_model') ?? 'Orchestrator (Neon)',
      reasoningEffort: prefs.getString('agy_effort') ?? 'medium',
      executionMode: savedExecMode,
      activeAgent: prefs.getString('agy_active_agent') ?? '',
      printTimeoutSeconds: prefs.getInt('agy_print_timeout') ?? 0,
      disableSlashCommands:
          prefs.getBool('agy_disable_slash_commands') ?? false,
      continueLast: prefs.getBool('agy_continue_last') ?? false,
      remoteAgent: prefs.getString('agy_remote_agent') ?? '',
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_theme_mode', mode.name);
  }

  Future<void> setAccent(AgyAccentPreset accent) async {
    state = state.copyWith(accent: accent);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_accent', accent.name);
  }

  Future<void> setLocaleCode(String code) async {
    state = state.copyWith(localeCode: code);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_locale', code);
  }

  Future<void> setUseG1Credits(bool enabled) async {
    state = state.copyWith(useG1Credits: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_use_g1_credits', enabled);
  }

  Future<void> setPermissionPreset(AntigravityPermissionPreset preset) async {
    state = state.copyWith(permissionPreset: preset);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_permission_preset', preset.name);
    await prefs.setBool(
      'agy_skip_permissions',
      preset == AntigravityPermissionPreset.turbo,
    );
    try {
      await RuntimeBridge.instance.writeCliSettings({
        'toolPermission': preset.cliValue,
      });
    } catch (_) {}
  }

  Future<void> setSkipPermissions(bool enabled) {
    return setPermissionPreset(
      enabled
          ? AntigravityPermissionPreset.turbo
          : AntigravityPermissionPreset.standard,
    );
  }

  Future<void> setAllowNonWorkspaceAccess(bool enabled) async {
    state = state.copyWith(allowNonWorkspaceAccess: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_allow_non_workspace', enabled);
    try {
      await RuntimeBridge.instance.writeCliSettings({
        'allowNonWorkspaceAccess': enabled,
      });
    } catch (_) {}
  }

  Future<void> setLayoutMode(AntigravityLayoutMode mode) async {
    state = state.copyWith(layoutMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_layout_mode', mode.name);
  }

  Future<void> setDesktopLayout(DesktopLayoutOverride mode) async {
    _dirtyKeys.add('agy_desktop_layout');
    state = state.copyWith(desktopLayout: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_desktop_layout', mode.name);
  }

  Future<void> setHapticOnComplete(bool enabled) async {
    _dirtyKeys.add('agy_haptic_on_complete');
    state = state.copyWith(hapticOnComplete: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_haptic_on_complete', enabled);
  }

  Future<void> setModel(String modelId) async {
    state = state.copyWith(selectedModelId: modelId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_selected_model', modelId);
  }

  Future<void> setEffort(String effort) async {
    state = state.copyWith(reasoningEffort: effort);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_effort', effort);
  }

  Future<void> setExecutionMode(String mode) async {
    state = state.copyWith(executionMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_exec_mode', mode);
  }

  Future<void> setActiveAgent(String agent) async {
    state = state.copyWith(activeAgent: agent);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_active_agent', agent);
  }

  Future<void> setPrintTimeoutSeconds(int seconds) async {
    final safe = seconds < 0 ? 0 : seconds;
    state = state.copyWith(printTimeoutSeconds: safe);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('agy_print_timeout', safe);
  }

  Future<void> setDisableSlashCommands(bool disabled) async {
    state = state.copyWith(disableSlashCommands: disabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_disable_slash_commands', disabled);
  }

  Future<void> setContinueLast(bool enabled) async {
    state = state.copyWith(continueLast: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_continue_last', enabled);
  }

  Future<void> setRemoteAgent(String remoteAgent) async {
    state = state.copyWith(remoteAgent: remoteAgent);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_remote_agent', remoteAgent);
  }
}
