import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/runtime_bridge.dart';
import '../state/settings_state.dart';

final usageProvider =
    NotifierProvider<UsageNotifier, UsageQuotaSnapshot>(UsageNotifier.new);

class UsageNotifier extends Notifier<UsageQuotaSnapshot> {
  static const _ledgerPrefsKey = 'agy_usage_ledger_v1';

  final UsageLedger _ledger = UsageLedger();
  ParsedUsageReport? _lastLiveProbe;
  String? _lastRawOutput;

  @override
  UsageQuotaSnapshot build() {
    Future.microtask(_loadLedger);
    return _ledger.buildSnapshot();
  }

  Future<void> _loadLedger() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_ledgerPrefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          _ledger.add(UsageLedgerRecord.fromJson(item));
        }
      } catch (_) {
        // Ignore corrupt cache and rebuild cleanly.
      }
    }
    _emit();
  }

  Future<void> recordTurn({
    required String modelId,
    required TokenUsage usage,
    String? sessionId,
  }) async {
    _ledger.add(
      UsageLedgerRecord(
        timestamp: DateTime.now().toUtc(),
        modelId: modelId,
        usage: usage,
        sessionId: sessionId,
      ),
    );
    _emit();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _ledgerPrefsKey,
      jsonEncode(_ledger.records.map((r) => r.toJson()).toList()),
    );
  }

  /// Probes `agy` on device for live `/usage`, `/credits`, and `agy models` limits.
  Future<void> refreshFromRuntime() async {
    try {
      final modelsOut = await RuntimeBridge.instance.runCommandCapture(
        args: ['models'],
        timeoutSeconds: 15,
      );
      final usageOut = await RuntimeBridge.instance.runCommandCapture(
        args: ['-p', '/usage', '--output-format', 'text'],
        timeoutSeconds: 20,
      );
      final creditsOut = await RuntimeBridge.instance.runCommandCapture(
        args: ['-p', '/credits', '--output-format', 'text'],
        timeoutSeconds: 15,
      );
      final combined = '$usageOut\n$creditsOut\n$modelsOut'.trim();
      if (combined.isNotEmpty) {
        _lastRawOutput = combined;
        _lastLiveProbe = UsageOutputParser.parseUsageText(combined);
      }
    } catch (_) {
      // Keep local ledger snapshot if agy isn't installed or offline.
    }
    _emit();
  }

  void applyRawProbeOutput(String output) {
    _lastRawOutput = output;
    _lastLiveProbe = UsageOutputParser.parseUsageText(output);
    _emit();
  }

  Future<void> toggleUseG1Credits(bool enabled) async {
    await ref.read(settingsProvider.notifier).setUseG1Credits(enabled);
    try {
      await RuntimeBridge.instance.writeCliSettings({'useG1Credits': enabled});
    } catch (_) {}
    _emit();
  }

  void _emit() {
    final useCredits = ref.read(settingsProvider).useG1Credits;
    state = _ledger.buildSnapshot(
      liveProbe: _lastLiveProbe,
      useG1Credits: useCredits,
      rawProbeOutput: _lastRawOutput,
    );
  }
}
