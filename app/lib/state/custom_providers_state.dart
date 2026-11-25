import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class CustomProvidersState {
  const CustomProvidersState({
    this.profiles = const [],
    this.activeProviderId,
    this.fallbackProviderId,
    this.hybridOfflineFallbackEnabled = true,
  });

  final List<OpenAiProviderConfig> profiles;
  final String? activeProviderId;
  final String? fallbackProviderId;
  final bool hybridOfflineFallbackEnabled;

  OpenAiProviderConfig? get activeProfile {
    if (activeProviderId == null || activeProviderId!.isEmpty) return null;
    for (final p in profiles) {
      if (p.id == activeProviderId) return p;
    }
    return null;
  }

  OpenAiProviderConfig? get fallbackProfile {
    if (fallbackProviderId != null && fallbackProviderId!.isNotEmpty) {
      for (final p in profiles) {
        if (p.id == fallbackProviderId) return p;
      }
    }
    for (final p in profiles) {
      if (p.isLocalEndpoint) return p;
    }
    return null;
  }

  CustomProvidersState copyWith({
    List<OpenAiProviderConfig>? profiles,
    String? activeProviderId,
    bool clearActiveProvider = false,
    String? fallbackProviderId,
    bool clearFallbackProvider = false,
    bool? hybridOfflineFallbackEnabled,
  }) {
    return CustomProvidersState(
      profiles: profiles ?? this.profiles,
      activeProviderId: clearActiveProvider
          ? null
          : (activeProviderId ?? this.activeProviderId),
      fallbackProviderId: clearFallbackProvider
          ? null
          : (fallbackProviderId ?? this.fallbackProviderId),
      hybridOfflineFallbackEnabled:
          hybridOfflineFallbackEnabled ?? this.hybridOfflineFallbackEnabled,
    );
  }
}

final customProvidersProvider =
    NotifierProvider<CustomProvidersNotifier, CustomProvidersState>(
  CustomProvidersNotifier.new,
);

final activeCustomProviderProvider = Provider<OpenAiProviderConfig?>((ref) {
  return ref.watch(customProvidersProvider).activeProfile;
});

class CustomProvidersNotifier extends Notifier<CustomProvidersState> {
  static const _profilesKey = 'agy_openai_providers_v1';
  static const _activeKey = 'agy_active_openai_provider_id';
  static const _fallbackKey = 'agy_hybrid_fallback_provider_id';
  static const _hybridEnabledKey = 'agy_hybrid_fallback_enabled';
  static const _secure = FlutterSecureStorage();
  final Map<String, String> _memoryKeyFallback = {};
  Future<void>? _loadFuture;

