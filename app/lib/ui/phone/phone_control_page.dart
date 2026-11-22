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
