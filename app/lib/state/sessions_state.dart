import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'hosts_state.dart';
import 'projects_state.dart';
import 'runtime_state.dart';
import 'settings_state.dart';

class SessionsState {
  const SessionsState({
    this.sessions = const [],
    this.activeSessionId,
  });

  final List<AgySessionSummary> sessions;
  final String? activeSessionId;

  AgySessionSummary? get activeSession {
    if (activeSessionId == null) return null;
    for (final s in sessions) {
      if (s.id == activeSessionId) return s;
    }
    return null;
  }

  SessionsState copyWith({
    List<AgySessionSummary>? sessions,
    String? activeSessionId,
  }) {
    return SessionsState(
      sessions: sessions ?? this.sessions,
      activeSessionId: activeSessionId ?? this.activeSessionId,
    );
  }
}

final sessionsProvider =
    NotifierProvider<SessionsNotifier, SessionsState>(SessionsNotifier.new);

class SessionsNotifier extends Notifier<SessionsState> {
  static const _prefsKey = 'agy_sessions_v1';

  @override
  SessionsState build() {
    Future.microtask(_load);
    return const SessionsState();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!ref.mounted) return;
    final raw = prefs.getString(_prefsKey);
    final loaded = <AgySessionSummary>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          loaded.add(AgySessionSummary.fromJson(item));
        }
      } catch (_) {}
    }

    if (loaded.isEmpty) {
      final first = _createDefaultSession();
      state = SessionsState(sessions: [first], activeSessionId: first.id);
      await _persist([first]);
      return;
    }

    loaded.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = SessionsState(
      sessions: loaded,
      activeSessionId: loaded.first.id,
    );
  }

  AgySessionSummary _createDefaultSession() {
    final hosts = ref.read(hostsProvider);
    final ssh = hosts.activeSshHost;
    final runtime = ref.read(runtimeProvider);
    final settings = ref.read(settingsProvider);
    final project = ref.read(projectsProvider).activeProject;

    return AgySessionSummary(
      id: const Uuid().v4(),
      title: 'New Agent Session',
      hostId: ssh?.id ?? 'local',
      hostName: ssh?.name ?? 'On Device',
      hostKind: ssh != null ? AgyHostKind.ssh : AgyHostKind.local,
      workspacePath: ssh?.defaultWorkspace ??
          (project.primaryFolder.isNotEmpty
              ? project.primaryFolder
              : (runtime.status.workspaceRoot ?? '')),
      projectId: project.id,
      modelId: settings.selectedModelId,
      updatedAt: DateTime.now(),
    );
  }

  Future<AgySessionSummary> createSession({String? title}) async {
    final created = _createDefaultSession();
    final item = title == null ? created : created.copyWith(title: title);
    final next = [item, ...state.sessions];
    state = SessionsState(sessions: next, activeSessionId: item.id);
    await _persist(next);
    return item;
  }

  void selectSession(String id) {
    state = state.copyWith(activeSessionId: id);
  }

  Future<void> updateSession(AgySessionSummary updated) async {
    final next = state.sessions
        .map((s) => s.id == updated.id ? updated : s)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    state = state.copyWith(sessions: next);
    await _persist(next);
  }

  Future<void> renameSession(String id, String title) async {
    final target = state.sessions.where((s) => s.id == id).firstOrNull;
    if (target == null) return;
    await updateSession(target.copyWith(title: title.trim()));
  }

  Future<void> deleteSession(String id) async {
    final next = state.sessions.where((s) => s.id != id).toList();
    if (next.isEmpty) {
      final created = _createDefaultSession();
      state = SessionsState(sessions: [created], activeSessionId: created.id);
      await _persist([created]);
      return;
    }
    final nextActive =
        state.activeSessionId == id ? next.first.id : state.activeSessionId;
    state = SessionsState(sessions: next, activeSessionId: nextActive);
    await _persist(next);
  }

  Future<void> _persist(List<AgySessionSummary> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(list.map((s) => s.toJson()).toList()),
    );
  }
}
