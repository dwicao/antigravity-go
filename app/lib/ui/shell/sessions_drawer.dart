import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../auth/google_login_sheet.dart';
import '../remote/ssh_hosts_page.dart';

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
    final auth = ref.watch(authProvider);
    final theme = Theme.of(context);

    final filtered = sessions.sessions.where((s) {
      if (_query.isEmpty) return true;
      return s.title.toLowerCase().contains(_query.toLowerCase()) ||
          (s.lastPreview?.toLowerCase().contains(_query.toLowerCase()) ?? false);
    }).toList();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
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
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await ref.read(sessionsProvider.notifier).createSession();
                    widget.onClose?.call();
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: hosts.activeHostId,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Execution Host',
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'local',
                        child: Text('On Device (Android)'),
                      ),
                      for (final h in hosts.sshHosts)
                        DropdownMenuItem(
                          value: h.id,
                          child: Text('SSH · ${h.name}'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        ref.read(hostsProvider.notifier).selectHost(v);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Manage SSH Hosts',
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: const InputDecoration(
                hintText: 'Search sessions…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
            ),
          ),
          const Divider(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final s = filtered[index];
                final active = s.id == sessions.activeSessionId;
                return ListTile(
                  selected: active,
                  leading: Icon(
                    s.hostKind == AgyHostKind.ssh
                        ? Icons.computer
                        : Icons.smartphone,
                    size: 18,
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
                );
              },
            ),
          ),
        ],
      ),
    );
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
