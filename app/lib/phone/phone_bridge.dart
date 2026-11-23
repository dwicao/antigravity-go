import 'package:flutter/services.dart';

class PhoneControlStatus {
  const PhoneControlStatus({
    required this.enabled,
    required this.accessibilityConnected,
    required this.safetyGateStrict,
    this.mcpPort,
    this.mcpToken,
  });

  const PhoneControlStatus.initial()
      : enabled = false,
        accessibilityConnected = false,
        safetyGateStrict = true,
        mcpPort = null,
        mcpToken = null;

  final bool enabled;
  final bool accessibilityConnected;
  final bool safetyGateStrict;
  final int? mcpPort;
  final String? mcpToken;

  factory PhoneControlStatus.fromMap(Map<Object?, Object?> map) {
    return PhoneControlStatus(
      enabled: map['enabled'] as bool? ?? false,
      accessibilityConnected: map['accessibilityConnected'] as bool? ?? false,
      safetyGateStrict: map['safetyGateStrict'] as bool? ?? true,
      mcpPort: (map['mcpPort'] as num?)?.toInt(),
      mcpToken: map['mcpToken'] as String?,
    );
  }
}

class PhoneActionLog {
  const PhoneActionLog({
    required this.action,
    required this.target,
    required this.allowed,
    required this.reason,
    required this.timestamp,
  });

  final String action;
  final String target;
  final bool allowed;
  final String reason;
  final DateTime timestamp;

  factory PhoneActionLog.fromMap(Map<Object?, Object?> map) {
    return PhoneActionLog(
      action: map['action']?.toString() ?? 'unknown',
      target: map['target']?.toString() ?? '',
      allowed: map['allowed'] as bool? ?? false,
      reason: map['reason']?.toString() ?? '',
      timestamp: DateTime.now(),
    );
  }
}

/// Bridge to Kotlin `PhonePlugin` (`agy/phone`, `agy/phone/events`).
class PhoneBridge {
  PhoneBridge._();
  static final PhoneBridge instance = PhoneBridge._();

  static const MethodChannel _method = MethodChannel('agy/phone');
  static const EventChannel _events = EventChannel('agy/phone/events');

  Stream<PhoneActionLog>? _stream;

  Stream<PhoneActionLog> get actionStream {
    _stream ??= _events
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => PhoneActionLog.fromMap(e as Map<Object?, Object?>))
        .asBroadcastStream();
    return _stream!;
  }

  Future<PhoneControlStatus> getStatus() async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>('status');
      if (raw == null) return const PhoneControlStatus.initial();
      return PhoneControlStatus.fromMap(raw);
    } on MissingPluginException {
      return const PhoneControlStatus.initial();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    await _method.invokeMethod<void>('setEnabled', {'enabled': enabled});
  }

  Future<void> setSafetyGateStrict(bool strict) async {
    await _method.invokeMethod<void>('setSafetyStrict', {'strict': strict});
  }

  Future<void> openAccessibilitySettings() async {
    await _method.invokeMethod<void>('openAccessibilitySettings');
  }

  Future<String> dumpScreenTree() async {
    return await _method.invokeMethod<String>('dumpScreen') ?? '';
  }
}
