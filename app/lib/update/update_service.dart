import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.tagName,
    required this.versionName,
    required this.htmlUrl,
    this.arm64ApkUrl,
    this.notes,
  });

  final String tagName;
  final String versionName;
  final String htmlUrl;
  final String? arm64ApkUrl;
  final String? notes;
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const String repoOwner = 'dwicao';
  static const String repoName = 'antigravity-go';
  static const MethodChannel _channel = MethodChannel('agy/update');

  Future<AppReleaseInfo?> fetchLatestRelease() async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$repoOwner/$repoName/releases/latest',
    );
    final res = await http.get(uri, headers: {
      'Accept': 'application/vnd.github+json',
    });
    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String? ?? '';
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final assets = json['assets'] as List<dynamic>? ?? const [];
    String? apkUrl;
    for (final asset in assets.whereType<Map<String, dynamic>>()) {
      final name = asset['name'] as String? ?? '';
      if (name.endsWith('arm64.apk')) {
        apkUrl = asset['browser_download_url'] as String?;
        break;
      }
    }
    return AppReleaseInfo(
      tagName: tag,
      versionName: version,
      htmlUrl: json['html_url'] as String? ??
          'https://github.com/$repoOwner/$repoName/releases',
      arm64ApkUrl: apkUrl,
      notes: json['body'] as String?,
    );
  }

  Future<void> downloadAndInstall(String apkUrl) async {
    await _channel.invokeMethod<void>('installFromUrl', {'url': apkUrl});
  }
}
