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
          Text(
            'Recent Phone Actions',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
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
                subtitle: Text(a.reason),
              ),
            ),
        ],
      ),
    );
  }
}