  @override
  CustomProvidersState build() {
    _loadFuture = _load();
    return const CustomProvidersState();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final raw = prefs.getString(_profilesKey);
      final active = prefs.getString(_activeKey);
      final fallback = prefs.getString(_fallbackKey);
      final hybridEnabled = prefs.getBool(_hybridEnabledKey) ?? true;
      final list = <OpenAiProviderConfig>[];
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw) as List<dynamic>;
          for (final item in decoded.whereType<Map<String, dynamic>>()) {
            final parsed = OpenAiProviderConfig.fromJson(item);
            if (parsed.id.isNotEmpty) list.add(parsed);
          }
        } catch (_) {}
      }
      final validActive = (active != null && list.any((p) => p.id == active))
          ? active
          : null;
      final validFallback =
          (fallback != null && list.any((p) => p.id == fallback))
              ? fallback
              : null;
      state = CustomProvidersState(
        profiles: list,
        activeProviderId: validActive,
        fallbackProviderId: validFallback,
        hybridOfflineFallbackEnabled: hybridEnabled,
      );
    } catch (_) {}
  }

  Future<void> selectProvider(String? providerId) async {
    await _loadFuture;
    if (!ref.mounted) return;
    final valid = providerId != null &&
            providerId.isNotEmpty &&
            state.profiles.any((p) => p.id == providerId)
        ? providerId
        : null;
    state = state.copyWith(
      activeProviderId: valid,
      clearActiveProvider: valid == null,
    );
    final prefs = await SharedPreferences.getInstance();
    if (valid == null) {
      await prefs.remove(_activeKey);
    } else {
      await prefs.setString(_activeKey, valid);
    }
  }

  Future<OpenAiProviderConfig> addOrUpdateProfile(
    OpenAiProviderConfig profile, {
    String? apiKey,
    bool activate = false,
  }) async {
    await _loadFuture;
    final normalized = profile.id.isEmpty
        ? OpenAiProviderConfig(
            id: const Uuid().v4(),
            name: profile.name.trim(),
            baseUrl: OpenAiProviderConfig.normalizeBaseUrl(profile.baseUrl),
            modelId: profile.modelId.trim(),
            contextWindowTokens: profile.contextWindowTokens,
            supportsTools: profile.supportsTools,
            supportsVision: profile.supportsVision,
            systemPrompt: profile.systemPrompt.trim(),
          )
        : profile.copyWith(
            name: profile.name.trim(),
            baseUrl: OpenAiProviderConfig.normalizeBaseUrl(profile.baseUrl),
            modelId: profile.modelId.trim(),
            systemPrompt: profile.systemPrompt.trim(),
          );

    final list = [...state.profiles];
    final idx = list.indexWhere((p) => p.id == normalized.id);
    if (idx >= 0) {
      list[idx] = normalized;
    } else {
      list.add(normalized);
    }

    if (apiKey != null && apiKey.trim().isNotEmpty) {
      await _writeKey(normalized.id, apiKey.trim());
    }

    final nextActive = activate ? normalized.id : state.activeProviderId;
    if (ref.mounted) {
      state = CustomProvidersState(profiles: list, activeProviderId: nextActive);
    }
    await _saveList(list);
    if (activate) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeKey, normalized.id);
    }
    return normalized;
  }

  Future<void> removeProfile(String id) async {
    await _loadFuture;
    final next = state.profiles.where((p) => p.id != id).toList();
    final clearActive = state.activeProviderId == id;
    if (ref.mounted) {
      state = state.copyWith(
        profiles: next,
        clearActiveProvider: clearActive,
      );
    }
    await _deleteKey(id);
    await _saveList(next);
    if (clearActive) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeKey);
    }
  }

  Future<void> setFallbackProvider(String? providerId) async {
    await _loadFuture;
    if (!ref.mounted) return;
    final valid = providerId != null &&
            providerId.isNotEmpty &&
            state.profiles.any((p) => p.id == providerId)
        ? providerId
        : null;
    state = state.copyWith(
      fallbackProviderId: valid,
      clearFallbackProvider: valid == null,
    );
    final prefs = await SharedPreferences.getInstance();
    if (valid == null) {
      await prefs.remove(_fallbackKey);
    } else {
      await prefs.setString(_fallbackKey, valid);
    }
  }

  Future<void> setHybridOfflineFallbackEnabled(bool enabled) async {
    state = state.copyWith(hybridOfflineFallbackEnabled: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hybridEnabledKey, enabled);
  }

  Future<String?> readApiKey(String id) async {
    try {
      final v = await _secure.read(key: 'openai_key_$id');
      if (v != null && v.isNotEmpty) return v;
    } on MissingPluginException {
      // Fallback in widget tests.
    } catch (_) {}
    return _memoryKeyFallback[id];
  }

  Future<void> _writeKey(String id, String key) async {
    _memoryKeyFallback[id] = key;
    try {
      await _secure.write(key: 'openai_key_$id', value: key);
    } on MissingPluginException {
      // No-op in tests.
    } catch (_) {}
  }

  Future<void> _deleteKey(String id) async {
    _memoryKeyFallback.remove(id);
    try {
      await _secure.delete(key: 'openai_key_$id');
    } on MissingPluginException {
      // No-op in tests.
    } catch (_) {}
  }

  Future<void> _saveList(List<OpenAiProviderConfig> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _profilesKey,
      jsonEncode(list.map((p) => p.toJson()).toList()),
    );
  }
}
