import 'permission_preset.dart';

enum WorktreeMode {
  local('Local'),
  newWorktree('New Worktree');

  const WorktreeMode(this.label);
  final String label;
}

/// Project workspace configuration matching Antigravity App Projects.
class AgyProject {
  const AgyProject({
    required this.id,
    required this.name,
    required this.folders,
    this.hostId = 'local',
    this.worktreeMode = WorktreeMode.local,
    this.permissionPreset,
    this.allowNonWorkspaceAccess,
  });

  final String id;
  final String name;
  final List<String> folders;
  final String hostId;
  final WorktreeMode worktreeMode;
  final AntigravityPermissionPreset? permissionPreset;
  final bool? allowNonWorkspaceAccess;

  String get primaryFolder => folders.isEmpty ? '' : folders.first;

  AgyProject copyWith({
    String? name,
    List<String>? folders,
    String? hostId,
    WorktreeMode? worktreeMode,
    AntigravityPermissionPreset? permissionPreset,
    bool clearPreset = false,
    bool? allowNonWorkspaceAccess,
  }) {
    return AgyProject(
      id: id,
      name: name ?? this.name,
      folders: folders ?? this.folders,
      hostId: hostId ?? this.hostId,
      worktreeMode: worktreeMode ?? this.worktreeMode,
      permissionPreset:
          clearPreset ? null : (permissionPreset ?? this.permissionPreset),
      allowNonWorkspaceAccess:
          allowNonWorkspaceAccess ?? this.allowNonWorkspaceAccess,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'folders': folders,
        'hostId': hostId,
        'worktreeMode': worktreeMode.name,
        if (permissionPreset != null)
          'permissionPreset': permissionPreset!.name,
        if (allowNonWorkspaceAccess != null)
          'allowNonWorkspaceAccess': allowNonWorkspaceAccess,
      };

  factory AgyProject.fromJson(Map<String, dynamic> json) {
    return AgyProject(
      id: json['id'] as String? ?? 'default',
      name: json['name'] as String? ?? 'Default Project',
      folders: (json['folders'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      hostId: json['hostId'] as String? ?? 'local',
      worktreeMode: json['worktreeMode'] == 'newWorktree'
          ? WorktreeMode.newWorktree
          : WorktreeMode.local,
      permissionPreset: json['permissionPreset'] != null
          ? AntigravityPermissionPreset.fromString(
              json['permissionPreset'] as String?,
            )
          : null,
      allowNonWorkspaceAccess: json['allowNonWorkspaceAccess'] as bool?,
    );
  }
}
