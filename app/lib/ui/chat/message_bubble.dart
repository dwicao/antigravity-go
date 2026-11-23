import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/chat_state.dart';
import '../../theme/app_theme.dart';
import '../auth/google_login_sheet.dart';
import 'change_card.dart';
import 'message_metrics_footer.dart';
import 'milestone_stack_card.dart';
import 'render/agy_markdown.dart';
import 'secret_mask.dart';

export 'message_metrics_footer.dart'
    show formatChatTimestamp, formatDurationSeconds, formatTokenCount;

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onRegenerate,
    this.onEditResend,
    this.onRewind,
    this.onOpenDiff,
    this.tokensPerSecond,
  });

  final ChatMessage message;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEditResend;
  final VoidCallback? onRewind;
  final VoidCallback? onOpenDiff;
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
                      icon: Icon(
                        Icons.edit_outlined,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                  if (onRewind != null) ...[
                    const SizedBox(width: 2),
                    IconButton(
                      iconSize: 15,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 24, minHeight: 24),
                      visualDensity: VisualDensity.compact,
                      tooltip: message.checkpointRef != null
                          ? 'Rewind workspace & thread to here'
                          : 'Rewind thread to here',
                      onPressed: onRewind,
                      icon: Icon(
                        Icons.history_rounded,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
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
          if (message.isCompactionSummary)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        Icons.compress_rounded,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                      label: Text(
                        'Context compacted · Fresh window active',
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 12,
                      backgroundColor:
                          theme.colorScheme.primary.withOpacity(0.16),
                      child: Icon(
                        Icons.auto_awesome,
                        size: 14,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Antigravity',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (message.isStreaming) ...[
                      const SizedBox(width: 8),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      if (tokensPerSecond != null &&
                          tokensPerSecond! > 0.5) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${tokensPerSecond!.toStringAsFixed(0)} tok/s',
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: semantic.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
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
          if (message.steps.isNotEmpty) ...[
            const SizedBox(height: 6),
            MilestoneStackCard(
              key: ValueKey('steps-${message.id}'),
              steps: message.steps,
              tools: message.tools,
              isStreaming: message.isStreaming,
            ),
          ] else ...[
            if (message.thoughts.isNotEmpty) ...[
              const SizedBox(height: 6),
              CollapsibleThoughtSection(
                icon: Icons.psychology_outlined,
                title: 'Reasoning & Thoughts',
                body: AgySecretMask.mask(message.thoughts),
              ),
            ],
            if (message.tools.isNotEmpty) ...[
              const SizedBox(height: 6),
              FoldedToolsBar(
                key: ValueKey('tools-${message.id}'),
                tools: message.tools,
              ),
            ],
          ],
          if (message.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            AgyMarkdown(
              text: message.text,
              streaming: message.isStreaming,
            ),
          ] else if (message.isStreaming &&
              message.steps.isEmpty &&
              message.tools.isEmpty &&
              message.thoughts.isEmpty) ...[
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
          if (!message.isStreaming && message.changedFiles.isNotEmpty)
            ChangeCard(
              files: message.changedFiles,
              onOpenDiff: onOpenDiff,
            ),
          if (!message.isStreaming) ...[
            const SizedBox(height: 8),
            MessageMetricsFooter(message: message),
          ],
        ],
      ),
    );
  }
}
