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
  });

  final List<OpenAiProviderConfig> profiles;
  final String? activeProviderId;

  OpenAiProviderConfig? get activeProfile {
    if (activeProviderId == null || activeProviderId!.isEmpty) return null;
    for (final p in profiles) {
      if (p.id == activeProviderId) return p;
    }
    return null;
  }

  CustomProvidersState copyWith({
    List<OpenAiProviderConfig>? profiles,
    String? activeProviderId,
    bool clearActiveProvider = false,
  }) {
    return CustomProvidersState(
      profiles: profiles ?? this.profiles,
      activeProviderId: clearActiveProvider
          ? null
          : (activeProviderId ?? this.activeProviderId),
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
  static const _secure = FlutterSecureStorage();
  final Map<String, String> _memoryKeyFallback = {};

  @override
  CustomProvidersState build() {
    Future.microtask(_load);
    return const CustomProvidersState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final raw = prefs.getString(_profilesKey);
    final active = prefs.getString(_activeKey);
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
    state = CustomProvidersState(profiles: list, activeProviderId: validActive);
  }

  Future<void> selectProvider(String? providerId) async {
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
    state = CustomProvidersState(profiles: list, activeProviderId: nextActive);
    await _saveList(list);
    if (activate) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeKey, normalized.id);
    }
    return normalized;
  }

  Future<void> removeProfile(String id) async {
    final next = state.profiles.where((p) => p.id != id).toList();
    final clearActive = state.activeProviderId == id;
    state = state.copyWith(
      profiles: next,
      clearActiveProvider: clearActive,
    );
    await _deleteKey(id);
    await _saveList(next);
    if (clearActive) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeKey);
    }
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
