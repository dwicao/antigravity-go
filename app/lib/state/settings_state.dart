import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import '../theme/app_theme.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accent = AgyAccentPreset.indigo,
    this.localeCode = 'en',
    this.useG1Credits = false,
    this.permissionPreset = AntigravityPermissionPreset.auto,
    this.allowNonWorkspaceAccess = true,
    this.layoutMode = AntigravityLayoutMode.softwareEngineering,
    this.selectedModelId = 'Orchestrator (Neon)',
    this.reasoningEffort = 'medium',
    this.executionMode = 'auto',
  });

  final ThemeMode themeMode;
  final AgyAccentPreset accent;
  final String localeCode;
  final bool useG1Credits;
  final AntigravityPermissionPreset permissionPreset;
  final bool allowNonWorkspaceAccess;
  final AntigravityLayoutMode layoutMode;
  final String selectedModelId;
  final String reasoningEffort;
  final String executionMode;

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
    String? selectedModelId,
    String? reasoningEffort,
    String? executionMode,
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
      selectedModelId: selectedModelId ?? this.selectedModelId,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      executionMode: executionMode ?? this.executionMode,
    );
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    Future.microtask(_load);
    return const AppSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString('agy_theme_mode');
    final accentName = prefs.getString('agy_accent');
    final presetName = prefs.getString('agy_permission_preset');
    final layoutName = prefs.getString('agy_layout_mode');
    final legacySkip = prefs.getBool('agy_skip_permissions') ?? false;
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
      permissionPreset: presetName != null
          ? AntigravityPermissionPreset.fromString(presetName)
          : (legacySkip
              ? AntigravityPermissionPreset.turbo
              : AntigravityPermissionPreset.auto),
      allowNonWorkspaceAccess:
          prefs.getBool('agy_allow_non_workspace') ?? true,
      layoutMode: AntigravityLayoutMode.values.firstWhere(
        (l) => l.name == layoutName,
        orElse: () => AntigravityLayoutMode.softwareEngineering,
      ),
      selectedModelId:
          prefs.getString('agy_selected_model') ?? 'Orchestrator (Neon)',
      reasoningEffort: prefs.getString('agy_effort') ?? 'medium',
      executionMode: prefs.getString('agy_exec_mode') ?? 'auto',
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
          : AntigravityPermissionPreset.auto,
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
}
