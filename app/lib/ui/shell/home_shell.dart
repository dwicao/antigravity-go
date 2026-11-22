import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_state.dart';
import '../../state/permissions_state.dart';
import '../../state/sessions_state.dart';
import '../chat/chat_screen.dart';
import '../settings/settings_page.dart';
import '../usage/usage_page.dart';
import 'quick_panel.dart';
import 'sessions_drawer.dart';

/// Adaptive shell optimized for Phones, Tablets, and Samsung DeX desktop windows:
/// - `< 720dp`: Mobile drawers
/// - `720–1099dp`: 2-pane (toggleable left sidebar + chat, quick panel as endDrawer)
/// - `>= 1100dp`: 3-pane desktop / DeX workspace with collapsible sidebars & keyboard shortcuts
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _showLeftSidebar = true;
  bool _showRightPanel = true;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final perms = ref.watch(permissionsProvider);
    final isTwoPane = width >= 720;
    final isThreePane = width >= 1100;
    final isDesktopUx = isTwoPane || perms.isDexMode;

    final bindings = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () {
        ref.read(sessionsProvider.notifier).createSession();
      },
      const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
        if (isTwoPane) {
          setState(() => _showLeftSidebar = !_showLeftSidebar);
        } else {
          _scaffoldKey.currentState?.openDrawer();
        }
      },
      const SingleActivator(LogicalKeyboardKey.keyI, control: true): () {
        if (isThreePane) {
          setState(() => _showRightPanel = !_showRightPanel);
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
              const SizedBox(width: 268, child: SessionsDrawer()),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: ChatScreen(
                isDesktopMode: isDesktopUx,
                onOpenSessions: () =>
                    setState(() => _showLeftSidebar = !_showLeftSidebar),
                onOpenQuickPanel: () =>
                    setState(() => _showRightPanel = !_showRightPanel),
              ),
            ),
            if (_showRightPanel) ...[
              const VerticalDivider(width: 1),
              const SizedBox(width: 316, child: QuickPanel()),
            ],
          ],
        ),
      );
    } else if (isTwoPane) {
      body = Scaffold(
        key: _scaffoldKey,
        endDrawer: Drawer(
          width: 320,
          child: QuickPanel(
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          ),
        ),
        body: Row(
          children: [
            if (_showLeftSidebar) ...[
              const SizedBox(width: 260, child: SessionsDrawer()),
              const VerticalDivider(width: 1),
            ],
            Expanded(
              child: ChatScreen(
                isDesktopMode: isDesktopUx,
                onOpenSessions: () =>
                    setState(() => _showLeftSidebar = !_showLeftSidebar),
                onOpenQuickPanel: () =>
                    _scaffoldKey.currentState?.openEndDrawer(),
              ),
            ),
          ],
        ),
      );
    } else {
      body = Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          width: 304,
          child: SessionsDrawer(
            onClose: () => _scaffoldKey.currentState?.closeDrawer(),
          ),
        ),
        endDrawer: Drawer(
          width: 316,
          child: QuickPanel(
            onClose: () => _scaffoldKey.currentState?.closeEndDrawer(),
          ),
        ),
        body: ChatScreen(
          isDesktopMode: isDesktopUx,
          onOpenSessions: () => _scaffoldKey.currentState?.openDrawer(),
          onOpenQuickPanel: () => _scaffoldKey.currentState?.openEndDrawer(),
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
