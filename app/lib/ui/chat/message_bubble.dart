import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../state/chat_state.dart';
import '../auth/google_login_sheet.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onRegenerate,
    this.onEditResend,
  });

  final ChatMessage message;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEditResend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              if (onEditResend != null)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    iconSize: 15,
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
              ],
              const Spacer(),
              if (message.usage != null && message.usage!.totalTokens > 0)
                Text(
                  '${message.usage!.totalTokens} tok',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
            _FoldedToolsBar(tools: message.tools),
          ],
          if (message.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            GptMarkdown(message.text),
          ] else if (message.isStreaming) ...[
            const SizedBox(height: 8),
            Text(
              'Thinking…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
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
        ],
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
        leading: Icon(icon, size: 18, color: theme.colorScheme.primary),
        title: Text(title, style: theme.textTheme.labelMedium),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              body.trim(),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FoldedToolsBar extends StatelessWidget {
  const _FoldedToolsBar({required this.tools});

  final List<ChatToolStep> tools;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running =
        tools.where((t) => t.state == ToolCallState.running).length;
    final failed = tools.where((t) => t.state == ToolCallState.failed).length;
    final summary = running > 0
        ? 'Running ${tools.last.toolName} (${tools.length} steps)'
        : failed > 0
            ? '${tools.length} tool steps ($failed failed)'
            : '${tools.length} tool steps completed';

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        dense: true,
        leading: Icon(
          running > 0
              ? Icons.sync
              : failed > 0
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
          size: 18,
          color: failed > 0
              ? theme.colorScheme.error
              : theme.colorScheme.primary,
        ),
        title: Text(summary, style: theme.textTheme.labelMedium),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: tools
            .map(
              (t) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• ${t.toolName} (${t.state.name})',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (t.output != null && t.output!.isNotEmpty)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          t.output!.length > 600
                              ? '${t.output!.substring(0, 600)}…'
                              : t.output!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (t.error != null && t.error!.isNotEmpty)
                      Text(
                        t.error!,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}
