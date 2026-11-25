import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SidePanelTabKind {
  files('Files'),
  terminal('Terminal'),
  preview('Preview'),
  browser('Browser'),
  artifact('Artifact'),
  usage('Usage');

  const SidePanelTabKind(this.label);
  final String label;
}

class SidePanelTab {
  const SidePanelTab({
    required this.id,
    required this.kind,
    required this.title,
    this.content,
    this.path,
  });

  final String id;
  final SidePanelTabKind kind;
  final String title;
  final String? content;
  final String? path;
}

class SidePanelState {
  const SidePanelState({
    this.showOverview = false,
    this.showSidePanel = false,
    this.tabs = const [
      SidePanelTab(id: 'files', kind: SidePanelTabKind.files, title: 'Files'),
      SidePanelTab(
        id: 'terminal',
        kind: SidePanelTabKind.terminal,
        title: 'Terminal',
      ),
    ],
    this.activeTabId = 'files',
  });

  final bool showOverview;
  final bool showSidePanel;
  final List<SidePanelTab> tabs;
  final String activeTabId;

  SidePanelTab? get activeTab {
    for (final t in tabs) {
      if (t.id == activeTabId) return t;
    }
    return tabs.isEmpty ? null : tabs.first;
  }

  SidePanelState copyWith({
    bool? showOverview,
    bool? showSidePanel,
    List<SidePanelTab>? tabs,
    String? activeTabId,
  }) {
    return SidePanelState(
      showOverview: showOverview ?? this.showOverview,
      showSidePanel: showSidePanel ?? this.showSidePanel,
      tabs: tabs ?? this.tabs,
      activeTabId: activeTabId ?? this.activeTabId,
    );
  }
}

final sidePanelProvider =
    NotifierProvider<SidePanelNotifier, SidePanelState>(SidePanelNotifier.new);

class SidePanelNotifier extends Notifier<SidePanelState> {
  @override
  SidePanelState build() => const SidePanelState();

  void toggleOverview() {
    state = state.copyWith(showOverview: !state.showOverview);
  }

  void toggleSidePanel() {
    state = state.copyWith(showSidePanel: !state.showSidePanel);
  }

  void openTab(SidePanelTab tab) {
    final exists = state.tabs.any((t) => t.id == tab.id);
    final nextTabs = exists
        ? state.tabs.map((t) => t.id == tab.id ? tab : t).toList()
        : [...state.tabs, tab];
    state = state.copyWith(
      showSidePanel: true,
      tabs: nextTabs,
      activeTabId: tab.id,
    );
  }

  void selectTab(String id) {
    state = state.copyWith(showSidePanel: true, activeTabId: id);
  }

  void closeTab(String id) {
    final next = state.tabs.where((t) => t.id != id).toList();
    if (next.isEmpty) {
      state = state.copyWith(showSidePanel: false);
      return;
    }
    final nextActive =
        state.activeTabId == id ? next.first.id : state.activeTabId;
    state = state.copyWith(tabs: next, activeTabId: nextActive);
  }
}
