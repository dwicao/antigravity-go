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
  gemini('gemini', 'Gemini Models'),
  geminiArgon('gemini_argon', 'Gemini 4 Argon'),
  geminiPro('gemini_pro', 'Gemini Pro (Neon / Carbon / 3.1 Pro)'),
  geminiFlash('gemini_flash', 'Gemini Flash & Hydrogen'),
  claudeAndGpt('claude_gpt', 'Claude and GPT models'),
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
    this.supportsMaxEffort = false,
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
  final bool supportsMaxEffort;
  final bool supportsEffort;
  final String contextWindow;
  final bool isDefault;
  final bool requiresPaidPlan;

  List<ReasoningEffort> get availableEfforts {
    if (!supportsEffort) return const [];
    return [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      if (supportsExtraEffort) ReasoningEffort.extra,
      if (supportsMaxEffort || supportsExtraEffort) ReasoningEffort.max,
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
      quotaGroup: QuotaGroup.gemini,
      description: 'Plans with Gemini 4 Neon and executes with Gemini 4 Hydrogen (shared Gemini Models quota)',
      supportsEffort: false,
      contextWindow: '1M',
      isDefault: true,
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-pro-orchestrator',
      displayName: 'Orchestrator (Carbon)',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Carbon orchestrator workflow sharing the Gemini Models quota',
      supportsEffort: false,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-pro-orchestrator-argon',
      displayName: 'Orchestrator (Argon)',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Argon orchestrator workflow sharing the Gemini Models quota',
      supportsEffort: false,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-neon',
      displayName: 'Gemini 4 Neon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Frontier reasoning model for architecture & multi-step coding (Low / Medium / High / XHigh / Max)',
      supportsExtraEffort: true,
      supportsMaxEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-carbon',
      displayName: 'Gemini 4 Carbon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Deep reasoning model sharing the Gemini Models quota (Low / Medium / High / Max)',
      supportsMaxEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-argon',
      displayName: 'Gemini 4 Argon',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'High-precision Gemini 4 Argon model merged into Gemini Models quota (Low / Medium / High / Max)',
      supportsMaxEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-4-hydrogen',
      displayName: 'Gemini 4 Hydrogen',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Fast everyday coding, refactoring, and execution model (Low / Medium / High / XHigh / Max)',
      supportsExtraEffort: true,
      supportsMaxEffort: true,
      contextWindow: '1M',
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gemini-3.8-flash',
      displayName: 'Gemini 3.8 Flash',
      provider: 'Google DeepMind',
      quotaGroup: QuotaGroup.gemini,
      description: 'Included on all plans (Free, Pro, Ultra, Enterprise)',
      contextWindow: '1M',
    ),
    AgyModelInfo(
      id: 'claude-opus-5-5-medium',
      displayName: 'Claude Opus 5.5',
      provider: 'Anthropic',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Partner frontier model sharing the Claude and GPT models quota pool (Low / Medium / High / Max)',
      supportsMaxEffort: true,
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'claude-sonnet-5-5-medium',
      displayName: 'Claude Sonnet 5.5',
      provider: 'Anthropic',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Balanced partner coding model sharing the Claude and GPT models pool (Low / Medium / High / Max)',
      supportsMaxEffort: true,
      requiresPaidPlan: true,
    ),
    AgyModelInfo(
      id: 'gpt-oss-120b-medium',
      displayName: 'GPT-OSS 120B',
      provider: 'OpenAI / Partner',
      quotaGroup: QuotaGroup.claudeAndGpt,
      description: 'Partner open-weight model sharing the Claude and GPT models pool',
      supportsEffort: false,
    ),
  ];

  static AgyModelInfo resolve(String modelId, {String? displayName}) {
    final normalized = modelId.toLowerCase().trim();
    if (normalized == 'gemini-pro-orchestrator-neon') {
      return builtIn.first;
    }
    for (final m in builtIn) {
      if (m.id.toLowerCase() == normalized ||
          m.displayName.toLowerCase() == normalized) {
        return displayName != null && displayName.trim().isNotEmpty
            ? AgyModelInfo(
                id: modelId,
                displayName: displayName.trim(),
                provider: m.provider,
                quotaGroup: m.quotaGroup,
                description: m.description,
                supportsExtraEffort: m.supportsExtraEffort,
                supportsMaxEffort: m.supportsMaxEffort,
                supportsEffort: m.supportsEffort,
                contextWindow: m.contextWindow,
                isDefault: m.isDefault,
                requiresPaidPlan: m.requiresPaidPlan,
              )
            : m;
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
    final inferredExtra = normalized.contains('neon') ||
        normalized.contains('hydrogen') ||
        normalized.contains('xhigh');
    final inferredMax = inferredExtra ||
        normalized.contains('claude') ||
        normalized.contains('carbon') ||
        normalized.contains('argon') ||
        normalized.contains('gemini-4') ||
        normalized.contains('max');
    return AgyModelInfo(
      id: modelId,
      displayName: (displayName != null && displayName.trim().isNotEmpty)
          ? displayName.trim()
          : modelId,
      provider: inferProvider(modelId),
      quotaGroup: inferQuotaGroup(modelId),
      description: 'Discovered model from active Antigravity account',
      supportsExtraEffort: inferredExtra,
      supportsMaxEffort: inferredMax,
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
    if (lower.contains('claude') || lower.contains('gpt')) {
      return QuotaGroup.claudeAndGpt;
    }
    return QuotaGroup.gemini;
  }
}
