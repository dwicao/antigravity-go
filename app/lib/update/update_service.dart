import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.changelogUrl,
    this.publishedAt,
  });

  final String tagName;
  final String versionName;
  final String htmlUrl;
  final String? arm64ApkUrl;
  final int? arm64SizeBytes;
  final String? arm64Sha256;
  final String? notes;
  final String? changelogUrl;
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

  Future<String?> getInstalledVersion() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getAppVersion',
      );
      final nativeVersion = raw?['versionName']?.toString().trim();
      if (nativeVersion != null && nativeVersion.isNotEmpty) {
        return nativeVersion;
      }
    } on MissingPluginException {
      // Fallback to bundled version.json when running outside Android.
    } catch (_) {}

    try {
      final rawJson = await rootBundle.loadString('assets/version.json');
      final decoded = jsonDecode(rawJson);
      if (decoded is Map<String, dynamic>) {
        final v = decoded['version']?.toString().trim();
        if (v != null && v.isNotEmpty) return v;
      }
    } catch (_) {}
    return null;
  }

  static AppReleaseInfo? parseVersionManifest(
    Map<String, dynamic> json, {
    bool? preferX64,
  }) {
    final rawVersion = (json['version'] as String? ?? '').trim();
    final rawTag = (json['tag'] as String? ?? '').trim();
    final tag = rawTag.isNotEmpty
        ? rawTag
        : (rawVersion.isNotEmpty ? 'v$rawVersion' : '');
    final version = rawVersion.isNotEmpty
        ? rawVersion
        : (tag.startsWith('v') ? tag.substring(1) : tag);
    if (version.isEmpty && tag.isEmpty) return null;

    final assetsMap = json['assets'];
    Map<String, dynamic>? selectedAsset;
    if (assetsMap is Map<String, dynamic>) {
      final isX64 = preferX64 ??
          (Platform.version.toLowerCase().contains('x64') ||
              Platform.version.toLowerCase().contains('x86_64'));
      final primaryKey = isX64 ? 'x64' : 'arm64';
      final fallbackKey = isX64 ? 'arm64' : 'x64';
      final primary = assetsMap[primaryKey];
      final fallback = assetsMap[fallbackKey];
      if (primary is Map<String, dynamic>) {
        selectedAsset = primary;
      } else if (fallback is Map<String, dynamic>) {
        selectedAsset = fallback;
      }
    }

    return AppReleaseInfo(
      tagName: tag,
      versionName: version,
      htmlUrl: json['page'] as String? ??
          'https://github.com/$repoOwner/$repoName/releases/tag/$tag',
      arm64ApkUrl: selectedAsset?['url'] as String?,
      arm64SizeBytes: (selectedAsset?['size'] as num?)?.toInt(),
      arm64Sha256: (selectedAsset?['sha256'] as String?)?.toLowerCase(),
      notes: json['releaseNotes'] as String?,
      changelogUrl: json['changelogUrl'] as String? ??
          'https://github.com/$repoOwner/$repoName/blob/main/CHANGELOG.md',
      publishedAt: DateTime.tryParse(json['publishedAt'] as String? ?? ''),
    );
  }

  Future<AppReleaseInfo?> fetchLatestRelease() async {
    final manifestUri = Uri.https(
      'github.com',
      '/$repoOwner/$repoName/releases/latest/download/version.json',
    );
    try {
      final manifestRes = await http
          .get(manifestUri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (manifestRes.statusCode == 200) {
        final decoded = jsonDecode(manifestRes.body);
        if (decoded is Map<String, dynamic>) {
          final parsed = parseVersionManifest(decoded);
          if (parsed != null) return parsed;
        }
      }
    } catch (_) {}

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
    final isX64 = Platform.version.toLowerCase().contains('x64') ||
        Platform.version.toLowerCase().contains('x86_64');
    final preferredSuffix = isX64 ? 'x64.apk' : 'arm64.apk';
    String? apkUrl;
    String? apkName;
    int? apkSize;
    String? sumsUrl;
    for (final asset in assets.whereType<Map<String, dynamic>>()) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith(preferredSuffix) ||
          (apkUrl == null && name.endsWith('.apk'))) {
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
      changelogUrl: 'https://github.com/$repoOwner/$repoName/blob/main/CHANGELOG.md',
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
