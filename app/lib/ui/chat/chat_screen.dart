import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../remote/ssh_agy_runner.dart';
import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_models.dart';
import 'secret_mask.dart';
import '../../state/auth_state.dart';
import '../../state/background_tasks_state.dart';
import '../../state/chat_state.dart';
import '../../state/custom_providers_state.dart';
import '../../state/customizations_state.dart';
import '../../state/draft_store.dart';
import '../../state/harness_state.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/side_panel_state.dart';
import '../../theme/app_theme.dart';
import '../auth/google_login_sheet.dart';
import '../cli/cli_manager_page.dart';
import '../harness/harness_page.dart';
import '../settings/settings_page.dart';
import '../shell/background_tasks_sheet.dart';
import '../shell/command_palette.dart';
import '../usage/usage_page.dart';
import 'chat_banners_and_sheets.dart';
import 'attachment_preview.dart';
import 'chat_composer_bar.dart';
import 'message_bubble.dart';
import 'subagents_activity_banner.dart';
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
  static const double _atBottomThreshold = 48.0;

  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<String> _attachments = [];
  List<Map<String, String>> _mentionFiles = const [];
  bool _showSlashMenu = false;
  bool _showMentionMenu = false;
  bool _listeningVoice = false;
  bool _enterToSend = true;
  bool _isAtBottom = true;
  bool _followLatest = true;
  bool _isProgrammaticScroll = false;
  bool _userActivelyScrollingUp = false;
  int _remainingOpenSnapFrames = 0;
  String? _observedActiveSessionId;
  String? _lastAutoScrolledSessionKey;
  String? _draftSessionId;
  bool _draftAppliedForSession = false;
  bool _compactBannerDismissed = false;
  String? _quotedText;

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
    final atBottom = distFromBottom <= _atBottomThreshold;
    var nextFollow = _followLatest;
    if (atBottom && !_userActivelyScrollingUp) {
      nextFollow = true;
    }
    if ((atBottom != _isAtBottom || nextFollow != _followLatest) && mounted) {
      setState(() {
        _isAtBottom = atBottom;
        _followLatest = nextFollow;
      });
    }
  }

  void _scheduleInitialBottomSnap(String sessionKey) {
    _lastAutoScrolledSessionKey = sessionKey;
    _remainingOpenSnapFrames = 4;
    WidgetsBinding.instance.addPostFrameCallback((_) => _performOpenSnap());
  }

  void _performOpenSnap() {
    if (!mounted || !_scrollController.hasClients) return;
    _jumpToBottomImmediate();
    if (_remainingOpenSnapFrames > 0) {
      _remainingOpenSnapFrames--;
    }
  }

  void _jumpToBottomImmediate() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = pos.maxScrollExtent;
    _isProgrammaticScroll = true;
    try {
      if ((pos.pixels - target).abs() > 0.5) {
        _scrollController.jumpTo(target);
      }
    } finally {
      _isProgrammaticScroll = false;
    }
    if (!_isAtBottom && mounted) {
      setState(() => _isAtBottom = true);
    }
  }

  Future<void> _jumpToBottom({bool animate = true}) async {
    if (!_scrollController.hasClients) return;
    final target = _scrollController.position.maxScrollExtent;
    _userActivelyScrollingUp = false;
    if (mounted && !_followLatest) {
      setState(() => _followLatest = true);
    } else {
      _followLatest = true;
    }
    _isProgrammaticScroll = true;
    try {
      if (animate) {
        await _scrollController.animateTo(
          target,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    } finally {
      _isProgrammaticScroll = false;
    }
    if (mounted) _onScroll();
  }

  final Map<String, GlobalKey> _turnKeys = {};
  int? _turnCursor;
  bool _reconnectDismissed = false;

  Future<void> _jumpUserTurn(
    List<ChatMessage> messages, {
    required int delta,
  }) async {
    final userIndices = <int>[
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == ChatRole.user) i,
    ];
    if (userIndices.isEmpty || !_scrollController.hasClients) return;
    final current = _turnCursor ?? (delta < 0 ? userIndices.length : -1);
    final nextIdx = (current + delta).clamp(0, userIndices.length - 1);
    setState(() {
      _turnCursor = nextIdx;
      _followLatest = false;
    });
    final msgIndex = userIndices[nextIdx];
    final targetId = messages[msgIndex].id;
    final keyCtx = _turnKeys[targetId]?.currentContext;
    if (keyCtx != null) {
      await Scrollable.ensureVisible(
        keyCtx,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: 0.08,
      );
      return;
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    final ratio = messages.length <= 1
        ? 0.0
        : (msgIndex / (messages.length - 1)).clamp(0.0, 1.0);
    await _scrollController.animateTo(
      maxExtent * ratio,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctxAfter = _turnKeys[targetId]?.currentContext;
      if (ctxAfter != null && mounted) {
        Scrollable.ensureVisible(
          ctxAfter,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: 0.08,
        );
      }
    });
  }

  Future<void> _showMultiSelectCopySheet(
    BuildContext context,
    List<ChatMessage> messages,
  ) async {
    if (messages.isEmpty) return;
    final selected = <String>{
      for (final m in messages)
        if (m.text.trim().isNotEmpty) m.id,
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final selectedCount = selected.length;
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.72,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Select & Copy ($selectedCount)',
                            style: Theme.of(ctx)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: () => setSheetState(() {
                            if (selected.length == messages.length) {
                              selected.clear();
                            } else {
                              selected.addAll(messages.map((m) => m.id));
                            }
                          }),
                          child: Text(
                            selected.length == messages.length
                                ? 'None'
                                : 'All',
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: selected.isEmpty
                              ? null
                              : () {
                                  final buf = StringBuffer();
                                  for (final m in messages) {
                                    if (!selected.contains(m.id)) continue;
                                    final role = switch (m.role) {
                                      ChatRole.user => '## User',
                                      ChatRole.assistant => '## Antigravity',
                                      ChatRole.system => '## System',
                                    };
                                    buf.writeln(role);
                                    buf.writeln(
                                      AgySecretMask.mask(m.text.trim()),
                                    );
                                    buf.writeln();
                                  }
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: buf.toString().trimRight(),
                                    ),
                                  );
                                  Navigator.of(ctx).pop();
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Copied $selectedCount message(s)',
                                        ),
                                      ),
                                    );
                                  }
                                },
                          icon: const Icon(Icons.copy_all, size: 16),
                          label: const Text('Copy'),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      itemCount: messages.length,
                      itemBuilder: (_, i) {
                        final m = messages[i];
                        final checked = selected.contains(m.id);
                        final preview = AgySecretMask.mask(m.text.trim())
                            .replaceAll('\n', ' ');
                        return CheckboxListTile(
                          value: checked,
                          dense: true,
                          title: Text(
                            m.role == ChatRole.user ? 'User' : 'Antigravity',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            preview.isEmpty ? '(tools / thinking)' : preview,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (v) => setSheetState(() {
                            if (v == true) {
                              selected.add(m.id);
                            } else {
                              selected.remove(m.id);
                            }
                          }),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onChanged(String val) async {
    _draftAppliedForSession = true;
    final sessionId =
        ref.read(sessionsProvider).activeSessionId ?? 'new_session';
    ref.read(draftStoreProvider.notifier).save(sessionId, val);

    final wantSlash = val.startsWith('/') && !val.contains(' ');
    final atIndex = val.lastIndexOf('@');
    final wantMention =
        atIndex >= 0 && !val.substring(atIndex).contains(' ') && !wantSlash;

    if (wantMention && !_showMentionMenu) {
      final sessionWs =
          ref.read(sessionsProvider).activeSession?.workspacePath ?? '';
      final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
      final fallback = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      final targetWs = sessionWs.isNotEmpty
          ? sessionWs
          : (projDir.isNotEmpty ? projDir : fallback);
      final sshHost = ref.read(hostsProvider).activeSshHost;
      List<Map<String, String>> files = const [];
      if (sshHost != null) {
        try {
          final (pwd, key) = await ref
              .read(hostsProvider.notifier)
              .readCredentials(sshHost.id);
          final out = await SshAgyRunner.instance.runRemoteCommand(
            host: sshHost,
            cwd: targetWs,
            password: pwd,
            privateKeyPem: key,
            command: 'ls -1Ap | head -n 60',
          );
          files = out
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .map((l) {
                final isDir = l.endsWith('/');
                final clean = isDir ? l.substring(0, l.length - 1) : l;
                final fullPath = targetWs.isEmpty ? clean : '$targetWs/$clean';
                return <String, String>{
                  'name': clean,
                  'path': fullPath,
                  'type': isDir ? 'dir' : 'file',
                };
              })
              .toList();
        } catch (_) {}
      } else {
        files = await RuntimeBridge.instance.listWorkspaceEntries(targetWs);
      }
      if (mounted) {
        setState(() {
          _mentionFiles = files;
          _showMentionMenu = files.isNotEmpty;
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
    if (text.isEmpty && _attachments.isEmpty) return;

    final firstWord =
        text.isEmpty ? '' : text.split(RegExp(r'\s+')).first.toLowerCase();

    if (firstWord == '/usage' ||
        firstWord == '/quota' ||
        firstWord == '/credits') {
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

    if (firstWord == '/clear') {
      _clearInputMenus();
      await ref.read(chatProvider.notifier).clearCurrentThread();
      return;
    }

    if (firstWord == '/new') {
      _clearInputMenus();
      await ref.read(sessionsProvider.notifier).createSession();
      return;
    }

    if (firstWord == '/resume') {
      _clearInputMenus();
      if (widget.onOpenSessions != null) {
        widget.onOpenSessions!();
      } else {
        await showChatSessionPickerSheet(context, ref);
      }
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

    if (firstWord == '/agents' && text.length > 7) {
      final agentName = text.substring(7).trim();
      _clearInputMenus();
      await ref.read(settingsProvider.notifier).setActiveAgent(agentName);
      await ref.read(chatProvider.notifier).appendSystemFeedback(
            agentName.isEmpty
                ? 'Cleared active CLI `--agent` preset.'
                : 'Active CLI `--agent` set to **$agentName**.',
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
      final branched =
          await ref.read(chatProvider.notifier).forkCurrentSession();
      await ref.read(chatProvider.notifier).appendSystemFeedback(
            'Forked conversation into **${branched.title}** with full history.',
          );
      return;
    }

    if (firstWord == '/model') {
      if (text.length > 6) {
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
      _clearInputMenus();
      await showChatModelPickerSheet(context, ref);
      return;
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
    final quote = _quotedText?.trim();
    final outgoing = (quote != null && quote.isNotEmpty)
        ? '> ${quote.replaceAll('\n', '\n> ')}\n\n$text'
        : text;
    _clearInputMenus(clearAttachments: true);
    if (_quotedText != null && mounted) {
      setState(() => _quotedText = null);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    await ref.read(chatProvider.notifier).sendPrompt(outgoing, attachments: files);
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
    if (text.isEmpty && _attachments.isEmpty) {
      if (ref.read(chatProvider).queuedPrompts.isNotEmpty) {
        await ref.read(chatProvider.notifier).sendQueuedNow();
      }
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    await ref.read(chatProvider.notifier).steerNow(text, attachments: files);
  }

  Future<void> _pickFile() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    setState(() {
      for (final f in files) {
        if (f.path != null && !_attachments.contains(f.path!)) {
          _attachments.add(f.path!);
        }
      }
    });
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final imgs = await picker.pickMultiImage();
    if (imgs.isEmpty) return;
    setState(() {
      for (final img in imgs) {
        if (!_attachments.contains(img.path)) {
          _attachments.add(img.path);
        }
      }
    });
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
    final activeSessionId =
        ref.watch(sessionsProvider.select((s) => s.activeSessionId)) ??
            'new_session';
    final hasCurrentSessionRunningTool = bgTasks.any(
      (t) =>
          t.kind != BackgroundTaskKind.queued &&
          t.kind != BackgroundTaskKind.session &&
          t.kind != BackgroundTaskKind.ci &&
          (t.sessionId == null || t.sessionId == activeSessionId),
    );
    final isCurrentSessionBusy = chat.isStreaming || hasCurrentSessionRunningTool;

    final auth = ref.watch(authProvider);
    final hosts = ref.watch(hostsProvider);
    final ctxSnap = ref.watch(contextBudgetProvider);
    final project = ref.watch(projectsProvider).activeProject;
    final runtime = ref.watch(runtimeProvider);
    final settings = ref.watch(settingsProvider);
    final activeCustom = ref.watch(activeCustomProviderProvider);
    final perms = ref.watch(permissionsProvider);
    final sidePanel = ref.watch(sidePanelProvider);

    ref.listen<Map<String, ChatDraft>>(draftStoreProvider, (prev, next) {
      if (!_draftAppliedForSession && _inputController.text.isEmpty) {
        final restored = next[activeSessionId]?.text ?? '';
        if (restored.isNotEmpty) {
          _draftAppliedForSession = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _inputController.text.isNotEmpty) return;
            _inputController.text = restored;
            _inputController.selection =
                TextSelection.collapsed(offset: restored.length);
          });
        }
      }
    });
    if (_observedActiveSessionId != activeSessionId) {
      _observedActiveSessionId = activeSessionId;
      _userActivelyScrollingUp = false;
      _lastAutoScrolledSessionKey = null;
      _compactBannerDismissed = false;
      _followLatest = true;
    }
    if (chat.messages.isNotEmpty) {
      final readyForActive = chat.loadedSessionId == null ||
          chat.loadedSessionId == activeSessionId;
      if (readyForActive) {
        final sessionKey = chat.loadedSessionId ?? activeSessionId;
        if (_lastAutoScrolledSessionKey != sessionKey) {
          _scheduleInitialBottomSnap(sessionKey);
        } else if (_followLatest && !_userActivelyScrollingUp) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _followLatest && !_userActivelyScrollingUp) {
              _jumpToBottomImmediate();
            }
          });
        }
      }
    }
    if (_draftSessionId != activeSessionId) {
      _draftSessionId = activeSessionId;
      final savedDraft =
          ref.read(draftStoreProvider.notifier).draftFor(activeSessionId);
      _draftAppliedForSession = savedDraft.isNotEmpty;
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
    final semantic = AgySemanticColors.of(context);
    final customItems = ref.watch(customizationsProvider);
    final skillSlashItems = customItems
        .where((c) => c.kind == CustomizationKind.skill && c.enabled)
        .map(
          (s) => AgySlashCommand(
            command: '/${SkillFrontmatter.sanitizeSlug(s.name)}',
            argHint: '<task>',
            description: 'Skill (${s.scope}): ${s.description}',
          ),
        )
        .where(
          (cmd) => !AgyCliCatalog.slashCommands
              .any((builtIn) => builtIn.command == cmd.command),
        )
        .toList();
    final slashMatches = _showSlashMenu
        ? [
            ...AgyCliCatalog.slashCommands,
            ...skillSlashItems,
          ].where((c) => c.matches(_inputController.text)).toList()
        : const <AgySlashCommand>[];

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
                    Text(project.name, overflow: TextOverflow.ellipsis),
                    Text(
                      activeCustom != null
                          ? 'Custom /v1 · ${activeCustom.name}'
                          : '$hostLabel · ${activeModel.displayName}',
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
                    case 'multi_copy':
                      _showMultiSelectCopySheet(context, chat.messages);
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
                  if (chat.messages.isNotEmpty) ...[
                    const PopupMenuItem(
                      value: 'multi_copy',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.checklist_rtl),
                        title: Text('Select & Copy Messages'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'share',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.ios_share),
                        title: Text('Share Transcript'),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
        if (activeCustom == null &&
            ((auth.initialized && !auth.isAuthenticated) ||
                (runtime.initialized &&
                    !runtime.status.isReady &&
                    hosts.isLocalActive)))
          wrapCentered(
            ChatOnboardingBanner(
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
              ? ChatEmptyHero(
                  onPickSuggestion: (s) => _inputController.text = s,
                )
              : Stack(
                  children: [
                    NotificationListener<UserScrollNotification>(
                      onNotification: (notification) {
                        // Ignore nested horizontal scrolls (code blocks / tables).
                        if (notification.depth != 0 ||
                            notification.metrics.axis != Axis.vertical) {
                          return false;
                        }
                        if (notification.direction == ScrollDirection.forward) {
                          _remainingOpenSnapFrames = 0;
                          _userActivelyScrollingUp = true;
                        } else {
                          _userActivelyScrollingUp = false;
                        }
                        return false;
                      },
                      child: NotificationListener<ScrollUpdateNotification>(
                        onNotification: (notification) {
                          if (notification.depth != 0 ||
                              notification.metrics.axis != Axis.vertical ||
                              _isProgrammaticScroll) {
                            return false;
                          }
                          final delta = notification.scrollDelta ?? 0.0;
                          final distFromBottom =
                              notification.metrics.maxScrollExtent -
                                  notification.metrics.pixels;
                          if (delta < -1.5 &&
                              distFromBottom > _atBottomThreshold) {
                            _remainingOpenSnapFrames = 0;
                            if (mounted && (_followLatest || _isAtBottom)) {
                              setState(() {
                                _followLatest = false;
                                _isAtBottom = false;
                              });
                            } else {
                              _followLatest = false;
                              _isAtBottom = false;
                            }
                          }
                          return false;
                        },
                        child: NotificationListener<ScrollMetricsNotification>(
                          onNotification: (notification) {
                            if (notification.depth != 0 ||
                                notification.metrics.axis != Axis.vertical) {
                              return false;
                            }
                            final dist = notification.metrics.maxScrollExtent -
                                notification.metrics.pixels;
                            if ((_remainingOpenSnapFrames > 0 ||
                                    (_followLatest &&
                                        !_userActivelyScrollingUp)) &&
                                dist > 1.0) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (!mounted) return;
                                if (_remainingOpenSnapFrames > 0) {
                                  _performOpenSnap();
                                } else if (_followLatest &&
                                    !_userActivelyScrollingUp) {
                                  _jumpToBottomImmediate();
                                }
                              });
                            } else {
                              final atBottom = dist <= _atBottomThreshold;
                              if (atBottom != _isAtBottom && mounted) {
                                WidgetsBinding.instance
                                    .addPostFrameCallback((_) => _onScroll());
                              }
                            }
                            return false;
                          },
                          child: Scrollbar(
                            controller: _scrollController,
                            child: ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.only(top: 8, bottom: 72),
                            itemCount: chat.messages.length,
                            itemBuilder: (context, index) {
                              final m = chat.messages[index];
                              final isLastAssistant = !chat.isStreaming &&
                                  m.role == ChatRole.assistant &&
                                  index == chat.messages.length - 1;
                              final turnKey = m.role == ChatRole.user
                                  ? _turnKeys.putIfAbsent(
                                      m.id,
                                      GlobalKey.new,
                                    )
                                  : null;
                              final bubble = wrapCentered(
                                MessageBubble(
                                  message: m,
                                  tokensPerSecond:
                                      m.isStreaming ? chat.tokensPerSecond : null,
                                  activeSubagents: chat.activeSubagents,
                                  onRegenerate: isLastAssistant
                                      ? () => ref
                                          .read(chatProvider.notifier)
                                          .regenerateLastTurn()
                                      : null,
                                  onEditResend: !chat.isStreaming &&
                                          m.role == ChatRole.user
                                      ? (newText) => ref
                                          .read(chatProvider.notifier)
                                          .editAndResend(m.id, newText)
                                      : null,
                                  onRewind: !chat.isStreaming &&
                                          m.role == ChatRole.user
                                      ? () => _handleRewind(m.id)
                                      : null,
                                  onQuote: m.text.trim().isNotEmpty
                                      ? (excerpt) => setState(() => _quotedText = excerpt)
                                      : null,
                                  onOpenDiff: () => ref
                                      .read(sidePanelProvider.notifier)
                                      .openTab(
                                        const SidePanelTab(
                                          id: 'review',
                                          kind: SidePanelTabKind.review,
                                          title: 'Review',
                                        ),
                                      ),
                                ),
                              );
                              return turnKey == null
                                  ? bubble
                                  : KeyedSubtree(key: turnKey, child: bubble);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                      right: 16,
                      bottom: 12,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (chat.messages
                                  .where((m) => m.role == ChatRole.user)
                                  .length >=
                              2) ...[
                            Material(
                              elevation: 3,
                              color: theme.colorScheme.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(20),
                              clipBehavior: Clip.antiAlias,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    padding: EdgeInsets.zero,
                                    tooltip: 'Previous user turn',
                                    iconSize: 18,
                                    onPressed: () => _jumpUserTurn(
                                      chat.messages,
                                      delta: -1,
                                    ),
                                    icon: const Icon(
                                      Icons.keyboard_arrow_up_rounded,
                                    ),
                                  ),
                                  IconButton(
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    padding: EdgeInsets.zero,
                                    tooltip: 'Next user turn',
                                    iconSize: 18,
                                    onPressed: () => _jumpUserTurn(
                                      chat.messages,
                                      delta: 1,
                                    ),
                                    icon: const Icon(
                                      Icons.keyboard_arrow_down_rounded,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          if (!_isAtBottom || !_followLatest)
                            FloatingActionButton.small(
                              heroTag: 'jump-to-latest-chat',
                              tooltip: 'Jump to latest',
                              onPressed: () => _jumpToBottom(animate: true),
                              child: const Icon(Icons.arrow_downward_rounded),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        if (hosts.activeSshHost == null &&
            !_reconnectDismissed &&
            !isCurrentSessionBusy &&
            (runtime.status.phase == RuntimePhase.stopped ||
                runtime.status.phase == RuntimePhase.error))
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: runtime.status.phase == RuntimePhase.error
                    ? theme.colorScheme.errorContainer.withOpacity(0.75)
                    : semantic.warningContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    runtime.status.phase == RuntimePhase.error
                        ? Icons.error_outline
                        : Icons.power_settings_new_rounded,
                    size: 16,
                    color: runtime.status.phase == RuntimePhase.error
                        ? theme.colorScheme.onErrorContainer
                        : semantic.onWarningContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      runtime.status.phase == RuntimePhase.error
                          ? (runtime.status.errorMessage?.trim().isNotEmpty == true
                              ? 'Runtime error: ${runtime.status.errorMessage}'
                              : 'Local runtime disconnected')
                          : 'Local runtime is stopped — start service to run prompts',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: runtime.status.phase == RuntimePhase.error
                            ? theme.colorScheme.onErrorContainer
                            : semantic.onWarningContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: runtime.busy
                        ? null
                        : () => ref.read(runtimeProvider.notifier).start(),
                    child: Text(
                      runtime.status.phase == RuntimePhase.error
                          ? 'Retry'
                          : 'Start',
                    ),
                  ),
                  IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _reconnectDismissed = true),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        if (isCurrentSessionBusy)
          wrapCentered(
            _StreamingAgentStatusBar(
              key: const ValueKey('bottom-agent-working-bar'),
              tokensPerSecond: chat.tokensPerSecond,
              messages: chat.messages,
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
                      size: 16, color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      chat.stallWarning!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (ctxSnap.shouldCompact &&
            !chat.isStreaming &&
            !_compactBannerDismissed)
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: semantic.warningContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.compress_rounded,
                    size: 16,
                    color: semantic.onWarningContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Context ${ctxSnap.percentage}% full — compact soon for peak focus.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: semantic.onWarningContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      final res =
                          await ref.read(chatProvider.notifier).compactThread();
                      if (!res.ok) {
                        messenger.showSnackBar(
                          SnackBar(content: Text(res.message)),
                        );
                      }
                    },
                    child: const Text('Compact'),
                  ),
                  IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        setState(() => _compactBannerDismissed = true),
                    icon: Icon(
                      Icons.close,
                      color: semantic.onWarningContainer,
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
                        icon: Icon(
                          Icons.close,
                          color: theme.colorScheme.onErrorContainer,
                        ),
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
        if (_showSlashMenu && slashMatches.isNotEmpty)
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
                    children: slashMatches
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
            AttachmentPreviewStrip(
              attachments: _attachments,
              onRemove: (a) => setState(() => _attachments.remove(a)),
            ),
          ),
        if (_quotedText != null && _quotedText!.isNotEmpty)
          wrapCentered(
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
                border: Border(
                  left: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _quotedText!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Clear quote',
                    onPressed: () => setState(() => _quotedText = null),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
        wrapCentered(const SubagentsActivityBanner()),
        wrapCentered(
          ChatComposerBar(
            inputController: _inputController,
            isBusy: isCurrentSessionBusy,
            isStreamingCurrentSession: chat.isStreaming,
            listeningVoice: _listeningVoice,
            isDesktopMode: widget.isDesktopMode,
            enterToSend: _enterToSend,
            ctxSnap: ctxSnap,
            onKeyEvent: _handleComposerKey,
            onChanged: _onChanged,
            onPickFile: _pickFile,
            onPickImage: _pickImage,
            onDictateVoice: _dictateVoice,
            onTriggerSlash: () {
              _inputController.text = '/';
              _inputController.selection =
                  const TextSelection.collapsed(offset: 1);
              _onChanged('/');
            },
            onSubmit: _submit,
            onSteerSubmit: _steerSubmit,
            onToggleEnterToSend: (v) => setState(() => _enterToSend = v),
          ),
        ),
      ],
    );
  }
}

class _StreamingAgentStatusBar extends StatefulWidget {
  const _StreamingAgentStatusBar({
    super.key,
    required this.tokensPerSecond,
    this.messages = const [],
  });

  final double tokensPerSecond;
  final List<ChatMessage> messages;

  @override
  State<_StreamingAgentStatusBar> createState() =>
      _StreamingAgentStatusBarState();
}

class _StreamingAgentStatusBarState extends State<_StreamingAgentStatusBar> {
  final Stopwatch _stopwatch = Stopwatch()..start();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  String _formatElapsed(Duration d) {
    final mins = d.inMinutes.toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final hasSpeed = widget.tokensPerSecond > 0.5;
    final rounds = widget.messages.where((m) => m.role == ChatRole.user).length;
    var toolCalls = 0;
    var totalTokens = 0;
    var cacheRead = 0;
    var inputTokens = 0;
    for (final m in widget.messages) {
      toolCalls += m.tools.length;
      final u = m.usage;
      if (u != null) {
        totalTokens += u.totalTokens;
        cacheRead += u.cacheReadTokens;
        inputTokens += u.inputTokens;
      }
    }
    final cacheDenom = inputTokens + cacheRead;
    final metaParts = <String>[
      _formatElapsed(_stopwatch.elapsed),
      if (rounds > 0) '$rounds rd',
      if (toolCalls > 0) '$toolCalls tools',
      if (totalTokens > 0)
        totalTokens >= 1000
            ? '${(totalTokens / 1000).toStringAsFixed(1)}k tok'
            : '$totalTokens tok',
      if (cacheRead > 0 && cacheDenom > 0)
        '${((cacheRead / cacheDenom) * 100).round()}% hit',
    ];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.45),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: theme.colorScheme.primary.withOpacity(0.16),
            child: Icon(
              Icons.auto_awesome,
              size: 12,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Antigravity',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            hasSpeed
                ? '${widget.tokensPerSecond.toStringAsFixed(0)} tok/s'
                : 'Working…',
            style: theme.textTheme.labelSmall?.copyWith(
              color: semantic.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '· ${metaParts.join(' · ')}',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: semantic.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
