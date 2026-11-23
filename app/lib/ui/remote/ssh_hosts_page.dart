import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../remote/ssh_agy_runner.dart';
import '../../remote/ssh_host.dart';
import '../../state/hosts_state.dart';

class SshHostsPage extends ConsumerWidget {
  const SshHostsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hosts = ref.watch(hostsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH Remote Workstations'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add SSH Host'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.smartphone),
              title: const Text('On Device (Android)'),
              subtitle: const Text('Local Antigravity CLI runtime'),
              trailing: hosts.isLocalActive
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
              onTap: () => ref.read(hostsProvider.notifier).selectHost('local'),
            ),
          ),
          const SizedBox(height: 12),
          if (hosts.sshHosts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Add your Linux, macOS, or Windows SSH workstation to run `agy` remotely from your phone.',
                textAlign: TextAlign.center,
              ),
            ),
          for (final h in hosts.sshHosts)
            Card(
              child: ListTile(
                leading: const Icon(Icons.computer),
                title: Text(h.name),
                subtitle: Text(
                  h.hostKeyFingerprint != null && h.hostKeyFingerprint!.isNotEmpty
                      ? '${h.username}@${h.hostname}:${h.port} · ${h.defaultWorkspace}\nHost key pinned: ${h.hostKeyFingerprint}'
                      : '${h.username}@${h.hostname}:${h.port} · ${h.defaultWorkspace}',
                ),
                isThreeLine: h.hostKeyFingerprint != null &&
                    h.hostKeyFingerprint!.isNotEmpty,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hosts.activeHostId == h.id)
                      const Icon(Icons.check_circle, color: Colors.green),
                    PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'test') {
                          await _testHost(context, ref, h);
                        } else if (action == 'edit') {
                          await _openEditor(context, ref, existing: h);
                        } else if (action == 'reset_key') {
                          await ref
                              .read(hostsProvider.notifier)
                              .clearHostFingerprint(h.id);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Pinned host key cleared — next connect will trust new key.',
                                ),
                              ),
                            );
                          }
                        } else if (action == 'delete') {
                          await ref
                              .read(hostsProvider.notifier)
                              .removeHost(h.id);
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'test', child: Text('Test SSH')),
                        const PopupMenuItem(value: 'edit', child: Text('Edit')),
                        if (h.hostKeyFingerprint != null &&
                            h.hostKeyFingerprint!.isNotEmpty)
                          const PopupMenuItem(
                            value: 'reset_key',
                            child: Text('Clear Pinned Host Key'),
                          ),
                        const PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
                onTap: () => ref.read(hostsProvider.notifier).selectHost(h.id),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _testHost(
    BuildContext context,
    WidgetRef ref,
    SshHostConfig host,
  ) async {
    final (pwd, key) =
        await ref.read(hostsProvider.notifier).readCredentials(host.id);
    try {
      final result = await SshAgyRunner.instance.testConnection(
        host,
        password: pwd,
        privateKeyPem: key,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connected: $result')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SSH error: $e')),
        );
      }
    }
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref, {
    SshHostConfig? existing,
  }) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final hostCtrl = TextEditingController(text: existing?.hostname ?? '');
    final portCtrl =
        TextEditingController(text: '${existing?.port ?? 22}');
    final userCtrl = TextEditingController(text: existing?.username ?? '');
    final dirCtrl =
        TextEditingController(text: existing?.defaultWorkspace ?? '~');
    final agyCtrl = TextEditingController(text: existing?.agyBinary ?? 'agy');
    final pwdCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    var clearFingerprint = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add SSH Host' : 'Edit SSH Host'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Display Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: hostCtrl,
                  decoration: const InputDecoration(labelText: 'Hostname / IP'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(labelText: 'Username'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 84,
                      child: TextField(
                        controller: portCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Port'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: dirCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Workspace Path'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: agyCtrl,
                  decoration:
                      const InputDecoration(labelText: 'agy Binary Path'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: pwdCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password (stored in Android Keystore)',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Private Key PEM (optional)',
                  ),
                ),
                if (existing?.hostKeyFingerprint != null &&
                    existing!.hostKeyFingerprint!.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          clearFingerprint
                              ? 'Pinned host key will be cleared on save'
                              : 'Pinned key: ${existing.hostKeyFingerprint}',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                      if (!clearFingerprint)
                        TextButton(
                          onPressed: () =>
                              setDialogState(() => clearFingerprint = true),
                          child: const Text('Reset Key'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true && hostCtrl.text.trim().isNotEmpty) {
      await ref.read(hostsProvider.notifier).addOrUpdateHost(
            SshHostConfig(
              id: existing?.id ?? '',
              name: nameCtrl.text.trim().isEmpty
                  ? hostCtrl.text.trim()
                  : nameCtrl.text.trim(),
              hostname: hostCtrl.text.trim(),
              port: int.tryParse(portCtrl.text.trim()) ?? 22,
              username: userCtrl.text.trim(),
              defaultWorkspace: dirCtrl.text.trim().isEmpty
                  ? '~'
                  : dirCtrl.text.trim(),
              agyBinary: agyCtrl.text.trim().isEmpty
                  ? 'agy'
                  : agyCtrl.text.trim(),
              usePrivateKey: keyCtrl.text.trim().isNotEmpty ||
                  (existing?.usePrivateKey ?? false),
              hostKeyFingerprint:
                  clearFingerprint ? null : existing?.hostKeyFingerprint,
            ),
            password: pwdCtrl.text,
            privateKeyPem: keyCtrl.text,
          );
    }

    nameCtrl.dispose();
    hostCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
    dirCtrl.dispose();
    agyCtrl.dispose();
    pwdCtrl.dispose();
    keyCtrl.dispose();
  }
}
