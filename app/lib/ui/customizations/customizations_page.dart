import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/customizations_state.dart';

class CustomizationsPage extends ConsumerStatefulWidget {
  const CustomizationsPage({super.key});

  @override
  ConsumerState<CustomizationsPage> createState() => _CustomizationsPageState();
}

class _CustomizationsPageState extends ConsumerState<CustomizationsPage> {
  CustomizationKind? _filter;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(customizationsProvider.notifier).refresh(),
    );
  }

  bool _isEditable(CustomizationItem item) =>
      item.kind == CustomizationKind.rule || item.kind == CustomizationKind.skill;

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(customizationsProvider);
    final filtered = _filter == null
        ? items
        : items.where((i) => i.kind == _filter).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customizations'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'New AGENTS.md or SKILL.md',
            icon: const Icon(Icons.add),
            onSelected: (action) {
              if (action == 'skill') {
                _createSkillDialog(context);
              } else if (action == 'mcp_http') {
                _addHttpMcpDialog(context);
              } else if (action == 'agents_project' || action == 'agents_global') {
                _createOrEditAgentsMd(
                  context,
                  items,
                  isGlobal: action == 'agents_global',
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'skill',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.psychology_outlined),
                  title: Text('New Skill (SKILL.md)'),
                ),
              ),
              PopupMenuItem(
                value: 'mcp_http',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.extension_outlined),
                  title: Text('Add HTTP/SSE MCP Server'),
                ),
              ),
              PopupMenuItem(
                value: 'agents_project',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.description_outlined),
                  title: Text('Project AGENTS.md'),
                ),
              ),
              PopupMenuItem(
                value: 'agents_global',
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.public),
                  title: Text('Global AGENTS.md'),
                ),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () =>
                ref.read(customizationsProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('All'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
                const SizedBox(width: 8),
                for (final k in CustomizationKind.values) ...[
                  FilterChip(
                    label: Text(k.label),
                    selected: _filter == k,
                    onSelected: (_) => setState(() => _filter = k),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Text(
                      'No rules, AGENTS.md, SKILL.md, or MCP servers found yet.',
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final item = filtered[i];
                      final editable = _isEditable(item);
                      final statusTag = item.enabled ? '' : ' · Not created';
                      return Card(
                        child: ListTile(
                          leading: Icon(switch (item.kind) {
                            CustomizationKind.rule => Icons.rule,
                            CustomizationKind.skill => Icons.psychology_outlined,
                            CustomizationKind.mcpServer => Icons.extension,
                            CustomizationKind.hook => Icons.webhook,
                            CustomizationKind.plugin => Icons.inventory_2_outlined,
                          }),
                          title: Text(item.name),
                          subtitle: Text(
                            '${item.scope}$statusTag · ${item.description}\n${item.pathOrCommand}',
                          ),
                          isThreeLine: true,
                          trailing: editable
                              ? Icon(
                                  item.enabled
                                      ? Icons.edit_outlined
                                      : Icons.add_circle_outline,
                                )
                              : null,
                          onTap: editable
                              ? () => _editCustomization(context, item)
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _initialContentFor(CustomizationItem item) {
    final existing = item.content?.trim() ?? '';
    if (existing.isNotEmpty) return item.content!;
    if (AgentCustomizationHelper.isAgentsFile(item)) {
      return '''# AGENTS.md

## Project Context
- Describe repository structure, build/test commands, and key conventions.

## Agent Guidelines
- Inspect files before editing and run relevant tests after changes.
''';
    }
    if (item.kind == CustomizationKind.skill) {
      return SkillFrontmatter.scaffold(
        name: item.name,
        description: item.description,
      );
    }
    return '';
  }

  Future<void> _editCustomization(
    BuildContext context,
    CustomizationItem item,
  ) async {
    final ctrl = TextEditingController(text: _initialContentFor(item));
    final slashTrigger = '/${SkillFrontmatter.sanitizeSlug(item.name)}';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          item.enabled ? 'Edit ${item.name}' : 'Create ${item.name}',
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.kind == CustomizationKind.skill) ...[
                  Text(
                    'Invoke in chat with `$slashTrigger <task>`',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
                TextField(
                  controller: ctrl,
                  maxLines: 14,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: InputDecoration(
                    hintText: item.kind == CustomizationKind.skill
                        ? 'YAML frontmatter (name, description) + skill instructions…'
                        : 'Write persistent instructions for Antigravity…',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (item.kind == CustomizationKind.skill)
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '$slashTrigger '));
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text('Copied $slashTrigger')),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy /cmd'),
            ),
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
    );
    if (saved == true) {
      await ref
          .read(customizationsProvider.notifier)
          .saveFile(item.pathOrCommand, ctrl.text);
    }
    ctrl.dispose();
  }

  Future<void> _createOrEditAgentsMd(
    BuildContext context,
    List<CustomizationItem> items, {
    required bool isGlobal,
  }) async {
    final targetScope = isGlobal ? 'Global' : 'Project';
    final match = items.cast<CustomizationItem?>().firstWhere(
          (i) =>
              i != null &&
              AgentCustomizationHelper.isAgentsFile(i) &&
              i.scope == targetScope,
          orElse: () => null,
        );
    if (match != null) {
      await _editCustomization(context, match);
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tap Refresh or open a workspace to edit AGENTS.md'),
        ),
      );
    }
  }

  Future<void> _createSkillDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final descCtrl = TextEditingController();
    var scope = 'Project';

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New Agent Skill (SKILL.md)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Skill Name',
                  hintText: 'e.g. release-check',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: descCtrl,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'What this skill does & when to trigger it',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'Project', label: Text('Project')),
                  ButtonSegment(value: 'Global', label: Text('Global')),
                ],
                selected: {scope},
                onSelectionChanged: (s) =>
                    setDialogState(() => scope = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (created == true && nameCtrl.text.trim().isNotEmpty) {
      final path = await ref.read(customizationsProvider.notifier).createSkill(
            name: nameCtrl.text,
            description: descCtrl.text,
            scope: scope,
          );
      if (path != null && mounted) {
        final createdItem = ref
            .read(customizationsProvider)
            .cast<CustomizationItem?>()
            .firstWhere((i) => i?.pathOrCommand == path, orElse: () => null);
        if (createdItem != null && context.mounted) {
          await _editCustomization(context, createdItem);
        }
      }
    }
    nameCtrl.dispose();
    descCtrl.dispose();
  }

  Future<void> _addHttpMcpDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController(text: 'http://127.0.0.1:8080/mcp');
    final authCtrl = TextEditingController();
    String? probeStatus;
    var probing = false;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Add HTTP / SSE MCP Server'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Server Name',
                    hintText: 'e.g. github-mcp',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'MCP Endpoint URL (HTTP / SSE)',
                    hintText: 'http://127.0.0.1:8080/mcp',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: authCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Authorization Header (optional)',
                    hintText: 'Bearer <token>',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: probing
                      ? null
                      : () async {
                          final uri = Uri.tryParse(urlCtrl.text.trim());
                          if (uri == null) {
                            setDialog(() => probeStatus = 'Invalid URL');
                            return;
                          }
                          setDialog(() {
                            probing = true;
                            probeStatus = 'Probing MCP server…';
                          });
                          final client = McpHttpClient();
                          try {
                            final headers = authCtrl.text.trim().isNotEmpty
                                ? {'Authorization': authCtrl.text.trim()}
                                : const <String, String>{};
                            final res = await client.probeServer(
                              uri,
                              headers: headers,
                            );
                            if (ctx.mounted) {
                              setDialog(() {
                                probing = false;
                                probeStatus = res.ok
                                    ? 'Connected (${res.serverName ?? "MCP"}) · ${res.tools.length} tool(s)'
                                    : 'Failed: ${res.error}';
                              });
                            }
                          } finally {
                            client.close();
                          }
                        },
                  icon: const Icon(Icons.network_check, size: 16),
                  label: const Text('Test MCP Handshake'),
                ),
                if (probeStatus != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    probeStatus!,
                    style: Theme.of(ctx).textTheme.bodySmall,
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
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty ||
                    urlCtrl.text.trim().isEmpty) {
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true &&
        nameCtrl.text.trim().isNotEmpty &&
        urlCtrl.text.trim().isNotEmpty) {
      await ref.read(customizationsProvider.notifier).addHttpMcpServer(
            name: nameCtrl.text,
            url: urlCtrl.text,
            authHeader:
                authCtrl.text.trim().isEmpty ? null : authCtrl.text.trim(),
          );
    }
    nameCtrl.dispose();
    urlCtrl.dispose();
    authCtrl.dispose();
  }
}
