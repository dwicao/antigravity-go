import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../permissions/permissions_bridge.dart';

final permissionsProvider =
    NotifierProvider<PermissionsNotifier, AndroidPermissionsStatus>(
  PermissionsNotifier.new,
);

class PermissionsNotifier extends Notifier<AndroidPermissionsStatus> {
  StreamSubscription<AndroidPermissionsStatus>? _sub;

  @override
  AndroidPermissionsStatus build() {
    _sub?.cancel();
    _sub = PermissionsBridge.instance.changes.listen((status) {
      if (!ref.mounted) return;
      state = status;
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(refresh);
    return const AndroidPermissionsStatus();
  }

  Future<void> refresh() async {
    final next = await PermissionsBridge.instance.getStatus();
    if (!ref.mounted) return;
    state = next;
  }

  Future<void> requestAllFilesAccess() async {
    await PermissionsBridge.instance.requestAllFilesAccess();
    if (!ref.mounted) return;
    await refresh();
  }

  Future<void> requestRuntimePermissions() async {
    await PermissionsBridge.instance.requestRuntimePermissions();
    if (!ref.mounted) return;
    await refresh();
  }

  Future<void> requestBatteryOptimizationExemption() async {
    await PermissionsBridge.instance.requestBatteryOptimizationExemption();
    if (!ref.mounted) return;
    await refresh();
  }
}
