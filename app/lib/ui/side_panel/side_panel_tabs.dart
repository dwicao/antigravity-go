import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../state/side_panel_state.dart';
import '../remote/remote_web_page.dart';
import '../terminal/terminal_page.dart';
import '../usage/usage_page.dart';
import '../workspace/diff_review_view.dart';
import '../workspace/workspace_page.dart';

/// 1:1 Antigravity Desktop Tabbed Side Panel (Files, Review, Terminal, Browser, Artifacts, Usage).
class SidePanelTabs extends ConsumerWidget {
  const SidePanelTabs({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(sidePanelProvider);
    final active = panel.activeTab;
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.4),
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final tab in panel.tabs)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 2,
                            vertical: 5,
                          ),
                          child: InputChip(
                            selected: tab.id == panel.activeTabId,
                            label: Text(tab.title),
                            onPressed: () => ref
                                .read(sidePanelProvider.notifier)
                                .selectTab(tab.id),
                            onDeleted: panel.tabs.length > 1
                                ? () => ref
                                    .read(sidePanelProvider.notifier)
                                    .closeTab(tab.id)
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<SidePanelTabKind>(
                  tooltip: 'New Side Tab',
                  icon: const Icon(Icons.add, size: 18),
                  onSelected: (kind) {
                    ref.read(sidePanelProvider.notifier).openTab(
                          SidePanelTab(
                            id: kind.name,
                            kind: kind,
                            title: kind.label,
                          ),
                        );
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: SidePanelTabKind.files,
                      child: Text('Files'),
                    ),
                    PopupMenuItem(
                      value: SidePanelTabKind.review,
                      child: Text('Review (Git Diff)'),
                    ),
                    PopupMenuItem(
                      value: SidePanelTabKind.terminal,
                      child: Text('Terminal'),
                    ),
                    PopupMenuItem(
                      value: SidePanelTabKind.browser,
                      child: Text('Built-in Browser'),
                    ),
                    PopupMenuItem(
                      value: SidePanelTabKind.usage,
                      child: Text('Usage Limits'),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Hide Side Panel (Ctrl+Shift+B)',
                  iconSize: 18,
                  onPressed: () =>
                      ref.read(sidePanelProvider.notifier).toggleSidePanel(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: active == null
                ? const SizedBox.shrink()
                : switch (active.kind) {
                    SidePanelTabKind.files => const WorkspacePage(),
                    SidePanelTabKind.review => const DiffReviewView(),
                    SidePanelTabKind.terminal => const TerminalPage(),
                    SidePanelTabKind.browser => const RemoteWebPage(),
                    SidePanelTabKind.usage => const UsagePage(),
                    SidePanelTabKind.artifact => SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: GptMarkdown(active.content ?? ''),
                      ),
                  },
          ),
        ],
      ),
    );
  }
}
