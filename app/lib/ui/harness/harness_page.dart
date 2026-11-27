import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/harness_state.dart';
import '../../state/rsi_loop_state.dart';
import '../../state/settings_state.dart';
import '../../theme/app_theme.dart';
import '../chat/rsi_sheet.dart';

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
    final settings = ref.watch(settingsProvider);
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
                            ? '~${ctxSnap.usedTokens} / ${ctxSnap.budgetTokens} tokens (${ctxSnap.compactedMessages} archived${ctxSnap.compactAtTokens != null ? ", compact @ ${(ctxSnap.compactAtTokens! / 1000).round()}K" : ""}) · ${ctxSnap.statusLabel}'
                            : '~${ctxSnap.usedTokens} / ${ctxSnap.budgetTokens} tokens${ctxSnap.compactAtTokens != null ? " (compact @ ${(ctxSnap.compactAtTokens! / 1000).round()}K)" : ""} · ${ctxSnap.statusLabel}',
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
                  secondary: const Icon(Icons.bolt_rounded, size: 20),
                  title: const Text('Auto-Pivot Stuck Loops'),
                  subtitle: const Text(
                    'Stops repeated failures automatically & injects a pivot prompt',
                  ),
                  value: harness.autoPivotLoopEnabled,
                  onChanged: harness.loopBreakerEnabled
                      ? (v) => ref
                          .read(harnessProvider.notifier)
                          .setAutoPivotLoop(v)
                      : null,
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.savings_outlined, size: 20),
                  title: const Text('Quota Saver Mode'),
                  subtitle: const Text(
                    'Adaptive 256K–800K auto-compact, Compaction effort profile & minimal MCP tools',
                  ),
                  value: harness.quotaSaverEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setQuotaSaver(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.alt_route_rounded, size: 20),
                  title: const Text('Category Effort Routing'),
                  subtitle: const Text(
                    'Uses your configured Thinking Effort per category (Chat, Normal, Refactor, Deep, Compaction)',
                  ),
                  value: harness.smartRoutingEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setSmartRouting(v),
                ),
                if (harness.smartRoutingEnabled) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Effort Per Category',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                              ),
                              onPressed: harness.effortProfile ==
                                      EffortCategoryProfile.defaults
                                  ? null
                                  : () => ref
                                      .read(harnessProvider.notifier)
                                      .resetEffortProfile(),
                              child: const Text('Reset defaults'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Always obeys your active model — only Thinking Effort changes per task category (inline !low–!max tags still override).',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final cat in EffortCategory.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        cat.label,
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        cat.description,
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          fontSize: 11,
                                          color: theme
                                              .colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PopupMenuButton<String>(
                                  tooltip: 'Set effort for ${cat.label}',
                                  onSelected: (value) => ref
                                      .read(harnessProvider.notifier)
                                      .setCategoryEffort(cat, value),
                                  itemBuilder: (_) => ReasoningEffort.values
                                      .map(
                                        (e) => PopupMenuItem<String>(
                                          value: e.cliValue,
                                          child: Row(
                                            children: [
                                              Expanded(child: Text(e.label)),
                                              if (harness.effortProfile
                                                      .effortFor(cat) ==
                                                  e.cliValue)
                                                Icon(
                                                  Icons.check_rounded,
                                                  size: 16,
                                                  color:
                                                      theme.colorScheme.primary,
                                                ),
                                            ],
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme
                                          .colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: theme.colorScheme.outlineVariant
                                            .withOpacity(0.45),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          ReasoningEffort.fromString(
                                            harness.effortProfile
                                                .effortFor(cat),
                                          ).label,
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(width: 2),
                                        Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          size: 16,
                                          color:
                                              theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Inference Speed Tier',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        switch (settings.speedTier) {
                          InferenceSpeedTier.regular =>
                            'Regular: Keeps your selected model & applies your Category Effort Profile',
                          InferenceSpeedTier.fast =>
                            'Fast: Keeps your selected model & caps Thinking Effort at Medium (Low on simple prompts)',
                          InferenceSpeedTier.ultrafast =>
                            'Ultrafast: Keeps your selected model with Low Thinking Effort for fastest responses',
                        },
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<InferenceSpeedTier>(
                          segments: InferenceSpeedTier.values
                              .map(
                                (t) => ButtonSegment<InferenceSpeedTier>(
                                  value: t,
                                  label: Text(t.label),
                                ),
                              )
                              .toList(),
                          selected: {settings.speedTier},
                          onSelectionChanged: (s) => ref
                              .read(settingsProvider.notifier)
                              .setSpeedTier(s.first),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.gpp_good_outlined, size: 20),
                  title: const Text('Command & Path Safety Guard'),
                  subtitle: const Text(
                    'Blocks catastrophic deletes, raw disk writes & credential overwrites (outputs >6KB offloaded)',
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
                    'Captures lightweight stash snapshots asynchronously for /rewind',
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
                    'Runs verification gate locally after code edits (zero LLM tokens on pass)',
                  ),
                  value: harness.autoVerifyEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setAutoVerify(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.compress_rounded, size: 20),
                  title: const Text('Auto-Compact History'),
                  subtitle: Text(
                    (harness.smartRoutingEnabled || harness.quotaSaverEnabled)
                        ? 'Adaptive auto-compact (256K min · up to 800K for refactors) via ${ReasoningEffort.fromString(harness.effortProfile.compaction).label} effort'
                        : 'Automatically summarizes context when usage exceeds 80%',
                  ),
                  value: harness.autoCompactEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setAutoCompact(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.data_object_rounded, size: 20),
                  title: const Text('Tool Output Variables (\$var)'),
                  subtitle: const Text(
                    'Stores large tool outputs as \$v_* variables so agents pass data by reference instead of re-typing tokens',
                  ),
                  value: harness.toolVariablesEnabled,
                  onChanged: (v) => ref
                      .read(harnessProvider.notifier)
                      .setToolVariablesEnabled(v),
                ),
                const Divider(height: 1),
                SwitchListTile.adaptive(
                  dense: true,
                  secondary: const Icon(Icons.account_tree_outlined, size: 20),
                  title: const Text('Smart Repo Map Context'),
                  subtitle: const Text(
                    'Injects structural class/function symbols on new sessions to save tokens',
                  ),
                  value: harness.repoMapEnabled,
                  onChanged: (v) =>
                      ref.read(harnessProvider.notifier).setRepoMapEnabled(v),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.map_outlined, size: 20),
                  title: const Text('Preview Repo Map'),
                  subtitle: Text(
                    harness.repoMapPreview.isEmpty
                        ? 'Tap to scan workspace symbols'
                        : '${harness.repoMapPreview.split('\n').length} lines indexed',
                  ),
                  trailing: const Icon(Icons.play_arrow_rounded, size: 20),
                  onTap: () => _showRepoMapDialog(context),
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

          // 2b. Lifecycle Hooks (PreToolUse / PostToolUse)
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Lifecycle Hooks (PreToolUse / PostToolUse)',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _promptAddHookDialog(context),
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add Hook'),
                      ),
                    ],
                  ),
                ),
                for (final rule in harness.hooksConfig.rules) ...[
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    dense: true,
                    secondary: Icon(
                      rule.phase == LifecycleHookPhase.preToolUse
                          ? Icons.shield_outlined
                          : Icons.build_circle_outlined,
                      size: 19,
                    ),
                    title: Text(rule.name),
                    subtitle: Text(
                      '${rule.phase.label} · ${rule.toolMatcher} · ${rule.pathPattern}'
                      '${rule.command.isNotEmpty ? " → ${rule.command}" : ""}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    value: rule.enabled,
                    onChanged: (v) => ref
                        .read(harnessProvider.notifier)
                        .toggleHookRule(rule.id, v),
                  ),
                ],
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
                      OutlinedButton.icon(
                        onPressed: () {
                          final activeRsi = ref.read(rsiLoopProvider);
                          RsiControlSheet.show(
                            context,
                            ref,
                            initialObjective: activeRsi.config.objective,
                          );
                        },
                        icon: const Icon(Icons.autorenew_rounded, size: 17),
                        label: const Text('RSI Loop (/rsi)'),
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

  Future<void> _showRepoMapDialog(BuildContext context) async {
    final mapText =
        await ref.read(harnessProvider.notifier).refreshRepoMap();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Smart Context Repo Map'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              mapText.isEmpty
                  ? 'No supported source files found in active workspace.'
                  : mapText,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _promptAddHookDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final patternCtrl = TextEditingController(text: '*.dart');
    final cmdCtrl = TextEditingController(text: 'dart format {file}');
    var phase = LifecycleHookPhase.postToolUse;
    var action = LifecycleHookAction.command;
    var toolMatcher = 'write_file';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Add Lifecycle Hook'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Hook Name',
                    hintText: 'e.g. Block secrets or Auto-format',
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<LifecycleHookPhase>(
                  value: phase,
                  decoration: const InputDecoration(labelText: 'Phase'),
                  items: const [
                    DropdownMenuItem(
                      value: LifecycleHookPhase.preToolUse,
                      child: Text('PreToolUse'),
                    ),
                    DropdownMenuItem(
                      value: LifecycleHookPhase.postToolUse,
                      child: Text('PostToolUse'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setDialog(() {
                        phase = v;
                        action = v == LifecycleHookPhase.preToolUse
                            ? LifecycleHookAction.block
                            : LifecycleHookAction.command;
                      });
                    }
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: toolMatcher,
                  decoration: const InputDecoration(labelText: 'Tool Matcher'),
                  items: const [
                    DropdownMenuItem(value: 'write_file', child: Text('write_file')),
                    DropdownMenuItem(value: 'shell', child: Text('shell')),
                    DropdownMenuItem(value: '*', child: Text('All (*)')),
                  ],
                  onChanged: (v) {
                    if (v != null) setDialog(() => toolMatcher = v);
                  },
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: patternCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Path / Pattern (comma-separated)',
                    hintText: '*.env,*.jks or *.dart',
                  ),
                ),
                if (action == LifecycleHookAction.command) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: cmdCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Shell Command ({file} placeholder)',
                      hintText: 'dart format {file}',
                    ),
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
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && nameCtrl.text.trim().isNotEmpty && context.mounted) {
      final id =
          'hook-${DateTime.now().millisecondsSinceEpoch}';
      await ref.read(harnessProvider.notifier).addCustomHookRule(
            LifecycleHookRule(
              id: id,
              name: nameCtrl.text.trim(),
              phase: phase,
              toolMatcher: toolMatcher,
              pathPattern: patternCtrl.text.trim().isEmpty
                  ? '*'
                  : patternCtrl.text.trim(),
              action: action,
              command: action == LifecycleHookAction.command
                  ? cmdCtrl.text.trim()
                  : '',
              reason: action == LifecycleHookAction.block
                  ? 'Blocked by PreToolUse hook "${nameCtrl.text.trim()}".'
                  : '',
            ),
          );
    }
    nameCtrl.dispose();
    patternCtrl.dispose();
    cmdCtrl.dispose();
  }
}
