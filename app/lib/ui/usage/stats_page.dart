import 'dart:math' as math;

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_state.dart';
import '../../state/sessions_state.dart';
import '../../state/usage_state.dart';
import '../../theme/app_theme.dart';
import 'usage_page.dart';

enum _StatsChartMetric {
  spend('Spend'),
  tokens('Tokens'),
  requests('Requests');

  const _StatsChartMetric(this.label);
  final String label;
}

enum _ModelSortMode {
  spend('Spend'),
  tokens('Tokens'),
  requests('Requests');

  const _ModelSortMode(this.label);
  final String label;
}

class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  StatsTimeframe _timeframe = StatsTimeframe.allTime;
  _StatsChartMetric _chartMetric = _StatsChartMetric.spend;
  _ModelSortMode _modelSort = _ModelSortMode.spend;
  String? _selectedDayKey;

  static const _compactSegStyle = ButtonStyle(
    visualDensity: VisualDensity(horizontal: -2, vertical: -2),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    ),
    textStyle: WidgetStatePropertyAll(
      TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final quota = ref.watch(usageProvider);
    final sessions = ref.watch(sessionsProvider).sessions;
    final auth = ref.watch(authProvider);
    final summary = ref.read(usageProvider.notifier).buildStatsSummary(
          _timeframe,
        );
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    final sortedModels = [...summary.models];
    sortedModels.sort((a, b) => switch (_modelSort) {
          _ModelSortMode.spend =>
            b.estimatedCostUsd.compareTo(a.estimatedCostUsd),
          _ModelSortMode.tokens =>
            b.usage.totalTokens.compareTo(a.usage.totalTokens),
          _ModelSortMode.requests => b.requests.compareTo(a.requests),
        });

    final totalSessionsCount = sessions.length;
    final pinnedSessionsCount = sessions.where((s) => s.pinned).length;
    final archivedSessionsCount = sessions.where((s) => s.archived).length;
    final totalMessagesStored = sessions.fold<int>(
      0,
      (sum, s) => sum + s.messageCount,
    );

    Widget wrapSection(Widget card) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Card(margin: EdgeInsets.zero, child: card),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Stats & Spend'),
        actions: [
          IconButton(
            tooltip: 'Copy stats report',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: summary.toMarkdownReport()),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Stats report copied')),
              );
            },
          ),
          IconButton(
            tooltip: 'Usage Limits & Quotas',
            icon: const Icon(Icons.speed_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const UsagePage()),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'More stats actions',
            onSelected: (v) async {
              if (v == 'reset') {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Reset All-Time Stats?'),
                    content: const Text(
                      'Clears stored lifetime spend, token, and request totals. Your 14-day rolling ledger and chat transcripts remain intact.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Reset'),
                      ),
                    ],
                  ),
                );
                if (confirmed == true && context.mounted) {
                  await ref.read(usageProvider.notifier).resetLifetimeStats();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'reset',
                child: Text('Reset All-Time Stats'),
              ),
            ],
          ),
        ],
      ),
      body: Scrollbar(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<StatsTimeframe>(
                      showSelectedIcon: false,
                      style: _compactSegStyle,
                      segments: StatsTimeframe.values
                          .map(
                            (tf) => ButtonSegment<StatsTimeframe>(
                              value: tf,
                              label: Text(
                                tf.shortLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      selected: {_timeframe},
                      onSelectionChanged: (s) => setState(() {
                        _timeframe = s.first;
                        _selectedDayKey = null;
                      }),
                    ),
                  ),
                ),
              ),
            ),
            // Headline 2x2 KPI Grid
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final gap = 8.0;
                      final colWidth = constraints.maxWidth >= 300
                          ? (constraints.maxWidth - gap) / 2
                          : constraints.maxWidth;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          _KpiTile(
                            width: colWidth,
                            icon: Icons.payments_outlined,
                            accent: theme.colorScheme.primary,
                            label: 'Estimated Spend',
                            value: ModelPricingCatalog.formatUsd(
                              summary.estimatedCostUsd,
                            ),
                            sublabel: summary.cacheSavedUsd > 0
                                ? 'Cache saved ${ModelPricingCatalog.formatUsd(summary.cacheSavedUsd)}'
                                : '${summary.timeframe.label} API equiv.',
                          ),
                          _KpiTile(
                            width: colWidth,
                            icon: Icons.bolt_rounded,
                            accent: theme.colorScheme.secondary,
                            label: 'Requests / Turns',
                            value: '${summary.requests}',
                            sublabel:
                                'Avg ${ModelPricingCatalog.formatUsd(summary.avgCostPerRequestUsd)} / req',
                          ),
                          _KpiTile(
                            width: colWidth,
                            icon: Icons.token_outlined,
                            accent: theme.colorScheme.tertiary,
                            label: 'Total Tokens',
                            value: UsageStatsSummary.formatCompactCount(
                              summary.usage.totalTokens,
                            ),
                            sublabel:
                                'Avg ${UsageStatsSummary.formatCompactCount(summary.avgTokensPerRequest.round())} / req',
                          ),
                          _KpiTile(
                            width: colWidth,
                            icon: Icons.cached_rounded,
                            accent: semantic.success,
                            label: 'Cache Hit Rate',
                            value:
                                '${summary.cacheHitRatePct.toStringAsFixed(1)}%',
                            sublabel:
                                'Think ${summary.thinkingSharePct.toStringAsFixed(1)}% · ${summary.distinctSessions} chats',
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            // Token Composition & Cost Breakdown
            wrapSection(
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.pie_chart_outline_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Token & Cost Breakdown',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _StackedTokenBar(
                      uncachedInput: summary.uncachedInputTokens,
                      cacheRead: summary.usage.cacheReadTokens,
                      output: summary.usage.outputTokens,
                      thinking: summary.usage.thinkingTokens,
                    ),
                    const SizedBox(height: 10),
                    _BreakdownRow(
                      color: theme.colorScheme.primary,
                      label: 'Uncached Input',
                      value: UsageStatsSummary.formatCompactCount(
                        summary.uncachedInputTokens,
                      ),
                      detail: '${summary.uncachedInputTokens} tok',
                    ),
                    _BreakdownRow(
                      color: semantic.success,
                      label: 'Cache Read Input',
                      value: UsageStatsSummary.formatCompactCount(
                        summary.usage.cacheReadTokens,
                      ),
                      detail:
                          'Saved ${ModelPricingCatalog.formatUsd(summary.cacheSavedUsd)}',
                    ),
                    _BreakdownRow(
                      color: theme.colorScheme.secondary,
                      label: 'Output Generated',
                      value: UsageStatsSummary.formatCompactCount(
                        summary.usage.outputTokens,
                      ),
                      detail: '${summary.usage.outputTokens} tok',
                    ),
                    _BreakdownRow(
                      color: theme.colorScheme.tertiary,
                      label: 'Thinking / Reasoning',
                      value: UsageStatsSummary.formatCompactCount(
                        summary.usage.thinkingTokens,
                      ),
                      detail:
                          '${summary.thinkingSharePct.toStringAsFixed(1)}% of total',
                    ),
                  ],
                ),
              ),
            ),
            // Daily Activity Chart
            wrapSection(
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bar_chart_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Daily Trend (${summary.dailySeries.length}d)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (summary.peakCostDay != null)
                          Text(
                            'Peak: ${ModelPricingCatalog.formatUsd(summary.peakCostDay!.estimatedCostUsd)}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _StatsChartMetric.values
                          .map(
                            (m) => ChoiceChip(
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -3,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              label: Text(
                                m.label,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: _chartMetric == m,
                              onSelected: (_) =>
                                  setState(() => _chartMetric = m),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    _DailyBarChart(
                      series: summary.dailySeries,
                      metric: _chartMetric,
                      selectedDateKey: _selectedDayKey,
                      onSelectDay: (key) => setState(() {
                        _selectedDayKey = _selectedDayKey == key ? null : key;
                      }),
                    ),
                  ],
                ),
              ),
            ),
            // Per-Model Breakdown
            wrapSection(
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.hub_outlined,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Models Used (${sortedModels.length})',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _ModelSortMode.values
                          .map(
                            (mode) => ChoiceChip(
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -3,
                              ),
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              labelPadding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 2,
                              ),
                              label: Text(
                                'Sort: ${mode.label}',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              selected: _modelSort == mode,
                              onSelected: (_) =>
                                  setState(() => _modelSort = mode),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    if (sortedModels.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'No completed turns recorded in ${summary.timeframe.label} yet. Send a chat message to begin tracking spend, tokens, and cache efficiency.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: semantic.textSecondary,
                          ),
                        ),
                      )
                    else
                      for (var i = 0; i < sortedModels.length; i++) ...[
                        if (i > 0) const Divider(height: 14),
                        _ModelStatsRow(
                          model: sortedModels[i],
                          maxCostUsd: sortedModels.fold<double>(
                            0.0,
                            (m, e) => e.estimatedCostUsd > m
                                ? e.estimatedCostUsd
                                : m,
                          ),
                          maxTokens: sortedModels.fold<int>(
                            0,
                            (m, e) => e.usage.totalTokens > m
                                ? e.usage.totalTokens
                                : m,
                          ),
                          sortMode: _modelSort,
                        ),
                      ],
                  ],
                ),
              ),
            ),
            // Conversations, Quotas & Account Summary
            wrapSection(
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Workspace & Account Data',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _BreakdownRow(
                      color: theme.colorScheme.primary,
                      label: 'Total Conversations',
                      value: '$totalSessionsCount chats',
                      detail:
                          '$pinnedSessionsCount pinned · $archivedSessionsCount archived',
                    ),
                    _BreakdownRow(
                      color: theme.colorScheme.secondary,
                      label: 'Messages Stored Locally',
                      value: '$totalMessagesStored msgs',
                      detail: '${summary.distinctSessions} in selected period',
                    ),
                    _BreakdownRow(
                      color: theme.colorScheme.tertiary,
                      label: 'Active Plan & Credits',
                      value: auth.planTier.label,
                      detail: quota.aiCreditsRemaining != null
                          ? '${quota.aiCreditsRemaining!.round()} AI credits left'
                          : quota.source,
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'USD spend uses API-equivalent rate estimates from ModelPricingCatalog. Subscription / OAuth accounts consume 5-hour and weekly quota pools rather than direct billing.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      color: semantic.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    required this.width,
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    required this.sublabel,
  });

  final double width;
  final IconData icon;
  final Color accent;
  final String label;
  final String value;
  final String sublabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: accent),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              sublabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StackedTokenBar extends StatelessWidget {
  const _StackedTokenBar({
    required this.uncachedInput,
    required this.cacheRead,
    required this.output,
    required this.thinking,
  });

  final int uncachedInput;
  final int cacheRead;
  final int output;
  final int thinking;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final sum = uncachedInput + cacheRead + output + thinking;
    if (sum <= 0) {
      return Container(
        height: 8,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
      );
    }

    final segments = <(int count, Color color)>[
      (uncachedInput, theme.colorScheme.primary),
      (cacheRead, semantic.success),
      (output, theme.colorScheme.secondary),
      (thinking, theme.colorScheme.tertiary),
    ].where((s) => s.$1 > 0).toList();

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            for (final seg in segments)
              Expanded(
                flex: seg.$1,
                child: ColoredBox(color: seg.$2, child: const SizedBox.expand()),
              ),
          ],
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.color,
    required this.label,
    required this.value,
    required this.detail,
  });

  final Color color;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            flex: 2,
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyBarChart extends StatelessWidget {
  const _DailyBarChart({
    required this.series,
    required this.metric,
    required this.selectedDateKey,
    required this.onSelectDay,
  });

  final List<DailyUsageBucket> series;
  final _StatsChartMetric metric;
  final String? selectedDateKey;
  final ValueChanged<String> onSelectDay;

  double _valueOf(DailyUsageBucket b) => switch (metric) {
        _StatsChartMetric.spend => b.estimatedCostUsd,
        _StatsChartMetric.tokens => b.usage.totalTokens.toDouble(),
        _StatsChartMetric.requests => b.requests.toDouble(),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var maxVal = 0.0;
    for (final b in series) {
      final v = _valueOf(b);
      if (v > maxVal) maxVal = v;
    }

    DailyUsageBucket? selectedBucket;
    if (selectedDateKey != null) {
      for (final b in series) {
        if (b.dateKey == selectedDateKey) {
          selectedBucket = b;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 92,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < series.length; i++) ...[
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onSelectDay(series[i].dateKey),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              widthFactor: 0.68,
                              heightFactor: maxVal <= 0
                                  ? 0.06
                                  : (_valueOf(series[i]) / maxVal)
                                      .clamp(0.06, 1.0),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: selectedDateKey == series[i].dateKey
                                      ? theme.colorScheme.tertiary
                                      : _valueOf(series[i]) > 0
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme
                                              .surfaceContainerHighest,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          series.length <= 7 || i.isEven || i == series.length - 1
                              ? '${series[i].date.day}'
                              : '',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 10,
                            color: selectedDateKey == series[i].dateKey
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: selectedDateKey == series[i].dateKey
                                ? FontWeight.w700
                                : FontWeight.w400,
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
        if (selectedBucket != null) ...[
          const SizedBox(height: 6),
          Text(
            '${selectedBucket.dateKey}: ${ModelPricingCatalog.formatUsd(selectedBucket.estimatedCostUsd)} · ${selectedBucket.requests} reqs · ${UsageStatsSummary.formatCompactCount(selectedBucket.usage.totalTokens)} tok',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _ModelStatsRow extends StatelessWidget {
  const _ModelStatsRow({
    required this.model,
    required this.maxCostUsd,
    required this.maxTokens,
    required this.sortMode,
  });

  final ModelUsageAggregate model;
  final double maxCostUsd;
  final int maxTokens;
  final _ModelSortMode sortMode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final ratio = switch (sortMode) {
      _ModelSortMode.spend => maxCostUsd > 0
          ? (model.estimatedCostUsd / maxCostUsd).clamp(0.05, 1.0)
          : 0.05,
      _ModelSortMode.tokens => maxTokens > 0
          ? (model.usage.totalTokens / maxTokens).clamp(0.05, 1.0)
          : 0.05,
      _ModelSortMode.requests => 1.0,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                model.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              ModelPricingCatalog.formatUsd(model.estimatedCostUsd),
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 5,
            child: Row(
              children: [
                Flexible(
                  flex: math.max(1, (ratio * 1000).round()),
                  child: ColoredBox(
                    color: theme.colorScheme.primary,
                    child: const SizedBox.expand(),
                  ),
                ),
                if (ratio < 1.0)
                  Flexible(
                    flex: math.max(1, ((1.0 - ratio) * 1000).round()),
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const SizedBox.expand(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${model.requests} reqs · ${UsageStatsSummary.formatCompactCount(model.usage.totalTokens)} tok (In ${UsageStatsSummary.formatCompactCount(model.usage.inputTokens)} · Cache ${UsageStatsSummary.formatCompactCount(model.usage.cacheReadTokens)} · Out ${UsageStatsSummary.formatCompactCount(model.usage.outputTokens)} · Think ${UsageStatsSummary.formatCompactCount(model.usage.thinkingTokens)})',
          style: theme.textTheme.labelSmall?.copyWith(
            fontSize: 11,
            color: semantic.textSecondary,
          ),
        ),
      ],
    );
  }
}
