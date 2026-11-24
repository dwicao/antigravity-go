import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../phone/phone_bridge.dart';

typedef AutomationTriggerCallback = Future<void> Function(
  AgyAutomation automation,
);

final automationsProvider =
    NotifierProvider<AutomationsNotifier, List<AgyAutomation>>(
  AutomationsNotifier.new,
);

class AutomationsNotifier extends Notifier<List<AgyAutomation>> {
  static const _prefsKey = 'agy_automations_v1';
  static const _nativeChannel = MethodChannel('agy/automations');

  Timer? _schedulerTimer;
  AutomationTriggerCallback? onAutomationDue;
  final Map<String, DateTime> _fileMtimes = {};
  final Map<String, int> _githubCounts = {};
  Future<int?> Function(String repo, String endpoint)? githubOpenCountOverride;
  Future<int?> Function()? batteryLevelOverride;

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
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        var loaded = decoded
            .whereType<Map<String, dynamic>>()
            .map(AgyAutomation.fromJson)
            .toList();
        loaded = await _mergeNativeRuns(loaded);
        if (!ref.mounted) return;
        state = loaded;
        await _syncNative(loaded);
        await runDueAutomations();
      } catch (_) {}
    }
  }

  Future<List<AgyAutomation>> _mergeNativeRuns(
    List<AgyAutomation> items,
  ) async {
    try {
      final rawRuns =
          await _nativeChannel.invokeMethod<List<Object?>>('pullRuns');
      if (rawRuns == null || rawRuns.isEmpty) return items;
      final byId = <String, ({DateTime runAt, String? status})>{};
      for (final entry in rawRuns.whereType<Map<Object?, Object?>>()) {
        final id = entry['id']?.toString();
        final iso = entry['lastRunAt']?.toString();
        final dt = iso != null ? DateTime.tryParse(iso) : null;
        if (id != null && dt != null) {
          byId[id] = (runAt: dt, status: entry['lastStatus']?.toString());
        }
      }
      var mergedAny = false;
      final out = items.map((a) {
        final native = byId[a.id];
        if (native == null) return a;
        if (a.lastRunAt == null || native.runAt.isAfter(a.lastRunAt!)) {
          mergedAny = true;
          return a.copyWith(
            lastRunAt: native.runAt,
            lastStatus: native.status ?? a.lastStatus,
          );
        }
        return a;
      }).toList();
      if (mergedAny) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _prefsKey,
          jsonEncode(out.map((a) => a.toJson()).toList()),
        );
      }
      return out;
    } on MissingPluginException {
      return items;
    } catch (_) {
      return items;
    }
  }

  Future<void> _syncNative(List<AgyAutomation> items) async {
    try {
      await _nativeChannel.invokeMethod<void>('sync', {
        'items': items.map((a) => a.toJson()).toList(),
      });
    } on MissingPluginException {
      // No-op in tests or non-Android platforms.
    } catch (_) {}
  }

  Future<bool> _isDaemonTriggerDue(AgyAutomation a, DateTime ts) async {
    if (!a.enabled) return false;
    switch (a.triggerType) {
      case AutomationTriggerType.schedule:
        return a.isDueAt(ts);
      case AutomationTriggerType.fileWatch:
        final p = a.triggerTarget.trim();
        if (p.isEmpty) return false;
        try {
          final type = FileSystemEntity.typeSync(p);
          if (type == FileSystemEntityType.notFound) return false;
          final stat = type == FileSystemEntityType.directory
              ? Directory(p).statSync()
              : File(p).statSync();
          final prev = _fileMtimes[a.id];
          _fileMtimes[a.id] = stat.modified;
          if (prev == null) return false;
          return stat.modified.isAfter(prev);
        } catch (_) {
          return false;
        }
      case AutomationTriggerType.githubPr:
      case AutomationTriggerType.githubIssue:
        final repo = a.triggerTarget.trim();
        if (!repo.contains('/')) return false;
        final endpoint = a.triggerType == AutomationTriggerType.githubPr
            ? 'pulls'
            : 'issues';
        final count = await _fetchGitHubOpenCount(repo, endpoint);
        if (count == null) return false;
        final prev = _githubCounts[a.id];
        _githubCounts[a.id] = count;
        return prev != null && count > prev;
      case AutomationTriggerType.batteryBelow:
        final threshold = int.tryParse(a.triggerTarget.trim());
        if (threshold == null || threshold <= 0) return false;
        if (a.lastRunAt != null &&
            ts.difference(a.lastRunAt!) < const Duration(minutes: 30)) {
          return false;
        }
        final pct = await _readBatteryPct();
        return pct != null && pct <= threshold;
    }
  }

  Future<int?> _fetchGitHubOpenCount(String repo, String endpoint) async {
    final override = githubOpenCountOverride;
    if (override != null) return override(repo, endpoint);
    try {
      final res = await http
          .get(
            Uri.https('api.github.com', '/repos/$repo/$endpoint', {'state': 'open'}),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is List) return decoded.length;
    } catch (_) {}
    return null;
  }

  Future<int?> _readBatteryPct() async {
    final override = batteryLevelOverride;
    if (override != null) return override();
    final info = await PhoneBridge.instance.getDeviceInfo();
    return (info['battery'] as num?)?.toInt();
  }

  Future<int> runDueAutomations({DateTime? now}) async {
    final cb = onAutomationDue;
    if (cb == null || state.isEmpty) return 0;
    final ts = now ?? DateTime.now();
    var count = 0;
    for (final a in state.toList()) {
      if (!await _isDaemonTriggerDue(a, ts)) continue;
      await markRun(a.id, a.triggerType.label);
      if (a.notifyOnComplete) {
        await PhoneBridge.instance.postNotification(
          title: 'Automation: ${a.name}',
          message: '${a.triggerType.label} triggered',
          tag: 'auto_${a.id}',
        );
      }
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
    AutomationTriggerType triggerType = AutomationTriggerType.schedule,
    String triggerTarget = '',
    bool notifyOnComplete = true,
    String projectId = 'default',
  }) async {
    final item = AgyAutomation(
      id: const Uuid().v4(),
      name: name.trim(),
      prompt: prompt.trim(),
      scheduleLabel: scheduleLabel.trim(),
      modelTier: modelTier,
      triggerType: triggerType,
      triggerTarget: triggerTarget.trim(),
      notifyOnComplete: notifyOnComplete,
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
    await _syncNative(state);
  }
}
