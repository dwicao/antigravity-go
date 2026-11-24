/// Supported Antigravity authentication methods.
enum AgyAuthMethod {
  googlePersonal('oauth-personal', 'Google Account'),
  googleBusiness('oauth-business', 'Gemini Enterprise (Google Cloud)'),
  geminiApiKey('gemini-api-key', 'Gemini API Key'),
  adc('agent-platform', 'Application Default Credentials');

  const AgyAuthMethod(this.id, this.label);

  final String id;
  final String label;
}

/// Subscription plan tier associated with the authenticated account.
enum AntigravityPlanTier {
  free('Free / Plus'),
  pro('Google AI Pro'),
  ultra('Google AI Ultra'),
  enterprise('Gemini Enterprise'),
  apiKey('Gemini API (BYOK)');

  const AntigravityPlanTier(this.label);

  final String label;

  static AntigravityPlanTier fromString(String? raw) {
    final lower = raw?.toLowerCase() ?? '';
    if (lower.contains('ultra')) return AntigravityPlanTier.ultra;
    if (lower.contains('pro')) return AntigravityPlanTier.pro;
    if (lower.contains('enterprise')) return AntigravityPlanTier.enterprise;
    if (lower.contains('api')) return AntigravityPlanTier.apiKey;
    return AntigravityPlanTier.free;
  }
}

/// Metadata for a saved / imported account stored in the on-device multi-account vault.
class SavedAccount {
  const SavedAccount({
    required this.id,
    required this.displayName,
    this.email,
    this.method = AgyAuthMethod.googlePersonal,
    this.planTier = AntigravityPlanTier.free,
    this.gcpProject,
    this.gcpLocation,
    this.hasApiKey = false,
    this.fileCount = 0,
    this.addedAt,
    this.lastUsedAt,
    this.isActive = false,
  });

  final String id;
  final String displayName;
  final String? email;
  final AgyAuthMethod method;
  final AntigravityPlanTier planTier;
  final String? gcpProject;
  final String? gcpLocation;
  final bool hasApiKey;
  final int fileCount;
  final DateTime? addedAt;
  final DateTime? lastUsedAt;
  final bool isActive;

  factory SavedAccount.fromMap(Map<Object?, Object?> map) {
    final methodId = map['method']?.toString();
    final method = AgyAuthMethod.values.firstWhere(
      (m) => m.id == methodId,
      orElse: () => AgyAuthMethod.googlePersonal,
    );
    final tierRaw = map['planTier']?.toString();
    final tier = AntigravityPlanTier.values.firstWhere(
      (t) => t.name == tierRaw,
      orElse: () => AntigravityPlanTier.fromString(tierRaw),
    );
    final email = map['email']?.toString();
    final addedMs = (map['addedAtMs'] as num?)?.toInt();
    final usedMs = (map['lastUsedAtMs'] as num?)?.toInt();
    return SavedAccount(
      id: map['id']?.toString() ?? '',
      displayName: map['displayName']?.toString() ?? email ?? 'Google Account',
      email: email,
      method: method,
      planTier: tier,
      gcpProject: map['gcpProject']?.toString(),
      gcpLocation: map['gcpLocation']?.toString(),
      hasApiKey: map['hasApiKey'] as bool? ?? false,
      fileCount: (map['fileCount'] as num?)?.toInt() ?? 0,
      addedAt: addedMs != null && addedMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(addedMs)
          : null,
      lastUsedAt: usedMs != null && usedMs > 0
          ? DateTime.fromMillisecondsSinceEpoch(usedMs)
          : null,
      isActive: map['isActive'] as bool? ?? false,
    );
  }
}

/// Current authentication state of Antigravity Go.
class AgyAuthStatus {
  const AgyAuthStatus({
    required this.isAuthenticated,
    this.initialized = true,
    this.method = AgyAuthMethod.googlePersonal,
    this.planTier = AntigravityPlanTier.free,
    this.email,
    this.displayName,
    this.gcpProject,
    this.gcpLocation,
    this.lastAuthenticatedAt,
    this.pendingOAuthUrl,
    this.awaitingCode = false,
    this.errorMessage,
    this.savedAccounts = const [],
  });

  const AgyAuthStatus.signedOut({
    this.initialized = true,
    this.savedAccounts = const [],
  })  : isAuthenticated = false,
        method = AgyAuthMethod.googlePersonal,
        planTier = AntigravityPlanTier.free,
        email = null,
        displayName = null,
        gcpProject = null,
        gcpLocation = null,
        lastAuthenticatedAt = null,
        pendingOAuthUrl = null,
        awaitingCode = false,
        errorMessage = null;

  final bool isAuthenticated;
  final bool initialized;
  final AgyAuthMethod method;
  final AntigravityPlanTier planTier;
  final String? email;
  final String? displayName;
  final String? gcpProject;
  final String? gcpLocation;
  final DateTime? lastAuthenticatedAt;
  final String? pendingOAuthUrl;
  final bool awaitingCode;
  final String? errorMessage;
  final List<SavedAccount> savedAccounts;

  AgyAuthStatus copyWith({
    bool? isAuthenticated,
    bool? initialized,
    AgyAuthMethod? method,
    AntigravityPlanTier? planTier,
    String? email,
    String? displayName,
    String? gcpProject,
    String? gcpLocation,
    DateTime? lastAuthenticatedAt,
    String? pendingOAuthUrl,
    bool? awaitingCode,
    String? errorMessage,
    List<SavedAccount>? savedAccounts,
  }) {
    return AgyAuthStatus(
      isAuthenticated: isAuthenticated ?? this.isAuthenticated,
      initialized: initialized ?? this.initialized,
      method: method ?? this.method,
      planTier: planTier ?? this.planTier,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      gcpProject: gcpProject ?? this.gcpProject,
      gcpLocation: gcpLocation ?? this.gcpLocation,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
      pendingOAuthUrl: pendingOAuthUrl ?? this.pendingOAuthUrl,
      awaitingCode: awaitingCode ?? this.awaitingCode,
      errorMessage: errorMessage ?? this.errorMessage,
      savedAccounts: savedAccounts ?? this.savedAccounts,
    );
  }

  Map<String, dynamic> toJson() => {
        'isAuthenticated': isAuthenticated,
        'method': method.id,
        'planTier': planTier.name,
        if (email != null) 'email': email,
        if (displayName != null) 'displayName': displayName,
        if (gcpProject != null) 'gcpProject': gcpProject,
        if (gcpLocation != null) 'gcpLocation': gcpLocation,
        if (lastAuthenticatedAt != null)
          'lastAuthenticatedAt': lastAuthenticatedAt!.toIso8601String(),
      };

  factory AgyAuthStatus.fromJson(Map<String, dynamic> json) {
    final methodId = json['method'] as String?;
    final method = AgyAuthMethod.values.firstWhere(
      (m) => m.id == methodId,
      orElse: () => AgyAuthMethod.googlePersonal,
    );
    final tierName = json['planTier'] as String?;
    final tier = AntigravityPlanTier.values.firstWhere(
      (t) => t.name == tierName,
      orElse: () => AntigravityPlanTier.free,
    );
    return AgyAuthStatus(
      isAuthenticated: json['isAuthenticated'] as bool? ?? false,
      method: method,
      planTier: tier,
      email: json['email'] as String?,
      displayName: json['displayName'] as String?,
      gcpProject: json['gcpProject'] as String?,
      gcpLocation: json['gcpLocation'] as String?,
      lastAuthenticatedAt: json['lastAuthenticatedAt'] != null
          ? DateTime.tryParse(json['lastAuthenticatedAt'] as String)
          : null,
    );
  }
}
