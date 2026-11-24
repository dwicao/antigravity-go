import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/performance_state.dart';

/// OEM Background Battery Saver & Keep-Alive Guide adopted from DSH Go.
class BackgroundGuidePage extends ConsumerWidget {
  const BackgroundGuidePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perf = ref.watch(performanceProvider);
    final snap = perf.snapshot;
    final theme = Theme.of(context);

    final oemGuides = <(String, String)>[
      (
        'Samsung (One UI / DeX)',
        'Settings -> Apps -> Antigravity Go -> Battery -> select "Unrestricted". Also disable "Put unused apps to sleep" in Device Care -> Battery -> Background usage limits.',
      ),
      (
        'Xiaomi / Redmi / POCO (HyperOS / MIUI)',
        'Long-press app icon -> App info -> Battery saver -> "No restrictions". Enable Autostart in Security -> Permissions -> Background autostart.',
      ),
      (
        'OPPO / OnePlus / Realme (ColorOS / OxygenOS)',
        'App info -> Battery usage -> enable "Allow background activity" and "Allow foreground activity". Lock the app card in Recents.',
      ),
      (
        'Huawei / Honor (EMUI / MagicOS)',
        'Settings -> Battery -> App launch -> switch Antigravity Go from Automatic to Manual and turn on Auto-launch, Secondary launch, and Run in background.',
      ),
      (
        'vivo / iQOO (OriginOS / Funtouch)',
        'Settings -> Battery -> Background power consumption management -> Antigravity Go -> "High background power usage".',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Background Keep-Alive Guide')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        snap.ignoringBatteryOptimizations
                            ? Icons.verified_user
                            : Icons.battery_alert_rounded,
                        color: snap.ignoringBatteryOptimizations
                            ? Colors.green
                            : theme.colorScheme.error,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          snap.ignoringBatteryOptimizations
                              ? 'Battery optimization is UNRESTRICTED'
                              : 'Battery optimization may pause background turns',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (snap.manufacturer.isNotEmpty || snap.model.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Device: ${snap.manufacturer} ${snap.model} · Android SDK ${snap.sdkInt}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          await ref
                              .read(performanceProvider.notifier)
                              .requestIgnoreBatteryOptimizations();
                          await ref
                              .read(performanceProvider.notifier)
                              .refreshSnapshot();
                        },
                        icon: const Icon(Icons.battery_saver_rounded, size: 18),
                        label: const Text('Allow Unrestricted Battery'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => ref
                            .read(performanceProvider.notifier)
                            .openBatterySettings(),
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        label: const Text('All Battery Settings'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final (oem, steps) in oemGuides)
            Card(
              child: ExpansionTile(
                title: Text(
                  oem,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                initiallyExpanded: snap.manufacturer.isNotEmpty &&
                    oem.toLowerCase().contains(snap.manufacturer.toLowerCase()),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text(steps),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
