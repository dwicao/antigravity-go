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
  static const _probeCachePrefsKey = 'agy_usage_probe_cache_v1';
  static const Duration _probeFreshnessWindow = Duration(seconds: 60);

  final UsageLedger _ledger = UsageLedger();
  ParsedUsageReport? _lastLiveProbe;
  String? _lastRawOutput;
  String? _lastProbeError;
  DateTime? _lastProbeAt;
  Future<void>? _inFlightProbe;

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
    final probeCacheRaw = prefs.getString(_probeCachePrefsKey);
    if (probeCacheRaw != null && probeCacheRaw.isNotEmpty && _lastLiveProbe == null) {
      try {
        final decoded = jsonDecode(probeCacheRaw);
        if (decoded is Map<String, dynamic>) {
          final cachedOutput = decoded['raw']?.toString() ?? '';
          final fetchedAtMs = (decoded['fetchedAtMs'] as num?)?.toInt();
          if (cachedOutput.isNotEmpty) {
            _lastRawOutput = UsageOutputParser.cleanProbeOutput(cachedOutput);
            _lastLiveProbe = UsageOutputParser.parseUsageText(cachedOutput);
            if (fetchedAtMs != null && fetchedAtMs > 0) {
              _lastProbeAt = DateTime.fromMillisecondsSinceEpoch(fetchedAtMs);
            }
          }
        }
      } catch (_) {}
    }
    _emit();
  }

  Future<void> _saveProbeCache(String rawOutput, DateTime fetchedAt) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _probeCachePrefsKey,
        jsonEncode({
          'raw': rawOutput,
          'fetchedAtMs': fetchedAt.millisecondsSinceEpoch,
        }),
      );
    } catch (_) {}
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
  /// Deduplicates concurrent calls and skips redundant probes within 60s unless [force] is true.
  Future<void> refreshFromRuntime({bool force = false}) async {
    final inFlight = _inFlightProbe;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    if (!force &&
        _lastLiveProbe != null &&
        _lastProbeAt != null &&
        DateTime.now().difference(_lastProbeAt!) < _probeFreshnessWindow) {
      return;
    }
    final future = _performProbe();
    _inFlightProbe = future;
    try {
      await future;
    } finally {
      if (identical(_inFlightProbe, future)) {
        _inFlightProbe = null;
      }
    }
  }

  Future<void> _performProbe() async {
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
        final now = DateTime.now();
        _lastRawOutput = UsageOutputParser.cleanProbeOutput(trimmed);
        _lastLiveProbe = UsageOutputParser.parseUsageText(trimmed);
        _lastProbeAt = now;
        await _saveProbeCache(trimmed, now);
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
    _lastRawOutput = UsageOutputParser.cleanProbeOutput(output);
    _lastLiveProbe = UsageOutputParser.parseUsageText(output);
    _lastProbeError = null;
    _lastProbeAt = DateTime.now();
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

  double get fiveHourEstimatedCostUsd =>
      _ledger.sumEstimatedCostUsd(UsageLedger.fiveHourWindow);

  double get weeklyEstimatedCostUsd =>
      _ledger.sumEstimatedCostUsd(UsageLedger.weeklyWindow);
}
