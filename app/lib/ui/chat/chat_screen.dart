import 'package:agy_client/agy_client.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/auth_state.dart';
import '../../state/chat_state.dart';
import '../../state/hosts_state.dart';
import '../../state/permissions_state.dart';
import '../../state/runtime_state.dart';
import '../../state/settings_state.dart';
import '../auth/google_login_sheet.dart';
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
  bool _showSlashMenu = false;
  bool _listeningVoice = false;
  bool _enterToSend = true;

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChanged(String val) {
    final wantMenu = val.startsWith('/') && !val.contains(' ');
    if (wantMenu != _showSlashMenu) {
      setState(() => _showSlashMenu = wantMenu);
    }
  }

  Future<void> _submit() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    if (text == '/usage' || text == '/quota') {
      _inputController.clear();
      setState(() => _showSlashMenu = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const UsagePage()),
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
    _inputController.clear();
    setState(() {
      _attachments.clear();
      _showSlashMenu = false;
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
    final runtime = ref.watch(runtimeProvider);
    final settings = ref.watch(settingsProvider);
    final perms = ref.watch(permissionsProvider);
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
                      : 'Sessions & Hosts',
                  onPressed: widget.onOpenSessions,
                  icon: Icon(
                    widget.isDesktopMode ? Icons.view_sidebar_outlined : Icons.menu,
                  ),
                )
              : null,
          title: Row(
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Antigravity Go'),
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
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.desktop_windows_outlined, size: 14),
                  label: const Text('DeX'),
                ),
              ],
            ],
          ),
          actions: [
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
                tooltip: widget.isDesktopMode
                    ? 'Toggle Inspector (Ctrl+I)'
                    : 'Controls & Tools',
                onPressed: widget.onOpenQuickPanel,
                icon: const Icon(Icons.tune_rounded),
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
                    itemBuilder: (context, index) => wrapCentered(
                      MessageBubble(message: chat.messages[index]),
                    ),
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
                    child: const Text('Send now'),
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
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
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
                                      ? 'Ask Antigravity… (Enter to send, Shift+Enter for newline)'
                                      : 'Ask Antigravity or type / for commands…',
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
                  if (widget.isDesktopMode)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 8, right: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Shortcuts: Ctrl+N New · Ctrl+B Sidebar · Ctrl+U Usage · Ctrl+, Settings',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            label: const Text('Enter sends'),
                            selected: _enterToSend,
                            onSelected: (v) =>
                                setState(() => _enterToSend = v),
                          ),
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
