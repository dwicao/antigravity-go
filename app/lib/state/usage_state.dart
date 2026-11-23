import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/ssh_agy_runner.dart';
import '../runtime/runtime_bridge.dart';
import 'auth_state.dart';
import 'hosts_state.dart';
import 'settings_state.dart';

final usageProvider =
    NotifierProvider<UsageNotifier, UsageQuotaSnapshot>(UsageNotifier.new);

class UsageNotifier extends Notifier<UsageQuotaSnapshot> {
  static const _ledgerPrefsKey = 'agy_usage_ledger_v1';

  final UsageLedger _ledger = UsageLedger();
  ParsedUsageReport? _lastLiveProbe;
  String? _lastRawOutput;
  String? _lastProbeError;

  @override
  UsageQuotaSnapshot build() {
    ref.listen<bool>(
      settingsProvider.select((s) => s.useG1Credits),
      (_, _) => _emit(),
    );
    Future.microtask(_loadLedger);
    return _ledger.buildSnapshot();
  }

  Future<void> _loadLedger() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
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
    if (usage.totalTokens <= 0 &&
        usage.inputTokens <= 0 &&
        usage.outputTokens <= 0) {
      return;
    }
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
    if (!ref.mounted) return;
    await prefs.setString(
      _ledgerPrefsKey,
      jsonEncode(_ledger.records.map((r) => r.toJson()).toList()),
    );
  }

  /// Probes `agy` (on-device or active SSH workstation) for live `/usage`, `/credits`, and `agy models`.
  Future<void> refreshFromRuntime() async {
    _lastProbeError = null;
    try {
      String combined = '';
      final sshHost = ref.read(hostsProvider).activeSshHost;
      if (sshHost != null) {
        final (pwd, key) =
            await ref.read(hostsProvider.notifier).readCredentials(sshHost.id);
        combined = await SshAgyRunner.instance.probeUsage(
          host: sshHost,
          password: pwd,
          privateKeyPem: key,
        );
      } else {
        combined = await RuntimeBridge.instance.probeUsage();
      }

      final trimmed = combined.trim();
      if (trimmed.isNotEmpty) {
        _lastRawOutput = UsageOutputParser.stripAnsi(trimmed);
        _lastLiveProbe = UsageOutputParser.parseUsageText(trimmed);
        if (UsageOutputParser.outputIndicatesAuthenticated(trimmed)) {
          final email = UsageOutputParser.extractEmail(trimmed);
          ref.read(authProvider.notifier).markAuthenticatedFromTurn(email: email);
        }
      } else {
        _lastProbeError =
            'No output from agy yet. Make sure the on-device runtime is installed and signed in.';
      }
    } catch (e) {
      _lastProbeError = e.toString();
    }
    if (!ref.mounted) return;
    _emit();
  }

  void applyRawProbeOutput(String output) {
    _lastRawOutput = UsageOutputParser.stripAnsi(output);
    _lastLiveProbe = UsageOutputParser.parseUsageText(output);
    _lastProbeError = null;
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
      lastProbeError: _lastProbeError,
    );
  }
}
