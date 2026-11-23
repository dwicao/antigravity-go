import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/settings_state.dart';
import '../../theme/app_theme.dart';

/// Full Antigravity CLI (`agy`) subcommands & startup flags manager,
/// with structured cards for `agy agent`, `agy mcp list`, and `agy plugin list`
/// plus full raw subcommand execution (`remote-control`, `models`, `changelog`, `update`).
class CliManagerPage extends ConsumerStatefulWidget {
  const CliManagerPage({super.key, this.initialSubcommand});

  final String? initialSubcommand;

  @override
  ConsumerState<CliManagerPage> createState() => _CliManagerPageState();
}

class _CliManagerPageState extends ConsumerState<CliManagerPage> {
  late final TextEditingController _agentCtrl;
  bool _running = false;
  String _lastCommand = '';
  String _output = '';
  List<AgyCliManagedItem> _agents = const [];
  List<AgyCliManagedItem> _mcpServers = const [];
  List<AgyCliManagedItem> _plugins = const [];

  @override
  void initState() {
    super.initState();
    _agentCtrl = TextEditingController(
      text: ref.read(settingsProvider).activeAgent,
    );
    Future.microtask(_loadStructuredLists);
    if (widget.initialSubcommand != null) {
      final spec = AgyCliCatalog.subcommands.where(
        (s) => s.name == widget.initialSubcommand,
      );
      if (spec.isNotEmpty) {
        Future.microtask(() => _runAgy(spec.first.defaultArgs));
      }
    }
  }

  @override
  void dispose() {
    _agentCtrl.dispose();
    super.dispose();
  }

  String _activeCwd() {
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
    return projDir.isNotEmpty ? projDir : fallback;
  }

  Future<void> _loadStructuredLists() async {
    final cwd = _activeCwd();
    try {
      final agentOut = await RuntimeBridge.instance.runCommandCapture(
        args: const ['agent'],
        cwd: cwd,
        timeoutSeconds: 12,
      );
      final mcpOut = await RuntimeBridge.instance.runCommandCapture(
        args: const ['mcp', 'list'],
        cwd: cwd,
        timeoutSeconds: 12,
      );
      final pluginOut = await RuntimeBridge.instance.runCommandCapture(
        args: const ['plugin', 'list'],
        cwd: cwd,
        timeoutSeconds: 12,
      );
      if (!mounted) return;
      setState(() {
        _agents = AgyCliManagedItem.parseListOutput(agentOut);
        _mcpServers = AgyCliManagedItem.parseListOutput(mcpOut);
        _plugins = AgyCliManagedItem.parseListOutput(pluginOut);
      });
    } catch (_) {
      // Runtime may be uninstalled or running in tests.
    }
  }

  Future<void> _runAgy(
    List<String> args, {
    int timeout = 30,
    bool refreshLists = false,
  }) async {
    setState(() {
      _running = true;
      _lastCommand = 'agy ${args.join(' ')}';
    });
    try {
      final out = await RuntimeBridge.instance.runCommandCapture(
        args: args,
        cwd: _activeCwd(),
        timeoutSeconds: timeout,
      );
      if (!mounted) return;
      setState(() {
        _output = out.trim().isEmpty ? '(completed with no output)' : out.trim();
      });
      if (refreshLists) {
        await _loadStructuredLists();
      }
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
    List<String> Function(String value) buildArgs, {
    bool refreshLists = false,
  }) async {
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
    await _runAgy(buildArgs(val), refreshLists: refreshLists);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    ref.listen<String>(
      settingsProvider.select((s) => s.activeAgent),
      (prev, next) {
        if (_agentCtrl.text != next) {
          _agentCtrl.text = next;
        }
      },
    );
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Antigravity CLI & Flags'),
        actions: [
          IconButton(
            tooltip: 'Refresh agents, MCP, & plugins',
            onPressed: _running ? null : _loadStructuredLists,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_mcpServers.isNotEmpty) ...[
            _ManagedListCard(
              title: 'MCP Servers (${_mcpServers.length})',
              items: _mcpServers,
              busy: _running,
              onToggle: (item, enabled) => _runAgy(
                ['mcp', enabled ? 'enable' : 'disable', item.name],
                refreshLists: true,
              ),
              onRemove: (item) => _runAgy(
                ['mcp', 'remove', item.name],
                refreshLists: true,
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_plugins.isNotEmpty) ...[
            _ManagedListCard(
              title: 'Plugins (${_plugins.length})',
              items: _plugins,
              busy: _running,
              onToggle: (item, enabled) => _runAgy(
                ['plugin', enabled ? 'enable' : 'disable', item.name],
                refreshLists: true,
              ),
              onRemove: (item) => _runAgy(
                ['plugin', 'uninstall', item.name],
                refreshLists: true,
              ),
            ),
            const SizedBox(height: 12),
          ],
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
                              : () => _runAgy(
                                    sub.defaultArgs,
                                    refreshLists: sub.name == 'mcp' ||
                                        sub.name == 'plugin' ||
                                        sub.name == 'agent',
                                  ),
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
                                  refreshLists: true,
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
                                  refreshLists: true,
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
                  if (_agents.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: _agents.any((a) => a.name == settings.activeAgent)
                          ? settings.activeAgent
                          : '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Select Discovered Agent (--agent)',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Default agent'),
                        ),
                        for (final agent in _agents)
                          DropdownMenuItem(
                            value: agent.name,
                            child: Text(
                              agent.detail.isNotEmpty
                                  ? '${agent.name} — ${agent.detail}'
                                  : agent.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) notifier.setActiveAgent(v);
                      },
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _agentCtrl,
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

class _ManagedListCard extends StatelessWidget {
  const _ManagedListCard({
    required this.title,
    required this.items,
    required this.busy,
    required this.onToggle,
    required this.onRemove,
  });

  final String title;
  final List<AgyCliManagedItem> items;
  final bool busy;
  final void Function(AgyCliManagedItem item, bool enabled) onToggle;
  final void Function(AgyCliManagedItem item) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            for (final item in items)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  item.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: item.detail.isNotEmpty
                    ? Text(
                        item.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch.adaptive(
                      value: item.enabled,
                      onChanged: busy ? null : (v) => onToggle(item, v),
                    ),
                    IconButton(
                      tooltip: 'Remove ${item.name}',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: busy ? null : () => onRemove(item),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
