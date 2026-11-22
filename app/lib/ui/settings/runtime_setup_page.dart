import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_models.dart';
import '../../state/runtime_state.dart';

class RuntimeSetupPage extends ConsumerWidget {
  const RuntimeSetupPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runtime = ref.watch(runtimeProvider);
    final status = runtime.status;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('On-Device Antigravity Runtime'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.read(runtimeProvider.notifier).refresh(),
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
                        status.phase == RuntimePhase.running
                            ? Icons.check_circle
                            : status.phase == RuntimePhase.error
                                ? Icons.error_outline
                                : Icons.memory,
                        color: status.phase == RuntimePhase.running
                            ? Colors.green
                            : theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Status: ${status.phase.name.toUpperCase()}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (status.agyVersion != null)
                        Chip(label: Text('agy ${status.agyVersion}')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(status.statusMessage),
                  if (status.phase == RuntimePhase.installing) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: status.installProgress),
                  ],
                  if (status.errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      status.errorMessage!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                  if (status.binaryPath != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Binary: ${status.binaryPath}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (status.workspaceRoot != null) ...[
                    Text(
                      'Workspace: ${status.workspaceRoot}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: runtime.busy
                            ? null
                            : () => ref
                                .read(runtimeProvider.notifier)
                                .installAndStart(),
                        icon: const Icon(Icons.download),
                        label: Text(
                          status.isReady ? 'Reinstall / Start' : 'Install & Start',
                        ),
                      ),
                      if (status.phase == RuntimePhase.running)
                        OutlinedButton.icon(
                          onPressed: runtime.busy
                              ? null
                              : () => ref.read(runtimeProvider.notifier).stop(),
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop Service'),
                        )
                      else if (status.isReady)
                        OutlinedButton.icon(
                          onPressed: runtime.busy
                              ? null
                              : () =>
                                  ref.read(runtimeProvider.notifier).start(),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Start Service'),
                        ),
                      TextButton.icon(
                        onPressed: runtime.busy
                            ? null
                            : () => ref.read(runtimeProvider.notifier).reset(),
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset Runtime'),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Safe Mode'),
                    subtitle: const Text(
                      'Starts agy without plugins, MCP servers, or phone control',
                    ),
                    value: status.safeMode,
                    onChanged: (v) =>
                        ref.read(runtimeProvider.notifier).setSafeMode(v),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Runtime Logs',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              runtime.logs.isEmpty
                  ? 'No runtime logs yet.'
                  : runtime.logs.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}
