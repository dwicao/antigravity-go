import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../remote/openai_compat_runner.dart';
import '../../state/custom_providers_state.dart';

class CustomProvidersPage extends ConsumerWidget {
  const CustomProvidersPage({super.key});

  static const _presets = <({String name, String baseUrl, String modelId, int ctx})>[
    (
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      modelId: 'gpt-4.1',
      ctx: 1000000,
    ),
    (
      name: 'OpenRouter',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'anthropic/claude-sonnet-4',
      ctx: 200000,
    ),
    (
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com/v1',
      modelId: 'deepseek-chat',
      ctx: 128000,
    ),
    (
      name: 'Ollama (Local)',
      baseUrl: 'http://127.0.0.1:11434/v1',
      modelId: 'qwen2.5-coder:14b',
      ctx: 128000,
    ),
    (
      name: 'LM Studio',
      baseUrl: 'http://127.0.0.1:1234/v1',
      modelId: 'local-model',
      ctx: 128000,
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providers = ref.watch(customProvidersProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('External /v1 Models'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add /v1 Model'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Antigravity CLI (Built-in)'),
              subtitle: const Text(
                'Uses native `agy` on-device runtime or SSH workstation',
              ),
              trailing: providers.activeProviderId == null
                  ? const Icon(Icons.check_circle, color: Colors.green)
                  : null,
              onTap: () =>
                  ref.read(customProvidersProvider.notifier).selectProvider(null),
            ),
          ),
          const SizedBox(height: 12),
          if (providers.profiles.isNotEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Hybrid Cloud + Local Fallback'),
                      subtitle: const Text(
                        'Automatically route to a local Ollama / llama.cpp profile when offline',
                      ),
                      value: providers.hybridOfflineFallbackEnabled,
                      onChanged: (v) => ref
                          .read(customProvidersProvider.notifier)
                          .setHybridOfflineFallbackEnabled(v),
                    ),
                    if (providers.hybridOfflineFallbackEnabled)
                      DropdownButtonFormField<String?>(
                        value: providers.fallbackProviderId,
                        decoration: const InputDecoration(
                          labelText: 'Offline Fallback Profile',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Auto-pick first local endpoint'),
                          ),
                          for (final p in providers.profiles)
                            DropdownMenuItem<String?>(
                              value: p.id,
                              child: Text('${p.name} (${p.modelId})'),
                            ),
                        ],
                        onChanged: (v) => ref
                            .read(customProvidersProvider.notifier)
                            .setFallbackProvider(v),
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (providers.profiles.isEmpty) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connect any OpenAI-compatible `/v1` API',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Works with OpenAI, OpenRouter, DeepSeek, Groq, Together, Ollama, LM Studio, vLLM, or custom proxies — with SSE streaming, tool calling, thinking blocks, and vision attachments.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in _presets)
                          ActionChip(
                            label: Text(preset.name),
                            onPressed: () => _openEditor(
                              context,
                              ref,
                              preset: preset,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          for (final p in providers.profiles)
            Card(
              child: ListTile(
                leading: const Icon(Icons.hub_outlined),
                title: Text(p.name),
                subtitle: Text(
                  '${p.modelId}${p.subagentModelId.trim().isNotEmpty ? " (sub: ${p.subagentModelId.trim()})" : ""} · ${p.normalizedBaseUrl}\nContext: ${(p.contextWindowTokens / 1000).round()}K${p.supportsTools ? " · Tools" : ""}${p.supportsVision ? " · Vision" : ""}',
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (providers.activeProviderId == p.id)
                      const Icon(Icons.check_circle, color: Colors.green),
                    PopupMenuButton<String>(
                      onSelected: (action) async {
                        if (action == 'test') {
                          await _testProfile(context, ref, p);
                        } else if (action == 'edit') {
                          await _openEditor(context, ref, existing: p);
                        } else if (action == 'delete') {
                          await ref
                              .read(customProvidersProvider.notifier)
                              .removeProfile(p.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'test',
                          child: Text('Test Endpoint'),
                        ),
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ],
                ),
                onTap: () => ref
                    .read(customProvidersProvider.notifier)
                    .selectProvider(p.id),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _testProfile(
    BuildContext context,
    WidgetRef ref,
    OpenAiProviderConfig profile,
  ) async {
    final key =
        await ref.read(customProvidersProvider.notifier).readApiKey(profile.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Testing ${profile.normalizedBaseUrl}…')),
    );
    try {
      final res = await OpenAiCompatRunner.instance.testConnection(
        profile,
        apiKey: key,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    }
  }

  Future<void> _openEditor(
    BuildContext context,
    WidgetRef ref, {
    OpenAiProviderConfig? existing,
    ({String name, String baseUrl, String modelId, int ctx})? preset,
  }) async {
    final nameCtrl =
        TextEditingController(text: existing?.name ?? preset?.name ?? '');
    final urlCtrl = TextEditingController(
      text: existing?.baseUrl ?? preset?.baseUrl ?? 'https://api.openai.com/v1',
    );
    final modelCtrl = TextEditingController(
      text: existing?.modelId ?? preset?.modelId ?? 'gpt-4.1',
    );
    final subModelCtrl = TextEditingController(
      text: existing?.subagentModelId ?? '',
    );
    final ctxCtrl = TextEditingController(
      text: '${existing?.contextWindowTokens ?? preset?.ctx ?? 128000}',
    );
    final sysCtrl = TextEditingController(text: existing?.systemPrompt ?? '');
    final keyCtrl = TextEditingController();
    if (existing != null) {
      final savedKey = await ref
          .read(customProvidersProvider.notifier)
          .readApiKey(existing.id);
      if (savedKey != null && savedKey.isNotEmpty) {
        keyCtrl.text = savedKey;
      }
    }

    var supportsTools = existing?.supportsTools ?? true;
    var supportsVision = existing?.supportsVision ?? true;
    var activateNow = true;
    var fetchingModels = false;
    var discoveredModels = <String>[];
    String? fetchError;

    if (!context.mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Add OpenAI /v1 Model' : 'Edit OpenAI /v1 Model',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (existing == null)
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in _presets)
                        ActionChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(p.name),
                          onPressed: () {
                            setDialogState(() {
                              nameCtrl.text = p.name;
                              urlCtrl.text = p.baseUrl;
                              modelCtrl.text = p.modelId;
                              ctxCtrl.text = '${p.ctx}';
                            });
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Profile Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Base URL (/v1)',
                    hintText: 'https://api.openai.com/v1',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API Key (stored in Android Keystore, optional for local)',
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: modelCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Model ID',
                          hintText: 'gpt-4.1 / deepseek-chat / qwen2.5-coder',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton.filledTonal(
                      tooltip: 'Fetch /models',
                      onPressed: fetchingModels
                          ? null
                          : () async {
                              setDialogState(() {
                                fetchingModels = true;
                                fetchError = null;
                              });
                              try {
                                final tmp = OpenAiProviderConfig(
                                  id: 'probe',
                                  name: nameCtrl.text,
                                  baseUrl: urlCtrl.text,
                                  modelId: modelCtrl.text,
                                );
                                final models = await OpenAiCompatRunner.instance
                                    .fetchModels(tmp, apiKey: keyCtrl.text);
                                setDialogState(() {
                                  discoveredModels = models;
                                  if (models.isNotEmpty &&
                                      !models.contains(modelCtrl.text.trim())) {
                                    modelCtrl.text = models.first;
                                  }
                                });
                              } catch (e) {
                                setDialogState(() => fetchError = '$e');
                              } finally {
                                setDialogState(() => fetchingModels = false);
                              }
                            },
                      icon: fetchingModels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined),
                    ),
                  ],
                ),
                if (fetchError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    fetchError!,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(ctx).colorScheme.error,
                    ),
                  ),
                ],
                if (discoveredModels.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: discoveredModels.contains(modelCtrl.text.trim())
                        ? modelCtrl.text.trim()
                        : discoveredModels.first,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Discovered Models',
                      isDense: true,
                    ),
                    items: discoveredModels
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text(m, overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setDialogState(() => modelCtrl.text = v);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 8),
                TextField(
                  controller: subModelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Subagent Model ID (optional, cheaper)',
                    hintText: 'e.g. gpt-4o-mini / deepseek-chat / qwen2.5:7b',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctxCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Context Window (tokens)',
                    hintText: '128000',
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Enable Agent Tools'),
                  subtitle: const Text(
                    'run_command, read_file, write_file, list_dir',
                  ),
                  value: supportsTools,
                  onChanged: (v) => setDialogState(() => supportsTools = v),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Supports Vision Images'),
                  value: supportsVision,
                  onChanged: (v) => setDialogState(() => supportsVision = v),
                ),
                TextField(
                  controller: sysCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Custom System Prompt (optional)',
                  ),
                ),
                if (existing == null)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Activate immediately'),
                    value: activateNow,
                    onChanged: (v) =>
                        setDialogState(() => activateNow = v ?? true),
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
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    if (saved == true &&
        urlCtrl.text.trim().isNotEmpty &&
        modelCtrl.text.trim().isNotEmpty) {
      final ctxTokens = int.tryParse(ctxCtrl.text.trim()) ?? 128000;
      await ref.read(customProvidersProvider.notifier).addOrUpdateProfile(
            OpenAiProviderConfig(
              id: existing?.id ?? '',
              name: nameCtrl.text.trim().isEmpty
                  ? modelCtrl.text.trim()
                  : nameCtrl.text.trim(),
              baseUrl: urlCtrl.text.trim(),
              modelId: modelCtrl.text.trim(),
              subagentModelId: subModelCtrl.text.trim(),
              contextWindowTokens: ctxTokens.clamp(2048, 4000000),
              supportsTools: supportsTools,
              supportsVision: supportsVision,
              systemPrompt: sysCtrl.text.trim(),
            ),
            apiKey: keyCtrl.text,
            activate: existing == null ? activateNow : false,
          );
    }

    nameCtrl.dispose();
    urlCtrl.dispose();
    modelCtrl.dispose();
    subModelCtrl.dispose();
    ctxCtrl.dispose();
    sysCtrl.dispose();
    keyCtrl.dispose();
  }
}
