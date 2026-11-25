import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';

import '../../state/chat_state.dart';
import '../../theme/app_theme.dart';

const _monthAbbr = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatChatTimestamp(DateTime dt) {
  final local = dt.toLocal();
  final m = _monthAbbr[(local.month - 1).clamp(0, 11)];
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$m ${local.day}, $hh:$mm';
}

String formatDurationSeconds(double seconds) {
  if (seconds < 10) return '${seconds.toStringAsFixed(1)}s';
  final rounded = seconds.round();
  if (rounded < 60) return '${rounded}s';
  final mins = rounded ~/ 60;
  final rem = rounded % 60;
  if (mins < 60) return '${mins}m ${rem}s';
  final hrs = mins ~/ 60;
  return '${hrs}h ${mins % 60}m';
}

String formatTokenCount(int count) {
  if (count < 1000) return '$count';
  final s = count.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(s[i]);
  }
  return buf.toString();
}

class MessageMetricsFooter extends StatelessWidget {
  const MessageMetricsFooter({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final usage = message.usage;
    final items = <({IconData icon, String label})>[];

    if (usage != null && usage.totalTokens > 0) {
      final parts = <String>[];
      if (usage.inputTokens > 0) {
        parts.add('${formatTokenCount(usage.inputTokens)} in');
      }
      if (usage.outputTokens > 0) {
        parts.add('${formatTokenCount(usage.outputTokens)} out');
      }
      if (usage.thinkingTokens > 0) {
        parts.add('${formatTokenCount(usage.thinkingTokens)} think');
      }
      if (usage.cacheReadTokens > 0) {
        parts.add('${formatTokenCount(usage.cacheReadTokens)} cache');
      }
      final detail = parts.isNotEmpty ? ' (${parts.join(' · ')})' : '';
      items.add((
        icon: Icons.toll_outlined,
        label: '${formatTokenCount(usage.totalTokens)} tok$detail',
      ));
      final cacheDenom = usage.inputTokens + usage.cacheReadTokens;
      if (usage.cacheReadTokens > 0 && cacheDenom > 0) {
        final hitPct = ((usage.cacheReadTokens / cacheDenom) * 100).round();
        items.add((
          icon: Icons.cached_rounded,
          label: '$hitPct% hit',
        ));
      }
      final estUsd = ModelPricingCatalog.estimateTurnCostUsd(
        message.modelId ?? '',
        usage,
      );
      items.add((
        icon: Icons.attach_money_rounded,
        label: ModelPricingCatalog.formatUsd(estUsd),
      ));
    } else {
      final estChars =
          message.text.trim().length + message.thoughts.trim().length;
      if (estChars > 0) {
        final estTok = (estChars * 0.35).round().clamp(1, 9999999);
        items.add((
          icon: Icons.toll_outlined,
          label: '~${formatTokenCount(estTok)} tok (est.)',
        ));
      }
    }

    if (message.tokensPerSecond != null && message.tokensPerSecond! > 0.1) {
      items.add((
        icon: Icons.bolt_outlined,
        label: '${message.tokensPerSecond!.toStringAsFixed(1)} tok/s',
      ));
    }

    if (message.durationSeconds != null && message.durationSeconds! > 0) {
      items.add((
        icon: Icons.timer_outlined,
        label: formatDurationSeconds(message.durationSeconds!),
      ));
    }

    items.add((
      icon: Icons.schedule_outlined,
      label: formatChatTimestamp(message.completedAt ?? message.createdAt),
    ));

    if (message.modelId != null && message.modelId!.isNotEmpty) {
      final model = AgyModelCatalog.resolve(message.modelId!);
      final effortLabel = model.supportsEffort &&
              message.reasoningEffort != null &&
              message.reasoningEffort!.isNotEmpty
          ? ' - ${ReasoningEffort.fromString(message.reasoningEffort!).label}'
          : '';
      items.add((
        icon: Icons.auto_awesome_outlined,
        label: '${model.displayName}$effortLabel',
      ));
    }

    final textStyle = theme.textTheme.labelSmall?.copyWith(
      fontSize: 11,
      color: semantic.textTertiary,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.35),
          ),
        ),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: items
            .map(
              (item) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(item.icon, size: 12, color: semantic.textTertiary),
                  const SizedBox(width: 4),
                  Text(item.label, style: textStyle),
                ],
              ),
            )
            .toList(),
      ),
    );
  }
}
