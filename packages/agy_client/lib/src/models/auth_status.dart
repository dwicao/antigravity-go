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
  });

  const AgyAuthStatus.signedOut({this.initialized = true})
      : isAuthenticated = false,
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
