import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/phone_bridge.dart';

class PhoneUiState {
  const PhoneUiState({
    this.status = const PhoneControlStatus.initial(),
    this.actions = const [],
  });

  final PhoneControlStatus status;
  final List<PhoneActionLog> actions;

  PhoneUiState copyWith({
    PhoneControlStatus? status,
    List<PhoneActionLog>? actions,
  }) {
    return PhoneUiState(
      status: status ?? this.status,
      actions: actions ?? this.actions,
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
      state = state.copyWith(actions: [log, ...state.actions.take(49)]);
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(refresh);
    return const PhoneUiState();
  }

  Future<void> refresh() async {
    final status = await PhoneBridge.instance.getStatus();
    state = state.copyWith(status: status);
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
