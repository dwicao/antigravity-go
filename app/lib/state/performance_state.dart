import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RefreshRateMode {
  auto('Auto (120Hz active)'),
  max('Always Peak Hz'),
  system('System Default');

  const RefreshRateMode(this.label);

  final String label;
}

class PerformanceSnapshot {
  const PerformanceSnapshot({
    this.tier = 'medium',
    this.ramMb = 0,
    this.cpuCores = 4,
    this.thermalStatus = 0,
    this.thermalLightweight = false,
    this.refreshRateMode = 'auto',
    this.maxRefreshHz = 60,
    this.ignoringBatteryOptimizations = false,
    this.manufacturer = '',
    this.model = '',
    this.sdkInt = 0,
  });

  final String tier;
  final int ramMb;
  final int cpuCores;
  final int thermalStatus;
  final bool thermalLightweight;
  final String refreshRateMode;
  final double maxRefreshHz;
  final bool ignoringBatteryOptimizations;
  final String manufacturer;
  final String model;
  final int sdkInt;

  factory PerformanceSnapshot.fromMap(Map<Object?, Object?> map) {
    return PerformanceSnapshot(
      tier: map['tier']?.toString() ?? 'medium',
      ramMb: (map['ramMb'] as num?)?.toInt() ?? 0,
      cpuCores: (map['cpuCores'] as num?)?.toInt() ?? 4,
      thermalStatus: (map['thermalStatus'] as num?)?.toInt() ?? 0,
      thermalLightweight: map['thermalLightweight'] == true,
      refreshRateMode: map['refreshRateMode']?.toString() ?? 'auto',
      maxRefreshHz: (map['maxRefreshHz'] as num?)?.toDouble() ?? 60.0,
      ignoringBatteryOptimizations:
          map['ignoringBatteryOptimizations'] == true,
      manufacturer: map['manufacturer']?.toString() ?? '',
      model: map['model']?.toString() ?? '',
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 0,
    );
  }
}

class PerformanceState {
  const PerformanceState({
    this.refreshRateMode = RefreshRateMode.auto,
    this.reduceMotion = false,
    this.reduceBlur = false,
    this.snapshot = const PerformanceSnapshot(),
  });

  final RefreshRateMode refreshRateMode;
  final bool reduceMotion;
  final bool reduceBlur;
  final PerformanceSnapshot snapshot;

  PerformanceState copyWith({
    RefreshRateMode? refreshRateMode,
    bool? reduceMotion,
    bool? reduceBlur,
    PerformanceSnapshot? snapshot,
  }) {
    return PerformanceState(
      refreshRateMode: refreshRateMode ?? this.refreshRateMode,
      reduceMotion: reduceMotion ?? this.reduceMotion,
      reduceBlur: reduceBlur ?? this.reduceBlur,
      snapshot: snapshot ?? this.snapshot,
    );
  }
}

final performanceProvider =
    NotifierProvider<PerformanceNotifier, PerformanceState>(
  PerformanceNotifier.new,
);

class PerformanceNotifier extends Notifier<PerformanceState> {
  static const MethodChannel _channel = MethodChannel('agy/performance');
  final Set<String> _dirtyKeys = <String>{};

  @override
  PerformanceState build() {
    Future.microtask(_load);
    return const PerformanceState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final modeName = prefs.getString('agy_refresh_rate_mode') ?? 'auto';
    final mode = RefreshRateMode.values.firstWhere(
      (m) => m.name == modeName,
      orElse: () => RefreshRateMode.auto,
    );
    final reduceMotion = prefs.getBool('agy_reduce_motion') ?? false;
    final reduceBlur = prefs.getBool('agy_reduce_blur') ?? false;
    state = state.copyWith(
      refreshRateMode: _dirtyKeys.contains('agy_refresh_rate_mode')
          ? state.refreshRateMode
          : mode,
      reduceMotion: _dirtyKeys.contains('agy_reduce_motion')
          ? state.reduceMotion
          : reduceMotion,
      reduceBlur: _dirtyKeys.contains('agy_reduce_blur')
          ? state.reduceBlur
          : reduceBlur,
    );
    await _syncNativeRefreshRate(state.refreshRateMode);
    await refreshSnapshot();
  }

  Future<void> _syncNativeRefreshRate(RefreshRateMode mode) async {
    try {
      await _channel.invokeMethod<String>(
        'setRefreshRateMode',
        {'mode': mode.name},
      );
    } catch (_) {}
  }

  Future<void> refreshSnapshot() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('snapshot');
      if (raw != null && ref.mounted) {
        state = state.copyWith(snapshot: PerformanceSnapshot.fromMap(raw));
      }
    } catch (_) {}
  }

  Future<void> setRefreshRateMode(RefreshRateMode mode) async {
    _dirtyKeys.add('agy_refresh_rate_mode');
    state = state.copyWith(refreshRateMode: mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agy_refresh_rate_mode', mode.name);
    await _syncNativeRefreshRate(mode);
    await refreshSnapshot();
  }

  Future<void> setReduceMotion(bool enabled) async {
    _dirtyKeys.add('agy_reduce_motion');
    state = state.copyWith(reduceMotion: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_reduce_motion', enabled);
  }

  Future<void> setReduceBlur(bool enabled) async {
    _dirtyKeys.add('agy_reduce_blur');
    state = state.copyWith(reduceBlur: enabled);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('agy_reduce_blur', enabled);
  }

  Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      return await _channel
              .invokeMethod<bool>('requestIgnoreBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openBatterySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
