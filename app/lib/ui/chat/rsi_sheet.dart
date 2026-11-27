import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/projects_state.dart';
import '../../state/rsi_loop_state.dart';
import '../../state/sessions_state.dart';
import '../../theme/app_theme.dart';

/// Compact live banner shown above the chat composer when an RSI loop is active
/// or recently finished.
class RsiStatusBanner extends ConsumerWidget {
  const RsiStatusBanner({super.key, required this.onOpenSheet});

  final VoidCallback onOpenSheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rsi = ref.watch(rsiLoopProvider);
    if (rsi.phase == RsiPhase.idle) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final isErr = rsi.phase == RsiPhase.failed;
    final isDone = rsi.phase == RsiPhase.completed;
    final bg = isErr
        ? theme.colorScheme.errorContainer.withOpacity(0.55)
        : isDone
            ? semantic.success.withOpacity(0.16)
            : theme.colorScheme.primaryContainer.withOpacity(0.45);
    final fg = isErr
        ? theme.colorScheme.onErrorContainer
        : isDone
            ? semantic.success
            : theme.colorScheme.onPrimaryContainer;

    final detail = rsi.statusDetail.trim().isNotEmpty
        ? rsi.statusDetail
        : 'Gen ${rsi.currentGeneration}/${rsi.config.maxGenerations} · ${rsi.phase.label}';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fg.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          if (rsi.isActive)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          else
            Icon(
              isErr
                  ? Icons.error_outline_rounded
                  : isDone
                      ? Icons.verified_rounded
                      : Icons.pause_circle_outline_rounded,
              size: 16,
              color: fg,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onOpenSheet,
            child: const Text('RSI'),
          ),
          if (rsi.isActive)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: () => ref
                  .read(rsiLoopProvider.notifier)
                  .stop(cancelStreamingTurn: true),
              child: const Text('Stop'),
            )
          else
            IconButton(
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              tooltip: 'Dismiss RSI banner',
              onPressed: () =>
                  ref.read(rsiLoopProvider.notifier).dismissBanner(),
              icon: Icon(Icons.close, color: fg),
            ),
        ],
      ),
    );
  }
}

/// Modal bottom sheet to configure, launch, monitor, and inspect the
/// AlphaEvolve + Evaluator-Optimizer Recursive Self-Improvement loop.
class RsiControlSheet extends ConsumerStatefulWidget {
  const RsiControlSheet({super.key, this.initialObjective});

  final String? initialObjective;

  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    String? initialObjective,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => RsiControlSheet(initialObjective: initialObjective),
    );
  }

  @override
  ConsumerState<RsiControlSheet> createState() => _RsiControlSheetState();
}

class _RsiControlSheetState extends ConsumerState<RsiControlSheet> {
  late final TextEditingController _objCtrl;
  late int _maxGenerations;
  late int _maxCiFixes;
  late RsiReleaseMode _releaseMode;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(rsiLoopProvider).config;
    final seedObj = widget.initialObjective?.trim();
    _objCtrl = TextEditingController(
      text: (seedObj != null && seedObj.isNotEmpty) ? seedObj : cfg.objective,
    );
    _maxGenerations = cfg.maxGenerations;
    _maxCiFixes = cfg.maxCiFixAttemptsPerGen;
    _releaseMode = cfg.releaseMode;
  }

  @override
  void dispose() {
    _objCtrl.dispose();
    super.dispose();
  }

  Future<void> _startLoop() async {
    final sessions = ref.read(sessionsProvider);
    var active = sessions.activeSession;
    active ??= await ref.read(sessionsProvider.notifier).createSession();
    final project = ref.read(projectsProvider).activeProject;
    final cwd = active.workspacePath.isNotEmpty
        ? active.workspacePath
        : project.primaryFolder;
    final nextCfg = RsiConfig(
      objective: _objCtrl.text,
      maxGenerations: _maxGenerations,
      maxCiFixAttemptsPerGen: _maxCiFixes,
      releaseMode: _releaseMode,
    ).normalized();

    if (mounted) Navigator.of(context).pop();
    await ref.read(rsiLoopProvider.notifier).start(
          sessionId: active.id,
          cwd: cwd,
          config: nextCfg,
        );
  }

  @override
  Widget build(BuildContext context) {
    final rsi = ref.watch(rsiLoopProvider);
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + bottomInset),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.autorenew_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Recursive Self-Improvement (RSI)',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(rsi.phase.label),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Universal AlphaEvolve + Evaluator-Optimizer loop: auto-detects Git branch, version manifest, local tests/CI, and release/APK workflows → self-heals on failure → ships & advances generations.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: semantic.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _objCtrl,
                enabled: !rsi.isActive,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Self-Improvement Objective',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Max Generations (RSP Bound)',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [1, 2, 3, 5, 10]
                    .map(
                      (n) => ChoiceChip(
                        label: Text('$n'),
                        selected: _maxGenerations == n,
                        onSelected: rsi.isActive
                            ? null
                            : (_) => setState(() => _maxGenerations = n),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 10),
              Text(
                'Max Self-Heal Retries / Generation',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [0, 1, 2, 3]
                    .map(
                      (n) => ChoiceChip(
                        label: Text('$n'),
                        selected: _maxCiFixes == n,
                        onSelected: rsi.isActive
                            ? null
                            : (_) => setState(() => _maxCiFixes = n),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 10),
              Text(
                'Post-Verification Release Mode',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: RsiReleaseMode.values
                    .map(
                      (m) => ChoiceChip(
                        label: Text(m.label),
                        selected: _releaseMode == m,
                        onSelected: rsi.isActive
                            ? null
                            : (_) => setState(() => _releaseMode = m),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 4),
              Text(
                _releaseMode.description,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: semantic.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (rsi.isActive)
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        onPressed: () {
                          ref
                              .read(rsiLoopProvider.notifier)
                              .stop(cancelStreamingTurn: true);
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.stop_rounded),
                        label: Text(
                          'Stop Active Loop (Gen ${rsi.currentGeneration}/${rsi.config.maxGenerations})',
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _startLoop,
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text('Start RSI Loop ($_maxGenerations gen)'),
                      ),
                    ),
                ],
              ),
              if (rsi.archive.isNotEmpty) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Evolutionary Lineage (${rsi.archive.length})',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          ref.read(rsiLoopProvider.notifier).clearArchive(),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final entry in rsi.archive.take(8)) ...[
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      entry.isSuccess
                          ? Icons.check_circle_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 18,
                      color: entry.isSuccess
                          ? semantic.success
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      'Gen ${entry.generation} · ${entry.status}${entry.tag != null ? ' (${entry.tag})' : ''}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      entry.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: entry.releaseUrl != null
                        ? IconButton(
                            tooltip: 'Open GitHub Release',
                            icon:
                                const Icon(Icons.open_in_new_rounded, size: 17),
                            onPressed: () => launchUrl(
                              Uri.parse(entry.releaseUrl!),
                              mode: LaunchMode.externalApplication,
                            ),
                          )
                        : null,
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
