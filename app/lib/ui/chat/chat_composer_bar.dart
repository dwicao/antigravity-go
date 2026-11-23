import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../state/update_state.dart';
import '../../theme/app_theme.dart';
import '../cli/cli_manager_page.dart';
import '../harness/harness_page.dart';
import '../update/update_sheet.dart';

class ChatPickerPill<T> extends StatelessWidget {
  const ChatPickerPill({
    super.key,
    required this.icon,
    required this.label,
    required this.items,
    required this.onSelected,
  });

  final IconData icon;
  final String label;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<T>(
      onSelected: onSelected,
      itemBuilder: (_) => items,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 5),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }
}

class ChatComposerBar extends ConsumerWidget {
  const ChatComposerBar({
    super.key,
    required this.inputController,
    required this.isBusy,
    required this.isStreamingCurrentSession,
    required this.listeningVoice,
    required this.isDesktopMode,
    required this.enterToSend,
    required this.ctxSnap,
    required this.onKeyEvent,
    required this.onChanged,
    required this.onPickFile,
    required this.onPickImage,
    required this.onDictateVoice,
    required this.onTriggerSlash,
    required this.onSubmit,
    required this.onSteerSubmit,
    required this.onToggleEnterToSend,
  });

  final TextEditingController inputController;
  final bool isBusy;
  final bool isStreamingCurrentSession;
  final bool listeningVoice;
  final bool isDesktopMode;
  final bool enterToSend;
  final ContextBudgetSnapshot ctxSnap;
  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;
  final ValueChanged<String> onChanged;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback onDictateVoice;
  final VoidCallback onTriggerSlash;
  final VoidCallback onSubmit;
  final VoidCallback onSteerSubmit;
  final ValueChanged<bool> onToggleEnterToSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final settings = ref.watch(settingsProvider);
    final hosts = ref.watch(hostsProvider);
    final activeModel = AgyModelCatalog.resolve(settings.selectedModelId);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.85),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.45),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Attach or CLI tools',
                    padding: EdgeInsets.zero,
                    onSelected: (action) {
                      switch (action) {
                        case 'file':
                          onPickFile();
                        case 'image':
                          onPickImage();
                        case 'voice':
                          if (!listeningVoice) onDictateVoice();
                        case 'slash':
                          onTriggerSlash();
                        case 'cli':
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const CliManagerPage(),
                            ),
                          );
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'file',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.attach_file),
                          title: Text('Attach file'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'image',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.image_outlined),
                          title: Text('Attach image'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'voice',
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            listeningVoice ? Icons.mic : Icons.mic_none,
                          ),
                          title: const Text('Voice input'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'slash',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.code),
                          title: Text('Slash commands (/)'),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'cli',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.terminal),
                          title: Text('Antigravity CLI & Flags'),
                        ),
                      ),
                    ],
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        listeningVoice ? Icons.mic : Icons.add_rounded,
                        size: 20,
                        color: listeningVoice
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Focus(
                      onKeyEvent: onKeyEvent,
                      child: TextField(
                        controller: inputController,
                        onChanged: onChanged,
                        minLines: 1,
                        maxLines: isDesktopMode ? 8 : 5,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          hintMaxLines: 1,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 8,
                          ),
                          hintText: isBusy
                              ? 'Queue message (or Steer)…'
                              : isDesktopMode && enterToSend
                                  ? 'Ask anything, @ file, / command (Enter sends)'
                                  : 'Ask anything, @ file, / command…',
                        ),
                      ),
                    ),
                  ),
                  if (isBusy) ...[
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      tooltip: 'Stop (Esc)',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: () {
                        if (isStreamingCurrentSession) {
                          ref.read(chatProvider.notifier).stopStreaming();
                        } else {
                          ref.read(chatProvider.notifier).forceStopAllTasks();
                        }
                      },
                      icon: const Icon(Icons.stop_rounded, size: 19),
                    ),
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      tooltip: 'Steer (force send now)',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      onPressed: onSteerSubmit,
                      icon: const Icon(Icons.bolt_rounded, size: 19),
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton.filled(
                    tooltip: isBusy ? 'Queue' : 'Send',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    onPressed: onSubmit,
                    icon: Icon(
                      isBusy
                          ? Icons.schedule_send_rounded
                          : Icons.arrow_upward_rounded,
                      size: 19,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  ChatPickerPill<String>(
                    icon: Icons.auto_awesome,
                    label: activeModel.displayName,
                    items: AgyModelCatalog.builtIn
                        .map(
                          (m) => PopupMenuItem(
                            value: m.id,
                            child: Text(m.displayName),
                          ),
                        )
                        .toList(),
                    onSelected: (v) =>
                        ref.read(settingsProvider.notifier).setModel(v),
                  ),
                  if (activeModel.supportsEffort) ...[
                    const SizedBox(width: 6),
                    ChatPickerPill<String>(
                      icon: Icons.psychology_outlined,
                      label: ReasoningEffort.fromString(
                        settings.reasoningEffort,
                      ).label,
                      items: activeModel.availableEfforts
                          .map(
                            (e) => PopupMenuItem(
                              value: e.cliValue,
                              child: Text(e.label),
                            ),
                          )
                          .toList(),
                      onSelected: (v) =>
                          ref.read(settingsProvider.notifier).setEffort(v),
                    ),
                  ],
                  const SizedBox(width: 6),
                  ChatPickerPill<AntigravityPermissionPreset>(
                    icon: Icons.shield_outlined,
                    label: settings.permissionPreset.label,
                    items: AntigravityPermissionPreset.values
                        .where(
                          (p) =>
                              hosts.activeSshHost != null ||
                              p != AntigravityPermissionPreset.auto,
                        )
                        .map(
                          (p) => PopupMenuItem(
                            value: p,
                            child: Text('${p.label} — ${p.description}'),
                          ),
                        )
                        .toList(),
                    onSelected: (p) => ref
                        .read(settingsProvider.notifier)
                        .setPermissionPreset(p),
                  ),
                  const SizedBox(width: 6),
                  ChatPickerPill<String>(
                    icon: Icons.tune,
                    label:
                        AgyExecutionMode.fromCli(settings.executionMode).label,
                    items: AgyExecutionMode.values
                        .where(
                          (m) =>
                              hosts.activeSshHost != null ||
                              m != AgyExecutionMode.auto,
                        )
                        .map(
                          (m) => PopupMenuItem(
                            value: m.cliValue,
                            child: Text(m.label),
                          ),
                        )
                        .toList(),
                    onSelected: (v) => ref
                        .read(settingsProvider.notifier)
                        .setExecutionMode(v),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message:
                        '~${ctxSnap.usedTokens} / ${ctxSnap.budgetTokens} tokens (${ctxSnap.statusLabel}) — tap for Harness & /compact',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const HarnessPage(),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: ctxSnap.shouldCompact
                              ? theme.colorScheme.errorContainer
                              : ctxSnap.needsWarning
                                  ? semantic.warningContainer
                                  : theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.engineering_outlined,
                              size: 13,
                              color: ctxSnap.shouldCompact
                                  ? theme.colorScheme.onErrorContainer
                                  : ctxSnap.needsWarning
                                      ? semantic.onWarningContainer
                                      : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${ctxSnap.percentage}% ctx',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: ctxSnap.shouldCompact
                                    ? theme.colorScheme.onErrorContainer
                                    : ctxSnap.needsWarning
                                        ? semantic.onWarningContainer
                                        : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isDesktopMode) ...[
                    const SizedBox(width: 8),
                    FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text('Enter sends'),
                      selected: enterToSend,
                      onSelected: onToggleEnterToSend,
                    ),
                  ],
                  if (settings.activeAgent.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.smart_toy_outlined, size: 14),
                      label: Text('@${settings.activeAgent}'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CliManagerPage(),
                        ),
                      ),
                    ),
                  ],
                  if (ref.watch(appUpdateProvider).hasNewerVersion) ...[
                    const SizedBox(width: 6),
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(
                        Icons.system_update_alt,
                        size: 14,
                      ),
                      label: Text(
                        'Update ${ref.watch(appUpdateProvider).latest!.tagName}',
                      ),
                      onPressed: () => UpdateSheet.show(context),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
