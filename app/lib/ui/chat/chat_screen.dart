import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/auth_state.dart';
import '../../state/chat_state.dart';
import '../../state/draft_store.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/side_panel_state.dart';
import '../auth/google_login_sheet.dart';
import '../shell/background_tasks_sheet.dart';
import '../shell/command_palette.dart';
import '../usage/usage_page.dart';
import 'message_bubble.dart';
import 'tool_approval_card.dart';

const _slashCommands = <(String cmd, String desc)>[
  ('/plan', 'Explore codebase and draft an implementation plan'),
  ('/goal', 'Run autonomously until objective is verified complete'),
  ('/boost', 'Multi-agent deep reasoning loop'),
  ('/swarm', 'Coordinate a swarm of named workers'),
  ('/teamwork', 'Launch collaborative multi-agent team'),
  ('/compact', 'Summarize conversation to free context'),
  ('/usage', 'Inspect 5-hour & weekly model quotas'),
  ('/model', 'Switch active reasoning model'),
  ('/diff', 'Review code changes and diffs'),
  ('/clear', 'Clear current conversation'),
];

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({
    super.key,
    this.isDesktopMode = false,
    this.onOpenSessions,
    this.onOpenQuickPanel,
  });

  final bool isDesktopMode;
  final VoidCallback? onOpenSessions;
  final VoidCallback? onOpenQuickPanel;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  static const _voiceChannel = MethodChannel('agy/voice');

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<String> _attachments = [];
  List<Map<String, String>> _mentionFiles = const [];
  bool _showSlashMenu = false;
  bool _showMentionMenu = false;
  bool _listeningVoice = false;
  bool _enterToSend = true;
  String? _draftSessionId;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String val) async {
    final sessionId =
        ref.read(sessionsProvider).activeSessionId ?? 'new_session';
    ref.read(draftStoreProvider.notifier).save(sessionId, val);

    final wantSlash = val.startsWith('/') && !val.contains(' ');
    final atIndex = val.lastIndexOf('@');
    final wantMention =
        atIndex >= 0 && !val.substring(atIndex).contains(' ') && !wantSlash;

    if (wantMention && !_showMentionMenu) {
      final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
      final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      final files = await RuntimeBridge.instance.listWorkspaceEntries(
        projDir.isNotEmpty ? projDir : fallback,
      );
      if (mounted) {
        setState(() {
          _mentionFiles = files;
          _showMentionMenu = true;
          _showSlashMenu = false;
        });
      }
      return;
    }

    if (wantSlash != _showSlashMenu || wantMention != _showMentionMenu) {
      setState(() {
        _showSlashMenu = wantSlash;
        _showMentionMenu = wantMention;
      });
    }
  }

  Future<void> _submit() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    if (text == '/usage' || text == '/quota') {
      _inputController.clear();
      setState(() {
        _showSlashMenu = false;
        _showMentionMenu = false;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const UsagePage()),
      );
      return;
    }

    if (text == '/diff') {
      _inputController.clear();
      setState(() => _showSlashMenu = false);
      ref.read(sidePanelProvider.notifier).openTab(
            const SidePanelTab(
              id: 'review',
              kind: SidePanelTabKind.review,
              title: 'Review',
            ),
          );
      return;
    }

    if (text == '/clear') {
      _inputController.clear();
      setState(() => _showSlashMenu = false);
      await ref.read(chatProvider.notifier).clearCurrentThread();
      return;
    }

    final files = List<String>.from(_attachments);
    final sessionId =
        ref.read(sessionsProvider).activeSessionId ?? 'new_session';
    ref.read(draftStoreProvider.notifier).clear(sessionId);
    _inputController.clear();
    setState(() {
      _attachments.clear();
      _showSlashMenu = false;
      _showMentionMenu = false;
    });
    await ref.read(chatProvider.notifier).sendPrompt(text, attachments: files);
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    setState(() {
      for (final f in files) {
        if (f.path != null) _attachments.add(f.path!);
      }
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery);
    if (img == null) return;
    setState(() => _attachments.add(img.path));
  }

  Future<void> _dictateVoice() async {
    setState(() => _listeningVoice = true);
    try {
      final spoken = await _voiceChannel.invokeMethod<String>('dictate');
      if (spoken != null && spoken.isNotEmpty) {
        final cur = _inputController.text;
        _inputController.text = cur.isEmpty ? spoken : '$cur $spoken';
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice dictation unavailable on device')),
        );
      }
    } finally {
      if (mounted) setState(() => _listeningVoice = false);
    }
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (!widget.isDesktopMode || !_enterToSend) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final shiftHeld = keys.contains(LogicalKeyboardKey.shiftLeft) ||
          keys.contains(LogicalKeyboardKey.shiftRight);
      if (!shiftHeld) {
        _submit();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider);
    final auth = ref.watch(authProvider);
    final hosts = ref.watch(hostsProvider);
    final project = ref.watch(projectsProvider).activeProject;
    final runtime = ref.watch(runtimeProvider);
    final settings = ref.watch(settingsProvider);
    final perms = ref.watch(permissionsProvider);
    final sidePanel = ref.watch(sidePanelProvider);
    final activeSessionId =
        ref.watch(sessionsProvider.select((s) => s.activeSessionId)) ??
            'new_session';
    if (_draftSessionId != activeSessionId) {
      _draftSessionId = activeSessionId;
      final savedDraft =
          ref.read(draftStoreProvider.notifier).draftFor(activeSessionId);
      if (_inputController.text != savedDraft) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _inputController.text = savedDraft;
          _inputController.selection =
              TextSelection.collapsed(offset: savedDraft.length);
        });
      }
    }
    final theme = Theme.of(context);

    final activeModel = AgyModelCatalog.resolve(settings.selectedModelId);
    final hostLabel = hosts.activeSshHost?.name ?? 'On Device';

    Widget wrapCentered(Widget child) {
      if (!widget.isDesktopMode) return child;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: child,
        ),
      );
    }

    return Column(
      children: [
        AppBar(
          leading: widget.onOpenSessions != null
              ? IconButton(
                  tooltip: widget.isDesktopMode
                      ? 'Toggle Sidebar (Ctrl+B)'
                      : 'Sessions & Projects',
                  onPressed: widget.onOpenSessions,
                  icon: Icon(
                    widget.isDesktopMode
                        ? Icons.view_sidebar_outlined
                        : Icons.menu,
                  ),
                )
              : null,
          title: Row(
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '$hostLabel · ${activeModel.displayName}',
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (perms.isDexMode) ...[
                const SizedBox(width: 8),
                const Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(Icons.desktop_windows_outlined, size: 14),
                  label: Text('DeX'),
                ),
              ],
            ],
          ),
          actions: [
            const BackgroundTasksAppBarPill(),
            IconButton(
              tooltip: 'Command Palette (Ctrl+K)',
              onPressed: () => CommandPaletteDialog.show(context),
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: 'Toggle Side Panel (Ctrl+Shift+B)',
              onPressed: () =>
                  ref.read(sidePanelProvider.notifier).toggleSidePanel(),
              icon: Icon(
                sidePanel.showSidePanel
                    ? Icons.vertical_split
                    : Icons.vertical_split_outlined,
                color: sidePanel.showSidePanel
                    ? theme.colorScheme.primary
                    : null,
              ),
            ),
            IconButton(
              tooltip: 'Usage Limits (Ctrl+U)',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const UsagePage()),
              ),
              icon: const Icon(Icons.speed_rounded),
            ),
            IconButton(
              tooltip: auth.isAuthenticated
                  ? (auth.email ?? 'Google Account')
                  : 'Sign in with Google',
              onPressed: () => GoogleLoginSheet.show(context),
              icon: Icon(
                auth.isAuthenticated
                    ? Icons.verified_user
                    : Icons.account_circle_outlined,
                color: auth.isAuthenticated ? Colors.green : null,
              ),
            ),
            if (chat.messages.isNotEmpty)
              IconButton(
                tooltip: 'Share transcript',
                onPressed: () {
                  final md = ref.read(chatProvider.notifier).exportMarkdown();
                  SharePlus.instance.share(ShareParams(text: md));
                },
                icon: const Icon(Icons.ios_share),
              ),
            if (widget.onOpenQuickPanel != null)
              IconButton(
                tooltip: 'Toggle Overview Panel (Ctrl+Alt+O)',
                onPressed: widget.onOpenQuickPanel,
                icon: const Icon(Icons.dashboard_outlined),
              ),
          ],
        ),
        if (!auth.isAuthenticated ||
            (!runtime.status.isReady && hosts.isLocalActive))
          wrapCentered(
            _OnboardingBanner(
              isAuthenticated: auth.isAuthenticated,
              runtimeReady: runtime.status.isReady,
              runtimeBusy: runtime.busy,
              isLocal: hosts.isLocalActive,
              onSignIn: () => GoogleLoginSheet.show(context),
              onInstallRuntime: () =>
                  ref.read(runtimeProvider.notifier).installAndStart(),
            ),
          ),
        Expanded(
          child: chat.messages.isEmpty
              ? _EmptyHero(
                  onPickSuggestion: (s) {
                    _inputController.text = s;
                  },
                )
              : Scrollbar(
                  controller: _scrollController,
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(top: 8, bottom: 16),
                    itemCount: chat.messages.length,
                    itemBuilder: (context, index) {
                      final m = chat.messages[index];
                      final isLastAssistant = !chat.isStreaming &&
                          m.role == ChatRole.assistant &&
                          index == chat.messages.length - 1;
                      return wrapCentered(
                        MessageBubble(
                          message: m,
                          tokensPerSecond:
                              m.isStreaming ? chat.tokensPerSecond : null,
                          onRegenerate: isLastAssistant
                              ? () => ref
                                  .read(chatProvider.notifier)
                                  .regenerateLastTurn()
                              : null,
                          onEditResend:
                              !chat.isStreaming && m.role == ChatRole.user
                                  ? (newText) => ref
                                      .read(chatProvider.notifier)
                                      .editAndResend(m.id, newText)
                                  : null,
                        ),
                      );
                    },
                  ),
                ),
        ),
        if (chat.stallWarning != null)
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withOpacity(0.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.hourglass_bottom,
                      size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chat.stallWarning!,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        wrapCentered(const BackgroundTasksBanner()),
        if (chat.pendingPermission != null)
          wrapCentered(
            ToolApprovalCard(
              request: chat.pendingPermission!,
              onSelectOption: (id) =>
                  ref.read(chatProvider.notifier).resolvePermission(id),
            ),
          ),
        if (chat.queuedPrompts.isNotEmpty)
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withOpacity(0.6),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.schedule_send, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Queued (${chat.queuedPrompts.length}): ${chat.queuedPrompts.first}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(chatProvider.notifier).sendQueuedNow(),
                    child: const Text('Steer now'),
                  ),
                  IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Remove queued prompt',
                    onPressed: () =>
                        ref.read(chatProvider.notifier).removeQueuedPrompt(0),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        if (_showSlashMenu)
          wrapCentered(
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Card(
                child: ListView(
                  shrinkWrap: true,
                  children: _slashCommands
                      .where((c) => c.$1.startsWith(_inputController.text))
                      .map(
                        (c) => ListTile(
                          dense: true,
                          title: Text(
                            c.$1,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(c.$2),
                          onTap: () {
                            _inputController.text = '${c.$1} ';
                            _inputController.selection = TextSelection.collapsed(
                              offset: _inputController.text.length,
                            );
                            setState(() => _showSlashMenu = false);
                          },
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        if (_showMentionMenu && _mentionFiles.isNotEmpty)
          wrapCentered(
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Card(
                child: ListView(
                  shrinkWrap: true,
                  children: _mentionFiles.take(12).map((f) {
                    final name = f['name'] ?? '';
                    final path = f['path'] ?? '';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        f['type'] == 'dir'
                            ? Icons.folder
                            : Icons.insert_drive_file_outlined,
                        size: 16,
                      ),
                      title: Text('@$name'),
                      subtitle: Text(path, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        final text = _inputController.text;
                        final idx = text.lastIndexOf('@');
                        final next =
                            '${text.substring(0, idx)}@$path ';
                        _inputController.text = next;
                        _inputController.selection =
                            TextSelection.collapsed(offset: next.length);
                        setState(() => _showMentionMenu = false);
                      },
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        if (_attachments.isNotEmpty)
          wrapCentered(
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: _attachments
                    .map(
                      (a) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InputChip(
                          label: Text(a.split('/').last.split('\\').last),
                          onDeleted: () =>
                              setState(() => _attachments.remove(a)),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: wrapCentered(
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach file',
                        onPressed: _pickFile,
                        icon: const Icon(Icons.attach_file),
                      ),
                      IconButton(
                        tooltip: 'Attach image',
                        onPressed: _pickImage,
                        icon: const Icon(Icons.image_outlined),
                      ),
                      Expanded(
                        child: Focus(
                          onKeyEvent: _handleComposerKey,
                          child: TextField(
                            controller: _inputController,
                            onChanged: _onChanged,
                            minLines: 1,
                            maxLines: widget.isDesktopMode ? 8 : 5,
                            textInputAction: TextInputAction.newline,
                            decoration: InputDecoration(
                              hintText: chat.isStreaming
                                  ? 'Queue follow-up or steer agent…'
                                  : widget.isDesktopMode && _enterToSend
                                      ? 'Ask anything, @ to mention, / for commands (Enter sends)'
                                      : 'Ask anything, @ to mention, / for commands…',
                              suffixIcon: IconButton(
                                tooltip: 'Voice input',
                                onPressed:
                                    _listeningVoice ? null : _dictateVoice,
                                icon: Icon(
                                  _listeningVoice ? Icons.mic : Icons.mic_none,
                                  color: _listeningVoice
                                      ? theme.colorScheme.primary
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (chat.isStreaming)
                        IconButton.filledTonal(
                          tooltip: 'Stop (Esc)',
                          onPressed: () =>
                              ref.read(chatProvider.notifier).stopStreaming(),
                          icon: const Icon(Icons.stop_rounded),
                        ),
                      const SizedBox(width: 4),
                      IconButton.filled(
                        tooltip: chat.isStreaming ? 'Queue' : 'Send',
                        onPressed: _submit,
                        icon: const Icon(Icons.arrow_upward_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // 1:1 Antigravity Desktop Inline Composer Bar (Model, Effort, Permission Preset, Mode)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _PickerPill<String>(
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
                          _PickerPill<String>(
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
                            onSelected: (v) => ref
                                .read(settingsProvider.notifier)
                                .setEffort(v),
                          ),
                        ],
                        const SizedBox(width: 6),
                        _PickerPill<AntigravityPermissionPreset>(
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
                        _PickerPill<String>(
                          icon: Icons.tune,
                          label: AgyExecutionMode.fromCli(
                            settings.executionMode,
                          ).label,
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
                        if (widget.isDesktopMode) ...[
                          const SizedBox(width: 8),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text('Enter sends'),
                            selected: _enterToSend,
                            onSelected: (v) =>
                                setState(() => _enterToSend = v),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PickerPill<T> extends StatelessWidget {
  const _PickerPill({
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

class _OnboardingBanner extends StatelessWidget {
  const _OnboardingBanner({
    required this.isAuthenticated,
    required this.runtimeReady,
    required this.runtimeBusy,
    required this.isLocal,
    required this.onSignIn,
    required this.onInstallRuntime,
  });

  final bool isAuthenticated;
  final bool runtimeReady;
  final bool runtimeBusy;
  final bool isLocal;
  final VoidCallback onSignIn;
  final VoidCallback onInstallRuntime;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            !runtimeReady && isLocal ? Icons.terminal : Icons.account_circle,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              !runtimeReady && isLocal
                  ? 'Install the on-device `agy` harness to run Antigravity agents on Android.'
                  : 'Sign in with your Google Account to run Antigravity AI agents & view quotas.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (!runtimeReady && isLocal)
            FilledButton.tonal(
              onPressed: runtimeBusy ? null : onInstallRuntime,
              child: Text(runtimeBusy ? 'Installing…' : 'Install agy'),
            )
          else if (!isAuthenticated)
            FilledButton.tonal(
              onPressed: onSignIn,
              child: const Text('Google Sign-In'),
            ),
        ],
      ),
    );
  }
}

class _EmptyHero extends StatelessWidget {
  const _EmptyHero({required this.onPickSuggestion});

  final ValueChanged<String> onPickSuggestion;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const suggestions = [
      '/plan Audit this project and propose improvements',
      '/goal Write unit tests and verify everything passes',
      'Check git status and summarize recent changes',
      '/boost Analyze performance bottlenecks in the codebase',
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              'Antigravity in your pocket',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Run AI agents on your phone or control your computer over SSH — with your Google Account & live 5h/weekly quota tracking.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: suggestions
                  .map(
                    (s) => ActionChip(
                      label: Text(s),
                      onPressed: () => onPickSuggestion(s),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
