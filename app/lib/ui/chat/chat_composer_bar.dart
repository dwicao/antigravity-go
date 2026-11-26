import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/custom_providers_state.dart';
import '../../state/harness_state.dart';
import '../../state/hosts_state.dart';
import '../../state/settings_state.dart';
import '../../state/update_state.dart';
import '../../theme/app_theme.dart';
import '../cli/cli_manager_page.dart';
import '../harness/harness_page.dart';
import '../remote/custom_providers_page.dart';
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withOpacity(0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: theme.colorScheme.primary),
            const SizedBox(width: 5),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 15,
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
    this.onPasteClipboardImage,
    this.onContentInserted,
    required this.onDictateVoice,
    required this.onTriggerSlash,
    required this.onSubmit,
    required this.onSteerSubmit,
    required this.onToggleEnterToSend,
    this.nextTurnEffortOverride,
    this.onEffortOverrideChanged,
    this.hasAttachments = false,
    this.sessionToolCalls = 0,
    this.sessionChangedFiles = 0,
    this.sessionHasRecentFailure = false,
    this.previousTurnEffort,
  });

  final TextEditingController inputController;
  final bool isBusy;
  final bool isStreamingCurrentSession;
  final bool listeningVoice;
  final bool isDesktopMode;
  final bool enterToSend;
  final HarnessContextSnapshot ctxSnap;
  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;
  final ValueChanged<String> onChanged;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback? onPasteClipboardImage;
  final ValueChanged<KeyboardInsertedContent>? onContentInserted;
  final VoidCallback onDictateVoice;
  final VoidCallback onTriggerSlash;
  final VoidCallback onSubmit;
  final VoidCallback onSteerSubmit;
  final ValueChanged<bool> onToggleEnterToSend;
  final String? nextTurnEffortOverride;
  final ValueChanged<String?>? onEffortOverrideChanged;
  final bool hasAttachments;
  final int sessionToolCalls;
  final int sessionChangedFiles;
  final bool sessionHasRecentFailure;
  final String? previousTurnEffort;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final settings = ref.watch(settingsProvider);
    final smartRoutingEnabled = ref.watch(
      harnessProvider.select((h) => h.smartRoutingEnabled),
    );
    final hosts = ref.watch(hostsProvider);
    final customState = ref.watch(customProvidersProvider);
    final activeCustom = customState.activeProfile;
    final activeModel = AgyModelCatalog.resolve(settings.selectedModelId);
    final allowSshSandbox = hosts.activeSshHost != null;
    final activeComposerMode = AgentComposerMode.resolve(
      preset: settings.permissionPreset,
      executionMode: settings.executionMode,
      allowSshSandbox: allowSshSandbox,
    );
    final visibleComposerModes = AgentComposerMode.values
        .where((m) => allowSshSandbox || m != AgentComposerMode.autoSandbox)
        .toList();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.92),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.55),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox(
                    width: 36,
                    height: 36,
                    child: PopupMenuButton<String>(
                    tooltip: 'Attach or CLI tools',
                    padding: EdgeInsets.zero,
                    onSelected: (action) {
                      switch (action) {
                        case 'file':
                          onPickFile();
                        case 'image':
                          onPickImage();
                        case 'paste_image':
                          onPasteClipboardImage?.call();
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
                      if (onPasteClipboardImage != null)
                        const PopupMenuItem(
                          value: 'paste_image',
                          child: ListTile(
                            dense: true,
                            leading: Icon(Icons.content_paste_rounded),
                            title: Text('Paste clipboard image'),
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
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 36),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Focus(
                          onKeyEvent: onKeyEvent,
                          child: TextField(
                            controller: inputController,
                            onChanged: onChanged,
                            minLines: 1,
                            maxLines: isDesktopMode ? 8 : 5,
                            textAlignVertical: TextAlignVertical.center,
                            textInputAction: TextInputAction.newline,
                            contentInsertionConfiguration:
                                onContentInserted == null
                                    ? null
                                    : ContentInsertionConfiguration(
                                        allowedMimeTypes: const [
                                          'image/png',
                                          'image/jpeg',
                                          'image/webp',
                                          'image/gif',
                                          'image/*',
                                        ],
                                        onContentInserted: onContentInserted!,
                                      ),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              hintMaxLines: 1,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 2,
                                vertical: 6,
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
                    ),
                  ),
                  if (isBusy) ...[
                    const SizedBox(width: 4),
                    IconButton.filledTonal(
                      tooltip: 'Stop (Esc)',
                      padding: EdgeInsets.zero,
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
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
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
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
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
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
                    icon: activeCustom != null ? Icons.hub_outlined : Icons.auto_awesome,
                    label: activeCustom != null
                        ? '${activeCustom.name} (${activeCustom.modelId})'
                        : activeModel.displayName,
                    items: [
                      for (final m in AgyModelCatalog.builtIn)
                        PopupMenuItem(
                          value: 'builtin:${m.id}',
                          child: Text(m.displayName),
                        ),
                      if (customState.profiles.isNotEmpty) const PopupMenuDivider(),
                      for (final p in customState.profiles)
                        PopupMenuItem(
                          value: 'custom:${p.id}',
                          child: Row(
                            children: [
                              const Icon(Icons.hub_outlined, size: 15),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '${p.name} · ${p.modelId}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'manage_custom',
                        child: Row(
                          children: [
                            Icon(Icons.add_circle_outline, size: 15),
                            SizedBox(width: 6),
                            Text('Configure External /v1 Models…'),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (v) async {
                      if (v == 'manage_custom') {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const CustomProvidersPage(),
                          ),
                        );
                      } else if (v.startsWith('custom:')) {
                        await ref
                            .read(customProvidersProvider.notifier)
                            .selectProvider(v.substring(7));
                      } else if (v.startsWith('builtin:')) {
                        await ref
                            .read(customProvidersProvider.notifier)
                            .selectProvider(null);
                        await ref
                            .read(settingsProvider.notifier)
                            .setModel(v.substring(8));
                      }
                    },
                  ),
                  if (activeCustom == null && activeModel.supportsEffort) ...[
                    const SizedBox(width: 6),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: inputController,
                      builder: (context, textVal, _) {
                        final inline =
                            HarnessTurnRouter.extractInlineEffortOverride(
                          textVal.text,
                        );
                        final autoRoute = HarnessTurnRouter.routeTurn(
                          prompt: textVal.text,
                          selectedModelId: settings.selectedModelId,
                          selectedEffort: settings.reasoningEffort,
                          speedTierName: settings.speedTier.name,
                          smartRoutingEnabled: smartRoutingEnabled,
                          hasAttachments: hasAttachments,
                          sessionToolCalls: sessionToolCalls,
                          sessionChangedFiles: sessionChangedFiles,
                          sessionHasRecentFailure: sessionHasRecentFailure,
                          previousTurnEffort: previousTurnEffort,
                        );
                        final effectiveLabel =
                            ReasoningEffort.fromString(autoRoute.effort).label;
                        final pinned = nextTurnEffortOverride != null &&
                            nextTurnEffortOverride!.isNotEmpty;
                        final pillLabel = pinned
                            ? 'Pin · ${ReasoningEffort.fromString(nextTurnEffortOverride!).label}'
                            : inline.effortOverride != null
                                ? 'Tag · $effectiveLabel'
                                : smartRoutingEnabled
                                    ? (textVal.text.trim().isEmpty &&
                                            !hasAttachments &&
                                            sessionToolCalls == 0 &&
                                            !sessionHasRecentFailure
                                        ? 'Auto'
                                        : 'Auto · $effectiveLabel')
                                    : ReasoningEffort.fromString(
                                        settings.reasoningEffort,
                                      ).label;
                        final pillIcon = pinned
                            ? Icons.push_pin_rounded
                            : Icons.psychology_outlined;

                        return ChatPickerPill<String>(
                          icon: pillIcon,
                          label: pillLabel,
                          items: smartRoutingEnabled
                              ? [
                                  PopupMenuItem<String>(
                                    value: '__auto__',
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.auto_awesome_rounded,
                                          size: 15,
                                          color: theme.colorScheme.primary,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Auto ($effectiveLabel)',
                                            style: TextStyle(
                                              fontWeight: !pinned
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        if (!pinned)
                                          Icon(
                                            Icons.check_rounded,
                                            size: 16,
                                            color: theme.colorScheme.primary,
                                          ),
                                      ],
                                    ),
                                  ),
                                  const PopupMenuDivider(height: 6),
                                  ...activeModel.availableEfforts.map(
                                    (e) => PopupMenuItem<String>(
                                      value: e.cliValue,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              '${e.label} (next message)',
                                              style: TextStyle(
                                                fontWeight:
                                                    nextTurnEffortOverride ==
                                                            e.cliValue
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                          if (nextTurnEffortOverride ==
                                              e.cliValue)
                                            Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: theme.colorScheme.primary,
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ]
                              : activeModel.availableEfforts
                                  .map(
                                    (e) => PopupMenuItem<String>(
                                      value: e.cliValue,
                                      child: Row(
                                        children: [
                                          Expanded(child: Text(e.label)),
                                          if (settings.reasoningEffort ==
                                              e.cliValue)
                                            Icon(
                                              Icons.check_rounded,
                                              size: 16,
                                              color: theme.colorScheme.primary,
                                            ),
                                        ],
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onSelected: (v) {
                            if (smartRoutingEnabled &&
                                onEffortOverrideChanged != null) {
                              onEffortOverrideChanged!(
                                v == '__auto__' ? null : v,
                              );
                            } else if (v != '__auto__') {
                              ref.read(settingsProvider.notifier).setEffort(v);
                            }
                          },
                        );
                      },
                    ),
                  ],
                  const SizedBox(width: 6),
                  ChatPickerPill<AgentComposerMode>(
                    icon: _composerModeIcon(activeComposerMode),
                    label: activeComposerMode.label,
                    items: visibleComposerModes
                        .map(
                          (m) => PopupMenuItem<AgentComposerMode>(
                            value: m,
                            child: Row(
                              children: [
                                Icon(
                                  _composerModeIcon(m),
                                  size: 16,
                                  color: m == activeComposerMode
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        m.label,
                                        style: theme.textTheme.labelLarge?.copyWith(
                                          fontWeight: m == activeComposerMode
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                        ),
                                      ),
                                      Text(
                                        m.description,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          fontSize: 11,
                                          color: theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (m == activeComposerMode) ...[
                                  const SizedBox(width: 6),
                                  Icon(
                                    Icons.check_rounded,
                                    size: 16,
                                    color: theme.colorScheme.primary,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onSelected: (m) => ref
                        .read(settingsProvider.notifier)
                        .setAgentComposerMode(m),
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
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                value: (ctxSnap.percentage / 100.0).clamp(0.0, 1.0),
                                strokeWidth: 2.2,
                                backgroundColor: (ctxSnap.shouldCompact
                                        ? theme.colorScheme.onErrorContainer
                                        : ctxSnap.needsWarning
                                            ? semantic.onWarningContainer
                                            : theme.colorScheme.onSurfaceVariant)
                                    .withOpacity(0.22),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  ctxSnap.shouldCompact
                                      ? theme.colorScheme.onErrorContainer
                                      : ctxSnap.needsWarning
                                          ? semantic.onWarningContainer
                                          : theme.colorScheme.primary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
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

  static IconData _composerModeIcon(AgentComposerMode mode) {
    return switch (mode) {
      AgentComposerMode.autoDev => Icons.bolt_rounded,
      AgentComposerMode.acceptEdits => Icons.edit_note_rounded,
      AgentComposerMode.standard => Icons.shield_outlined,
      AgentComposerMode.planOnly => Icons.architecture_rounded,
      AgentComposerMode.autoSandbox => Icons.dns_outlined,
    };
  }
}
