import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/phone_state.dart';
import '../../state/runtime_state.dart';
import '../../state/settings_state.dart';
import '../../state/usage_state.dart';
import '../phone/phone_control_page.dart';
import '../remote/remote_web_page.dart';
import '../remote/ssh_hosts_page.dart';
import '../settings/runtime_setup_page.dart';
import '../settings/settings_page.dart';
import '../terminal/terminal_page.dart';
import '../usage/usage_page.dart';
import '../workspace/workspace_page.dart';

class QuickPanel extends ConsumerWidget {
  const QuickPanel({super.key, this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final usage = ref.watch(usageProvider);
    final runtime = ref.watch(runtimeProvider);
    final phone = ref.watch(phoneProvider);
    final theme = Theme.of(context);

    final activeModel = AgyModelCatalog.resolve(settings.selectedModelId);

    void pushPage(Widget page) {
      onClose?.call();
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => page),
      );
    }

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            'Agent Controls',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          // Compact 5h & Weekly Usage card
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => pushPage(const UsagePage()),
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.speed_rounded,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Usage Limits',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.chevron_right, size: 18),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      usage.overallFiveHourRemainingPct != null
                          ? '5h: ${usage.overallFiveHourRemainingPct!.toStringAsFixed(0)}% left · Weekly: ${(usage.overallWeeklyRemainingPct ?? 100).toStringAsFixed(0)}% left'
                          : '5h: ${usage.fiveHourLedgerTokens.totalTokens} tok · Weekly: ${usage.weeklyLedgerTokens.totalTokens} tok',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Gemini Argon · Neon/Carbon · Hydrogen · Claude & GPT',
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
          DropdownButtonFormField<String>(
            value: AgyModelCatalog.builtIn.any((m) => m.id == settings.selectedModelId)
                ? settings.selectedModelId
                : AgyModelCatalog.builtIn.first.id,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Reasoning Model'),
            items: AgyModelCatalog.builtIn
                .map(
                  (m) => DropdownMenuItem(
                    value: m.id,
                    child: Text(
                      m.displayName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) ref.read(settingsProvider.notifier).setModel(v);
            },
          ),
          const SizedBox(height: 10),
          if (activeModel.supportsEffort) ...[
            Text('Reasoning Effort', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: activeModel.availableEfforts
                  .map(
                    (e) => ButtonSegment(
                      value: e.cliValue,
                      label: Text(e.label),
                    ),
                  )
                  .toList(),
              selected: {
                activeModel.availableEfforts
                        .any((e) => e.cliValue == settings.reasoningEffort)
                    ? settings.reasoningEffort
                    : 'medium',
              },
              onSelectionChanged: (s) =>
                  ref.read(settingsProvider.notifier).setEffort(s.first),
            ),
            const SizedBox(height: 10),
          ],
          DropdownButtonFormField<String>(
            value: settings.executionMode,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Execution Mode'),
            items: AgyExecutionMode.values
                .map(
                  (m) => DropdownMenuItem(
                    value: m.cliValue,
                    child: Text('${m.label} — ${m.description}',
                        overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (v) {
              if (v != null) {
                ref.read(settingsProvider.notifier).setExecutionMode(v);
              }
            },
          ),
          const SizedBox(height: 14),
          Text(
            'Harness Tools',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            leading: const Icon(Icons.memory),
            title: const Text('On-Device Runtime'),
            subtitle: Text(runtime.status.phase.name),
            onTap: () => pushPage(const RuntimeSetupPage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.public),
            title: const Text('Remote Control Web'),
            subtitle: const Text('antigravity.google.com'),
            onTap: () => pushPage(const RemoteWebPage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.dns_outlined),
            title: const Text('SSH Workstations'),
            subtitle: const Text('Drive PC / Mac / Linux'),
            onTap: () => pushPage(const SshHostsPage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.touch_app_outlined),
            title: const Text('Phone Control'),
            subtitle: Text(
              phone.status.accessibilityConnected
                  ? 'Accessibility active'
                  : 'Accessibility off',
            ),
            onTap: () => pushPage(const PhoneControlPage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_outlined),
            title: const Text('Workspace Files'),
            onTap: () => pushPage(const WorkspacePage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.terminal),
            title: const Text('Terminal & agy TUI'),
            onTap: () => pushPage(const TerminalPage()),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.settings_outlined),
            title: const Text('Settings & Updates'),
            onTap: () => pushPage(const SettingsPage()),
          ),
        ],
      ),
    );
  }
}
