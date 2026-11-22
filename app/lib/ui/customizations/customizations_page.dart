import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
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
                    child: Text('No rules, skills, or MCP servers found yet.'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final item = filtered[i];
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
                            '${item.scope} · ${item.description}\n${item.pathOrCommand}',
                          ),
                          isThreeLine: true,
                          trailing: item.kind == CustomizationKind.rule
                              ? const Icon(Icons.edit_outlined)
                              : null,
                          onTap: item.kind == CustomizationKind.rule
                              ? () => _editRule(context, item)
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

  Future<void> _editRule(BuildContext context, CustomizationItem item) async {
    final ctrl = TextEditingController(text: item.content ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit ${item.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: 'Write persistent instructions for Antigravity…',
            ),
          ),
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
    );
    if (saved == true) {
      await ref
          .read(customizationsProvider.notifier)
          .saveFile(item.pathOrCommand, ctrl.text);
    }
    ctrl.dispose();
  }
}
