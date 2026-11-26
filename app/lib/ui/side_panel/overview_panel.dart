import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/background_tasks_state.dart';
import '../../state/chat_state.dart';
import '../../state/harness_state.dart';
import '../../state/phone_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/side_panel_state.dart';
import '../../state/usage_state.dart';
import '../chat/secret_mask.dart';
import '../harness/harness_page.dart';
import '../phone/phone_control_page.dart';
import '../shell/background_tasks_sheet.dart';
import '../usage/usage_page.dart';
import '../workspace/diff_review_view.dart';

class _OverviewArtifactSummary {
  const _OverviewArtifactSummary({
    required this.id,
    required this.text,
  });

  final String id;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is _OverviewArtifactSummary &&
      other.id == id &&
      other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

class _OverviewChatSummary {
  const _OverviewChatSummary({
    required this.modifiedFiles,
    required this.artifacts,
  });

  factory _OverviewChatSummary.fromState(ChatThreadState chat) {
    final modified = <String>{};
    final artifacts = <_OverviewArtifactSummary>[];
    for (final m in chat.messages) {
      for (final t in m.tools) {
        final path = t.parameters['TargetFile'] ??
            t.parameters['AbsolutePath'] ??
            t.parameters['path'] ??
            t.parameters['file'];
        if (path != null) {
          final s = path.toString();
          if (s.isNotEmpty) modified.add(s);
        }
      }
      if (m.role == ChatRole.assistant &&
          m.text.length > 260 &&
          (m.text.contains('## ') || m.text.contains('```'))) {
        artifacts.add(_OverviewArtifactSummary(id: m.id, text: m.text));
      }
    }
    return _OverviewChatSummary(
      modifiedFiles: modified.toList(growable: false),
      artifacts: artifacts,
    );
  }

  final List<String> modifiedFiles;
  final List<_OverviewArtifactSummary> artifacts;

  @override
  bool operator ==(Object other) =>
      other is _OverviewChatSummary &&
      listEquals(other.modifiedFiles, modifiedFiles) &&
      listEquals(other.artifacts, artifacts);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(modifiedFiles),
        Object.hashAll(artifacts),
      );
}

/// 1:1 Antigravity App Overview Panel:
/// - Top launcher rows: Review, Files, Terminal, Browser, Phone Control
/// - Conversation sections: Usage Quotas, Modified Files, Artifacts, Tool Steps
class OverviewPanel extends ConsumerWidget {
  const OverviewPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(
      chatProvider.select(_OverviewChatSummary.fromState),
    );
    final bgTasks = ref.watch(backgroundTasksProvider);
    final usage = ref.watch(
      usageProvider.select((u) => (
            fiveHourRemaining: u.overallFiveHourRemainingPct,
            weeklyRemaining: u.overallWeeklyRemainingPct,
            fiveHourResetAt: u.overallFiveHourResetAt,
            fiveHourResetText: u.overallFiveHourResetText,
            weeklyResetAt: u.overallWeeklyResetAt,
            weeklyResetText: u.overallWeeklyResetText,
            fiveHourLedgerTotal: u.fiveHourLedgerTokens.totalTokens,
            weeklyLedgerTotal: u.weeklyLedgerTokens.totalTokens,
          )),
    );
    final accessibilityConnected = ref.watch(
      phoneProvider.select((p) => p.status.accessibilityConnected),
    );
    final settings = ref.watch(
      settingsProvider.select((s) => (
            presetLabel: s.permissionPreset.label,
            allowNonWorkspaceAccess: s.allowNonWorkspaceAccess,
          )),
    );
    final ctxPercentage =
        ref.watch(contextBudgetProvider.select((c) => c.percentage));
    final theme = Theme.of(context);

    final modifiedFiles = summary.modifiedFiles;
    final artifacts = summary.artifacts;

