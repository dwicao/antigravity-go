import 'dart:async';
import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef AutomationTriggerCallback = Future<void> Function(
  AgyAutomation automation,
);

final automationsProvider =
    NotifierProvider<AutomationsNotifier, List<AgyAutomation>>(
  AutomationsNotifier.new,
);

class AutomationsNotifier extends Notifier<List<AgyAutomation>> {
  static const _prefsKey = 'agy_automations_v1';

  Timer? _schedulerTimer;
  AutomationTriggerCallback? onAutomationDue;

  @override
  List<AgyAutomation> build() {
    _schedulerTimer?.cancel();
    _schedulerTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(runDueAutomations()),
    );
    ref.onDispose(() {
      _schedulerTimer?.cancel();
      _schedulerTimer = null;
    });
    Future.microtask(_load);
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      state = decoded
          .whereType<Map<String, dynamic>>()
          .map(AgyAutomation.fromJson)
          .toList();
      await runDueAutomations();
    } catch (_) {}
  }

  Future<int> runDueAutomations({DateTime? now}) async {
    final cb = onAutomationDue;
    if (cb == null || state.isEmpty) return 0;
    final ts = now ?? DateTime.now();
    var count = 0;
    for (final a in state.toList()) {
      if (!a.isDueAt(ts)) continue;
      await markRun(a.id, 'Scheduled');
      await cb(a);
      count++;
    }
    return count;
  }

  Future<void> add({
    required String name,
    required String prompt,
    required String scheduleLabel,
    AutomationModelTier modelTier = AutomationModelTier.flash,
    String projectId = 'default',
  }) async {
    final item = AgyAutomation(
      id: const Uuid().v4(),
      name: name.trim(),
      prompt: prompt.trim(),
      scheduleLabel: scheduleLabel.trim(),
      modelTier: modelTier,
      projectId: projectId,
    );
    state = [item, ...state];
    await _persist();
  }

  Future<void> update(AgyAutomation updated) async {
    state = state.map((a) => a.id == updated.id ? updated : a).toList();
    await _persist();
  }

  Future<void> toggle(String id, bool enabled) async {
    state = state
        .map((a) => a.id == id ? a.copyWith(enabled: enabled) : a)
        .toList();
    await _persist();
  }

  Future<void> markRun(String id, String status) async {
    state = state
        .map(
          (a) => a.id == id
              ? a.copyWith(lastRunAt: DateTime.now(), lastStatus: status)
              : a,
        )
        .toList();
    await _persist();
  }

  Future<void> delete(String id) async {
    state = state.where((a) => a.id != id).toList();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(state.map((a) => a.toJson()).toList()),
    );
  }
}
