import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/google_auth_service.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_models.dart';
import 'usage_state.dart';

final authServiceProvider = Provider<GoogleAuthService>(
  (ref) => GoogleAuthService(),
);

final authProvider =
    NotifierProvider<AuthNotifier, AgyAuthStatus>(AuthNotifier.new);

class AuthNotifier extends Notifier<AgyAuthStatus> {
  StreamSubscription<RuntimeEvent>? _sub;

  @override
  AgyAuthStatus build() {
    _sub?.cancel();
    _sub = RuntimeBridge.instance.events.listen((evt) {
      if (evt.kind == 'auth_oauth_url' && evt.logLine != null) {
        final url = UsageOutputParser.extractOAuthUrl(evt.logLine!) ??
            evt.logLine!.trim();
        state = state.copyWith(
          pendingOAuthUrl: url,
          awaitingCode: true,
        );
        ref.read(authServiceProvider).openOAuthUrl(url);
      } else if (evt.kind == 'auth_completed') {
        Future.microtask(() async {
          await refresh(verifyWithCli: true);
          await ref.read(usageProvider.notifier).refreshFromRuntime();
        });
      } else if (evt.kind == 'auth_error' && evt.logLine != null) {
        state = state.copyWith(
          awaitingCode: false,
          errorMessage: evt.logLine,
        );
      }
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(_bootstrap);
    return const AgyAuthStatus.signedOut(initialized: false);
  }

  Future<void> _bootstrap() async {
    final svc = ref.read(authServiceProvider);
    final cached = await svc.readCachedStatus();
    if (!ref.mounted) return;
    if (cached != null) {
      state = cached;
      await refresh(verifyWithCli: false);
      return;
    }
    await refresh(verifyWithCli: true);
  }

  Future<void> refresh({bool verifyWithCli = false}) async {
    final svc = ref.read(authServiceProvider);
    if (verifyWithCli) {
      await svc.refreshOAuthSession(force: true);
    }
    final wasTurnVerified = state.isAuthenticated;
    final loaded = await svc.loadStatus(verifyWithCli: verifyWithCli);
    if (!ref.mounted) return;
    final nextBase = (!verifyWithCli && wasTurnVerified && !loaded.isAuthenticated)
        ? state.copyWith(initialized: true)
        : loaded.copyWith(initialized: true);
    final accounts = await svc.listAccounts(activeStatus: nextBase);
    if (!ref.mounted) return;
    state = nextBase.copyWith(savedAccounts: accounts);
  }

  /// Marks state authenticated immediately when an `agy` turn or model probe succeeds.
  void markAuthenticatedFromTurn({String? email}) {
    if (state.isAuthenticated) return;
    final next = state.copyWith(
      isAuthenticated: true,
      initialized: true,
      email: email ?? state.email,
      displayName: email ?? state.displayName ?? 'Google Account',
      awaitingCode: false,
      errorMessage: null,
      lastAuthenticatedAt: DateTime.now(),
    );
    state = next;
    final svc = ref.read(authServiceProvider);
    unawaited(svc.cacheStatus(next));
    unawaited(svc.syncActiveAccount(next));
    Future.microtask(() => refresh(verifyWithCli: false));
  }

  Future<void> startGoogleSignIn({bool enterprise = false}) async {
    await ref.read(authServiceProvider).syncActiveAccount(state);
    state = state.copyWith(
      awaitingCode: true,
      errorMessage: null,
    );
    await ref
        .read(authServiceProvider)
        .launchGoogleSignIn(enterprise: enterprise);
  }

  Future<void> submitVerificationCode(String code) async {
    await ref.read(authServiceProvider).submitVerificationCode(code);
    await Future<void>.delayed(const Duration(seconds: 2));
    await refresh(verifyWithCli: true);
    if (state.isAuthenticated) {
      await ref.read(usageProvider.notifier).refreshFromRuntime();
    }
  }

  Future<void> saveGeminiApiKey(String key) async {
    await ref.read(authServiceProvider).saveGeminiApiKey(key);
    await refresh();
  }

  Future<void> configureEnterpriseGcp({
    required String projectId,
    required String location,
  }) async {
    await ref.read(authServiceProvider).configureEnterpriseGcp(
          projectId: projectId,
          location: location,
        );
    await refresh();
  }

  Future<void> keepAliveOnResume() async {
    if (!state.isAuthenticated && state.savedAccounts.isEmpty) return;
    try {
      await ref.read(authServiceProvider).refreshOAuthSession();
    } catch (_) {}
  }

  Future<void> signOut() async {
    final svc = ref.read(authServiceProvider);
    await svc.signOut();
    final accounts = await svc.listAccounts();
    if (!ref.mounted) return;
    state = AgyAuthStatus.signedOut(
      initialized: true,
      savedAccounts: accounts,
    );
  }

  Future<String> exportCredentialsBundle(
    String passphrase, {
    String? accountId,
  }) {
    return ref.read(authServiceProvider).exportCredentialsBundle(
          passphrase: passphrase,
          currentStatus: state,
          accountId: accountId,
        );
  }

  Future<({int restoredFiles, String? email, SavedAccount? account})>
      importCredentialsBundle({
    required String bundleJson,
    required String passphrase,
    bool activate = true,
  }) async {
    final res = await ref.read(authServiceProvider).importCredentialsBundle(
          bundleJson: bundleJson,
          passphrase: passphrase,
          activate: activate,
          currentStatus: state,
        );
    await refresh(verifyWithCli: false);
    if (activate && state.isAuthenticated) {
      await ref.read(usageProvider.notifier).refreshFromRuntime();
    }
    return res;
  }

  Future<void> switchAccount(String accountId) async {
    await ref.read(authServiceProvider).switchAccount(
          accountId: accountId,
          currentStatus: state,
        );
    await refresh(verifyWithCli: false);
    if (state.isAuthenticated) {
      await ref.read(usageProvider.notifier).refreshFromRuntime();
    }
  }

  Future<void> removeAccount(String accountId) async {
    final wasActive =
        await ref.read(authServiceProvider).removeAccount(accountId);
    await refresh(verifyWithCli: false);
    if (wasActive && !state.isAuthenticated) {
      // Clear cached live quota output when active account is removed.
      await ref.read(usageProvider.notifier).refreshFromRuntime();
    }
  }
}
