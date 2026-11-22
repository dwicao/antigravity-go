import 'package:flutter/material.dart';

import '../chat/chat_screen.dart';
import 'quick_panel.dart';
import 'sessions_drawer.dart';

/// Adaptive shell matching DSH Go: phone uses drawers, >= 840dp docks sidebars.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final isWide = width >= 960;

    if (isWide) {
      return Scaffold(
        body: Row(
          children: [
            const SizedBox(width: 280, child: SessionsDrawer()),
            const VerticalDivider(width: 1),
            const Expanded(child: ChatScreen()),
            const VerticalDivider(width: 1),
            const SizedBox(width: 300, child: QuickPanel()),
          ],
        ),
      );
    }

    return Scaffold(
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
        onOpenSessions: () => _scaffoldKey.currentState?.openDrawer(),
        onOpenQuickPanel: () => _scaffoldKey.currentState?.openEndDrawer(),
      ),
    );
  }
}
