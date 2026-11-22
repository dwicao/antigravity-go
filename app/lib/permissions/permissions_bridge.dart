import 'dart:async';

import 'package:flutter/services.dart';

class AndroidPermissionsStatus {
  const AndroidPermissionsStatus({
    this.allFilesAccess = false,
    this.notifications = false,
    this.microphone = false,
    this.accessibility = false,
    this.batteryOptimizationExempt = false,
    this.isDexMode = false,
    this.sdkInt = 30,
    this.externalStorageRoot = '/storage/emulated/0',
  });

  final bool allFilesAccess;
  final bool notifications;
  final bool microphone;
  final bool accessibility;
  final bool batteryOptimizationExempt;
  final bool isDexMode;
  final int sdkInt;
  final String externalStorageRoot;

  factory AndroidPermissionsStatus.fromMap(Map<Object?, Object?> map) {
    return AndroidPermissionsStatus(
      allFilesAccess: map['allFilesAccess'] as bool? ?? false,
      notifications: map['notifications'] as bool? ?? false,
      microphone: map['microphone'] as bool? ?? false,
      accessibility: map['accessibility'] as bool? ?? false,
      batteryOptimizationExempt:
          map['batteryOptimizationExempt'] as bool? ?? false,
      isDexMode: map['isDexMode'] as bool? ?? false,
      sdkInt: (map['sdkInt'] as num?)?.toInt() ?? 30,
      externalStorageRoot:
          map['externalStorageRoot']?.toString() ?? '/storage/emulated/0',
    );
  }
}

/// Bridge to Kotlin `PermissionsPlugin` (`agy/permissions` & `agy/permissions/events`).
class PermissionsBridge {
  PermissionsBridge._();
  static final PermissionsBridge instance = PermissionsBridge._();

  static const MethodChannel _method = MethodChannel('agy/permissions');
  static const EventChannel _events = EventChannel('agy/permissions/events');

  Stream<AndroidPermissionsStatus>? _broadcast;

  Stream<AndroidPermissionsStatus> get changes {
    _broadcast ??= _events
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => AndroidPermissionsStatus.fromMap(e as Map<Object?, Object?>))
        .asBroadcastStream();
    return _broadcast!;
  }

  Future<AndroidPermissionsStatus> getStatus() async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>('status');
      if (raw == null) return const AndroidPermissionsStatus();
      return AndroidPermissionsStatus.fromMap(raw);
    } on MissingPluginException {
      return const AndroidPermissionsStatus();
    }
  }

  Future<void> requestAllFilesAccess() async {
    try {
      await _method.invokeMethod<void>('requestAllFilesAccess');
    } on MissingPluginException {
      // Ignore in widget tests / non-Android platforms.
    }
  }

  Future<void> requestRuntimePermissions() async {
    try {
      await _method.invokeMethod<void>('requestRuntimePermissions');
    } on MissingPluginException {
      // Ignore in widget tests / non-Android platforms.
    }
  }

  Future<void> requestBatteryOptimizationExemption() async {
    try {
      await _method.invokeMethod<void>('requestBatteryOptimizationExemption');
    } on MissingPluginException {
      // Ignore in widget tests / non-Android platforms.
    }
  }
}
