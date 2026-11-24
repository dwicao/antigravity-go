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
    final cached = await readCachedStatus();
    final resolvedTier = (planStr != null && planStr.isNotEmpty)
        ? AntigravityPlanTier.fromString(planStr)
        : (cached != null &&
                (email == null || cached.email == email)
            ? cached.planTier
            : AntigravityPlanTier.free);

    final status = AgyAuthStatus(
      isAuthenticated: true,
      initialized: true,
      method: method,
      planTier: resolvedTier,
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

  Future<void> _setApiKeySafely(String? apiKey) async {
    try {
      if (apiKey == null || apiKey.trim().isEmpty) {
        await _secureStorage.delete(key: _apiKeyStorageKey);
      } else {
        await _secureStorage.write(key: _apiKeyStorageKey, value: apiKey.trim());
      }
    } catch (_) {}
  }

  Future<String?> _activeProfileJson(AgyAuthStatus? currentStatus) async {
    if (currentStatus != null && currentStatus.isAuthenticated) {
      return jsonEncode(currentStatus.toJson());
    }
    final cached = await readCachedStatus();
    if (cached != null) {
      return jsonEncode(cached.toJson());
    }
    return null;
  }

  Future<void> _cacheFromPayload(
    String? profileJson,
    Map<Object?, Object?>? accountMap,
  ) async {
    if (profileJson != null && profileJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(profileJson);
        if (decoded is Map<String, dynamic>) {
          final parsed = AgyAuthStatus.fromJson(decoded);
          if (parsed.isAuthenticated) {
            await cacheStatus(parsed.copyWith(initialized: true));
            return;
          }
        }
      } catch (_) {}
    }
    if (accountMap != null) {
      final acct = SavedAccount.fromMap(accountMap);
      await cacheStatus(
        AgyAuthStatus(
          isAuthenticated: true,
          initialized: true,
          method: acct.method,
          planTier: acct.planTier,
          email: acct.email,
          displayName: acct.displayName,
          gcpProject: acct.gcpProject,
          gcpLocation: acct.gcpLocation,
          lastAuthenticatedAt: DateTime.now(),
        ),
      );
    }
  }

  Future<List<SavedAccount>> listAccounts({AgyAuthStatus? activeStatus}) async {
    final apiKey = await _readApiKeySafely();
    final profileJson = await _activeProfileJson(activeStatus);
    final rawList = await _runtime.listAccounts(
      authProfileJson: profileJson,
      geminiApiKey: apiKey,
    );
    return rawList.map(SavedAccount.fromMap).toList();
  }

  Future<void> syncActiveAccount(AgyAuthStatus status) async {
    if (!status.isAuthenticated) return;
    final apiKey = await _readApiKeySafely();
    await _runtime.syncActiveAccount(
      authProfileJson: jsonEncode(status.toJson()),
      geminiApiKey: apiKey,
    );
  }

  Future<String> exportCredentialsBundle({
    required String passphrase,
    AgyAuthStatus? currentStatus,
    String? accountId,
  }) async {
    final apiKey = accountId == null ? await _readApiKeySafely() : null;
    final profileJson =
        accountId == null ? await _activeProfileJson(currentStatus) : null;
    return _runtime.exportCredentials(
      passphrase: passphrase,
      geminiApiKey: apiKey,
      authProfileJson: profileJson,
      accountId: accountId,
    );
  }

  Future<({int restoredFiles, String? email, SavedAccount? account})>
      importCredentialsBundle({
    required String bundleJson,
    required String passphrase,
    bool activate = true,
    AgyAuthStatus? currentStatus,
  }) async {
    final currentApiKey = await _readApiKeySafely();
    final currentProfile = await _activeProfileJson(currentStatus);
    final res = await _runtime.importCredentials(
      bundleJson: bundleJson,
      passphrase: passphrase,
      activate: activate,
      authProfileJson: currentProfile,
      geminiApiKey: currentApiKey,
    );
    final acctRaw = res['account'];
    final account = acctRaw is Map<Object?, Object?>
        ? SavedAccount.fromMap(acctRaw)
        : null;
    final profileJson = res['authProfileJson']?.toString();
    if (activate) {
      await _setApiKeySafely(res['geminiApiKey']?.toString());
      await _cacheFromPayload(
        profileJson,
        acctRaw is Map<Object?, Object?> ? acctRaw : null,
      );
    }
    var email = account?.email ?? account?.displayName;
    if (email == null && profileJson != null && profileJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(profileJson);
        if (decoded is Map<String, dynamic>) {
          final parsed = AgyAuthStatus.fromJson(decoded);
          email = parsed.email ?? parsed.displayName;
        }
      } catch (_) {}
    }
    final restoredFiles = (res['restoredFiles'] as num?)?.toInt() ?? 0;
    return (restoredFiles: restoredFiles, email: email, account: account);
  }

  Future<SavedAccount?> switchAccount({
    required String accountId,
    AgyAuthStatus? currentStatus,
  }) async {
    final currentApiKey = await _readApiKeySafely();
    final currentProfile = await _activeProfileJson(currentStatus);
    final res = await _runtime.switchAccount(
      accountId: accountId,
      authProfileJson: currentProfile,
      geminiApiKey: currentApiKey,
    );
    await _setApiKeySafely(res['geminiApiKey']?.toString());
    final acctRaw = res['account'];
    await _cacheFromPayload(
      res['authProfileJson']?.toString(),
      acctRaw is Map<Object?, Object?> ? acctRaw : null,
    );
    return acctRaw is Map<Object?, Object?>
        ? SavedAccount.fromMap(acctRaw)
        : null;
  }

  Future<bool> removeAccount(String accountId) async {
    final res = await _runtime.removeAccount(accountId: accountId);
    final wasActive = res['wasActive'] == true;
    if (wasActive) {
      await _setApiKeySafely(null);
      await cacheStatus(const AgyAuthStatus.signedOut(initialized: true));
    }
    return wasActive;
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
    await _setApiKeySafely(null);
    await cacheStatus(const AgyAuthStatus.signedOut(initialized: true));
    await _runtime.logout();
  }
}
