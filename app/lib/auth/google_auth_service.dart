import 'package:agy_client/agy_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  Future<AgyAuthStatus> loadStatus({bool verifyWithCli = false}) async {
    final apiKey = await _secureStorage.read(key: _apiKeyStorageKey);
    var native = await _runtime.checkAuthStatus();
    if (verifyWithCli || native['isAuthenticated'] != true) {
      final verified = await _runtime.verifyAuth();
      if (verified['isAuthenticated'] == true) {
        native = verified;
      }
    }
    final isAuth = native['isAuthenticated'] == true ||
        (apiKey != null && apiKey.isNotEmpty);

    if (!isAuth) {
      return const AgyAuthStatus.signedOut();
    }

    if (apiKey != null && apiKey.isNotEmpty && native['isAuthenticated'] != true) {
      return const AgyAuthStatus(
        isAuthenticated: true,
        method: AgyAuthMethod.geminiApiKey,
        planTier: AntigravityPlanTier.apiKey,
        displayName: 'Gemini API Key',
      );
    }

    final email = native['email']?.toString();
    final planStr = native['planTier']?.toString();
    final methodStr = native['method']?.toString();
    final method = AgyAuthMethod.values.firstWhere(
      (m) => m.id == methodStr,
      orElse: () => AgyAuthMethod.googlePersonal,
    );

    return AgyAuthStatus(
      isAuthenticated: true,
      method: method,
      planTier: AntigravityPlanTier.fromString(planStr),
      email: email,
      displayName: email ?? 'Google Account',
      gcpProject: native['gcpProject']?.toString(),
      gcpLocation: native['gcpLocation']?.toString(),
      lastAuthenticatedAt: DateTime.now(),
    );
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
    return _secureStorage.read(key: _apiKeyStorageKey);
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
