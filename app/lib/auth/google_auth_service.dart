import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../runtime/runtime_bridge.dart';

/// Handles Google Account sign-in (`agy acp --login`), Enterprise GCP auth,
/// and Gemini API key persistence without logging secrets.
class GoogleAuthService {
  GoogleAuthService({
    RuntimeBridge? runtime,
    FlutterSecureStorage? secureStorage,
  })  : _runtime = runtime ?? RuntimeBridge.instance,
        _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _apiKeyStorageKey = 'agy_gemini_api_key';
  static const _authProfileKey = 'agy_auth_profile_json';

  final RuntimeBridge _runtime;
  final FlutterSecureStorage _secureStorage;

  Future<AgyAuthStatus?> readCachedStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_authProfileKey);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final parsed = AgyAuthStatus.fromJson(decoded);
        if (parsed.isAuthenticated) {
          return parsed.copyWith(initialized: true);
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> cacheStatus(AgyAuthStatus status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!status.isAuthenticated) {
        await prefs.remove(_authProfileKey);
        return;
      }
      await prefs.setString(_authProfileKey, jsonEncode(status.toJson()));
    } catch (_) {}
  }

  Future<String?> _readApiKeySafely() async {
    try {
      return await _secureStorage.read(key: _apiKeyStorageKey);
    } catch (_) {
      return null;
    }
  }

  Future<AgyAuthStatus> loadStatus({bool verifyWithCli = false}) async {
    final apiKey = await _readApiKeySafely();
    var native = await _runtime.checkAuthStatus();
    if (verifyWithCli && native['isAuthenticated'] != true) {
      final verified = await _runtime.verifyAuth();
      if (verified['isAuthenticated'] == true) {
        native = verified;
      }
    }
    final isAuth = native['isAuthenticated'] == true ||
        (apiKey != null && apiKey.isNotEmpty);

    if (!isAuth) {
      final cached = await readCachedStatus();
      if (cached != null) {
        return cached;
      }
      return const AgyAuthStatus.signedOut(initialized: true);
    }

    if (apiKey != null && apiKey.isNotEmpty && native['isAuthenticated'] != true) {
      const apiKeyStatus = AgyAuthStatus(
        isAuthenticated: true,
        initialized: true,
        method: AgyAuthMethod.geminiApiKey,
        planTier: AntigravityPlanTier.apiKey,
        displayName: 'Gemini API Key',
      );
      await cacheStatus(apiKeyStatus);
      return apiKeyStatus;
    }

    final email = native['email']?.toString();
    final planStr = native['planTier']?.toString();
    final methodStr = native['method']?.toString();
    final method = AgyAuthMethod.values.firstWhere(
      (m) => m.id == methodStr,
      orElse: () => AgyAuthMethod.googlePersonal,
    );

    final status = AgyAuthStatus(
      isAuthenticated: true,
      initialized: true,
      method: method,
      planTier: AntigravityPlanTier.fromString(planStr),
      email: email,
      displayName: email ?? 'Google Account',
      gcpProject: native['gcpProject']?.toString(),
      gcpLocation: native['gcpLocation']?.toString(),
      lastAuthenticatedAt: DateTime.now(),
    );
    await cacheStatus(status);
    return status;
  }

  Future<void> launchGoogleSignIn({bool enterprise = false}) async {
    await _runtime.startGoogleLogin(enterprise: enterprise);
  }

  Future<void> openOAuthUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> submitVerificationCode(String code) async {
    await _runtime.submitLoginCode(code.trim());
  }

  Future<void> saveGeminiApiKey(String apiKey) async {
    final trimmed = apiKey.trim();
    if (trimmed.isEmpty) {
      await _secureStorage.delete(key: _apiKeyStorageKey);
      return;
    }
    await _secureStorage.write(key: _apiKeyStorageKey, value: trimmed);
    await _runtime.writeCliSettings({'modelProvider': 'gemini'});
  }

  Future<String?> readGeminiApiKey() {
    return _readApiKeySafely();
  }

  Future<String> exportCredentialsBundle({
    required String passphrase,
    AgyAuthStatus? currentStatus,
  }) async {
    final apiKey = await _readApiKeySafely();
    String? profileJson;
    if (currentStatus != null && currentStatus.isAuthenticated) {
      profileJson = jsonEncode(currentStatus.toJson());
    } else {
      final cached = await readCachedStatus();
      if (cached != null) {
        profileJson = jsonEncode(cached.toJson());
      }
    }
    return _runtime.exportCredentials(
      passphrase: passphrase,
      geminiApiKey: apiKey,
      authProfileJson: profileJson,
    );
  }

  Future<({int restoredFiles, String? email})> importCredentialsBundle({
    required String bundleJson,
    required String passphrase,
  }) async {
    final res = await _runtime.importCredentials(
      bundleJson: bundleJson,
      passphrase: passphrase,
    );
    final apiKey = res['geminiApiKey']?.toString();
    if (apiKey != null && apiKey.isNotEmpty) {
      try {
        await _secureStorage.write(key: _apiKeyStorageKey, value: apiKey);
      } catch (_) {}
    }
    String? email;
    final profileJson = res['authProfileJson']?.toString();
    if (profileJson != null && profileJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(profileJson);
        if (decoded is Map<String, dynamic>) {
          final parsed = AgyAuthStatus.fromJson(decoded);
          email = parsed.email ?? parsed.displayName;
          if (parsed.isAuthenticated) {
            await cacheStatus(parsed.copyWith(initialized: true));
          }
        }
      } catch (_) {}
    }
    final restoredFiles = (res['restoredFiles'] as num?)?.toInt() ?? 0;
    return (restoredFiles: restoredFiles, email: email);
  }

  Future<void> configureEnterpriseGcp({
    required String projectId,
    required String location,
  }) async {
    await _runtime.writeCliSettings({
      'gcp': {
        'project': projectId.trim(),
        'location': location.trim(),
      },
    });
  }

  Future<void> signOut() async {
    await _secureStorage.delete(key: _apiKeyStorageKey);
    await _secureStorage.delete(key: _authProfileKey);
    await _runtime.logout();
  }
}
