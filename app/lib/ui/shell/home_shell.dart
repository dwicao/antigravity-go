import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../phone/phone_bridge.dart';
import '../../state/auth_state.dart';
import '../../state/automations_state.dart';
import '../../state/chat_state.dart';
import '../../state/device_policy_state.dart';
import '../../state/performance_state.dart';
import '../../state/permissions_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../state/settings_state.dart';
import '../../state/share_inbox_state.dart';
import '../../state/side_panel_state.dart';
import '../../state/update_state.dart';
import '../chat/chat_screen.dart';
import '../phone/phone_control_page.dart';
import '../settings/settings_page.dart';
import '../side_panel/overview_panel.dart';
import '../side_panel/side_panel_tabs.dart';
import '../usage/usage_page.dart';
import 'command_palette.dart';
import 'sessions_drawer.dart';

/// 1:1 Antigravity Desktop adaptive shell:
/// - `< 720dp`: Mobile drawers (Sessions left, Overview right, Side Panel modal/sheet)
/// - `720–1099dp`: 2-pane (Sidebar + Chat, Overview endDrawer, Side Panel split when open)
/// - `>= 1100dp` (Samsung DeX / Tablet): Full desktop workspace with Sidebar + Chat + Side Panel + Overview
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell>
    with WidgetsBindingObserver {
  static const MethodChannel _systemChannel = MethodChannel('agy/system');
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _showLeftSidebar = true;
  bool _showOverviewPanel = true;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  Timer? _updateCheckTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _systemChannel.setMethodCallHandler((call) async {
      if (call.method == 'onShortcutAction' && call.arguments is String) {
        _handleShortcutAction(call.arguments as String);
      } else if (call.method == 'onSharedContent' && call.arguments is Map) {
        final payload = SharedInboxPayload.fromMap(
          call.arguments as Map<Object?, Object?>,
        );
        if (payload != null && mounted) {
          ref.read(sharedInboxProvider.notifier).enqueue(payload);
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateCheckTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          ref.read(appUpdateProvider.notifier).autoCheckIfDue();
        }
      });
      // Touch performanceProvider so saved refresh-rate mode syncs cleanly to MainActivity.
      ref.read(performanceProvider);
      _consumeInitialShortcut();
      _consumeInitialShare();
      ref.read(automationsProvider.notifier).onAutomationDue = (task) async {
        if (!mounted) return;
        if (ref.read(chatProvider).isStreaming) return;
        await ref
            .read(settingsProvider.notifier)
            .setModel(task.modelTier.modelId);
        await ref
            .read(sessionsProvider.notifier)
            .createSession(title: 'Auto: ${task.name}');
        await ref.read(chatProvider.notifier).sendPrompt(task.prompt);
      };
    });
  }

  @override
  void dispose() {
    _updateCheckTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _systemChannel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      ref.read(runtimeProvider.notifier).ensureRunningOnResume();
      ref.read(devicePolicyProvider.notifier).refresh();
      unawaited(ref.read(authProvider.notifier).keepAliveOnResume());
    }
  }

  Future<void> _consumeInitialShortcut() async {
    try {
      final pending =
          await _systemChannel.invokeMethod<String>('consumePendingAction');
      if (pending != null && pending.isNotEmpty && mounted) {
        _handleShortcutAction(pending);
      }
    } catch (_) {}
  }

  Future<void> _consumeInitialShare() async {
    try {
      final raw = await _systemChannel.invokeMethod<Map<Object?, Object?>>(
        'consumePendingShare',
      );
      final payload = SharedInboxPayload.fromMap(raw);
      if (payload != null && mounted) {
        ref.read(sharedInboxProvider.notifier).enqueue(payload);
      }
    } catch (_) {}
  }

  void _handleShortcutAction(String action) {
    if (!mounted) return;
    switch (action) {
      case 'new_chat':
        ref.read(sessionsProvider.notifier).createSession();
      case 'terminal':
        ref.read(sidePanelProvider.notifier).openTab(
              const SidePanelTab(
                id: 'terminal',
                kind: SidePanelTabKind.terminal,
                title: 'Terminal',
              ),
            );
      case 'phone':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const PhoneControlPage()),
        );
      case 'usage':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const UsagePage()),
        );
    }
  }

  bool _shouldPostAlert(AppSettings settings) {
    if (!settings.notifyBackgroundOnly) return true;
    return _lifecycleState != AppLifecycleState.resumed;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isDexMode = ref.watch(permissionsProvider.select((p) => p.isDexMode));
    final desktopLayout =
        ref.watch(settingsProvider.select((s) => s.desktopLayout));
    final showSidePanel =
        ref.watch(sidePanelProvider.select((s) => s.showSidePanel));

    ref.listen<bool>(chatProvider.select((c) => c.isStreaming), (prev, next) {
      if (prev == true && !next) {
        final settings = ref.read(settingsProvider);
        if (settings.hapticOnComplete) {
          PhoneBridge.instance.vibrate(durationMs: 45);
        }
        if (settings.notifyOnTurnComplete && _shouldPostAlert(settings)) {
          final activeTitle =
              ref.read(sessionsProvider).activeSession?.title ?? 'Antigravity Go';
          PhoneBridge.instance.postNotification(
            title: 'Reply finished',
            message: '$activeTitle completed its turn.',
            tag: 'agy_turn_complete',
          );
        }
      }
    });

    ref.listen<List<ActiveSubagent>>(
        chatProvider.select((c) => c.activeSubagents), (prev, next) {
      final settings = ref.read(settingsProvider);
      final activeNext = next.where((s) => s.isActive).toList();
      final activePrev = (prev ?? const []).where((s) => s.isActive).toList();
      if (activeNext.isEmpty && activePrev.isNotEmpty) {
        PhoneBridge.instance.cancelSubagentNotification('active_turn');
        return;
      }
      if (activeNext.isNotEmpty && _shouldPostAlert(settings)) {
        final turnId = ref.read(chatProvider).activeTurnId ?? '';
        final roles = activeNext.map((s) => s.role).take(3).join(', ');
        PhoneBridge.instance.postSubagentNotification(
          subagentId: 'active_turn',
          title:
              '${activeNext.length} subagent${activeNext.length == 1 ? '' : 's'} active',
          message: roles,
          turnId: turnId,
        );
      }
    });

    ref.listen<AgyPermissionRequestEvent?>(
        chatProvider.select((c) => c.pendingPermission), (prev, next) {
      if (next == null) {
        if (prev != null) {
          PhoneBridge.instance.cancelApprovalNotification();
        }
        return;
      }
      final settings = ref.read(settingsProvider);
      if (prev == null &&
          settings.notifyOnApproval &&
          _shouldPostAlert(settings)) {
        final allowOpt = next.options.firstWhere(
          (o) =>
              o.kind.toLowerCase().contains('allow') ||
              o.optionId.toLowerCase().contains('allow'),
          orElse: () => next.options.isNotEmpty
              ? next.options.first
              : const PermissionOption(
                  optionId: 'allow',
                  name: 'Allow',
                  kind: 'allow_once',
                ),
        );
        final denyOpt = next.options.firstWhere(
          (o) =>
              o.kind.toLowerCase().contains('reject') ||
              o.optionId.toLowerCase().contains('reject') ||
              o.optionId.toLowerCase().contains('deny'),
          orElse: () => next.options.length > 1
              ? next.options.last
              : const PermissionOption(
                  optionId: 'reject',
                  name: 'Deny',
                  kind: 'reject_once',
                ),
        );
        final turnId = ref.read(chatProvider).activeTurnId ?? '';
        final detail = next.commandOrPath?.trim().isNotEmpty == true
            ? '${next.toolName}: ${next.commandOrPath}'
            : next.title;
        PhoneBridge.instance.postApprovalNotification(
          turnId: turnId,
          requestId: next.requestId.toString(),
          allowOptionId: allowOpt.optionId,
          denyOptionId: denyOpt.optionId,
          title: 'Approval needed (${next.toolName})',
          message: detail,
        );
      }
    });

    final isTwoPane = switch (desktopLayout) {
      DesktopLayoutOverride.desktop => true,
      DesktopLayoutOverride.mobile => false,
      DesktopLayoutOverride.auto => width >= 720,
    };
    final isThreePane = switch (desktopLayout) {
      DesktopLayoutOverride.desktop => width >= 840,
      DesktopLayoutOverride.mobile => false,
      DesktopLayoutOverride.auto => width >= 1100,
    };
    final isDesktopUx = switch (desktopLayout) {
      DesktopLayoutOverride.desktop => true,
      DesktopLayoutOverride.mobile => false,
      DesktopLayoutOverride.auto => isTwoPane || isDexMode,
    };

    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
        ref.read(sessionsProvider.notifier).createSession();
      },
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
        CommandPaletteDialog.show(context);
      },
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
        if (isTwoPane) {
          setState(() => _showLeftSidebar = !_showLeftSidebar);
        } else {
          _scaffoldKey.currentState?.openDrawer();
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true):
          () {
        ref.read(sidePanelProvider.notifier).toggleSidePanel();
      },
      const SingleActivator(LogicalKeyboardKey.keyO, control: true, alt: true):
          () {
        if (isThreePane) {
          setState(() => _showOverviewPanel = !_showOverviewPanel);
        } else {
          _scaffoldKey.currentState?.openEndDrawer();
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyU, control: true): () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const UsagePage()),
        );
      },
      const SingleActivator(LogicalKeyboardKey.comma, control: true): () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
        );
      },
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (ref.read(chatProvider).isStreaming) {
          ref.read(chatProvider.notifier).stopStreaming();
        }
      },
    };

    Widget body;
    if (isThreePane) {
      body = Scaffold(
        key: _scaffoldKey,
        body: Row(
          children: [
            if (_showLeftSidebar) ...[
              const SizedBox(width: 276, child: SessionsDrawer()),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              flex: 5,
              child: ChatScreen(
                isDesktopMode: isDesktopUx,
                onOpenSessions: () =>
                    setState(() => _showLeftSidebar = !_showLeftSidebar),
                onOpenQuickPanel: () =>
                    setState(() => _showOverviewPanel = !_showOverviewPanel),
              ),
            ),
            if (showSidePanel) ...[
              const VerticalDivider(width: 1),
              const Expanded(flex: 4, child: SidePanelTabs()),
            ],
            if (_showOverviewPanel) ...[
              const VerticalDivider(width: 1),
              const SizedBox(width: 300, child: OverviewPanel()),
            ],
          ],
        ),
      );
    } else if (isTwoPane) {
      body = Scaffold(
        key: _scaffoldKey,
        endDrawer: Drawer(
          width: 320,
          child: OverviewPanel(
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          ),
        ),
        body: Row(
          children: [
            if (_showLeftSidebar) ...[
              const SizedBox(width: 264, child: SessionsDrawer()),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              flex: 5,
              child: ChatScreen(
                isDesktopMode: isDesktopUx,
                onOpenSessions: () =>
                    setState(() => _showLeftSidebar = !_showLeftSidebar),
                onOpenQuickPanel: () =>
                    _scaffoldKey.currentState?.openEndDrawer(),
              ),
            ),
            if (showSidePanel) ...[
              const VerticalDivider(width: 1),
              const Expanded(flex: 4, child: SidePanelTabs()),
            ],
          ],
        ),
      );
    } else {
      body = Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          width: 308,
          child: SessionsDrawer(
            onClose: () => _scaffoldKey.currentState?.closeDrawer(),
          ),
        ),
        endDrawer: Drawer(
          width: 316,
          child: OverviewPanel(
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          ),
        ),
        body: showSidePanel
            ? const SidePanelTabs()
            : ChatScreen(
                isDesktopMode: isDesktopUx,
                onOpenSessions: () => _scaffoldKey.currentState?.openDrawer(),
                onOpenQuickPanel: () =>
                    _scaffoldKey.currentState?.openEndDrawer(),
              ),
      );
    }

    return CallbackShortcuts(
      bindings: bindings,
      child: Focus(
        autofocus: false,
        child: body,
      ),
    );
  }
}
