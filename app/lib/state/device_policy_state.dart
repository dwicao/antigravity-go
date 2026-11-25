import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/phone_bridge.dart';
import 'harness_state.dart';
import 'settings_state.dart';

class DevicePolicyState {
  const DevicePolicyState({
    this.batteryPct = -1,
    this.charging = false,
    this.network = 'unknown',
    this.ecoModeActive = false,
    this.warningDismissed = false,
  });

  final int batteryPct;
  final bool charging;
  final String network; // wifi, cellular, ethernet, offline, unknown
  final bool ecoModeActive;
  final bool warningDismissed;

  bool get isLowBattery => batteryPct >= 0 && batteryPct < 15 && !charging;
  bool get isCellular => network == 'cellular';
  bool get isOffline => network == 'offline';
  bool get shouldWarn => !warningDismissed && (isLowBattery || isCellular);

  String get warningLabel {
    if (isLowBattery && isCellular) {
      return 'Low battery ($batteryPct%) & cellular data — high-tool tasks may drain battery and quota.';
    }
    if (isLowBattery) {
      return 'Battery low ($batteryPct%) — consider Eco Mode for long agent turns.';
    }
    if (isCellular) {
      return 'On cellular network — heavy multi-tool tasks will use mobile data.';
    }
    return '';
  }

  DevicePolicyState copyWith({
    int? batteryPct,
    bool? charging,
    String? network,
    bool? ecoModeActive,
    bool? warningDismissed,
  }) {
    return DevicePolicyState(
      batteryPct: batteryPct ?? this.batteryPct,
      charging: charging ?? this.charging,
      network: network ?? this.network,
      ecoModeActive: ecoModeActive ?? this.ecoModeActive,
      warningDismissed: warningDismissed ?? this.warningDismissed,
    );
  }
}

final devicePolicyProvider =
    NotifierProvider<DevicePolicyNotifier, DevicePolicyState>(
  DevicePolicyNotifier.new,
);

class DevicePolicyNotifier extends Notifier<DevicePolicyState> {
  @override
  DevicePolicyState build() {
    Future.microtask(refresh);
    return const DevicePolicyState();
  }

  Future<void> refresh() async {
    try {
      final info = await PhoneBridge.instance.getDeviceInfo();
      if (!ref.mounted || info.isEmpty) return;
      final bat = (info['battery'] as num?)?.toInt() ?? -1;
      final chg = info['charging'] as bool? ?? false;
      final net = info['network']?.toString() ?? 'unknown';
      state = state.copyWith(
        batteryPct: bat,
        charging: chg,
        network: net,
        warningDismissed: (!((bat >= 0 && bat < 15 && !chg) || net == 'cellular'))
            ? false
            : state.warningDismissed,
      );
    } catch (_) {}
  }

  void dismissWarning() {
    state = state.copyWith(warningDismissed: true);
  }

  Future<void> activateEcoMode() async {
    state = state.copyWith(ecoModeActive: true, warningDismissed: true);
    await ref.read(settingsProvider.notifier).setEffort('low');
    await ref.read(harnessProvider.notifier).setAutoCompact(true);
  }
}
