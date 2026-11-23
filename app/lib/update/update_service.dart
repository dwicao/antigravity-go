import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.versionName,
    required this.htmlUrl,
    this.arm64ApkUrl,
    this.arm64SizeBytes,
    this.arm64Sha256,
    this.notes,
    this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final String htmlUrl;
  final String? arm64ApkUrl;
  final int? arm64SizeBytes;
  final String? arm64Sha256;
  final String? notes;
  final DateTime? publishedAt;
}

enum UpdateTransferPhase {
  idle,
  downloading,
  verifying,
  installing,
  cancelled,
  failed,
}

class UpdateProgressEvent {
  const UpdateProgressEvent({
    required this.phase,
    this.received = 0,
    this.total,
    this.speedBps = 0,
    this.error,
  });

  final UpdateTransferPhase phase;
  final int received;
  final int? total;
  final int speedBps;
  final String? error;

  factory UpdateProgressEvent.fromMap(Map<Object?, Object?> raw) {
    final phaseRaw = raw['phase']?.toString() ?? 'idle';
    final phase = UpdateTransferPhase.values.firstWhere(
      (p) => p.name == phaseRaw,
      orElse: () => UpdateTransferPhase.idle,
    );
    final totalNum = (raw['total'] as num?)?.toInt();
    return UpdateProgressEvent(
      phase: phase,
      received: (raw['received'] as num?)?.toInt() ?? 0,
      total: (totalNum != null && totalNum > 0) ? totalNum : null,
      speedBps: (raw['speedBps'] as num?)?.toInt() ?? 0,
      error: raw['error']?.toString(),
    );
  }
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const String repoOwner = 'dwicao';
  static const String repoName = 'antigravity-go';
  static const MethodChannel _channel = MethodChannel('agy/update');
  static const EventChannel _events = EventChannel('agy/update/events');

  Stream<UpdateProgressEvent>? _eventStream;

  Stream<UpdateProgressEvent> get progressEvents {
    _eventStream ??= _events
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => UpdateProgressEvent.fromMap(e as Map<Object?, Object?>))
        .asBroadcastStream();
    return _eventStream!;
  }

  Future<AppReleaseInfo?> fetchLatestRelease() async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$repoOwner/$repoName/releases/latest',
    );
    final res = await http
        .get(uri, headers: {'Accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final assets = json['assets'] as List<dynamic>? ?? const [];
    String? apkUrl;
    String? apkName;
    int? apkSize;
    String? sumsUrl;
    for (final asset in assets.whereType<Map<String, dynamic>>()) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('arm64.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        apkName = name;
        apkSize = (asset['size'] as num?)?.toInt();
      } else if (name == 'SHA256SUMS') {
        sumsUrl = asset['browser_download_url'] as String?;
      }
    }

    String? sha256;
    if (sumsUrl != null && apkName != null) {
      try {
        final sumRes = await http
            .get(Uri.parse(sumsUrl))
            .timeout(const Duration(seconds: 6));
        if (sumRes.statusCode == 200) {
          sha256 = _parseSha256ForAsset(sumRes.body, apkName);
        }
      } catch (_) {}
    }

    return AppReleaseInfo(
      tagName: tag,
      versionName: version,
      htmlUrl: json['html_url'] as String? ??
          'https://github.com/$repoOwner/$repoName/releases',
      arm64ApkUrl: apkUrl,
      arm64SizeBytes: apkSize,
      arm64Sha256: sha256,
      notes: json['body'] as String?,
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
    );
  }

  String? _parseSha256ForAsset(String body, String fileName) {
    for (final line in body.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.endsWith(fileName)) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.isNotEmpty && parts.first.length == 64) {
        return parts.first.toLowerCase();
      }
    }
    return null;
  }

  Future<Map<String, int>> downloadAndInstall(
    String apkUrl, {
    String? expectedSha256,
  }) async {
    final res = await _channel.invokeMethod<Map<Object?, Object?>>(
      'installFromUrl',
      {
        'url': apkUrl,
        'expectedSha256': ?expectedSha256,
      },
    );
    return {
      'received': (res?['received'] as num?)?.toInt() ?? 0,
      'total': (res?['total'] as num?)?.toInt() ?? 0,
    };
  }

  Future<void> cancelUpdate() async {
    try {
      await _channel.invokeMethod<bool>('cancelUpdate');
    } on MissingPluginException {
      // No-op in tests or unsupported platforms.
    }
  }

  Future<bool> canRequestPackageInstalls() async {
    try {
      return await _channel.invokeMethod<bool>('canRequestPackageInstalls') ??
          true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<bool> openInstallUnknownAppsSettings() async {
    try {
      return await _channel
              .invokeMethod<bool>('openInstallUnknownAppsSettings') ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
