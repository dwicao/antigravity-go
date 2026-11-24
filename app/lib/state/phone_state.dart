import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/phone_bridge.dart';

class PhoneUiState {
  const PhoneUiState({
    this.status = const PhoneControlStatus.initial(),
    this.actions = const [],
    this.deviceInfo = const {},
    this.appRules = const {},
    this.selfCheck,
    this.torchOn = false,
  });

  final PhoneControlStatus status;
  final List<PhoneActionLog> actions;
  final Map<String, Object?> deviceInfo;
  final Map<String, String> appRules;
  final PhoneSelfCheckResult? selfCheck;
  final bool torchOn;

  PhoneUiState copyWith({
    PhoneControlStatus? status,
    List<PhoneActionLog>? actions,
    Map<String, Object?>? deviceInfo,
    Map<String, String>? appRules,
    PhoneSelfCheckResult? selfCheck,
    bool? torchOn,
  }) {
    return PhoneUiState(
      status: status ?? this.status,
      actions: actions ?? this.actions,
      deviceInfo: deviceInfo ?? this.deviceInfo,
      appRules: appRules ?? this.appRules,
      selfCheck: selfCheck ?? this.selfCheck,
      torchOn: torchOn ?? this.torchOn,
    );
  }
}

final phoneProvider =
    NotifierProvider<PhoneNotifier, PhoneUiState>(PhoneNotifier.new);

class PhoneNotifier extends Notifier<PhoneUiState> {
  StreamSubscription<PhoneActionLog>? _sub;

  @override
  PhoneUiState build() {
    _sub?.cancel();
    _sub = PhoneBridge.instance.actionStream.listen((log) {
      state = state.copyWith(actions: [log, ...state.actions.take(199)]);
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(refresh);
    return const PhoneUiState();
  }

  Future<void> refresh() async {
    final status = await PhoneBridge.instance.getStatus();
    final info = await PhoneBridge.instance.getDeviceInfo();
    final history = await PhoneBridge.instance.getActionLog();
    final rules = await PhoneBridge.instance.getAppRules();
    if (!ref.mounted) return;
    state = state.copyWith(
      status: status,
      deviceInfo: info,
      actions: history.isNotEmpty ? history : state.actions,
      appRules: rules,
    );
  }

  Future<void> runSelfCheck() async {
    final res = await PhoneBridge.instance.runSelfCheck();
    if (!ref.mounted || res == null) return;
    state = state.copyWith(selfCheck: res);
  }

  Future<void> clearActionLog() async {
    await PhoneBridge.instance.clearActionLog();
    if (!ref.mounted) return;
    state = state.copyWith(actions: const []);
  }

  Future<void> setAppRule(String packageName, String? mode) async {
    final next = await PhoneBridge.instance.setAppRule(packageName, mode);
    if (!ref.mounted) return;
    state = state.copyWith(appRules: next);
  }

  Future<bool> toggleTorch() async {
    final next = !state.torchOn;
    final ok = await PhoneBridge.instance.setTorch(next);
    if (ok && ref.mounted) {
      state = state.copyWith(torchOn: next);
    }
    return ok;
  }

  Future<void> setEnabled(bool enabled) async {
    await PhoneBridge.instance.setEnabled(enabled);
    await refresh();
  }

  Future<void> setSafetyStrict(bool strict) async {
    await PhoneBridge.instance.setSafetyGateStrict(strict);
    await refresh();
  }

  Future<void> openAccessibilitySettings() {
    return PhoneBridge.instance.openAccessibilitySettings();
  }
}
