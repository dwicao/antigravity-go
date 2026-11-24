import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';

import '../../state/chat_state.dart';
import '../../state/chat_turn_helpers.dart';
import '../../theme/app_theme.dart';
import 'message_metrics_footer.dart';
import 'render/agy_markdown.dart';
import 'secret_mask.dart';

class CollapsibleThoughtSection extends StatelessWidget {
  const CollapsibleThoughtSection({
    super.key,
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

class FoldedToolsBar extends StatefulWidget {
  const FoldedToolsBar({
    super.key,
    required this.tools,
  });

  final List<ChatToolStep> tools;

  @override
  State<FoldedToolsBar> createState() => _FoldedToolsBarState();
}

class _FoldedToolsBarState extends State<FoldedToolsBar> {
  bool _expanded = false;

  String _formatCommandOrParams(ChatToolStep step) {
    final formatted = ChatTurnHelpers.formatToolTarget(step);
    if (formatted.isNotEmpty) return formatted;
    if (step.parameters.isEmpty) return '';
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
                    final displayTool = _MilestoneStackCardState._toolActionVerb(t);
                    final dur = t.durationSeconds != null
                      ? ' · ${formatDurationSeconds(t.durationSeconds!)}'
                      : '';
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '• ${AgySecretMask.mask(displayTool)} (${t.state.name}$dur)',
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

/// Chronological stacked progress & milestone feed showing interleaved
/// `Thinking — ...` and `Run — ...` cards inside one turn.
class MilestoneStackCard extends StatefulWidget {
  const MilestoneStackCard({
    super.key,
    required this.steps,
    required this.tools,
    required this.isStreaming,
  });

  final List<ChatMilestoneStep> steps;
  final List<ChatToolStep> tools;
  final bool isStreaming;

  @override
  State<MilestoneStackCard> createState() => _MilestoneStackCardState();
}

class _MilestoneStackCardState extends State<MilestoneStackCard> {
  bool _stackOpen = true;
  final Set<String> _expandedSteps = <String>{};

  static String _firstLine(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _toolActionVerb(ChatToolStep tool) {
    final toolName = tool.toolName.trim();
    final lower = toolName.toLowerCase();
    if (lower.contains('invoke_subagent') ||
        lower.contains('invoking subagent')) {
      return 'Subagent';
    }
    if (lower.contains('define_subagent') ||
        lower.contains('defining subagent')) {
      return 'Define subagent';
    }
    if (lower.contains('manage_subagents') ||
        lower.contains('managing subagents')) {
      return 'Subagents';
    }
    if (lower.contains('send_message') || lower.contains('sending message')) {
      return 'Message';
    }
    if (lower.contains('run_workflow') || lower.contains('workflow')) {
      return 'Workflow';
    }
    if (lower.contains('command_status') ||
        lower.contains('send_command_input') ||
        lower.contains('read_terminal')) {
      return 'Terminal';
    }
    if (lower.contains('run') ||
        lower.contains('command') ||
        lower.contains('terminal') ||
        lower.contains('shell') ||
        lower.contains('exec')) {
      return 'Run';
    }
    if (lower.contains('write') ||
        lower.contains('edit') ||
        lower.contains('replace') ||
        lower.contains('patch')) {
      return 'Edit';
    }
    if (lower == 'file' ||
        lower.startsWith('file ') ||
        lower.contains('read') ||
        lower.contains('view') ||
        lower.contains('analyz')) {
      final p = tool.parameters;
      final isEdit = p.containsKey('Replacement') ||
          p.containsKey('ReplacementContent') ||
          p.containsKey('oldText') ||
          p.containsKey('newText');
      return isEdit ? 'Edit' : 'Read';
    }
    if (lower.contains('list_dir') || lower.contains('list_resources')) {
      return 'List';
    }
    if (lower.contains('find_by_name')) return 'Find';
    if (lower.contains('read_url') || lower.contains('fetch')) return 'Fetch';
    if (lower.contains('grep') ||
        lower.contains('find') ||
        lower.contains('search')) {
      return 'Search';
    }
    if (lower.contains('../') || lower.contains('/')) {
      return 'File';
    }
    return toolName;
  }

  static IconData _toolStepIcon(ChatToolStep tool) {
    if (tool.state == ToolCallState.failed) return Icons.error_outline;
    if (tool.state == ToolCallState.running) return Icons.play_circle_outline;
    final lower = tool.toolName.toLowerCase();
    if (lower.contains('subagent')) return Icons.smart_toy_outlined;
    if (lower.contains('workflow')) return Icons.account_tree_outlined;
    if (lower.contains('send_message') || lower.contains('sending message')) {
      return Icons.send_outlined;
    }
    final verb = _toolActionVerb(tool);
    return switch (verb) {
      'Read' || 'File' => Icons.description_outlined,
      'Edit' => Icons.edit_note_rounded,
      'Search' || 'Find' => Icons.search_rounded,
      'List' => Icons.folder_open_outlined,
      'Fetch' => Icons.language_rounded,
      _ => Icons.terminal,
    };
  }

  static String _toolCommandOrTarget(ChatToolStep step) =>
      ChatTurnHelpers.formatToolTarget(step);

  static String _summarizeCompletedHeader(List<ChatToolStep> tools) {
    var commands = 0;
    var reads = 0;
    var edits = 0;
    var searches = 0;
    var others = 0;
    for (final t in tools) {
      switch (_toolActionVerb(t)) {
        case 'Run' || 'Terminal':
          commands++;
        case 'Read' || 'File' || 'List' || 'Fetch':
          reads++;
        case 'Edit':
          edits++;
        case 'Search' || 'Find':
          searches++;
        default:
          others++;
      }
    }
    final total = tools.length;
    if (commands == total) {
      return 'Ran $commands command${commands == 1 ? '' : 's'}';
    }
    if (reads == total) {
      return 'Read $reads file${reads == 1 ? '' : 's'}';
    }
    if (edits == total) {
      return 'Edited $edits file${edits == 1 ? '' : 's'}';
    }
    if (searches == total) {
      return '$searches search${searches == 1 ? '' : 'es'}';
    }
    final parts = <String>[
      if (reads > 0) '$reads read',
      if (edits > 0) '$edits edited',
      if (searches > 0) '$searches search',
      if (commands > 0) '$commands ran',
      if (others > 0) '$others other',
    ];
    return 'Completed $total step${total == 1 ? '' : 's'} · ${parts.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final toolsById = {for (final t in widget.tools) t.id: t};
    final runningCount = widget.tools
        .where((t) => t.state == ToolCallState.running)
        .length;
    final subagentSpawnCount = widget.tools
        .where((t) => ChatTurnHelpers.isSubagentSpawnTool(t.toolName))
        .length;
    final runningSubagentCount = widget.tools
        .where(
          (t) =>
              t.state == ToolCallState.running &&
              ChatTurnHelpers.isSubagentSpawnTool(t.toolName),
        )
        .length;
    final cmdCount = widget.tools.length;
    final thoughtCount = widget.steps
        .where((s) => s.kind == ChatMilestoneKind.thought)
        .length;

    final String headerLabel;
    if (runningSubagentCount > 0) {
      headerLabel =
          'Spawning $runningSubagentCount subagent${runningSubagentCount == 1 ? '' : 's'} ($cmdCount total)';
    } else if (runningCount > 0) {
      final allRunningCommands = widget.tools
          .where((t) => t.state == ToolCallState.running)
          .every((t) {
        final v = _toolActionVerb(t);
        return v == 'Run' || v == 'Terminal';
      });
      final unit = allRunningCommands ? 'command' : 'step';
      headerLabel =
          'Running $runningCount $unit${runningCount == 1 ? '' : 's'} ($cmdCount total)';
    } else if (subagentSpawnCount > 0) {
      headerLabel =
          'Spawned $subagentSpawnCount subagent${subagentSpawnCount == 1 ? '' : 's'} ($cmdCount step${cmdCount == 1 ? '' : 's'})';
    } else if (cmdCount > 0) {
      headerLabel = _summarizeCompletedHeader(widget.tools);
    } else {
      headerLabel = '$thoughtCount thinking step${thoughtCount == 1 ? '' : 's'}';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _stackOpen = !_stackOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    runningCount > 0 ? Icons.sync : Icons.layers_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      headerLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    _stackOpen
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: semantic.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_stackOpen) ...[
            const Divider(height: 1),
            for (final step in widget.steps)
              _buildStepTile(context, step, toolsById, theme, semantic),
          ],
        ],
      ),
    );
  }

  Widget _buildStepTile(
    BuildContext context,
    ChatMilestoneStep step,
    Map<String, ChatToolStep> toolsById,
    ThemeData theme,
    AgySemanticColors semantic,
  ) {
    final isOpen = _expandedSteps.contains(step.id);

    if (step.kind == ChatMilestoneKind.thought) {
      final masked = AgySecretMask.mask(step.text);
      final preview = _firstLine(masked);
      return InkWell(
        onTap: () => setState(() {
          if (isOpen) {
            _expandedSteps.remove(step.id);
          } else {
            _expandedSteps.add(step.id);
          }
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: theme.colorScheme.outlineVariant.withOpacity(0.25),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Thinking — $preview',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: semantic.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (isOpen) ...[
                const SizedBox(height: 6),
                AgyMarkdown(text: masked.trim(), secondary: true),
              ],
            ],
          ),
        ),
      );
    }

    final tool = toolsById[step.toolId];
    if (tool == null) return const SizedBox.shrink();
    final verb = _toolActionVerb(tool);
    final arg = _toolCommandOrTarget(tool);
    final label = arg.isEmpty ? verb : '$verb — $arg';

    return InkWell(
      onTap: () => setState(() {
        if (isOpen) {
          _expandedSteps.remove(step.id);
        } else {
          _expandedSteps.add(step.id);
        }
      }),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: theme.colorScheme.outlineVariant.withOpacity(0.25),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _toolStepIcon(tool),
                  size: 15,
                  color: tool.state == ToolCallState.failed
                      ? semantic.danger
                      : tool.state == ToolCallState.running
                          ? theme.colorScheme.primary
                          : semantic.success,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    AgySecretMask.mask(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: arg.isNotEmpty ? 'monospace' : null,
                      color: tool.state == ToolCallState.failed
                          ? semantic.danger
                          : semantic.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (tool.durationSeconds != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    formatDurationSeconds(tool.durationSeconds!),
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5,
                      color: semantic.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
            if (isOpen &&
                (arg.isNotEmpty ||
                    (tool.output?.isNotEmpty ?? false) ||
                    (tool.error?.isNotEmpty ?? false))) ...[
              const SizedBox(height: 6),
              if (arg.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: semantic.codeWellHeader,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    AgySecretMask.mask(
                      arg.length > 300 ? '${arg.substring(0, 300)}…' : arg,
                    ),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: semantic.textSecondary,
                    ),
                  ),
                ),
              if (tool.output != null && tool.output!.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: semantic.codeWellBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    AgySecretMask.mask(
                      tool.output!.length > 600
                          ? '${tool.output!.substring(0, 600)}…'
                          : tool.output!,
                    ),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: semantic.codeWellFg,
                    ),
                  ),
                ),
              if (tool.error != null && tool.error!.isNotEmpty)
                SelectableText(
                  AgySecretMask.mask(tool.error!),
                  style: TextStyle(color: semantic.danger, fontSize: 11.5),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