    void openSideTab(SidePanelTab tab) {
      onClose?.call();
      ref.read(sidePanelProvider.notifier).openTab(tab);
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
            child: Row(
              children: [
                Icon(Icons.dashboard_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Overview',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (onClose != null)
                  IconButton(
                    iconSize: 18,
                    tooltip: 'Close Overview',
                    onPressed: onClose,
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: Scrollbar(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  // Top launcher rows (1:1 Antigravity Desktop Overview Panel)
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.difference_outlined, size: 18),
                          title: const Text('Files Changed (Diff)'),
                          subtitle: const Text('Git uncommitted changes & diffs'),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () {
                            onClose?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const DiffReviewPage(),
                              ),
                            );
                          },
                        ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined, size: 18),
                          title: const Text('Files'),
                          subtitle: const Text('Project & device storage tree'),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => openSideTab(
                            const SidePanelTab(
                              id: 'files',
                              kind: SidePanelTabKind.files,
                              title: 'Files',
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.terminal, size: 18),
                          title: const Text('Terminal'),
                          subtitle: const Text('Integrated shell & agy TUI'),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => openSideTab(
                            const SidePanelTab(
                              id: 'terminal',
                              kind: SidePanelTabKind.terminal,
                              title: 'Terminal',
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.public, size: 18),
                          title: const Text('Browser'),
                          subtitle: const Text('Built-in browser & Remote Control'),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => openSideTab(
                            const SidePanelTab(
                              id: 'browser',
                              kind: SidePanelTabKind.browser,
                              title: 'Browser',
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.engineering_outlined, size: 18),
                          title: const Text('Harness Engineering'),
                          subtitle: Text(
                            'Context $ctxPercentage%, loop guard, /rewind & ledger',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () {
                            onClose?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const HarnessPage(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Background Tasks Section
                  Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => BackgroundTasksSheet.show(context),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                if (bgTasks.isNotEmpty)
                                  SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: RepaintBoundary(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  )
                                else
                                  Icon(
                                    Icons.layers_outlined,
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    bgTasks.isEmpty
                                        ? 'Background Tasks'
                                        : 'Background Tasks (${bgTasks.length})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(Icons.open_in_new, size: 15),
                              ],
                            ),
                            const SizedBox(height: 6),
                            if (bgTasks.isEmpty)
                              Text(
                                'No active background tasks',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            else
                              for (final task in bgTasks.take(3))
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        iconForBackgroundTask(task.kind),
                                        size: 14,
                                        color: theme.colorScheme.primary,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          AgySecretMask.mask(task.title),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ),
                                      if (task.canCancel)
                                        IconButton(
                                          iconSize: 16,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 24,
                                          ),
                                          tooltip: 'Force stop task',
                                          onPressed: () => ref
                                              .read(chatProvider.notifier)
                                              .forceStopTask(
                                                kindName: task.kind.name,
                                                nativeTaskId: task.nativeTaskId,
                                                sessionId: task.sessionId,
                                                queuedIndex: task.queuedIndex,
                                              ),
                                          icon: Icon(
                                            Icons.stop_circle_outlined,
                                            color: theme.colorScheme.error,
                                          ),
                                        ),
                                      if (task.kind ==
                                              BackgroundTaskKind.session &&
                                          task.sessionId != null)
                                        TextButton(
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                            ),
                                            minimumSize: const Size(0, 24),
                                            tapTargetSize: MaterialTapTargetSize
                                                .shrinkWrap,
                                          ),
                                          onPressed: () {
                                            ref
                                                .read(sessionsProvider.notifier)
                                                .selectSession(task.sessionId!);
                                            onClose?.call();
                                          },
                                          child: const Text('Open'),
                                        ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Usage Quotas Section
                  Card(
                    margin: EdgeInsets.zero,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const UsagePage(),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.speed_rounded,
                                    size: 18, color: theme.colorScheme.primary),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Quotas & Limits',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Icon(Icons.open_in_new, size: 15),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              usage.fiveHourRemaining != null ||
                                      usage.weeklyRemaining != null
                                  ? [
                                      if (usage.fiveHourRemaining != null)
                                        '5h: ${formatQuotaPct(usage.fiveHourRemaining!)} left (${formatQuotaPct(100.0 - usage.fiveHourRemaining!)} used${usage.fiveHourResetAt != null ? ", ${formatResetCountdown(usage.fiveHourResetAt!)}" : (usage.fiveHourResetText != null ? ", ${usage.fiveHourResetText}" : "")})',
                                      if (usage.weeklyRemaining != null)
                                        'Weekly: ${formatQuotaPct(usage.weeklyRemaining!)} left (${formatQuotaPct(100.0 - usage.weeklyRemaining!)} used${usage.weeklyResetAt != null ? ", ${formatResetCountdown(usage.weeklyResetAt!)}" : (usage.weeklyResetText != null ? ", ${usage.weeklyResetText}" : "")})',
                                    ].join(' · ')
                                  : '5h: ${usage.fiveHourLedgerTotal} tok · 7d: ${usage.weeklyLedgerTotal} tok',
                              style: theme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Argon · Neon/Carbon · Hydrogen · Claude & GPT',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Artifacts Section
                  if (artifacts.isNotEmpty) ...[
                    Text(
                      'Artifacts (${artifacts.length})',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (var i = 0; i < artifacts.length && i < 4; i++)
                      Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.article_outlined, size: 18),
                          title: Text(
                            'Artifact #${i + 1}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            artifacts[i].text.replaceAll('\n', ' '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => openSideTab(
                            SidePanelTab(
                              id: 'artifact-${artifacts[i].id}',
                              kind: SidePanelTabKind.artifact,
                              title: 'Artifact #${i + 1}',
                              content: artifacts[i].text,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],

                  // Modified Files Section
                  if (modifiedFiles.isNotEmpty) ...[
                    Text(
                      'Modified / Referenced Files (${modifiedFiles.length})',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final path in modifiedFiles.take(6))
                      Card(
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.edit_document, size: 18),
                          title: Text(
                            path.split('/').last,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () {
                            onClose?.call();
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => DiffReviewPage(
                                  initialFocusPath: path,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    const SizedBox(height: 8),
                  ],

                  // Tool Steps & Phone Control Summary
                  Text(
                    'Device & Policy',
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Card(
                    margin: EdgeInsets.zero,
                    child: Column(
                      children: [
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.security, size: 18),
                          title: Text('Preset: ${settings.presetLabel}'),
                          subtitle: Text(
                            settings.allowNonWorkspaceAccess
                                ? 'Non-workspace file access: Allowed'
                                : 'Non-workspace file access: Restricted',
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.touch_app_outlined, size: 18),
                          title: const Text('Phone Control'),
                          subtitle: Text(
                            accessibilityConnected
                                ? 'Accessibility connected'
                                : 'Accessibility off',
                          ),
                          trailing: const Icon(Icons.chevron_right, size: 18),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const PhoneControlPage(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
