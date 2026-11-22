import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/automations_state.dart';
import '../../state/chat_state.dart';
import '../../state/projects_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';

class AutomationsPage extends ConsumerWidget {
  const AutomationsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(automationsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Automations')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createAutomation(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New Automation'),
      ),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'No Automations Yet',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Schedule repeatable prompts or run one-click workflows on your projects.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final a = items[i];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                a.name,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Chip(
                              visualDensity: VisualDensity.compact,
                              label: Text(a.modelTier.label),
                            ),
                            Switch.adaptive(
                              value: a.enabled,
                              onChanged: (v) => ref
                                  .read(automationsProvider.notifier)
                                  .toggle(a.id, v),
                            ),
                          ],
                        ),
                        Text(
                          a.scheduleLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          a.prompt,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: () async {
                                await ref
                                    .read(settingsProvider.notifier)
                                    .setModel(a.modelTier.modelId);
                                await ref
                                    .read(sessionsProvider.notifier)
                                    .createSession(title: 'Auto: ${a.name}');
                                await ref
                                    .read(automationsProvider.notifier)
                                    .markRun(a.id, 'Triggered');
                                if (context.mounted) Navigator.of(context).pop();
                                await ref
                                    .read(chatProvider.notifier)
                                    .sendPrompt(a.prompt);
                              },
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('Run Now'),
                            ),
                            const Spacer(),
                            IconButton(
                              tooltip: 'Delete',
                              onPressed: () => ref
                                  .read(automationsProvider.notifier)
                                  .delete(a.id),
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  Future<void> _createAutomation(BuildContext context, WidgetRef ref) async {
    final nameCtrl = TextEditingController();
    final promptCtrl = TextEditingController();
    final schedCtrl = TextEditingController(text: 'Daily · 09:00');
    var tier = AutomationModelTier.flash;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('New Automation'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: schedCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Schedule / Cron',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<AutomationModelTier>(
                  value: tier,
                  decoration: const InputDecoration(labelText: 'Model Tier'),
                  items: AutomationModelTier.values
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(t.label),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setLocal(() => tier = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: promptCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Agent Prompt',
                    hintText: 'Summarize recent commits and check failing tests',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    if (ok == true && promptCtrl.text.trim().isNotEmpty) {
      final projectId = ref.read(projectsProvider).activeProjectId;
      await ref.read(automationsProvider.notifier).add(
            name: nameCtrl.text.trim().isEmpty
                ? 'Automation'
                : nameCtrl.text.trim(),
            prompt: promptCtrl.text.trim(),
            scheduleLabel: schedCtrl.text.trim(),
            modelTier: tier,
            projectId: projectId,
          );
    }

    nameCtrl.dispose();
    promptCtrl.dispose();
    schedCtrl.dispose();
  }
}
