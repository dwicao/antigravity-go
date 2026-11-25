import '../models/usage_quota.dart';

/// Approximate USD pricing per 1,000,000 tokens for BYOK / API cost telemetry.
class ModelPriceTier {
  const ModelPriceTier({
    required this.inputPerMillionUsd,
    required this.outputPerMillionUsd,
    this.cacheReadPerMillionUsd,
    this.thinkingPerMillionUsd,
  });

  final double inputPerMillionUsd;
  final double outputPerMillionUsd;
  final double? cacheReadPerMillionUsd;
  final double? thinkingPerMillionUsd;

  static const ModelPriceTier free = ModelPriceTier(
    inputPerMillionUsd: 0.0,
    outputPerMillionUsd: 0.0,
    cacheReadPerMillionUsd: 0.0,
  );
}

/// Estimates per-turn and session USD costs from model IDs and [TokenUsage].
class ModelPricingCatalog {
  const ModelPricingCatalog._();

  static ModelPriceTier resolve(String modelId) {
    final m = modelId.toLowerCase().trim();
    if (m.isEmpty) return ModelPriceTier.free;
    if (m.contains('ollama') ||
        m.contains('llama') ||
        m.contains('local') ||
        m.contains('qwen') ||
        m.contains('deepseek-r1:local')) {
      return ModelPriceTier.free;
    }
    if (m.contains('flash') || m.contains('hydrogen')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 0.15,
        outputPerMillionUsd: 0.60,
        cacheReadPerMillionUsd: 0.0375,
      );
    }
    if (m.contains('neon') ||
        m.contains('carbon') ||
        m.contains('argon') ||
        m.contains('orchestrator') ||
        m.contains('gemini-2.5-pro') ||
        m.contains('gemini-3')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 1.25,
        outputPerMillionUsd: 10.00,
        cacheReadPerMillionUsd: 0.3125,
      );
    }
    if (m.contains('opus')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 15.00,
        outputPerMillionUsd: 75.00,
        cacheReadPerMillionUsd: 1.50,
      );
    }
    if (m.contains('sonnet')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 3.00,
        outputPerMillionUsd: 15.00,
        cacheReadPerMillionUsd: 0.30,
      );
    }
    if (m.contains('haiku')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 0.80,
        outputPerMillionUsd: 4.00,
        cacheReadPerMillionUsd: 0.08,
      );
    }
    if (m.contains('gpt-oss') || m.contains('gpt-4o-mini')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 0.15,
        outputPerMillionUsd: 0.60,
        cacheReadPerMillionUsd: 0.075,
      );
    }
    if (m.contains('gpt-')) {
      return const ModelPriceTier(
        inputPerMillionUsd: 2.50,
        outputPerMillionUsd: 10.00,
        cacheReadPerMillionUsd: 1.25,
      );
    }
    // Conservative default fallback for unknown cloud models.
    return const ModelPriceTier(
      inputPerMillionUsd: 0.50,
      outputPerMillionUsd: 2.00,
      cacheReadPerMillionUsd: 0.125,
    );
  }

  static double estimateTurnCostUsd(String modelId, TokenUsage usage) {
    if (usage.totalTokens <= 0) return 0.0;
    final tier = resolve(modelId);
    final cacheCostRate =
        tier.cacheReadPerMillionUsd ?? (tier.inputPerMillionUsd * 0.25);
    final thinkCostRate =
        tier.thinkingPerMillionUsd ?? tier.outputPerMillionUsd;

    final uncachedInput = (usage.inputTokens - usage.cacheReadTokens).clamp(
      0,
      usage.inputTokens,
    );
    final inputUsd = (uncachedInput / 1000000.0) * tier.inputPerMillionUsd;
    final cacheUsd = (usage.cacheReadTokens / 1000000.0) * cacheCostRate;
    final outputUsd = (usage.outputTokens / 1000000.0) * tier.outputPerMillionUsd;
    final thinkUsd = (usage.thinkingTokens / 1000000.0) * thinkCostRate;
    return inputUsd + cacheUsd + outputUsd + thinkUsd;
  }

  static String formatUsd(double usd) {
    if (usd <= 0.0) return r'$0.00';
    if (usd < 0.0001) return r'<$0.0001';
    if (usd < 0.01) return '\$${usd.toStringAsFixed(4)}';
    if (usd < 1.0) return '\$${usd.toStringAsFixed(3)}';
    return '\$${usd.toStringAsFixed(2)}';
  }
}
