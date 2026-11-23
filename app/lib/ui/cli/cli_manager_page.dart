import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/settings_state.dart';
import '../../theme/app_theme.dart';

/// Full Antigravity CLI (`agy`) subcommands & startup flags manager,
/// implementing all commands documented at antigravity.google/docs/cli/reference.
class CliManagerPage extends ConsumerStatefulWidget {
  const CliManagerPage({super.key, this.initialSubcommand});

  final String? initialSubcommand;

  @override
  ConsumerState<CliManagerPage> createState() => _CliManagerPageState();
}

class _CliManagerPageState extends ConsumerState<CliManagerPage> {
  bool _running = false;
  String _lastCommand = '';
  String _output = '';

  @override
  void initState() {
    super.initState();
    if (widget.initialSubcommand != null) {
      final spec = AgyCliCatalog.subcommands.where(
        (s) => s.name == widget.initialSubcommand,
      );
      if (spec.isNotEmpty) {
        Future.microtask(() => _runAgy(spec.first.defaultArgs));
      }
    }
  }

  Future<void> _runAgy(List<String> args, {int timeout = 30}) async {
    setState(() {
      _running = true;
      _lastCommand = 'agy ${args.join(' ')}';
    });
    try {
      final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
      final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      final cwd = projDir.isNotEmpty ? projDir : fallback;
      final out = await RuntimeBridge.instance.runCommandCapture(
        args: args,
        cwd: cwd,
        timeoutSeconds: timeout,
      );
      if (!mounted) return;
      setState(() {
        _output = out.trim().isEmpty ? '(completed with no output)' : out.trim();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _output = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _promptAndRun(
    String title,
    String hint,
    List<String> Function(String value) buildArgs,
  ) async {
    final ctrl = TextEditingController();
    final val = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Run'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (val == null || val.isEmpty) return;
    await _runAgy(buildArgs(val));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Antigravity CLI & Flags'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CLI Subcommands (`agy <cmd>`)',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final sub in AgyCliCatalog.subcommands)
                        ActionChip(
                          avatar: const Icon(Icons.terminal, size: 16),
                          label: Text('agy ${sub.name}'),
                          tooltip: sub.summary,
                          onPressed: _running
                              ? null
                              : () => _runAgy(sub.defaultArgs),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _promptAndRun(
                                  'Add MCP Server',
                                  'name command-or-url (e.g. fs npx -y ...)',
                                  (v) => ['mcp', 'add', ...v.split(RegExp(r'\s+'))],
                                ),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('mcp add'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _promptAndRun(
                                  'Install Plugin',
                                  'plugin name or path',
                                  (v) => ['plugin', 'install', v],
                                ),
                        icon: const Icon(Icons.extension_outlined, size: 16),
                        label: const Text('plugin install'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _runAgy(['remote-control', 'start']),
                        icon: const Icon(Icons.cast_connected, size: 16),
                        label: const Text('remote-control start'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _running
                            ? null
                            : () => _runAgy(['remote-control', 'stop']),
                        icon: const Icon(Icons.cast, size: 16),
                        label: const Text('remote-control stop'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_running || _output.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _lastCommand,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (_running)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: SelectableText(
                        _output,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Turn CLI Flags',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Passed automatically to `agy` turns when configured.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: semantic.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: settings.activeAgent,
                    decoration: const InputDecoration(
                      labelText: '--agent (named agent preset)',
                      hintText: 'Leave empty for default',
                    ),
                    onChanged: notifier.setActiveAgent,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: settings.remoteAgent,
                    decoration: const InputDecoration(
                      labelText: '--remote-agent (target remote agent ID)',
                      hintText: 'Optional',
                    ),
                    onChanged: notifier.setRemoteAgent,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    initialValue: settings.printTimeoutSeconds > 0
                        ? settings.printTimeoutSeconds.toString()
                        : '',
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '--print-timeout (seconds)',
                      hintText: '0 or blank for CLI default',
                    ),
                    onChanged: (v) => notifier.setPrintTimeoutSeconds(
                      int.tryParse(v.trim()) ?? 0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('--continue'),
                    subtitle: const Text(
                      'Continue most recent workspace conversation',
                    ),
                    value: settings.continueLast,
                    onChanged: notifier.setContinueLast,
                  ),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('--disable-slash-commands'),
                    subtitle: const Text(
                      'Treat leading / prompts as plain literal text',
                    ),
                    value: settings.disableSlashCommands,
                    onChanged: notifier.setDisableSlashCommands,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
