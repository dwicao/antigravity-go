/// Host target where an Antigravity session runs.
enum AgyHostKind { local, ssh }

/// Saved conversation metadata shown in the Sessions Drawer.
class AgySessionSummary {
  const AgySessionSummary({
    required this.id,
    required this.title,
    required this.hostId,
    required this.hostName,
    required this.hostKind,
    required this.workspacePath,
    required this.modelId,
    required this.updatedAt,
    this.projectId = 'default',
    this.remoteConversationId,
    this.messageCount = 0,
    this.lastPreview,
  });

  final String id;
  final String title;
  final String hostId;
  final String hostName;
  final AgyHostKind hostKind;
  final String workspacePath;
  final String modelId;
  final DateTime updatedAt;
  final String projectId;
  final String? remoteConversationId;
  final int messageCount;
  final String? lastPreview;

  AgySessionSummary copyWith({
    String? title,
    String? modelId,
    DateTime? updatedAt,
    String? projectId,
    String? workspacePath,
    String? remoteConversationId,
    int? messageCount,
    String? lastPreview,
  }) {
    return AgySessionSummary(
      id: id,
      title: title ?? this.title,
      hostId: hostId,
      hostName: hostName,
      hostKind: hostKind,
      workspacePath: workspacePath ?? this.workspacePath,
      modelId: modelId ?? this.modelId,
      updatedAt: updatedAt ?? this.updatedAt,
      projectId: projectId ?? this.projectId,
      remoteConversationId: remoteConversationId ?? this.remoteConversationId,
      messageCount: messageCount ?? this.messageCount,
      lastPreview: lastPreview ?? this.lastPreview,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'hostId': hostId,
        'hostName': hostName,
        'hostKind': hostKind.name,
        'workspacePath': workspacePath,
        'modelId': modelId,
        'updatedAt': updatedAt.toIso8601String(),
        'projectId': projectId,
        if (remoteConversationId != null)
          'remoteConversationId': remoteConversationId,
        'messageCount': messageCount,
        if (lastPreview != null) 'lastPreview': lastPreview,
      };

  factory AgySessionSummary.fromJson(Map<String, dynamic> json) {
    return AgySessionSummary(
      id: json['id'] as String,
      title: json['title'] as String? ?? 'New Chat',
      hostId: json['hostId'] as String? ?? 'local',
      hostName: json['hostName'] as String? ?? 'On Device',
      hostKind: json['hostKind'] == 'ssh' ? AgyHostKind.ssh : AgyHostKind.local,
      workspacePath: json['workspacePath'] as String? ?? '',
      modelId: json['modelId'] as String? ?? 'Orchestrator (Neon)',
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
      projectId: json['projectId'] as String? ?? 'default',
      remoteConversationId: json['remoteConversationId'] as String?,
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      lastPreview: json['lastPreview'] as String?,
    );
  }
}
