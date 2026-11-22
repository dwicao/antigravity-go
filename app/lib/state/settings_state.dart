import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.accent = AgyAccentPreset.indigo,
    this.localeCode = 'en',
    this.useG1Credits = false,
    this.dangerouslySkipPermissions = false,
    this.selectedModelId = 'Orchestrator (Neon)',
    this.reasoningEffort = 'medium',
    this.executionMode = 'auto',
  });

  final ThemeMode themeMode;
  final AgyAccentPreset accent;
  final String localeCode;
  final bool useG1Credits;
  final bool dangerouslySkipPermissions;
  final String selectedModelId;
  final String reasoningEffort;
  final String executionMode;

  AppSettings copyWith({
    ThemeMode? themeMode,
    AgyAccentPreset? accent,
    String? localeCode,
    bool? useG1Credits,
    bool? dangerouslySkipPermissions,
    String? selectedModelId,
    String? reasoningEffort,
    String? executionMode,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      accent: accent ?? this.accent,
      localeCode: localeCode ?? this.localeCode,
      useG1Credits: useG1Credits ?? this.useG1Credits,
      dangerouslySkipPermissions:
          dangerouslySkipPermissions ?? this.dangerouslySkipPermissions,
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
      dangerouslySkipPermissions:
          prefs.getBool('agy_skip_permissions') ?? false,
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

  Future<void> setSkipPermissions(bool enabled) async {
    state = state.copyWith(dangerouslySkipPermissions: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_skip_permissions', enabled);
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
