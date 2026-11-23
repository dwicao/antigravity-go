/// Reasoning effort supported by Antigravity models.
enum ReasoningEffort {
  low('low', 'Low'),
  medium('medium', 'Medium'),
  high('high', 'High'),
  extra('xhigh', 'Extra'),
  max('max', 'Max');

  const ReasoningEffort(this.cliValue, this.label);

  final String cliValue;
  final String label;

  static ReasoningEffort fromString(String? value) {
    return switch (value?.toLowerCase().trim()) {
      'low' => ReasoningEffort.low,
      'high' => ReasoningEffort.high,
      'xhigh' || 'extra' || 'extra_high' => ReasoningEffort.extra,
      'max' => ReasoningEffort.max,
      _ => ReasoningEffort.medium,
    };
  }
}

/// Quota bucket used by Antigravity's 5-hour and weekly model limits.
enum QuotaGroup {
  geminiArgon('gemini_argon', 'Gemini 4 Argon'),
  geminiPro('gemini_pro', 'Gemini Pro (Neon / Carbon / 3.1 Pro)'),
  geminiFlash('gemini_flash', 'Gemini Flash & Hydrogen'),
  claudeAndGpt('claude_gpt', 'Claude & GPT'),
  orchestrator('orchestrator', 'Orchestrator');

  const QuotaGroup(this.id, this.displayName);

  final String id;
  final String displayName;
}

/// Metadata for a reasoning model available in Antigravity.
class AgyModelInfo {
  const AgyModelInfo({
    required this.id,
    required this.displayName,
    required this.provider,
    required this.quotaGroup,
    required this.description,
    this.supportsExtraEffort = false,
    this.supportsEffort = true,
    this.contextWindow = '512K',
    this.isDefault = false,
    this.requiresPaidPlan = false,
  });

  final String id;
  final String displayName;
  final String provider;
  final QuotaGroup quotaGroup;
  final String description;
  final bool supportsExtraEffort;
  final bool supportsEffort;
  final String contextWindow;
  final bool isDefault;
  final bool requiresPaidPlan;

  List<ReasoningEffort> get availableEfforts {
    if (!supportsEffort) return const [];
    if (supportsExtraEffort) {
      return const [
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
        ReasoningEffort.extra,
        ReasoningEffort.max,
      ];
    }
    return const [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
    ];
  }
}

/// Built-in Antigravity model catalog matching `antigravity.google/docs/models`.
class AgyModelCatalog {
  const AgyModelCatalog._();

  static const List<AgyModelInfo> builtIn = [
    AgyModelInfo(
      id: 'Orchestrator (Neon)',
      displayName: 'Orchestrator (Neon)',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.orchestrator,
      description: 'Plans with Gemini 4 Neon and executes with Gemini 4 Hydrogen',
      supportsEffort: false,
      contextWindow: '1M',
      isDefault: true,
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-neon',
      displayName: 'Gemini 4 Neon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.geminiPro,
      description: 'Frontier reasoning model for architecture & multi-step coding',
      supportsExtraEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-carbon',
      displayName: 'Gemini 4 Carbon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.geminiPro,
      description: 'Deep reasoning model for Ultra & Enterprise plans',
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-argon',
      displayName: 'Gemini 4 Argon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.geminiArgon,
      description: 'High-precision Gemini 4 Argon reasoning model',
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-hydrogen',
      displayName: 'Gemini 4 Hydrogen',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.geminiFlash,
      description: 'Fast everyday coding, refactoring, and execution model',
      supportsExtraEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-3.8-flash',
      displayName: 'Gemini 3.8 Flash',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.geminiFlash,
      description: 'Included on all plans (Free, Pro, Ultra, Enterprise)',
      contextWindow: '1M',
    ),
    AgyModelInfo(
      id: 'claude-opus-5.5-thinking',
      displayName: 'Claude Opus 5.5 (thinking)',
      provider: 'Anthropic',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Partner frontier model sharing the Claude & GPT quota pool',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'claude-sonnet-5.5-thinking',
      displayName: 'Claude Sonnet 5.5 (thinking)',
      provider: 'Anthropic',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Balanced partner coding model sharing the Claude & GPT pool',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'claude-sonnet-4.6-thinking',
      displayName: 'Claude Sonnet 4.6 (thinking)',
      provider: 'Anthropic',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Claude 4.6 thinking model',
    ),
    AgyModelInfo(
      id: 'gpt-oss-120b',
      displayName: 'GPT-OSS-120b',
      provider: 'OpenAI / Partner',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Partner open-weight model sharing the Claude & GPT pool',
    ),
  ];

  static AgyModelInfo resolve(String modelId) {
    final normalized = modelId.toLowerCase().trim();
    for (final m in builtIn) {
      if (m.id.toLowerCase() == normalized ||
          m.displayName.toLowerCase() == normalized) {
        return m;
      }
    }
    final inferredContext = (normalized.contains('gemini') ||
            normalized.contains('orchestrator') ||
            normalized.contains('neon') ||
            normalized.contains('carbon') ||
            normalized.contains('argon') ||
            normalized.contains('hydrogen'))
        ? '1M'
        : normalized.contains('claude')
            ? '200K'
            : '160K';
    return AgyModelInfo(
      id: modelId,
      displayName: modelId,
      provider: inferProvider(modelId),
      quotaGroup: inferQuotaGroup(modelId),
      description: 'Discovered model from active Antigravity account',
      contextWindow: inferredContext,
    );
  }

  static String inferProvider(String modelId) {
    final lower = modelId.toLowerCase();
    if (lower.contains('claude')) return 'Anthropic';
    if (lower.contains('gpt')) return 'Partner (GPT)';
    return 'Google DeepMind';
  }

  static QuotaGroup inferQuotaGroup(String modelId) {
    final lower = modelId.toLowerCase();
    if (lower.contains('orchestrator')) return QuotaGroup.orchestrator;
    if (lower.contains('argon')) return QuotaGroup.geminiArgon;
    if (lower.contains('claude') || lower.contains('gpt')) {
      return QuotaGroup.claudeAndGpt;
    }
    if (lower.contains('hydrogen') || lower.contains('flash')) {
      return QuotaGroup.geminiFlash;
    }
    return QuotaGroup.geminiPro;
  }
}
