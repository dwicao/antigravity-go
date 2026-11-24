import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/chat_state.dart';
import '../../state/chat_turn_helpers.dart';
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
    this.activeSubagents = const [],
  });

  final ChatMessage message;
  final VoidCallback? onRegenerate;
  final ValueChanged<String>? onEditResend;
  final VoidCallback? onRewind;
  final VoidCallback? onOpenDiff;
  final double? tokensPerSecond;
  final List<ActiveSubagent> activeSubagents;

  List<Widget> _buildBodySegments(ThemeData theme, AgySemanticColors semantic) {
    final hasTextSteps =
        message.steps.any((s) => s.kind == ChatMilestoneKind.text);
    if (!hasTextSteps) {
      return [
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
      ];
    }

    // Chronologically group steps so milestones appearing after chat result
    // text stay rendered below that text rather than hoisted to the top.
    final segments = <({bool isText, String text, List<ChatMilestoneStep> steps})>[];
    var pendingSteps = <ChatMilestoneStep>[];
    for (final step in message.steps) {
      if (step.kind == ChatMilestoneKind.text) {
        if (step.text.trim().isEmpty) continue;
        if (pendingSteps.isNotEmpty) {
          segments.add((isText: false, text: '', steps: pendingSteps));
          pendingSteps = <ChatMilestoneStep>[];
        }
        segments.add((isText: true, text: step.text, steps: const []));
      } else {
        pendingSteps.add(step);
      }
    }
    if (pendingSteps.isNotEmpty) {
      segments.add((isText: false, text: '', steps: pendingSteps));
    }

    final coveredToolIds = <String>{
      for (final s in message.steps)
        if (s.toolId != null) s.toolId!,
    };
    final orphanTools = message.tools
        .where((t) => !coveredToolIds.contains(t.id))
        .toList();

    final widgets = <Widget>[];
    var milestoneGroupIdx = 0;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final isLast = i == segments.length - 1;
      if (seg.isText) {
        widgets.add(const SizedBox(height: 8));
        widgets.add(
          AgyMarkdown(
            text: seg.text,
            streaming: message.isStreaming && isLast,
          ),
        );
      } else {
        final stepToolIds = seg.steps
            .map((s) => s.toolId)
            .whereType<String>()
            .toSet();
        final segTools = message.tools
            .where((t) => stepToolIds.contains(t.id))
            .toList();
        widgets.add(const SizedBox(height: 6));
        widgets.add(
          MilestoneStackCard(
            key: ValueKey('steps-${message.id}-${milestoneGroupIdx++}'),
            steps: seg.steps,
            tools: segTools,
            isStreaming: message.isStreaming && isLast,
          ),
        );
      }
    }
    if (orphanTools.isNotEmpty) {
      widgets.add(const SizedBox(height: 6));
      widgets.add(
        FoldedToolsBar(
          key: ValueKey('tools-${message.id}'),
          tools: orphanTools,
        ),
      );
    }
    return widgets;
  }

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
                  ],
                ),
              ),
              if (message.text.isNotEmpty)
                IconButton(
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Copy',
                  onPressed: () => _copyResponseText(context, message.text),
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
          ..._buildBodySegments(theme, semantic),
          if (message.tools.any(
              (t) => ChatTurnHelpers.isSubagentSpawnTool(t.toolName))) ...[
            const SizedBox(height: 6),
            _SpawnedSubagentsStrip(
              tools: message.tools,
              activeSubagents: activeSubagents,
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
          if (!message.isStreaming && message.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            _BottomCopyButton(text: message.text),
          ],
          if (!message.isStreaming) ...[
            const SizedBox(height: 8),
            MessageMetricsFooter(message: message),
          ],
        ],
      ),
    );
  }
}

void _copyResponseText(BuildContext context, String text) {
  HapticFeedback.lightImpact();
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      const SnackBar(content: Text('Response copied')),
    );
}

class _BottomCopyButton extends StatefulWidget {
  const _BottomCopyButton({required this.text});

  final String text;

  @override
  State<_BottomCopyButton> createState() => _BottomCopyButtonState();
}

class _BottomCopyButtonState extends State<_BottomCopyButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _copyResponseText(context, widget.text);
    _resetTimer?.cancel();
    setState(() => _copied = true);
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final color = _copied ? theme.colorScheme.primary : semantic.textSecondary;

    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Copy response',
        child: InkWell(
          key: const ValueKey('bottom-copy-button'),
          borderRadius: BorderRadius.circular(8),
          onTap: _handleTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withOpacity(0.45),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 13,
                  color: color,
                ),
                const SizedBox(width: 5),
                Text(
                  _copied ? 'Copied' : 'Copy',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11.5,
                    color: color,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SpawnedSubagentsStrip extends StatelessWidget {
  const _SpawnedSubagentsStrip({
    required this.tools,
    required this.activeSubagents,
  });

  final List<ChatToolStep> tools;
  final List<ActiveSubagent> activeSubagents;

  @override
  Widget build(BuildContext context) {
    final spawns = tools
        .where((t) => ChatTurnHelpers.isSubagentSpawnTool(t.toolName))
        .toList();
    if (spawns.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    return Wrap(
      key: const ValueKey('spawned-subagents-strip'),
      spacing: 6,
      runSpacing: 6,
      children: spawns.map((tool) {
        final role =
            ChatTurnHelpers.extractSubagentRole(tool.toolName, tool.parameters);
        final convId = ChatTurnHelpers.extractConversationId(tool.output);
        ActiveSubagent? liveMatch;
        for (final s in activeSubagents) {
          if (s.id == tool.id || (convId != null && s.conversationId == convId)) {
            liveMatch = s;
            break;
          }
        }

        final SubagentStatus effectiveStatus;
        if (liveMatch != null) {
          effectiveStatus = liveMatch.status;
        } else if (tool.state == ToolCallState.failed ||
            (tool.error?.isNotEmpty ?? false)) {
          effectiveStatus = SubagentStatus.failed;
        } else if (tool.state == ToolCallState.running ||
            tool.state == ToolCallState.pending) {
          effectiveStatus = SubagentStatus.spawning;
        } else {
          effectiveStatus = SubagentStatus.completed;
        }

        final isBusy = effectiveStatus == SubagentStatus.spawning ||
            effectiveStatus == SubagentStatus.running;
        final isFailed = effectiveStatus == SubagentStatus.failed;
        final tint = isFailed
            ? semantic.danger
            : isBusy
                ? theme.colorScheme.primary
                : semantic.success;
        final stateLabel = switch (effectiveStatus) {
          SubagentStatus.spawning => 'spawning',
          SubagentStatus.running => 'working',
          SubagentStatus.failed => 'failed',
          SubagentStatus.completed => 'launched',
        };

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.75),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tint.withOpacity(0.32)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isBusy)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: tint),
                )
              else
                Icon(
                  isFailed ? Icons.error_outline : Icons.smart_toy_outlined,
                  size: 13,
                  color: tint,
                ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(
                  AgySecretMask.mask(role),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: semantic.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                stateLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  color: tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
