import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../update/update_service.dart';

String formatUpdateBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class AppUpdateState {
  static const String fallbackVersion = '1.0.24';

  const AppUpdateState({
    this.currentVersion = fallbackVersion,
    this.checking = false,
    this.latest,
    this.phase = UpdateTransferPhase.idle,
    this.receivedBytes = 0,
    this.totalBytes,
    this.speedBps = 0,
    this.persistedDataUsedBytes = 0,
    this.needsInstallPermission = false,
    this.errorMessage,
    this.lastCheckedAt,
  });

  final String currentVersion;
  final bool checking;
  final AppReleaseInfo? latest;
  final UpdateTransferPhase phase;
  final int receivedBytes;
  final int? totalBytes;
  final int speedBps;
  final int persistedDataUsedBytes;
  final bool needsInstallPermission;
  final String? errorMessage;
  final DateTime? lastCheckedAt;

  bool get hasNewerVersion =>
      latest != null && compareSemver(latest!.versionName, currentVersion) > 0;

  bool get isUpToDate => latest != null && !hasNewerVersion;

  static int compareSemver(String a, String b) {
    List<int> parse(String s) {
      final core = s.replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
      return core.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    }

    final pa = parse(a);
    final pb = parse(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }

  bool get isDownloading =>
      phase == UpdateTransferPhase.downloading ||
      phase == UpdateTransferPhase.verifying ||
      phase == UpdateTransferPhase.installing;

  int? get effectiveTotalBytes => totalBytes ?? latest?.arm64SizeBytes;

  double? get progress {
    final total = effectiveTotalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }

  /// Cumulative bytes transferred across update attempts including the active stream.
  int get totalDataUsedBytes => persistedDataUsedBytes + receivedBytes;

  AppUpdateState copyWith({
    String? currentVersion,
    bool? checking,
    AppReleaseInfo? latest,
    bool clearLatest = false,
    UpdateTransferPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    bool clearTotal = false,
    int? speedBps,
    int? persistedDataUsedBytes,
    bool? needsInstallPermission,
    String? errorMessage,
    bool clearError = false,
    DateTime? lastCheckedAt,
  }) {
    return AppUpdateState(
      currentVersion: currentVersion ?? this.currentVersion,
      checking: checking ?? this.checking,
      latest: clearLatest ? null : (latest ?? this.latest),
      phase: phase ?? this.phase,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: clearTotal ? null : (totalBytes ?? this.totalBytes),
      speedBps: speedBps ?? this.speedBps,
      persistedDataUsedBytes:
          persistedDataUsedBytes ?? this.persistedDataUsedBytes,
      needsInstallPermission:
          needsInstallPermission ?? this.needsInstallPermission,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }
}

final appUpdateProvider =
    NotifierProvider<AppUpdateNotifier, AppUpdateState>(AppUpdateNotifier.new);

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  static const _kDataUsedKey = 'agy_update_total_data_bytes';
  static const _kLastCheckMsKey = 'agy_update_last_check_ms';
  StreamSubscription<UpdateProgressEvent>? _sub;
  int _lastRecordedReceived = 0;

  @override
  AppUpdateState build() {
    _sub?.cancel();
    _sub = UpdateService.instance.progressEvents.listen(handleProgressEvent);
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(_loadPersisted);
    return const AppUpdateState();
  }

  Future<void> _loadPersisted() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final used = prefs.getInt(_kDataUsedKey) ?? 0;
    final lastMs = prefs.getInt(_kLastCheckMsKey);
    final canInstall = await UpdateService.instance.canRequestPackageInstalls();
    final installed = await UpdateService.instance.getInstalledVersion();
    if (!ref.mounted) return;
    state = state.copyWith(
      currentVersion: installed,
      persistedDataUsedBytes: used,
      needsInstallPermission: !canInstall,
      lastCheckedAt:
          lastMs != null ? DateTime.fromMillisecondsSinceEpoch(lastMs) : null,
    );
  }

  Future<void> autoCheckIfDue({Duration interval = const Duration(hours: 24)}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_kLastCheckMsKey);
    if (lastMs != null) {
      final elapsed = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(lastMs));
      if (elapsed < interval) return;
    }
    await checkForUpdates();
  }

  Future<void> refreshInstallPermission() async {
    final canInstall = await UpdateService.instance.canRequestPackageInstalls();
    if (ref.mounted) {
      state = state.copyWith(needsInstallPermission: !canInstall);
    }
  }

  Future<void> _commitReceivedBytes() async {
    if (_lastRecordedReceived <= 0) return;
    final delta = _lastRecordedReceived;
    _lastRecordedReceived = 0;
    final nextPersisted = state.persistedDataUsedBytes + delta;
    if (ref.mounted) {
      state = state.copyWith(
        persistedDataUsedBytes: nextPersisted,
        receivedBytes: 0,
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDataUsedKey, nextPersisted);
  }

  void handleProgressEvent(UpdateProgressEvent evt) {
    if (!ref.mounted) return;
    if (evt.received > _lastRecordedReceived) {
      _lastRecordedReceived = evt.received;
    }
    state = state.copyWith(
      phase: evt.phase,
      receivedBytes: evt.received > 0 ? evt.received : state.receivedBytes,
      totalBytes: evt.total ?? state.totalBytes,
      speedBps: evt.speedBps,
      errorMessage: evt.error,
      clearError: evt.phase != UpdateTransferPhase.failed,
    );
    if (evt.phase == UpdateTransferPhase.cancelled ||
        evt.phase == UpdateTransferPhase.failed) {
      unawaited(_commitReceivedBytes());
    }
  }

  Future<AppReleaseInfo?> checkForUpdates() async {
    state = state.copyWith(checking: true, clearError: true);
    try {
      final installed = await UpdateService.instance.getInstalledVersion();
      final info = await UpdateService.instance.fetchLatestRelease();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _kLastCheckMsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      if (!ref.mounted) return info;
      state = state.copyWith(
        currentVersion: installed,
        checking: false,
        latest: info,
        lastCheckedAt: DateTime.now(),
      );
      return info;
    } catch (e) {
      if (!ref.mounted) return null;
      state = state.copyWith(
        checking: false,
        errorMessage: 'Failed checking updates: $e',
      );
      return null;
    }
  }

  Future<void> startUpdate() async {
    final release = state.latest;
    final url = release?.arm64ApkUrl;
    if (url == null || url.isEmpty) return;

    _lastRecordedReceived = 0;
    state = state.copyWith(
      phase: UpdateTransferPhase.downloading,
      receivedBytes: 0,
      totalBytes: release?.arm64SizeBytes,
      speedBps: 0,
      clearError: true,
    );

    try {
      final result = await UpdateService.instance.downloadAndInstall(
        url,
        expectedSha256: release?.arm64Sha256,
      );
      final finalReceived = result['received'] ?? state.receivedBytes;
      if (finalReceived > _lastRecordedReceived) {
        _lastRecordedReceived = finalReceived;
      }
      await _commitReceivedBytes();
      if (ref.mounted) {
        state = state.copyWith(
          phase: UpdateTransferPhase.idle,
          speedBps: 0,
        );
      }
    } on PlatformException catch (e) {
      await _commitReceivedBytes();
      if (!ref.mounted) return;
      if (e.code == 'update_cancelled') {
        state = state.copyWith(
          phase: UpdateTransferPhase.cancelled,
          speedBps: 0,
          clearError: true,
        );
      } else {
        state = state.copyWith(
          phase: UpdateTransferPhase.failed,
          speedBps: 0,
          errorMessage: e.message ?? e.code,
        );
      }
    } catch (e) {
      await _commitReceivedBytes();
      if (!ref.mounted) return;
      state = state.copyWith(
        phase: UpdateTransferPhase.failed,
        speedBps: 0,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> cancelUpdate() async {
    await UpdateService.instance.cancelUpdate();
    await _commitReceivedBytes();
    if (!ref.mounted) return;
    state = state.copyWith(
      phase: UpdateTransferPhase.cancelled,
      speedBps: 0,
      clearError: true,
    );
  }
}
