import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/auth_state.dart';
import '../../state/usage_state.dart';
import '../../theme/app_theme.dart';
import '../chat/message_bubble.dart' show formatChatTimestamp;

class UsagePage extends ConsumerStatefulWidget {
  const UsagePage({super.key, this.autoRefreshOnOpen = true});

  final bool autoRefreshOnOpen;

  @override
  ConsumerState<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends ConsumerState<UsagePage> {
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoRefreshOnOpen) {
      Future.microtask(_refreshLive);
    }
  }

  Future<void> _refreshLive() async {
    if (!mounted) return;
    setState(() => _probing = true);
    try {
      await ref.read(usageProvider.notifier).refreshFromRuntime();
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final usage = ref.watch(usageProvider);
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    final fiveHReset = _resolveResetLabel(
      resetAt: usage.overallFiveHourResetAt,
      resetText: usage.overallFiveHourResetText,
    );
    final weeklyReset = _resolveResetLabel(
      resetAt: usage.overallWeeklyResetAt,
      resetText: usage.overallWeeklyResetText,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Usage Limits & Quotas'),
        actions: [
          IconButton(
            tooltip: 'Refresh from agy /usage',
            onPressed: _probing ? null : _refreshLive,
            icon: _probing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.speed_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Quota Overview',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Chip(
                          visualDensity: VisualDensity.compact,
                          label: Text(auth.planTier.label),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Updated ${TimeOfDay.fromDateTime(usage.fetchedAt.toLocal()).format(context)} · ${usage.source}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: semantic.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final twoCol = constraints.maxWidth >= 480;
                        final fiveHCard = _WindowHeroTile(
                          title: '5-Hour Rolling Window',
                          remainingPct: usage.overallFiveHourRemainingPct,
                          resetCountdown: fiveHReset,
                          resetAt: usage.overallFiveHourResetAt,
                          tokensUsed: usage.fiveHourLedgerTokens.totalTokens,
                          defaultColor: theme.colorScheme.primary,
                        );
                        final weeklyCard = _WindowHeroTile(
                          title: 'Weekly Limit',
                          remainingPct: usage.overallWeeklyRemainingPct,
                          resetCountdown: weeklyReset,
                          resetAt: usage.overallWeeklyResetAt,
                          tokensUsed: usage.weeklyLedgerTokens.totalTokens,
                          defaultColor: theme.colorScheme.tertiary,
                        );
                        if (twoCol) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: fiveHCard),
                              const SizedBox(width: 12),
                              Expanded(child: weeklyCard),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            fiveHCard,
                            const SizedBox(height: 10),
                            weeklyCard,
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _TokenChip(
                          label: '5h Input',
                          value: usage.fiveHourLedgerTokens.inputTokens,
                        ),
                        _TokenChip(
                          label: '5h Output',
                          value: usage.fiveHourLedgerTokens.outputTokens,
                        ),
                        _TokenChip(
                          label: '5h Thinking',
                          value: usage.fiveHourLedgerTokens.thinkingTokens,
                        ),
                        _TokenChip(
                          label: '7d Cached',
                          value: usage.weeklyLedgerTokens.cacheReadTokens,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Model & Group Quotas',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: semantic.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in usage.entries) ...[
              _ModelQuotaCard(entry: entry),
              const SizedBox(height: 10),
            ],
            if (usage.discoveredModels.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Models Enabled On Your Account (${usage.discoveredModels.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: semantic.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: usage.discoveredModels
                    .map(
                      (m) => Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(m.displayName),
                      ),
                    )
                    .toList(),
              ),
            ],
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.toll_rounded,
                          color: theme.colorScheme.secondary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'AI Credits & Overages',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (usage.aiCreditsRemaining != null)
                          Text(
                            '${usage.aiCreditsRemaining!.toStringAsFixed(0)} credits',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        if (usage.upgradeUrl != null) ...[
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () =>
                                launchUrl(Uri.parse(usage.upgradeUrl!)),
                            icon: const Icon(Icons.open_in_new, size: 15),
                            label: const Text('Upgrade'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Use AI Credits on Quota Overage'),
                      subtitle: const Text(
                        'Matches CLI `useG1Credits` setting when 5h or weekly limits are reached',
                      ),
                      value: usage.useG1Credits,
                      onChanged: (v) =>
                          ref.read(usageProvider.notifier).toggleUseG1Credits(v),
                    ),
                  ],
                ),
              ),
            ),
            if (usage.lastProbeError != null &&
                usage.lastProbeError!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Card(
                color: theme.colorScheme.errorContainer.withOpacity(0.5),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(usage.lastProbeError!),
                ),
              ),
            ],
            if (usage.rawProbeOutput != null &&
                usage.rawProbeOutput!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Card(
                child: Theme(
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    dense: true,
                    initiallyExpanded: false,
                    title: Text(
                      'Raw CLI Report (/usage & models)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: semantic.codeWellBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: semantic.codeWellBorder),
                        ),
                        child: SelectableText(
                          usage.rawProbeOutput!,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: semantic.codeWellFg,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String? _resolveResetLabel({
  DateTime? resetAt,
  String? resetText,
}) {
  if (resetAt != null) {
    return formatResetCountdown(resetAt);
  }
  if (resetText != null && resetText.trim().isNotEmpty) {
    return resetText.trim();
  }
  return null;
}

Color _quotaBarColor(BuildContext context, double? pct, Color fallback) {
  if (pct == null) return fallback;
  final theme = Theme.of(context);
  final semantic = AgySemanticColors.of(context);
  if (pct < 15) return theme.colorScheme.error;
  if (pct < 40) return semantic.warning;
  return semantic.success;
}

class _WindowHeroTile extends StatelessWidget {
  const _WindowHeroTile({
    required this.title,
    required this.remainingPct,
    required this.resetCountdown,
    required this.resetAt,
    required this.tokensUsed,
    required this.defaultColor,
  });

  final String title;
  final double? remainingPct;
  final String? resetCountdown;
  final DateTime? resetAt;
  final int tokensUsed;
  final Color defaultColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final pct = remainingPct;
    final usedPct = pct != null ? (100.0 - pct).clamp(0.0, 100.0) : null;
    final barColor = _quotaBarColor(context, pct, defaultColor);
    final progress = pct != null ? (pct / 100.0).clamp(0.0, 1.0) : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelMedium?.copyWith(
              color: semantic.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                pct != null ? formatQuotaPct(pct) : '—',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: barColor,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  pct != null
                      ? 'left · ${formatQuotaPct(usedPct!)} used'
                      : '${_formatTokens(tokensUsed)} logged',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: semantic.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _SegmentedQuotaBar(
            value: progress ?? (tokensUsed > 0 ? 0.15 : 1.0),
            color: barColor,
            height: 8,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.schedule_outlined,
                  size: 14, color: semantic.textSecondary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  resetCountdown != null
                      ? 'Reset in $resetCountdown${resetAt != null ? " (${formatChatTimestamp(resetAt!)})" : ""}'
                      : '${_formatTokens(tokensUsed)} tokens logged',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: semantic.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModelQuotaCard extends StatelessWidget {
  const _ModelQuotaCard({required this.entry});

  final ModelQuotaEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final icon = switch (entry.group) {
      QuotaGroup.gemini || QuotaGroup.geminiArgon => Icons.auto_awesome,
      QuotaGroup.geminiPro => Icons.diamond_outlined,
      QuotaGroup.geminiFlash => Icons.bolt_rounded,
      QuotaGroup.claudeAndGpt => Icons.hub_outlined,
      QuotaGroup.orchestrator => Icons.account_tree_outlined,
    };

    final fiveHReset = _resolveResetLabel(
      resetAt: entry.fiveHourResetAt,
      resetText: entry.fiveHourResetText,
    );
    final weeklyReset = _resolveResetLabel(
      resetAt: entry.weeklyResetAt,
      resetText: entry.weeklyResetText,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (entry.statusNote != null &&
                          entry.statusNote!.trim().isNotEmpty)
                        Text(
                          entry.statusNote!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: semantic.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!entry.isAvailable)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('Not in plan'),
                  )
                else
                  Text(
                    '${entry.fiveHourRequests} turns (5h) · ${entry.weeklyRequests} (7d)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: semantic.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (entry.fiveHourRemainingPct != null) ...[
              _QuotaWindowRow(
                label: '5-Hour Limit',
                pct: entry.fiveHourRemainingPct!,
                resetCountdown: fiveHReset,
                resetAt: entry.fiveHourResetAt,
              ),
              const SizedBox(height: 8),
            ],
            if (entry.weeklyRemainingPct != null) ...[
              _QuotaWindowRow(
                label: 'Weekly Limit',
                pct: entry.weeklyRemainingPct!,
                resetCountdown: weeklyReset,
                resetAt: entry.weeklyResetAt,
              ),
              const SizedBox(height: 8),
            ],
            if (entry.fiveHourRemainingPct == null &&
                entry.weeklyRemainingPct == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Tap refresh to probe live % remaining and next reset time.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: semantic.textSecondary,
                  ),
                ),
              ),
            Text(
              'Logged: ${_formatTokens(entry.fiveHourTokensUsed)} tok (5h) · ${_formatTokens(entry.weeklyTokensUsed)} tok (7d)',
              style: theme.textTheme.labelSmall?.copyWith(
                color: semantic.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuotaWindowRow extends StatelessWidget {
  const _QuotaWindowRow({
    required this.label,
    required this.pct,
    this.resetCountdown,
    this.resetAt,
  });

  final String label;
  final double pct;
  final String? resetCountdown;
  final DateTime? resetAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final barColor = _quotaBarColor(context, pct, theme.colorScheme.primary);
    final usedPct = (100.0 - pct).clamp(0.0, 100.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${formatQuotaPct(pct)} left · ${formatQuotaPct(usedPct)} used',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: barColor,
              ),
            ),
            if (resetCountdown != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Reset in $resetCountdown${resetAt != null ? " · ${formatChatTimestamp(resetAt!)}" : ""}',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: semantic.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        _SegmentedQuotaBar(
          value: (pct / 100.0).clamp(0.0, 1.0),
          color: barColor,
          height: 7,
        ),
      ],
    );
  }
}

class _SegmentedQuotaBar extends StatelessWidget {
  const _SegmentedQuotaBar({
    required this.value,
    required this.color,
    this.height = 7,
  });

  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    const segments = 10;
    final clamped = value.clamp(0.0, 1.0);
    final activeCount = (clamped * segments).round();
    return Row(
      children: List.generate(segments, (i) {
        final filled = i < activeCount;
        return Expanded(
          child: Container(
            height: height,
            margin: EdgeInsets.only(right: i == segments - 1 ? 0 : 3),
            decoration: BoxDecoration(
              color: filled ? color : color.withOpacity(0.16),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }
}

class _TokenChip extends StatelessWidget {
  const _TokenChip({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label: ${_formatTokens(value)}'),
    );
  }
}

String _formatTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(2)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}
