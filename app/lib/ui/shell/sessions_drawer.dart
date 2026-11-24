import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_state.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/sessions_state.dart';
import '../auth/google_login_sheet.dart';
import '../automations/automations_page.dart';
import '../customizations/customizations_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../replay/conversation_replay_page.dart';
import '../settings/settings_page.dart';
import '../usage/usage_page.dart';
import 'command_palette.dart';
import 'session_search_page.dart';

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
  String _folderFilter = '';

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sessionsProvider);
    final bgSessionIds = ref.watch(
      chatProvider.select((c) => c.activeBackgroundSessionIds),
    );
    final activeSubagentCount = ref.watch(
      chatProvider.select(
        (c) => c.activeSubagents.where((a) => a.isActive).length,
      ),
    );
    final archivedCount = sessions.sessions.where((s) => s.archived).length;
    final hosts = ref.watch(hostsProvider);
    final projects = ref.watch(projectsProvider);
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);

    final folders = sessions.sessions
        .where((s) => !s.archived)
        .map((s) => s.folder.trim())
        .where((f) => f.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final filtered = sessions.sessions.where((s) {
      if (_folderFilter == '__archived__') {
        if (!s.archived) return false;
      } else {
        if (s.archived) return false;
        if (_folderFilter == '__pinned__' && !s.pinned) return false;
        if (_folderFilter.isNotEmpty &&
            _folderFilter != '__pinned__' &&
            s.folder != _folderFilter) {
          return false;
        }
      }
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return s.title.toLowerCase().contains(q) ||
          s.folder.toLowerCase().contains(q) ||
          (s.lastPreview?.toLowerCase().contains(q) ?? false);
    }).toList();

    final activeProject = projects.projects.firstWhere(
      (p) => p.id == projects.activeProjectId,
      orElse: () => projects.projects.first,
    );
    final activeHostLabel = hosts.activeHostId == 'local'
        ? 'On Device'
        : hosts.sshHosts
                .where((h) => h.id == hosts.activeHostId)
                .map((h) => 'SSH · ${h.name}')
                .firstOrNull ??
            'On Device';

    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final topControls = <Widget>[
            // Compact Header Row
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Antigravity Go',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Command Palette (Ctrl+K)',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => CommandPaletteDialog.show(context),
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    tooltip: 'Search all chat messages',
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SessionSearchPage(),
                      ),
                    ),
                    icon: const Icon(Icons.manage_search),
                  ),
                  const SizedBox(width: 2),
                  FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () async {
                      await ref.read(sessionsProvider.notifier).createSession();
                      widget.onClose?.call();
                    },
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('New', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

            // Side-by-side compact Project & Execution Host pills
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _CompactPickerPill(
                      icon: Icons.folder_outlined,
                      label: activeProject.name,
                      tooltip: 'Switch project',
                      itemBuilder: (_) => [
                        for (final p in projects.projects)
                          PopupMenuItem(
                            value: p.id,
                            child: Text(
                              p.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: '__new_project__',
                          child: Row(
                            children: [
                              Icon(Icons.create_new_folder_outlined, size: 16),
                              SizedBox(width: 8),
                              Text('New Project…'),
                            ],
                          ),
                        ),
                      ],
                      onSelected: (v) {
                        if (v == '__new_project__') {
                          _createProjectDialog(context);
                        } else {
                          ref.read(projectsProvider.notifier).selectProject(v);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _CompactPickerPill(
                      icon: hosts.activeHostId == 'local'
                          ? Icons.smartphone_outlined
                          : Icons.dns_outlined,
                      label: activeHostLabel,
                      tooltip: 'Switch execution host',
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'local',
                          child: Text('On Device (Android)'),
                        ),
                        for (final h in hosts.sshHosts)
                          PopupMenuItem(
                            value: h.id,
                            child: Text(
                              'SSH · ${h.name}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: '__manage_ssh__',
                          child: Row(
                            children: [
                              Icon(Icons.dns_outlined, size: 16),
                              SizedBox(width: 8),
                              Text('Manage SSH Hosts…'),
                            ],
                          ),
                        ),
                      ],
                      onSelected: (v) {
                        if (v == '__manage_ssh__') {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const SshHostsPage(),
                            ),
                          );
                        } else {
                          ref.read(hostsProvider.notifier).selectHost(v);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Slim Conversation Filter Input
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
              child: TextField(
                style: const TextStyle(fontSize: 12.5),
                onChanged: (v) => setState(() => _query = v),
                decoration: InputDecoration(
                  hintText: 'Filter chats…',
                  hintStyle: const TextStyle(fontSize: 12),
                  prefixIcon: const Icon(Icons.filter_list, size: 16),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 30,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 7,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),

            if (folders.isNotEmpty ||
                sessions.sessions.any((s) => s.pinned) ||
                archivedCount > 0)
              SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  children: [
                    _CompactFilterChip(
                      label: 'All',
                      selected: _folderFilter.isEmpty,
                      onTap: () => setState(() => _folderFilter = ''),
                    ),
                    if (sessions.sessions.any((s) => s.pinned))
                      _CompactFilterChip(
                        label: 'Pinned',
                        selected: _folderFilter == '__pinned__',
                        onTap: () => setState(
                          () => _folderFilter =
                              _folderFilter == '__pinned__' ? '' : '__pinned__',
                        ),
                      ),
                    for (final f in folders)
                      _CompactFilterChip(
                        label: f,
                        selected: _folderFilter == f,
                        onTap: () => setState(
                          () => _folderFilter = _folderFilter == f ? '' : f,
                        ),
                      ),
                    if (archivedCount > 0)
                      _CompactFilterChip(
                        label: 'Archived ($archivedCount)',
                        selected: _folderFilter == '__archived__',
                        onTap: () => setState(
                          () => _folderFilter =
                              _folderFilter == '__archived__'
                                  ? ''
                                  : '__archived__',
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(height: 8),
          ];

          final bottomNav = <Widget>[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
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
                    badge: 'Rules · MCP',
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
                        MaterialPageRoute<void>(
                          builder: (_) => const UsagePage(),
                        ),
                      );
                    },
                  ),
                  _SidebarNavTile(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    onTap: () {
                      widget.onClose?.call();
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const SettingsPage(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            InkWell(
              onTap: () => GoogleLoginSheet.show(context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
                child: Row(
                  children: [
                    Icon(
                      auth.isAuthenticated
                          ? Icons.verified_user
                          : Icons.account_circle_outlined,
                      size: 16,
                      color: auth.isAuthenticated
                          ? Colors.green
                          : theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            auth.isAuthenticated
                                ? (auth.email ??
                                    auth.displayName ??
                                    'Signed in')
                                : 'Sign in with Google',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            auth.isAuthenticated
                                ? (auth.savedAccounts.length > 1
                                    ? '${auth.planTier.label} · ${auth.savedAccounts.length} accounts'
                                    : auth.planTier.label)
                                : (auth.savedAccounts.isNotEmpty
                                    ? '${auth.savedAccounts.length} saved account(s)'
                                    : 'Connect Google Account'),
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
                    const Icon(Icons.chevron_right, size: 16),
                  ],
                ),
              ),
            ),
          ];

          Widget buildSessionTile(AgySessionSummary s) {
            final active = s.id == sessions.activeSessionId;
            final isRunning = bgSessionIds.contains(s.id);
            final subCount = active ? activeSubagentCount : 0;
            final triageLabel = s.archived
                ? 'Archived'
                : isRunning
                    ? (subCount > 0 ? 'Running · $subCount sub' : 'Running')
                    : null;
            final menuItems = [
              PopupMenuItem(
                value: 'pin',
                child: Text(s.pinned ? 'Unpin' : 'Pin'),
              ),
              const PopupMenuItem(value: 'folder', child: Text('Folder')),
              PopupMenuItem(
                value: 'archive',
                child: Text(s.archived ? 'Restore' : 'Archive'),
              ),
              const PopupMenuItem(
                value: 'replay',
                child: Text('Replay & Export'),
              ),
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ];
            return _CompactSessionRow(
              session: s,
              active: active,
              isRunning: isRunning,
              triageLabel: triageLabel,
              menuItems: menuItems,
              onSelect: () {
                ref.read(sessionsProvider.notifier).selectSession(s.id);
                widget.onClose?.call();
              },
              onAction: (action) => _handleSessionAction(context, s, action),
            );
          }

          if (constraints.maxHeight < 480) {
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
                    padding: const EdgeInsets.symmetric(vertical: 2),
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

  Future<void> _handleSessionAction(
    BuildContext context,
    AgySessionSummary s,
    String action,
  ) async {
    if (action == 'pin') {
      await ref.read(sessionsProvider.notifier).togglePinSession(s.id);
    } else if (action == 'folder') {
      await _promptFolder(context, s);
    } else if (action == 'archive') {
      await ref
          .read(sessionsProvider.notifier)
          .archiveSession(s.id, archived: !s.archived);
    } else if (action == 'replay') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationReplayPage(session: s),
        ),
      );
    } else if (action == 'delete') {
      await ref.read(sessionsProvider.notifier).deleteSession(s.id);
    } else if (action == 'rename') {
      await _promptRename(context, s);
    }
  }

  Future<void> _promptFolder(
    BuildContext context,
    AgySessionSummary session,
  ) async {
    final ctrl = TextEditingController(text: session.folder);
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Assign Session Folder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name (leave blank to clear)',
            hintText: 'e.g. Work, Bugfixes, Research',
          ),
        ),
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
    if (updated != null) {
      await ref
          .read(sessionsProvider.notifier)
          .setSessionFolder(session.id, updated);
    }
  }
}

class _CompactPickerPill extends StatelessWidget {
  const _CompactPickerPill({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.itemBuilder,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final PopupMenuItemBuilder<String> itemBuilder;
  final PopupMenuItemSelected<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      tooltip: tooltip,
      itemBuilder: itemBuilder,
      onSelected: onSelected,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.55),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.45),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 13.5, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactFilterChip extends StatelessWidget {
  const _CompactFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSessionRow extends StatelessWidget {
  const _CompactSessionRow({
    required this.session,
    required this.active,
    required this.isRunning,
    required this.triageLabel,
    required this.menuItems,
    required this.onSelect,
    required this.onAction,
  });

  final AgySessionSummary session;
  final bool active;
  final bool isRunning;
  final String? triageLabel;
  final List<PopupMenuEntry<String>> menuItems;
  final VoidCallback onSelect;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (session.folder.isNotEmpty) '[${session.folder}]',
      session.hostName,
      session.modelId,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: GestureDetector(
        onSecondaryTapUp: (details) async {
          final action = await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(
              details.globalPosition.dx,
              details.globalPosition.dy,
              details.globalPosition.dx,
              details.globalPosition.dy,
            ),
            items: menuItems,
          );
          if (action != null && context.mounted) {
            onAction(action);
          }
        },
        child: Material(
          color: active
              ? theme.colorScheme.secondaryContainer.withOpacity(0.65)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onSelect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    child: Center(
                      child: isRunning
                          ? SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.8,
                                color: theme.colorScheme.primary,
                              ),
                            )
                          : Icon(
                              session.archived
                                  ? Icons.inventory_2_outlined
                                  : session.pinned
                                      ? Icons.push_pin
                                      : (session.hostKind == AgyHostKind.ssh
                                          ? Icons.computer
                                          : Icons.chat_bubble_outline),
                              size: 14,
                              color: active
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          session.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.8,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500,
                            color: active
                                ? theme.colorScheme.onSecondaryContainer
                                : theme.colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            if (triageLabel != null) ...[
                              Container(
                                margin: const EdgeInsets.only(right: 5),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 0.5,
                                ),
                                decoration: BoxDecoration(
                                  color: isRunning
                                      ? theme.colorScheme.primaryContainer
                                      : theme
                                          .colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  triageLabel!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: isRunning
                                        ? theme.colorScheme.onPrimaryContainer
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                            Expanded(
                              child: Text(
                                meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10.5,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      icon: Icon(
                        Icons.more_horiz,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onSelected: onAction,
                      itemBuilder: (_) => menuItems,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarNavTile extends StatelessWidget {
  const _SidebarNavTile({
    required this.icon,
    required this.title,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (badge != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  badge!,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
