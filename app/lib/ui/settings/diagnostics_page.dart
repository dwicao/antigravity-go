import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/hosts_state.dart';
import '../../state/performance_state.dart';
import '../../state/permissions_state.dart';
import '../../state/phone_state.dart';
import '../../state/runtime_state.dart';
import '../../state/session_export_helper.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/update_state.dart';
import '../chat/secret_mask.dart';

/// Redacted diagnostics report generator & exporter adopted from DSH Go.
class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  String _report = '';
  bool _building = true;
  bool _hasCrashLog = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_buildReport);
  }

  Future<void> _buildReport() async {
    setState(() => _building = true);
    Map<String, Object?> diag = const {};
    try {
      diag = await RuntimeBridge.instance.diagnoseRuntime();
    } catch (_) {}
    await ref.read(performanceProvider.notifier).refreshSnapshot();
    if (!mounted) return;

    final perf = ref.read(performanceProvider);
    final snap = perf.snapshot;
    final runtime = ref.read(runtimeProvider);
    final perms = ref.read(permissionsProvider);
    final hosts = ref.read(hostsProvider);
    final phone = ref.read(phoneProvider);
    final settings = ref.read(settingsProvider);
    final sessions = ref.read(sessionsProvider);
    final update = ref.read(appUpdateProvider);

    final buf = StringBuffer()
      ..writeln('# Antigravity Go Diagnostics Report')
      ..writeln('- **Generated:** ${DateTime.now().toIso8601String()}')
      ..writeln('- **App Version:** v${update.currentVersion}')
      ..writeln('- **Device:** ${snap.manufacturer} ${snap.model} (SDK ${snap.sdkInt})')
      ..writeln('- **Hardware Tier:** ${snap.tier} (${snap.ramMb} MB RAM, ${snap.cpuCores} cores, max ${snap.maxRefreshHz.round()} Hz)')
      ..writeln('- **Thermal:** status=${snap.thermalStatus}, lightweight=${snap.thermalLightweight}')
      ..writeln('- **Battery Unrestricted:** ${snap.ignoringBatteryOptimizations}')
      ..writeln()
      ..writeln('## Runtime')
      ..writeln('- **Phase:** ${runtime.status.phase.name}')
      ..writeln('- **CLI Version:** ${runtime.status.agyVersion ?? "unknown"}')
      ..writeln('- **Active Host:** ${hosts.activeSshHost?.name ?? "On Device"}')
      ..writeln('- **Model:** ${settings.selectedModelId} (${settings.reasoningEffort})')
      ..writeln('- **Sessions:** ${sessions.sessions.length}')
      ..writeln()
      ..writeln('## Permissions & Phone Control')
      ..writeln('- **All Files Access:** ${perms.allFilesAccess}')
      ..writeln('- **Notifications:** ${perms.notifications}')
      ..writeln('- **Accessibility Service:** ${perms.accessibility}')
      ..writeln('- **Phone MCP Port:** ${phone.status.mcpPort ?? "stopped"} (Shizuku: ${phone.status.shizukuAvailable})');

    if (diag.isNotEmpty) {
      buf.writeln('\n## Runtime Diagnose');
      for (final e in diag.entries) {
        buf.writeln('- `${e.key}`: ${AgySecretMask.mask(e.value.toString())}');
      }
    }
    if (runtime.logs.isNotEmpty) {
      buf.writeln('\n## Recent Runtime Logs (Redacted)');
      buf.writeln('```text');
      for (final line in runtime.logs.reversed.take(40).toList().reversed) {
        buf.writeln(AgySecretMask.mask(line));
      }
      buf.writeln('```');
    }

    final crashLog = await SessionExportHelper.getRecentCrashLog();
    if (crashLog.trim().isNotEmpty) {
      buf.writeln();
      buf.writeln('## Recent Native Crash Log (Redacted)');
      buf.writeln('```');
      buf.writeln(AgySecretMask.mask(crashLog.trim()));
      buf.writeln('```');
    }

    if (!mounted) return;
    setState(() {
      _report = buf.toString();
      _hasCrashLog = crashLog.trim().isNotEmpty;
      _building = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics Bundle'),
        actions: [
          IconButton(
            tooltip: 'Refresh diagnostics',
            onPressed: _building ? null : _buildReport,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _building
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _report));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Redacted diagnostics copied'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy_all_outlined, size: 18),
                          label: const Text('Copy'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => SessionExportHelper.shareText(
                            'Antigravity Go Diagnostics',
                            _report,
                          ),
                          icon: const Icon(Icons.share_outlined, size: 18),
                          label: const Text('Share'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () async {
                            final saved =
                                await SessionExportHelper.saveTextToDownloads(
                              filename:
                                  'antigravity-diag-${DateTime.now().millisecondsSinceEpoch}.md',
                              content: _report,
                            );
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  saved != null
                                      ? 'Saved to $saved'
                                      : 'Save unavailable on this device',
                                ),
                              ),
                            );
                          },
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: const Text('Save .md'),
                        ),
                      ),
                      if (_hasCrashLog) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Clear saved crash log',
                          onPressed: () async {
                            await SessionExportHelper.clearCrashLog();
                            await _buildReport();
                          },
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      _report,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
