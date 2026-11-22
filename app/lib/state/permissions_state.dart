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
      state = status;
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(refresh);
    return const AndroidPermissionsStatus();
  }

  Future<void> refresh() async {
    state = await PermissionsBridge.instance.getStatus();
  }

  Future<void> requestAllFilesAccess() async {
    await PermissionsBridge.instance.requestAllFilesAccess();
    await refresh();
  }

  Future<void> requestRuntimePermissions() async {
    await PermissionsBridge.instance.requestRuntimePermissions();
    await refresh();
  }

  Future<void> requestBatteryOptimizationExemption() async {
    await PermissionsBridge.instance.requestBatteryOptimizationExemption();
    await refresh();
  }
}
