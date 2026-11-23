import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/auth_state.dart';
import '../../state/background_tasks_state.dart';
import '../../state/chat_state.dart';
import '../../state/draft_store.dart';
import '../../state/harness_state.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/side_panel_state.dart';
import '../../state/update_state.dart';
import '../auth/google_login_sheet.dart';
import '../cli/cli_manager_page.dart';
import '../harness/harness_page.dart';
import '../settings/settings_page.dart';
import '../shell/background_tasks_sheet.dart';
import '../shell/command_palette.dart';
import '../update/update_sheet.dart';
import '../usage/usage_page.dart';
import 'message_bubble.dart';
import 'tool_approval_card.dart';

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
  bool _showJumpToBottom = false;
  String? _draftSessionId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final distFromBottom = pos.maxScrollExtent - pos.pixels;
    final show = distFromBottom > 120;
    if (show != _showJumpToBottom && mounted) {
      setState(() => _showJumpToBottom = show);
    }
  }

  void _jumpToBottom({bool animate = true}) {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    if (animate) {
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
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

    if (wantSlash ||
        wantMention ||
        wantSlash != _showSlashMenu ||
        wantMention != _showMentionMenu) {
      setState(() {
        _showSlashMenu = wantSlash;
        _showMentionMenu = wantMention;
      });
    }
  }

  Future<void> _submit() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    final firstWord = text.split(RegExp(r'\s+')).first.toLowerCase();

    if (firstWord == '/usage' || firstWord == '/quota') {
      _clearInputMenus();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const UsagePage()),
      );
      return;
    }

    if (firstWord == '/compact') {
      _clearInputMenus();
      final instructions = text.length > firstWord.length
          ? text.substring(firstWord.length).trim()
          : null;
      final res = await ref.read(chatProvider.notifier).compactThread(
            instructions: instructions,
          );
      if (!res.ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res.message)),
        );
      }
      return;
    }

    if (firstWord == '/context' || firstWord == '/harness') {
      _clearInputMenus();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const HarnessPage()),
      );
      return;
    }

    if (firstWord == '/rewind' || firstWord == '/undo') {
      _clearInputMenus();
      await _handleRewind('__latest__');
      return;
    }

    if (firstWord == '/diff') {
      _clearInputMenus();
      ref.read(sidePanelProvider.notifier).openTab(
            const SidePanelTab(
              id: 'review',
              kind: SidePanelTabKind.review,
              title: 'Review',
            ),
          );
      return;
    }

    if (firstWord == '/clear' || firstWord == '/new') {
      _clearInputMenus();
      await ref.read(chatProvider.notifier).clearCurrentThread();
      return;
    }

    if (firstWord == '/config' ||
        firstWord == '/settings' ||
        firstWord == '/permissions') {
      _clearInputMenus();
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
      );
      return;
    }

    if (firstWord == '/mcp' ||
        firstWord == '/plugin' ||
        firstWord == '/agents' ||
        firstWord == '/changelog') {
      _clearInputMenus();
      final sub = switch (firstWord) {
        '/mcp' => 'mcp',
        '/plugin' => 'plugin',
        '/agents' => 'agent',
        '/changelog' => 'changelog',
        _ => null,
      };
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CliManagerPage(initialSubcommand: sub),
        ),
      );
      return;
    }

    if (firstWord == '/export') {
      _clearInputMenus();
      final md = ref.read(chatProvider.notifier).exportMarkdown();
      await SharePlus.instance.share(ShareParams(text: md));
      return;
    }

    if (firstWord == '/fork' || firstWord == '/branch') {
      _clearInputMenus();
      final prev = ref.read(sessionsProvider).activeSession;
      final branched = await ref.read(sessionsProvider.notifier).createSession(
            title: prev != null ? '${prev.title} (fork)' : 'Forked session',
          );
      await ref.read(chatProvider.notifier).appendSystemFeedback(
            'Branched into new conversation **${branched.title}**.',
          );
      return;
    }

    if (firstWord == '/model' && text.length > 6) {
      final arg = text.substring(6).trim();
      final match = AgyModelCatalog.builtIn.where(
        (m) =>
            m.id.toLowerCase() == arg.toLowerCase() ||
            m.displayName.toLowerCase().contains(arg.toLowerCase()),
      );
      if (match.isNotEmpty) {
        _clearInputMenus();
        await ref.read(settingsProvider.notifier).setModel(match.first.id);
        await ref.read(chatProvider.notifier).appendSystemFeedback(
              'Switched active model to **${match.first.displayName}**.',
            );
        return;
      }
    }

    if (firstWord == '/help' || firstWord == '/?') {
      _clearInputMenus();
      final buf = StringBuffer('### Antigravity CLI Slash Commands\n');
      for (final cmd in AgyCliCatalog.slashCommands) {
        final hint = cmd.argHint != null ? ' `${cmd.argHint}`' : '';
        buf.writeln('- `${cmd.command}`$hint — ${cmd.description}');
      }
      buf.writeln('\n### Supported CLI Subcommands');
      for (final sub in AgyCliCatalog.subcommands) {
        buf.writeln('- `agy ${sub.name}` — ${sub.summary}');
      }
      await ref.read(chatProvider.notifier).appendSystemFeedback(buf.toString());
      return;
    }

    final files = List<String>.from(_attachments);
    _clearInputMenus(clearAttachments: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    await ref.read(chatProvider.notifier).sendPrompt(text, attachments: files);
  }

  void _clearInputMenus({bool clearAttachments = false}) {
    final sessionId =
        ref.read(sessionsProvider).activeSessionId ?? 'new_session';
    ref.read(draftStoreProvider.notifier).clear(sessionId);
    _inputController.clear();
    setState(() {
      if (clearAttachments) _attachments.clear();
      _showSlashMenu = false;
      _showMentionMenu = false;
    });
  }

  Future<void> _handleRewind(String userMessageId) async {
    final res =
        await ref.read(chatProvider.notifier).rewindToMessage(userMessageId);
    if (!mounted) return;
    if (res.ok && res.restoredPrompt != null && res.restoredPrompt!.isNotEmpty) {
      _inputController.text = res.restoredPrompt!;
      _inputController.selection = TextSelection.collapsed(
        offset: _inputController.text.length,
      );
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.message)),
    );
  }

  Future<void> _steerSubmit() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) {
      if (ref.read(chatProvider).queuedPrompts.isNotEmpty) {
        await ref.read(chatProvider.notifier).sendQueuedNow();
      }
      return;
    }
    final sessionId =
        ref.read(sessionsProvider).activeSessionId ?? 'new_session';
    ref.read(draftStoreProvider.notifier).clear(sessionId);
    _inputController.clear();
    setState(() {
      _attachments.clear();
      _showSlashMenu = false;
      _showMentionMenu = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    await ref.read(chatProvider.notifier).steerNow(text);
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
    final bgTasks = ref.watch(backgroundTasksProvider);
    final hasRunningBg =
        bgTasks.any((t) => t.kind != BackgroundTaskKind.queued);
    final isBusyOrBg = chat.isStreaming || hasRunningBg;
    final auth = ref.watch(authProvider);
    final hosts = ref.watch(hostsProvider);
    final ctxSnap = ref.watch(contextBudgetProvider);
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
    final isNarrow = MediaQuery.sizeOf(context).width < 520;

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
            if (!isNarrow) ...[
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
            ] else ...[
              PopupMenuButton<String>(
                tooltip: 'More actions',
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case 'palette':
                      CommandPaletteDialog.show(context);
                    case 'usage':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const UsagePage()),
                      );
                    case 'harness':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const HarnessPage()),
                      );
                    case 'account':
                      GoogleLoginSheet.show(context);
                    case 'cli':
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const CliManagerPage()),
                      );
                    case 'overview':
                      widget.onOpenQuickPanel?.call();
                    case 'side':
                      ref.read(sidePanelProvider.notifier).toggleSidePanel();
                    case 'share':
                      final md =
                          ref.read(chatProvider.notifier).exportMarkdown();
                      SharePlus.instance.share(ShareParams(text: md));
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'palette',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.search),
                      title: Text('Command Palette'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'usage',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.speed_rounded),
                      title: Text('Usage Limits'),
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'harness',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.engineering_outlined),
                      title: Text('Harness Engineering'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'account',
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        auth.isAuthenticated
                            ? Icons.verified_user
                            : Icons.account_circle_outlined,
                      ),
                      title: Text(
                        auth.isAuthenticated ? 'Google Account' : 'Sign in',
                      ),
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
                  if (widget.onOpenQuickPanel != null)
                    const PopupMenuItem(
                      value: 'overview',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.dashboard_outlined),
                        title: Text('Overview Panel'),
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'side',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.vertical_split_outlined),
                      title: Text('Toggle Side Panel'),
                    ),
                  ),
                  if (chat.messages.isNotEmpty)
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.ios_share),
                        title: Text('Share Transcript'),
                      ),
                    ),
                ],
              ),
            ],
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
              : Stack(
                  children: [
                    NotificationListener<ScrollMetricsNotification>(
                      onNotification: (notification) {
                        final show = (notification.metrics.maxScrollExtent -
                                notification.metrics.pixels) >
                            120;
                        if (show != _showJumpToBottom && mounted) {
                          WidgetsBinding.instance
                              .addPostFrameCallback((_) => _onScroll());
                        }
                        return false;
                      },
                      child: Scrollbar(
                        controller: _scrollController,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(top: 8, bottom: 24),
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
                                onRewind:
                                    !chat.isStreaming && m.role == ChatRole.user
                                        ? () => _handleRewind(m.id)
                                        : null,
                                onOpenDiff: () =>
                                    ref.read(sidePanelProvider.notifier).openTab(
                                          const SidePanelTab(
                                            id: 'review',
                                            kind: SidePanelTabKind.review,
                                            title: 'Review',
                                          ),
                                        ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (_showJumpToBottom)
                      Positioned(
                        right: 16,
                        bottom: 12,
                        child: FloatingActionButton.small(
                          heroTag: 'jump-to-latest-chat',
                          tooltip: 'Jump to latest',
                          onPressed: _jumpToBottom,
                          child: const Icon(Icons.arrow_downward_rounded),
                        ),
                      ),
                  ],
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
        if (chat.loopWarning != null)
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withOpacity(0.75),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.loop_rounded,
                        size: 18,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Doom-loop guard: ${chat.loopWarning!.reason}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Dismiss warning',
                        onPressed: () => ref
                            .read(chatProvider.notifier)
                            .dismissLoopWarning(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: () => ref
                          .read(chatProvider.notifier)
                          .breakLoopAndPivot(),
                      icon: const Icon(Icons.bolt_rounded, size: 16),
                      label: const Text('Break Loop & Pivot'),
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
          Flexible(
            fit: FlexFit.loose,
            child: wrapCentered(
              Container(
                constraints: BoxConstraints(
                  maxHeight:
                      (MediaQuery.sizeOf(context).height * 0.28).clamp(100.0, 220.0),
                ),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Card(
                  child: ListView(
                    shrinkWrap: true,
                    children: AgyCliCatalog.slashCommands
                        .where((c) => c.matches(_inputController.text))
                        .map(
                          (c) => ListTile(
                            dense: true,
                            title: Row(
                              children: [
                                Text(
                                  c.command,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (c.argHint != null) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    c.argHint!,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              c.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () {
                              final next = c.argHint != null
                                  ? '${c.command} '
                                  : c.command;
                              _inputController.text = next;
                              _inputController.selection = TextSelection.collapsed(
                                offset: next.length,
                              );
                              setState(() => _showSlashMenu = false);
                              if (c.handledLocally && c.argHint == null) {
                                _submit();
                              }
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
            ),
          ),
        if (_showMentionMenu && _mentionFiles.isNotEmpty)
          Flexible(
            fit: FlexFit.loose,
            child: wrapCentered(
              Container(
                constraints: BoxConstraints(
                  maxHeight:
                      (MediaQuery.sizeOf(context).height * 0.25).clamp(90.0, 190.0),
                ),
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Card(
                  child: ListView(
                    shrinkWrap: true,
                    children: (() {
                      final txt = _inputController.text;
                      final atIdx = txt.lastIndexOf('@');
                      final query = atIdx >= 0
                          ? txt.substring(atIdx + 1).trim().toLowerCase()
                          : '';
                      final filtered = query.isEmpty
                          ? _mentionFiles
                          : _mentionFiles.where((f) {
                              final name = (f['name'] ?? '').toLowerCase();
                              final path = (f['path'] ?? '').toLowerCase();
                              return name.contains(query) || path.contains(query);
                            }).toList();
                      return filtered.take(12).map((f) {
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
                      }).toList();
                    })(),
                  ),
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
                  // dsh-Go style rounded pill composer so narrow mobile widths
                  // give maximum unobstructed horizontal space to the TextField.
                  Container(
                    padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHigh
                          .withOpacity(0.85),
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
                                _pickFile();
                              case 'image':
                                _pickImage();
                              case 'voice':
                                if (!_listeningVoice) _dictateVoice();
                              case 'slash':
                                _inputController.text = '/';
                                _inputController.selection =
                                    const TextSelection.collapsed(offset: 1);
                                _onChanged('/');
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
                                  _listeningVoice ? Icons.mic : Icons.mic_none,
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
                              _listeningVoice ? Icons.mic : Icons.add_rounded,
                              size: 20,
                              color: _listeningVoice
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
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
                                hintText: isBusyOrBg
                                    ? 'Queue message (or Steer)…'
                                    : widget.isDesktopMode && _enterToSend
                                        ? 'Ask anything, @ file, / command (Enter sends)'
                                        : 'Ask anything, @ file, / command…',
                              ),
                            ),
                          ),
                        ),
                        if (isBusyOrBg) ...[
                          const SizedBox(width: 4),
                          IconButton.filledTonal(
                            tooltip: 'Stop (Esc)',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            onPressed: () {
                              if (chat.isStreaming) {
                                ref.read(chatProvider.notifier).stopStreaming();
                              } else {
                                ref
                                    .read(chatProvider.notifier)
                                    .forceStopAllTasks();
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
                            onPressed: _steerSubmit,
                            icon: const Icon(Icons.bolt_rounded, size: 19),
                          ),
                        ],
                        const SizedBox(width: 4),
                        IconButton.filled(
                          tooltip: isBusyOrBg ? 'Queue' : 'Send',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 36,
                            height: 36,
                          ),
                          onPressed: _submit,
                          icon: Icon(
                            isBusyOrBg
                                ? Icons.schedule_send_rounded
                                : Icons.arrow_upward_rounded,
                            size: 19,
                          ),
                        ),
                      ],
                    ),
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
                                        ? Colors.amber.withOpacity(0.18)
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
                                        ? theme.colorScheme.error
                                        : ctxSnap.needsWarning
                                            ? Colors.amber.shade800
                                            : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${ctxSnap.percentage}% ctx',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: ctxSnap.shouldCompact
                                          ? theme.colorScheme.error
                                          : null,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
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
    final isCompact = MediaQuery.sizeOf(context).width < 460;
    final icon = Icon(
      !runtimeReady && isLocal ? Icons.terminal : Icons.account_circle,
      color: theme.colorScheme.primary,
    );
    final msg = Text(
      !runtimeReady && isLocal
          ? 'Install the on-device `agy` harness to run Antigravity agents on Android.'
          : 'Sign in with your Google Account to run Antigravity AI agents & view quotas.',
      style: theme.textTheme.bodySmall,
      maxLines: isCompact ? 3 : null,
      overflow: isCompact ? TextOverflow.ellipsis : null,
    );
    final action = (!runtimeReady && isLocal)
        ? FilledButton.tonal(
            onPressed: runtimeBusy ? null : onInstallRuntime,
            child: Text(runtimeBusy ? 'Installing…' : 'Install agy'),
          )
        : (!isAuthenticated)
            ? FilledButton.tonal(
                onPressed: onSignIn,
                child: const Text('Google Sign-In'),
              )
            : null;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: EdgeInsets.all(isCompact ? 10 : 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(16),
      ),
      child: isCompact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    icon,
                    const SizedBox(width: 10),
                    Expanded(child: msg),
                  ],
                ),
                if (action != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: action,
                  ),
                ],
              ],
            )
          : Row(
              children: [
                icon,
                const SizedBox(width: 10),
                Expanded(child: msg),
                ?action,
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
