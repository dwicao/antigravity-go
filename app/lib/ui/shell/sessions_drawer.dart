import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_state.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/sessions_state.dart';
import '../auth/google_login_sheet.dart';
import '../automations/automations_page.dart';
import '../customizations/customizations_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../settings/settings_page.dart';
import '../usage/usage_page.dart';
import 'command_palette.dart';

/// 1:1 Antigravity Desktop Left Sidebar:
/// - Google Account profile pill + Command Palette (Ctrl+K)
/// - Projects switcher (+ New Project / SSH Host…)
/// - Conversations list
/// - Automations, Customizations, Usage Limits, Settings
class SessionsDrawer extends ConsumerStatefulWidget {
  const SessionsDrawer({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  ConsumerState<SessionsDrawer> createState() => _SessionsDrawerState();
}

class _SessionsDrawerState extends ConsumerState<SessionsDrawer> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final hosts = ref.watch(hostsProvider);
    final projects = ref.watch(projectsProvider);
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);

    final filtered = sessions.sessions.where((s) {
      if (_query.isEmpty) return true;
      return s.title.toLowerCase().contains(_query.toLowerCase()) ||
          (s.lastPreview?.toLowerCase().contains(_query.toLowerCase()) ?? false);
    }).toList();

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final topControls = <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Antigravity Go',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Search & Command Palette (Ctrl+K)',
                    iconSize: 18,
                    onPressed: () => CommandPaletteDialog.show(context),
                    icon: const Icon(Icons.search),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await ref.read(sessionsProvider.notifier).createSession();
                      widget.onClose?.call();
                    },
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New'),
                  ),
                ],
              ),
            ),

            // Google Account card
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => GoogleLoginSheet.show(context),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withOpacity(0.5),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        auth.isAuthenticated
                            ? Icons.verified_user
                            : Icons.account_circle_outlined,
                        color: auth.isAuthenticated
                            ? Colors.green
                            : theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              auth.isAuthenticated
                                  ? (auth.email ??
                                      auth.displayName ??
                                      'Signed in')
                                  : 'Sign in with Google',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              auth.isAuthenticated
                                  ? auth.planTier.label
                                  : 'Tap to connect Google Account',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                ),
              ),
            ),

            // Projects Selector + New Project / SSH Host
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: projects.projects
                              .any((p) => p.id == projects.activeProjectId)
                          ? projects.activeProjectId
                          : projects.projects.first.id,
                      isDense: true,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Project',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      items: projects.projects
                          .map(
                            (p) => DropdownMenuItem(
                              value: p.id,
                              child: Text(
                                p.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          ref.read(projectsProvider.notifier).selectProject(v);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'New Project',
                    iconSize: 18,
                    onPressed: () => _createProjectDialog(context),
                    icon: const Icon(Icons.create_new_folder_outlined),
                  ),
                ],
              ),
            ),

            // Host Switcher (On-Device vs SSH Workstation)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: hosts.activeHostId,
                      isDense: true,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Execution Host',
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'local',
                          child: Text(
                            'On Device (Android)',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        for (final h in hosts.sshHosts)
                          DropdownMenuItem(
                            value: h.id,
                            child: Text(
                              'SSH · ${h.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          ref.read(hostsProvider.notifier).selectHost(v);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'SSH Hosts',
                    iconSize: 18,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SshHostsPage(),
                      ),
                    ),
                    icon: const Icon(Icons.dns_outlined),
                  ),
                ],
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  hintText: 'Filter conversations…',
                  prefixIcon: Icon(Icons.filter_list, size: 18),
                  isDense: true,
                ),
              ),
            ),
            const Divider(height: 10),
          ];

          final bottomNav = <Widget>[
            const Divider(height: 1),
            _SidebarNavTile(
              icon: Icons.schedule_rounded,
              title: 'Automations',
              onTap: () {
                widget.onClose?.call();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AutomationsPage(),
                  ),
                );
              },
            ),
            _SidebarNavTile(
              icon: Icons.extension_outlined,
              title: 'Customizations',
              subtitle: 'Rules · Skills · MCP',
              onTap: () {
                widget.onClose?.call();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CustomizationsPage(),
                  ),
                );
              },
            ),
            _SidebarNavTile(
              icon: Icons.speed_rounded,
              title: 'Usage Limits',
              onTap: () {
                widget.onClose?.call();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const UsagePage()),
                );
              },
            ),
            _SidebarNavTile(
              icon: Icons.settings_outlined,
              title: 'Settings',
              onTap: () {
                widget.onClose?.call();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                );
              },
            ),
          ];

          Widget buildSessionTile(AgySessionSummary s) {
            final active = s.id == sessions.activeSessionId;
            return GestureDetector(
              onSecondaryTapUp: (details) async {
                final action = await showMenu<String>(
                  context: context,
                  position: RelativeRect.fromLTRB(
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                    details.globalPosition.dx,
                    details.globalPosition.dy,
                  ),
                  items: const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                );
                if (action == 'delete') {
                  await ref
                      .read(sessionsProvider.notifier)
                      .deleteSession(s.id);
                } else if (action == 'rename' && context.mounted) {
                  await _promptRename(context, s);
                }
              },
              child: ListTile(
                dense: true,
                selected: active,
                leading: Icon(
                  s.hostKind == AgyHostKind.ssh
                      ? Icons.computer
                      : Icons.chat_bubble_outline,
                  size: 16,
                ),
                title: Text(
                  s.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${s.hostName} · ${s.modelId}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: PopupMenuButton<String>(
                  iconSize: 16,
                  onSelected: (action) async {
                    if (action == 'delete') {
                      await ref
                          .read(sessionsProvider.notifier)
                          .deleteSession(s.id);
                    } else if (action == 'rename') {
                      await _promptRename(context, s);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () {
                  ref.read(sessionsProvider.notifier).selectSession(s.id);
                  widget.onClose?.call();
                },
              ),
            );
          }

          // When vertical space is constrained (e.g. 600px landscape or DeX
          // split window), allow the entire sidebar to scroll cleanly instead of
          // overflowing the fixed chrome sections.
          if (constraints.maxHeight < 680) {
            return Scrollbar(
              child: ListView(
                children: [
                  ...topControls,
                  for (final s in filtered) buildSessionTile(s),
                  ...bottomNav,
                ],
              ),
            );
          }

          return Column(
            children: [
              ...topControls,
              Expanded(
                child: Scrollbar(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) =>
                        buildSessionTile(filtered[index]),
                  ),
                ),
              ),
              ...bottomNav,
            ],
          );
        },
      ),
    );
  }

  Future<void> _createProjectDialog(BuildContext context) async {
    final extRoot = ref.read(permissionsProvider).externalStorageRoot;
    final nameCtrl = TextEditingController();
    final folderCtrl = TextEditingController(text: '$extRoot/Download/Projects');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Project'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Project Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: folderCtrl,
              decoration: const InputDecoration(
                labelText: 'Folder Path',
                hintText: '/storage/emulated/0/Download/Projects',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      await ref.read(projectsProvider.notifier).addProject(
            name: nameCtrl.text,
            folders: [folderCtrl.text.trim()],
          );
    }
    nameCtrl.dispose();
    folderCtrl.dispose();
  }

  Future<void> _promptRename(
    BuildContext context,
    AgySessionSummary session,
  ) async {
    final ctrl = TextEditingController(text: session.title);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Session'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (updated != null && updated.trim().isNotEmpty) {
      await ref
          .read(sessionsProvider.notifier)
          .renameSession(session.id, updated);
    }
  }
}

class _SidebarNavTile extends StatelessWidget {
  const _SidebarNavTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      leading: Icon(icon, size: 18),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      onTap: onTap,
    );
  }
}
