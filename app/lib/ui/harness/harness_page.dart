import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/harness_state.dart';
import '../../theme/app_theme.dart';

/// Modern Agent Harness Dashboard:
/// - Context saturation gauge & proactive `/compact` trigger
/// - Doom-loop breaker, command/write guardrails, offloading & checkpoint toggles
/// - Verification gate detector (`flutter test`, `dart test`, `pytest`, `npm test`, etc.)
/// - Anthropic-style Initializer / Incremental Coder / Adversarial Verifier workflows
/// - Interactive `.agy-harness/feature_list.json` & `.agy-harness/progress.txt` ledger
class HarnessPage extends ConsumerStatefulWidget {
  const HarnessPage({super.key, this.autoRefreshOnOpen = true});

  final bool autoRefreshOnOpen;

  @override
  ConsumerState<HarnessPage> createState() => _HarnessPageState();
}

class _HarnessPageState extends ConsumerState<HarnessPage> {
  final _goalCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.autoRefreshOnOpen) {
      Future.microtask(() {
        if (mounted) {
          ref.read(harnessProvider.notifier).refreshWorkspace();
        }
      });
    }
  }

  @override
  void dispose() {
    _goalCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendAgentPrompt(String prompt) async {
    Navigator.of(context).pop();
    await ref.read(chatProvider.notifier).sendPrompt(prompt);
  }

  Future<void> _compactThread() async {
    final notifier = ref.read(chatProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    final res = await notifier.compactThread(
      instructions:
          'Summarize decisions, touched files, open blockers, and verified checks concisely.',
    );
    if (!res.ok) {
      messenger.showSnackBar(SnackBar(content: Text(res.message)));
    }
  }

  Future<void> _promptCustomVerify(HarnessState harness) async {
    final ctrl = TextEditingController(
      text: harness.customVerifyCommand ?? harness.detectedVerifyCommand ?? '',
    );
    final updated = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verification Gate Command'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'Command (leave empty for auto-detect)',
            hintText: 'e.g. flutter test',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (updated != null && mounted) {
      await ref.read(harnessProvider.notifier).setCustomVerifyCommand(updated);
    }
  }

  Future<void> _promptAddFeature() async {
    final ctrl = TextEditingController();
    final desc = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Feature Requirement'),
        content: TextField(
          controller: ctrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Describe a single verifiable feature…',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (desc != null && desc.trim().isNotEmpty && mounted) {
      await ref.read(harnessProvider.notifier).addFeature(desc);
    }
  }

  @override
  Widget build(BuildContext context) {
    final harness = ref.watch(harnessProvider);
    final ctxSnap = ref.watch(contextBudgetProvider);
    final theme = Theme.of(context);
    final counts = harness.progressCounts;
    final verifyCmd = harness.effectiveVerifyCommand;

    final semantic = AgySemanticColors.of(context);
    final ctxColor = ctxSnap.shouldCompact
        ? theme.colorScheme.error
        : ctxSnap.needsWarning
            ? semantic.warning
            : theme.colorScheme.primary;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Harness Engineering'),
        actions: [
          IconButton(
            tooltip: 'Refresh workspace artifacts',
            onPressed: harness.loading
                ? null
                : () => ref.read(harnessProvider.notifier).refreshWorkspace(),
            icon: harness.loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          // 1. Context Budget Monitor
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.memory_rounded, size: 18, color: ctxColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Context Window Budget',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Text(
                        '${ctxSnap.percentage}%',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: ctxColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: ctxSnap.ratio,
                      minHeight: 7,
                      color: ctxColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        ctxSnap.compactedMessages > 0
                            ? '~${ctxSnap.usedTokens} / ${ctxSnap.budgetTokens} tokens (${ctxSnap.compactedMessages} archived) · ${ctxSnap.statusLabel}'
                            : '~${ctxSnap.usedTokens} / ${ctxSnap.budgetTokens} tokens · ${ctxSnap.statusLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _compactThread,
                        icon: const Icon(Icons.compress_rounded, size: 16),
                        label: const Text('Compact Thread'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Runtime Guardrails & Circuit Breakers
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                  child: Text(
                    'Guardrails & Circuit Breakers',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.loop_rounded, size: 20),
                  title: const Text('Doom-Loop Circuit Breaker'),
                  subtitle: const Text(
                    'Detects repeated identical calls & ping-pong cycles',
                  ),
                  value: harness.loopBreakerEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setLoopBreaker(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.gpp_good_outlined, size: 20),
                  title: const Text('Command & Path Safety Guard'),
                  subtitle: const Text(
                    'Blocks catastrophic deletes, raw disk writes & credential overwrites (outputs >12KB offloaded)',
                  ),
                  value: harness.guardrailsEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setGuardrails(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.history_rounded, size: 20),
                  title: const Text('Pre-Turn Git Checkpoints'),
                  subtitle: const Text(
                    'Captures lightweight stash snapshots for deterministic /rewind',
                  ),
                  value: harness.autoCheckpointEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setAutoCheckpoint(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.fact_check_outlined, size: 20),
                  title: const Text('Auto-Verify After Turn'),
                  subtitle: const Text(
                    'Appends verification-gate instructions after feature work',
                  ),
                  value: harness.autoVerifyEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setAutoVerify(v),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.verified_outlined, size: 20),
                  title: const Text('Verification Gate'),
                  subtitle: Text(
                    verifyCmd ?? 'Not detected (tap to set custom command)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: () => _promptCustomVerify(harness),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 3. Long-Running Agent Topologies
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Multi-Session Harness Topologies',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Structured Initializer → Incremental Coder → Adversarial Evaluator workflow stored in `.agy-harness/`.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (!harness.initialized) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _goalCtrl,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Project / Milestone Goal',
                        hintText: 'e.g. Implement OAuth login & add tests',
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (!harness.initialized)
                        FilledButton.icon(
                          onPressed: () async {
                            final goal = _goalCtrl.text.trim().isEmpty
                                ? 'Deliver verified milestone cleanly'
                                : _goalCtrl.text.trim();
                            await ref
                                .read(harnessProvider.notifier)
                                .initializeWorkspace(goal);
                          },
                          icon: const Icon(Icons.playlist_add_check, size: 18),
                          label: const Text('Init .agy-harness'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          final goal = _goalCtrl.text.trim().isEmpty
                              ? 'Inspect codebase and scaffold verifiable feature ledger'
                              : _goalCtrl.text.trim();
                          _sendAgentPrompt(
                            HarnessWorkspaceTemplates.buildInitializerPrompt(
                              goal: goal,
                              verifyCommand: verifyCmd,
                            ),
                          );
                        },
                        icon: const Icon(Icons.rocket_launch_outlined, size: 17),
                        label: const Text('Run Initializer Agent'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => _sendAgentPrompt(
                          HarnessWorkspaceTemplates.buildNextFeaturePrompt(
                            nextFeature: harness.nextPendingFeature,
                            verifyCommand: verifyCmd,
                          ),
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 18),
                        label: Text(
                          harness.nextPendingFeature != null
                              ? 'Next: ${harness.nextPendingFeature!.id}'
                              : 'Next Feature Turn',
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _sendAgentPrompt(
                          HarnessWorkspaceTemplates.buildAdversarialReviewPrompt(
                            verifyCommand: verifyCmd,
                            pendingCount: counts.total - counts.passed,
                          ),
                        ),
                        icon: const Icon(Icons.policy_outlined, size: 17),
                        label: const Text('Adversarial Diff Review'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 4. Feature Ledger (.agy-harness/feature_list.json)
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.checklist_rounded, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Feature Ledger (${counts.passed}/${counts.total})',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _promptAddFeature,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  if (harness.features.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No `.agy-harness/feature_list.json` found in active workspace yet.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 4),
                    ...harness.features.map(
                      (f) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: f.passes,
                        onChanged: (_) => ref
                            .read(harnessProvider.notifier)
                            .toggleFeaturePasses(f.id),
                        title: Text(
                          '${f.id} · ${f.description}',
                          style: TextStyle(
                            decoration:
                                f.passes ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        subtitle: Text(
                          f.category,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (harness.progressLog.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Session Handoff Log (progress.txt)',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      harness.progressLog.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
