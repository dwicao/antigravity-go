import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../phone/phone_bridge.dart';
import '../../state/phone_state.dart';

class PhoneControlPage extends ConsumerStatefulWidget {
  const PhoneControlPage({super.key});

  @override
  ConsumerState<PhoneControlPage> createState() => _PhoneControlPageState();
}

class _PhoneControlPageState extends ConsumerState<PhoneControlPage> {
  String? _screenDump;
  String? _gatewayOutput;

  @override
  Widget build(BuildContext context) {
    final phone = ref.watch(phoneProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Phone Control & SafetyGate'),
        actions: [
          IconButton(
            tooltip: 'Refresh status',
            onPressed: () => ref.read(phoneProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        phone.status.accessibilityConnected
                            ? Icons.accessibility_new
                            : Icons.warning_amber_rounded,
                        color: phone.status.accessibilityConnected
                            ? Colors.green
                            : Colors.amber,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          phone.status.accessibilityConnected
                              ? 'Accessibility Service Connected'
                              : 'Accessibility Service Disabled',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => ref
                            .read(phoneProvider.notifier)
                            .openAccessibilitySettings(),
                        child: const Text('Android Settings'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable AI Phone Control'),
                    subtitle: Text(
                      phone.status.mcpPort != null
                          ? 'Local Phone MCP listening on 127.0.0.1:${phone.status.mcpPort}'
                          : 'Allows Antigravity agents to read screen UI and tap/type',
                    ),
                    value: phone.status.enabled,
                    onChanged: (v) =>
                        ref.read(phoneProvider.notifier).setEnabled(v),
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Strict SafetyGate Protection'),
                    subtitle: const Text(
                      'Blocks banking, payment, password managers, and system security screens by default',
                    ),
                    value: phone.status.safetyGateStrict,
                    onChanged: (v) =>
                        ref.read(phoneProvider.notifier).setSafetyStrict(v),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: phone.status.accessibilityConnected
                        ? () async {
                            final dump =
                                await PhoneBridge.instance.dumpScreenTree();
                            setState(() => _screenDump = dump);
                          }
                        : null,
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('Test Screen Tree Inspection'),
                  ),
                ],
              ),
            ),
          ),
          if (_screenDump != null && _screenDump!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _screenDump!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.devices_other_rounded, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Device Gateway & Hardware Tools',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          phone.status.shizukuAvailable
                              ? 'Shizuku rish ready'
                              : 'Standard user',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Exposes 11 MCP tools to Antigravity agents: screen, tap, type, telemetry, notify, clipboard, flashlight torch, vibrate, toast, browser URL, and Shizuku rish.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (phone.deviceInfo.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (phone.deviceInfo['battery'] != null)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              'Battery ${phone.deviceInfo['battery']}%${phone.deviceInfo['charging'] == true ? ' (charging)' : ''}',
                            ),
                          ),
                        if (phone.deviceInfo['network'] != null)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('Net: ${phone.deviceInfo['network']}'),
                          ),
                        if (phone.deviceInfo['storageFreeMb'] != null)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              'Free: ${phone.deviceInfo['storageFreeMb']} MB',
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () =>
                            ref.read(phoneProvider.notifier).toggleTorch(),
                        icon: Icon(
                          phone.torchOn
                              ? Icons.flashlight_on_rounded
                              : Icons.flashlight_off_rounded,
                          size: 16,
                        ),
                        label: Text(phone.torchOn ? 'Torch Off' : 'Torch On'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => PhoneBridge.instance.vibrate(durationMs: 70),
                        icon: const Icon(Icons.vibration, size: 16),
                        label: const Text('Vibrate'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => PhoneBridge.instance.postNotification(
                          title: 'Antigravity Go',
                          message: 'Phone Gateway notification check succeeded.',
                        ),
                        icon: const Icon(Icons.notifications_active_outlined, size: 16),
                        label: const Text('Test Notify'),
                      ),
                      if (phone.status.shizukuAvailable)
                        OutlinedButton.icon(
                          onPressed: () async {
                            final res = await PhoneBridge.instance.shizukuExec('id');
                            if (mounted) {
                              setState(
                                () => _gatewayOutput =
                                    res['output']?.toString() ?? res.toString(),
                              );
                            }
                          },
                          icon: const Icon(Icons.admin_panel_settings_outlined, size: 16),
                          label: const Text('Shizuku id'),
                        ),
                    ],
                  ),
                  if (_gatewayOutput != null && _gatewayOutput!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SelectableText(
                      _gatewayOutput!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Self-Check Diagnostics Card (adopted from DSH Go)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Phone Control Self-Check',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            ref.read(phoneProvider.notifier).runSelfCheck(),
                        icon: const Icon(Icons.fact_check_outlined, size: 16),
                        label: const Text('Run Self-Check'),
                      ),
                    ],
                  ),
                  if (phone.selfCheck != null) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _CheckPill(
                          label: 'Accessibility',
                          ok: phone.selfCheck!.accessibilityConnected,
                        ),
                        _CheckPill(
                          label: 'Notifications',
                          ok: phone.selfCheck!.notificationsGranted,
                        ),
                        _CheckPill(
                          label: 'All Files Storage',
                          ok: phone.selfCheck!.storageGranted,
                        ),
                        _CheckPill(
                          label: 'Battery Unrestricted',
                          ok: phone.selfCheck!.batteryOptimizationIgnored,
                        ),
                        _CheckPill(
                          label: 'Shizuku rish',
                          ok: phone.selfCheck!.shizukuAvailable,
                        ),
                        _CheckPill(
                          label: phone.selfCheck!.mcpPort != null
                              ? 'MCP :${phone.selfCheck!.mcpPort}'
                              : 'MCP Loopback',
                          ok: phone.selfCheck!.mcpRunning,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Per-App SafetyGate Rules Card (adopted from DSH Go)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Per-App Rules',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showAddRuleDialog(context),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Rule'),
                      ),
                    ],
                  ),
                  Text(
                    'Override SafetyGate per Android package (Allow, Confirm, or Block). Sensitive password fields stay protected.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (phone.appRules.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final entry in phone.appRules.entries)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(entry.key),
                        subtitle: Text('Mode: ${entry.value}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: 'Remove rule',
                          onPressed: () => ref
                              .read(phoneProvider.notifier)
                              .setAppRule(entry.key, null),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent Phone Actions',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (phone.actions.isNotEmpty)
                TextButton.icon(
                  onPressed: () =>
                      ref.read(phoneProvider.notifier).clearActionLog(),
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (phone.actions.isEmpty)
            const Card(
              child: ListTile(
                title: Text('No phone control actions recorded yet'),
              ),
            ),
          for (final a in phone.actions)
            Card(
              child: ListTile(
                leading: Icon(
                  a.allowed ? Icons.check_circle_outline : Icons.block,
                  color: a.allowed ? Colors.green : theme.colorScheme.error,
                ),
                title: Text('${a.action} · ${a.target}'),
                subtitle: Text(
                  '${a.reason} · ${a.timestamp.hour.toString().padLeft(2, '0')}:${a.timestamp.minute.toString().padLeft(2, '0')}:${a.timestamp.second.toString().padLeft(2, '0')}',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showAddRuleDialog(BuildContext context) async {
    final pkgController = TextEditingController();
    var mode = 'block';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: const Text('Add Per-App Safety Rule'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pkgController,
                decoration: const InputDecoration(
                  labelText: 'Package name or token',
                  hintText: 'e.g. com.whatsapp',
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: mode,
                decoration: const InputDecoration(labelText: 'Action policy'),
                items: const [
                  DropdownMenuItem(value: 'allow', child: Text('Allow')),
                  DropdownMenuItem(value: 'confirm', child: Text('Confirm')),
                  DropdownMenuItem(value: 'block', child: Text('Block')),
                ],
                onChanged: (v) {
                  if (v != null) setStateDialog(() => mode = v);
                },
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
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    final pkg = pkgController.text.trim();
    pkgController.dispose();
    if (saved == true && pkg.isNotEmpty && context.mounted) {
      await ref.read(phoneProvider.notifier).setAppRule(pkg, mode);
    }
  }
}

class _CheckPill extends StatelessWidget {
  const _CheckPill({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        size: 16,
        color: ok ? Colors.green : theme.colorScheme.error,
      ),
      label: Text(label),
    );
  }
}
