import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_state.dart';
import '../../state/usage_state.dart';

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
                            'Plan & Rolling Windows',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Chip(label: Text(auth.planTier.label)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Source: ${usage.source} · Updated ${TimeOfDay.fromDateTime(usage.fetchedAt.toLocal()).format(context)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _WindowSummaryRow(
                      title: '5-Hour Rolling Window',
                      remainingPct: usage.overallFiveHourRemainingPct,
                      resetText: usage.overallFiveHourResetText,
                      tokensUsed: usage.fiveHourLedgerTokens.totalTokens,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 14),
                    _WindowSummaryRow(
                      title: 'Weekly Limit',
                      remainingPct: usage.overallWeeklyRemainingPct,
                      resetText: usage.overallWeeklyResetText,
                      tokensUsed: usage.weeklyLedgerTokens.totalTokens,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
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
            if (usage.discoveredModels.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                'Models Enabled On Your Account (${usage.discoveredModels.length})',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
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
            const SizedBox(height: 14),
            Text(
              'Model & Group Quotas',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final entry in usage.entries) ...[
              _ModelQuotaCard(entry: entry),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),
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
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Live CLI Report (/usage & models)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          usage.rawProbeOutput!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
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

class _WindowSummaryRow extends StatelessWidget {
  const _WindowSummaryRow({
    required this.title,
    required this.remainingPct,
    required this.resetText,
    required this.tokensUsed,
    required this.color,
  });

  final String title;
  final double? remainingPct;
  final String? resetText;
  final int tokensUsed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = remainingPct;
    final progress = pct != null ? (pct / 100.0).clamp(0.0, 1.0) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              pct != null
                  ? '${pct.toStringAsFixed(0)}% remaining'
                  : '${_formatTokens(tokensUsed)} tokens logged',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: progress ?? (tokensUsed > 0 ? 0.15 : 1.0),
            minHeight: 8,
            color: color,
            backgroundColor: color.withOpacity(0.16),
          ),
        ),
        if (resetText != null || tokensUsed > 0) ...[
          const SizedBox(height: 4),
          Text(
            [
              if (resetText != null) 'Resets in $resetText',
              '${_formatTokens(tokensUsed)} tokens',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _ModelQuotaCard extends StatelessWidget {
  const _ModelQuotaCard({required this.entry});

  final ModelQuotaEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = switch (entry.group) {
      QuotaGroup.geminiArgon => Icons.auto_awesome,
      QuotaGroup.geminiPro => Icons.diamond_outlined,
      QuotaGroup.geminiFlash => Icons.bolt_rounded,
      QuotaGroup.claudeAndGpt => Icons.hub_outlined,
      QuotaGroup.orchestrator => Icons.account_tree_outlined,
    };

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
                  child: Text(
                    entry.label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!entry.isAvailable)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Not in plan'),
                  )
                else
                  Text(
                    '${entry.fiveHourRequests} turns (5h) · ${entry.weeklyRequests} (7d)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (entry.fiveHourRemainingPct != null) ...[
              _MiniQuotaBar(
                label: '5-Hour Limit',
                pct: entry.fiveHourRemainingPct!,
                reset: entry.fiveHourResetText,
              ),
              const SizedBox(height: 6),
            ],
            if (entry.weeklyRemainingPct != null) ...[
              _MiniQuotaBar(
                label: 'Weekly Limit',
                pct: entry.weeklyRemainingPct!,
                reset: entry.weeklyResetText,
              ),
              const SizedBox(height: 6),
            ],
            Text(
              [
                if (entry.statusNote != null && entry.statusNote!.isNotEmpty)
                  entry.statusNote!,
                'Logged: ${_formatTokens(entry.fiveHourTokensUsed)} tok (5h) · ${_formatTokens(entry.weeklyTokensUsed)} tok (7d)',
              ].join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniQuotaBar extends StatelessWidget {
  const _MiniQuotaBar({
    required this.label,
    required this.pct,
    this.reset,
  });

  final String label;
  final double pct;
  final String? reset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor = pct < 15
        ? theme.colorScheme.error
        : pct < 40
            ? Colors.amber
            : theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: theme.textTheme.labelSmall),
            const Spacer(),
            Text(
              '${pct.toStringAsFixed(0)}%${reset != null ? " · resets $reset" : ""}',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (pct / 100.0).clamp(0.0, 1.0),
            minHeight: 6,
            color: barColor,
            backgroundColor: barColor.withOpacity(0.18),
          ),
        ),
      ],
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
