import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/chat_state.dart';
import '../../theme/app_theme.dart';
import '../auth/google_login_sheet.dart';
import 'render/agy_markdown.dart';
import 'secret_mask.dart';

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

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onRegenerate,
    this.onEditResend,
    this.tokensPerSecond,
  });

  final ChatMessage message;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEditResend;
  final double? tokensPerSecond;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final isUser = message.role == ChatRole.user;

    if (isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.attachments.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: message.attachments
                      .map(
                        (a) => Chip(
                          visualDensity: VisualDensity.compact,
                          avatar: const Icon(Icons.attach_file, size: 14),
                          label: Text(
                            a.split('/').last.split('\\').last,
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 6),
              ],
              SelectableText(
                message.text,
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatChatTimestamp(message.createdAt),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      color: theme.colorScheme.onPrimaryContainer
                          .withOpacity(0.72),
                    ),
                  ),
                  if (onEditResend != null) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      iconSize: 15,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 24, minHeight: 24),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Edit & resend',
                      onPressed: () async {
                        final ctrl = TextEditingController(text: message.text);
                        final updated = await showDialog<String>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Edit & Resend'),
                            content: TextField(
                              controller: ctrl,
                              minLines: 2,
                              maxLines: 6,
                              autofocus: true,
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(ctx).pop(ctrl.text),
                                child: const Text('Resend'),
                              ),
                            ],
                          ),
                        );
                        ctrl.dispose();
                        if (updated != null && updated.trim().isNotEmpty) {
                          onEditResend!(updated);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: theme.colorScheme.primary.withOpacity(0.16),
                child: Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Antigravity',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (message.isStreaming) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                if (tokensPerSecond != null && tokensPerSecond! > 0.5) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${tokensPerSecond!.toStringAsFixed(0)} tok/s',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: semantic.textSecondary,
                    ),
                  ),
                ],
              ],
              const Spacer(),
              if (message.text.isNotEmpty)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Response copied')),
                    );
                  },
                  icon: const Icon(Icons.copy_all_outlined),
                ),
              if (onRegenerate != null && !message.isStreaming)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Regenerate',
                  onPressed: onRegenerate,
                  icon: const Icon(Icons.refresh_rounded),
                ),
            ],
          ),
          if (message.thoughts.isNotEmpty) ...[
            const SizedBox(height: 6),
            _CollapsibleSection(
              icon: Icons.psychology_outlined,
              title: 'Reasoning & Thoughts',
              body: message.thoughts,
            ),
          ],
          if (message.tools.isNotEmpty) ...[
            const SizedBox(height: 6),
            _FoldedToolsBar(
              key: ValueKey('tools-${message.id}'),
              tools: message.tools,
            ),
          ],
          if (message.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            AgyMarkdown(
              text: message.text,
              streaming: message.isStreaming,
            ),
          ] else if (message.isStreaming) ...[
            const SizedBox(height: 8),
            Text(
              'Thinking…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: semantic.textSecondary,
              ),
            ),
          ],
          if (message.requiresAuth) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () => GoogleLoginSheet.show(context),
              icon: const Icon(Icons.login),
              label: const Text('Sign in with Google Account'),
            ),
          ],
          if (!message.isStreaming) ...[
            const SizedBox(height: 8),
            _MessageMetricsFooter(message: message),
          ],
        ],
      ),
    );
  }
}

class _MessageMetricsFooter extends StatelessWidget {
  const _MessageMetricsFooter({required this.message});

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

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        dense: true,
        initiallyExpanded: false,
        visualDensity: VisualDensity.compact,
        minTileHeight: 36,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        leading: Icon(icon, size: 17, color: theme.colorScheme.primary),
        title: Text(title, style: theme.textTheme.labelMedium),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: AgyMarkdown(
              text: body.trim(),
              secondary: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _FoldedToolsBar extends StatefulWidget {
  const _FoldedToolsBar({
    super.key,
    required this.tools,
  });

  final List<ChatToolStep> tools;

  @override
  State<_FoldedToolsBar> createState() => _FoldedToolsBarState();
}

class _FoldedToolsBarState extends State<_FoldedToolsBar> {
  bool _expanded = false;

  String _formatCommandOrParams(ChatToolStep step) {
    if (step.parameters.isEmpty) return '';
    final cmd = step.parameters['CommandLine'] ??
        step.parameters['command'] ??
        step.parameters['Path'] ??
        step.parameters['path'] ??
        step.parameters['TargetFile'];
    if (cmd != null && cmd.toString().trim().isNotEmpty) {
      return cmd.toString().trim();
    }
    return step.parameters.entries
        .map((e) => '${e.key}: ${e.value}')
        .join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final tools = widget.tools;
    final running =
        tools.where((t) => t.state == ToolCallState.running).length;
    final failed = tools.where((t) => t.state == ToolCallState.failed).length;
    // Keep the collapsed header strictly compact without printing running commands
    // unless the user taps to expand.
    final summary = running > 0
        ? 'Running $running tool step${running == 1 ? '' : 's'} (${tools.length} total)'
        : failed > 0
            ? '${tools.length} tool steps ($failed failed)'
            : '${tools.length} tool steps completed';

    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          dense: true,
          initiallyExpanded: false,
          visualDensity: VisualDensity.compact,
          minTileHeight: 36,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          onExpansionChanged: (v) => setState(() => _expanded = v),
          leading: Icon(
            running > 0
                ? Icons.sync
                : failed > 0
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
            size: 17,
            color: failed > 0
                ? semantic.danger
                : theme.colorScheme.primary,
          ),
          title: Text(
            summary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: semantic.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          children: _expanded
              ? tools.map((t) {
                  final cmdOrParam = _formatCommandOrParams(t);
                  final dur = t.durationSeconds != null
                      ? ' · ${formatDurationSeconds(t.durationSeconds!)}'
                      : '';
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• ${AgySecretMask.mask(t.toolName)} (${t.state.name}$dur)',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: semantic.textPrimary,
                          ),
                        ),
                        if (cmdOrParam.isNotEmpty)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 3),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: semantic.codeWellHeader,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              AgySecretMask.mask(
                                cmdOrParam.length > 300
                                    ? '${cmdOrParam.substring(0, 300)}…'
                                    : cmdOrParam,
                              ),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11,
                                color: semantic.textSecondary,
                              ),
                            ),
                          ),
                        if (t.output != null && t.output!.isNotEmpty)
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: semantic.codeWellBg,
                              borderRadius: BorderRadius.circular(8),
                              border:
                                  Border.all(color: semantic.codeWellBorder),
                            ),
                            child: Text(
                              AgySecretMask.mask(
                                t.output!.length > 600
                                    ? '${t.output!.substring(0, 600)}…'
                                    : t.output!,
                              ),
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                color: semantic.codeWellFg,
                              ),
                            ),
                          ),
                        if (t.error != null && t.error!.isNotEmpty)
                          Text(
                            AgySecretMask.mask(t.error!),
                            style: TextStyle(
                              color: semantic.danger,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList()
              : const [],
        ),
      ),
    );
  }
}
