/// Configuration profile for an OpenAI-compatible `/v1` external model endpoint
/// (e.g. OpenAI, OpenRouter, DeepSeek, Ollama, LM Studio, vLLM, LiteLLM).
class OpenAiProviderConfig {
  const OpenAiProviderConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.modelId,
    this.subagentModelId = '',
    this.contextWindowTokens = 128000,
    this.supportsTools = true,
    this.supportsVision = true,
    this.systemPrompt = '',
  });

  final String id;
  final String name;
  final String baseUrl;
  final String modelId;
  final String subagentModelId;
  final int contextWindowTokens;
  final bool supportsTools;
  final bool supportsVision;
  final String systemPrompt;

  String get effectiveSubagentModelId =>
      subagentModelId.trim().isNotEmpty ? subagentModelId.trim() : modelId;

  /// Normalizes user-provided URLs into a clean API base without trailing slashes.
  /// - `https://api.openai.com/v1/` -> `https://api.openai.com/v1`
  /// - `http://127.0.0.1:11434` -> `http://127.0.0.1:11434/v1`
  /// - `https://openrouter.ai/api/v1` -> `https://openrouter.ai/api/v1`
  /// - `https://proxy.example.com/v1/chat/completions` -> `https://proxy.example.com/v1`
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isEmpty) return '';
    if (url.endsWith('/chat/completions')) {
      url = url.substring(0, url.length - '/chat/completions'.length);
    } else if (url.endsWith('/models')) {
      url = url.substring(0, url.length - '/models'.length);
    }
    final uri = Uri.tryParse(url);
    if (uri != null && (uri.path.isEmpty || uri.path == '/')) {
      return '$url/v1';
    }
    return url;
  }

  String get normalizedBaseUrl => normalizeBaseUrl(baseUrl);

  Uri get chatCompletionsUri => Uri.parse('$normalizedBaseUrl/chat/completions');

  Uri get modelsUri => Uri.parse('$normalizedBaseUrl/models');

  bool get isLocalEndpoint {
    final host = Uri.tryParse(normalizedBaseUrl)?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '0.0.0.0' ||
        host == '::1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.endsWith('.local') ||
        host.endsWith('.ts.net');
  }

  OpenAiProviderConfig copyWith({
    String? name,
    String? baseUrl,
    String? modelId,
    String? subagentModelId,
    int? contextWindowTokens,
    bool? supportsTools,
    bool? supportsVision,
    String? systemPrompt,
  }) {
    return OpenAiProviderConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      modelId: modelId ?? this.modelId,
      subagentModelId: subagentModelId ?? this.subagentModelId,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
      supportsTools: supportsTools ?? this.supportsTools,
      supportsVision: supportsVision ?? this.supportsVision,
      systemPrompt: systemPrompt ?? this.systemPrompt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'modelId': modelId,
        if (subagentModelId.trim().isNotEmpty)
          'subagentModelId': subagentModelId.trim(),
        'contextWindowTokens': contextWindowTokens,
        'supportsTools': supportsTools,
        'supportsVision': supportsVision,
        if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
      };

  factory OpenAiProviderConfig.fromJson(Map<String, dynamic> json) {
    return OpenAiProviderConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Custom /v1 Model',
      baseUrl: json['baseUrl'] as String? ?? '',
      modelId: json['modelId'] as String? ?? '',
      subagentModelId: json['subagentModelId'] as String? ?? '',
      contextWindowTokens:
          ((json['contextWindowTokens'] as num?)?.toInt() ?? 128000)
              .clamp(2048, 4000000),
      supportsTools: json['supportsTools'] as bool? ?? true,
      supportsVision: json['supportsVision'] as bool? ?? true,
      systemPrompt: json['systemPrompt'] as String? ?? '',
    );
  }
}
