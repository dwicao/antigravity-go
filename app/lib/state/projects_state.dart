import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'permissions_state.dart';
import 'runtime_state.dart';

class ProjectsState {
  const ProjectsState({
    this.projects = const [],
    this.activeProjectId = 'default',
  });

  final List<AgyProject> projects;
  final String activeProjectId;

  AgyProject get activeProject {
    for (final p in projects) {
      if (p.id == activeProjectId) return p;
    }
    return projects.isNotEmpty
        ? projects.first
        : const AgyProject(
            id: 'default',
            name: 'Default Workspace',
            folders: [],
          );
  }

  ProjectsState copyWith({
    List<AgyProject>? projects,
    String? activeProjectId,
  }) {
    return ProjectsState(
      projects: projects ?? this.projects,
      activeProjectId: activeProjectId ?? this.activeProjectId,
    );
  }
}

final projectsProvider =
    NotifierProvider<ProjectsNotifier, ProjectsState>(ProjectsNotifier.new);

class ProjectsNotifier extends Notifier<ProjectsState> {
  static const _projectsKey = 'agy_projects_v1';
  static const _activeProjectKey = 'agy_active_project_id';

  @override
  ProjectsState build() {
    Future.microtask(_load);
    return const ProjectsState(
      projects: [
        AgyProject(
          id: 'default',
          name: 'Default Workspace',
          folders: [],
        ),
      ],
    );
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_projectsKey);
    final activeId = prefs.getString(_activeProjectKey) ?? 'default';
    final loaded = <AgyProject>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded.whereType<Map<String, dynamic>>()) {
          loaded.add(AgyProject.fromJson(item));
        }
      } catch (_) {}
    }

    if (loaded.isEmpty) {
      final runtimeRoot = ref.read(runtimeProvider).status.workspaceRoot ?? '';
      final extRoot = ref.read(permissionsProvider).externalStorageRoot;
      loaded.addAll([
        AgyProject(
          id: 'default',
          name: 'App Workspace',
          folders: [if (runtimeRoot.isNotEmpty) runtimeRoot],
        ),
        AgyProject(
          id: 'downloads-projects',
          name: 'Device Downloads',
          folders: ['$extRoot/Download'],
          allowNonWorkspaceAccess: true,
        ),
      ]);
      await _persist(loaded);
    }

    state = ProjectsState(projects: loaded, activeProjectId: activeId);
  }

  Future<void> selectProject(String id) async {
    state = state.copyWith(activeProjectId: id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProjectKey, id);
  }

  Future<AgyProject> addProject({
    required String name,
    required List<String> folders,
    String hostId = 'local',
    WorktreeMode worktreeMode = WorktreeMode.local,
    AntigravityPermissionPreset? permissionPreset,
  }) async {
    final created = AgyProject(
      id: const Uuid().v4(),
      name: name.trim(),
      folders: folders.where((f) => f.trim().isNotEmpty).toList(),
      hostId: hostId,
      worktreeMode: worktreeMode,
      permissionPreset: permissionPreset,
    );
    final next = [...state.projects, created];
    state = ProjectsState(projects: next, activeProjectId: created.id);
    await _persist(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeProjectKey, created.id);
    return created;
  }

  Future<void> updateProject(AgyProject project) async {
    final next = state.projects
        .map((p) => p.id == project.id ? project : p)
        .toList();
    state = state.copyWith(projects: next);
    await _persist(next);
  }

  Future<void> deleteProject(String id) async {
    if (state.projects.length <= 1) return;
    final next = state.projects.where((p) => p.id != id).toList();
    final active =
        state.activeProjectId == id ? next.first.id : state.activeProjectId;
    state = ProjectsState(projects: next, activeProjectId: active);
    await _persist(next);
  }

  Future<void> _persist(List<AgyProject> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _projectsKey,
      jsonEncode(list.map((p) => p.toJson()).toList()),
    );
  }
}
