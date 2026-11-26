import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/projects_state.dart';
import '../../state/sessions_state.dart';
import '../../state/side_panel_state.dart';
import '../automations/automations_page.dart';
import '../cli/cli_manager_page.dart';
import '../customizations/customizations_page.dart';
import '../harness/harness_page.dart';
import '../phone/phone_control_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../replay/conversation_replay_page.dart';
import '../settings/background_guide_page.dart';
import '../settings/diagnostics_page.dart';
import '../settings/settings_page.dart';
import '../update/update_sheet.dart';
import '../usage/stats_page.dart';
import '../usage/usage_page.dart';
import '../workspace/diff_review_view.dart';
import 'session_search_page.dart';

/// Antigravity Desktop `Ctrl+K` Search & Command Palette.
class CommandPaletteDialog extends ConsumerStatefulWidget {
  const CommandPaletteDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const CommandPaletteDialog(),
    );
  }

  @override
  ConsumerState<CommandPaletteDialog> createState() =>
      _CommandPaletteDialogState();
}

class _CommandPaletteDialogState extends ConsumerState<CommandPaletteDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider).sessions;
    final projects = ref.watch(projectsProvider).projects;
    final q = _query.toLowerCase().trim();

    final actions = <(String label, String subtitle, IconData icon, VoidCallback run)>[
      (
        'New Conversation',
        'Start a fresh agent chat in the active project',
        Icons.add_comment_outlined,
        () {
          Navigator.of(context).pop();
          ref.read(sessionsProvider.notifier).createSession();
        },
      ),
      (
        'Stats & Spend Analytics',
        'View cumulative USD spend, tokens, requests & per-model breakdown',
        Icons.bar_chart_rounded,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const StatsPage()),
          );
        },
      ),
      (
        'Usage Limits & Quotas',
        'View 5h, Weekly, Gemini Argon/Pro/Flash, Claude & GPT quotas',
        Icons.speed_rounded,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const UsagePage()),
          );
        },
      ),
      (
        'Harness Engineering Dashboard',
        'Context budget, loop breaker, /rewind checkpoints & feature ledger',
        Icons.engineering_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const HarnessPage()),
          );
        },
      ),
      (
        'Antigravity CLI & Subcommands',
        'Run agy mcp, plugin, agent, remote-control, models & flags',
        Icons.terminal,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CliManagerPage()),
          );
        },
      ),
      (
        'Check for App Updates',
        'Download APK update with live progress, data usage & cancel',
        Icons.system_update_alt,
        () {
          Navigator.of(context).pop();
          UpdateSheet.show(context);
        },
      ),
      (
        'Open Side Panel: Files',
        'Browse workspace files & storage',
        Icons.folder_outlined,
        () {
          Navigator.of(context).pop();
          ref.read(sidePanelProvider.notifier).openTab(
                const SidePanelTab(
                  id: 'files',
                  kind: SidePanelTabKind.files,
                  title: 'Files',
                ),
              );
        },
      ),
      (
        'Open Files Changed (GitHub Diff Viewer)',
        'Inspect changed files, red/green diffs, Split/Unified & commit/push',
        Icons.difference_outlined,
        () {
          final nav = Navigator.of(context);
          nav.pop();
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => const DiffReviewPage(),
            ),
          );
        },
      ),
      (
        'Open Side Panel: Terminal',
        'Launch integrated terminal tab',
        Icons.terminal,
        () {
          Navigator.of(context).pop();
          ref.read(sidePanelProvider.notifier).openTab(
                const SidePanelTab(
                  id: 'terminal',
                  kind: SidePanelTabKind.terminal,
                  title: 'Terminal',
                ),
              );
        },
      ),
      (
        'Open Side Panel: Built-in Browser',
        'Browse antigravity.google.com or localhost previews',
        Icons.public,
        () {
          Navigator.of(context).pop();
          ref.read(sidePanelProvider.notifier).openTab(
                const SidePanelTab(
                  id: 'browser',
                  kind: SidePanelTabKind.browser,
                  title: 'Browser',
                ),
              );
        },
      ),
      (
        'Open Side Panel: Web Preview + Console',
        'Preview localhost / HTML apps with live console error capture',
        Icons.web_asset_outlined,
        () {
          Navigator.of(context).pop();
          ref.read(sidePanelProvider.notifier).openTab(
                const SidePanelTab(
                  id: 'preview',
                  kind: SidePanelTabKind.preview,
                  title: 'Preview',
                ),
              );
        },
      ),
      (
        'Automations',
        'Scheduled & one-click agent tasks',
        Icons.schedule_rounded,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const AutomationsPage()),
          );
        },
      ),
      (
        'Customizations (Rules, AGENTS.md, SKILL.md, MCP)',
        'Edit GEMINI.md, AGENTS.md, SKILL.md & MCP servers',
        Icons.extension_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const CustomizationsPage()),
          );
        },
      ),
      (
        'SSH Remote Workstations',
        'Connect to Linux/macOS/Windows over SSH',
        Icons.dns_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SshHostsPage()),
          );
        },
      ),
      (
        'Phone Control & SafetyGate',
        'Configure Android Accessibility automation',
        Icons.touch_app_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const PhoneControlPage()),
          );
        },
      ),
      (
        'Search All Conversations',
        'Full-text search across every chat transcript and folder',
        Icons.manage_search,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SessionSearchPage()),
          );
        },
      ),
      (
        'Replay & Export Active Chat',
        'Step-by-step playback, Markdown/JSON export & Android share',
        Icons.play_circle_outline,
        () {
          final active = ref.read(sessionsProvider).activeSession;
          Navigator.of(context).pop();
          if (active != null) {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ConversationReplayPage(session: active),
              ),
            );
          }
        },
      ),
      (
        'Background Keep-Alive Guide',
        'Check battery optimization & OEM background settings',
        Icons.battery_saver_rounded,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const BackgroundGuidePage(),
            ),
          );
        },
      ),
      (
        'Diagnostics Bundle Export',
        'Build & export redacted device/runtime report',
        Icons.bug_report_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const DiagnosticsPage()),
          );
        },
      ),
      (
        'Settings',
        'Permissions, presets, themes & updates',
        Icons.settings_outlined,
        () {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
          );
        },
      ),
    ];

    final matchedActions = actions
        .where(
          (a) =>
              q.isEmpty ||
              a.$1.toLowerCase().contains(q) ||
              a.$2.toLowerCase().contains(q),
        )
        .toList();

    final matchedProjects = projects
        .where((p) => q.isEmpty || p.name.toLowerCase().contains(q))
        .toList();

    final matchedSessions = sessions
        .where(
          (s) =>
              q.isEmpty ||
              s.title.toLowerCase().contains(q) ||
              (s.lastPreview?.toLowerCase().contains(q) ?? false),
        )
        .take(8)
        .toList();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 540),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Search conversations, projects, or commands…',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                children: [
                  for (final a in matchedActions)
                    ListTile(
                      dense: true,
                      leading: Icon(a.$3, size: 18),
                      title: Text(a.$1),
                      subtitle: Text(a.$2),
                      onTap: a.$4,
                    ),
                  if (matchedProjects.isNotEmpty) ...[
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Text(
                        'Projects',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    for (final p in matchedProjects)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.workspaces_outline, size: 18),
                        title: Text(p.name),
                        subtitle: Text(
                          p.primaryFolder.isEmpty
                              ? 'App Workspace'
                              : p.primaryFolder,
                        ),
                        onTap: () {
                          ref
                              .read(projectsProvider.notifier)
                              .selectProject(p.id);
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                  if (matchedSessions.isNotEmpty) ...[
                    const Divider(),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 6, 16, 4),
                      child: Text(
                        'Conversations',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    for (final s in matchedSessions)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.chat_bubble_outline, size: 18),
                        title: Text(s.title),
                        subtitle: Text(s.lastPreview ?? s.modelId),
                        onTap: () {
                          ref
                              .read(sessionsProvider.notifier)
                              .selectSession(s.id);
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
