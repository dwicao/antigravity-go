enum AutomationModelTier {
  flashLite('Flash Lite', 'gemini-3.8-flash'),
  flash('Flash', 'gemini-4-hydrogen'),
  pro('Pro', 'gemini-4-neon');

  const AutomationModelTier(this.label, this.modelId);

  final String label;
  final String modelId;
}

class AgyAutomation {
  const AgyAutomation({
    required this.id,
    required this.name,
    required this.prompt,
    required this.scheduleLabel,
    this.projectId = 'default',
    this.modelTier = AutomationModelTier.flash,
    this.enabled = true,
    this.lastRunAt,
    this.lastStatus,
  });

  final String id;
  final String name;
  final String prompt;
  final String scheduleLabel;
  final String projectId;
  final AutomationModelTier modelTier;
  final bool enabled;
  final DateTime? lastRunAt;
  final String? lastStatus;

  AgyAutomation copyWith({
    String? name,
    String? prompt,
    String? scheduleLabel,
    String? projectId,
    AutomationModelTier? modelTier,
    bool? enabled,
    DateTime? lastRunAt,
    String? lastStatus,
  }) {
    return AgyAutomation(
      id: id,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      scheduleLabel: scheduleLabel ?? this.scheduleLabel,
      projectId: projectId ?? this.projectId,
      modelTier: modelTier ?? this.modelTier,
      enabled: enabled ?? this.enabled,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      lastStatus: lastStatus ?? this.lastStatus,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'prompt': prompt,
        'scheduleLabel': scheduleLabel,
        'projectId': projectId,
        'modelTier': modelTier.name,
        'enabled': enabled,
        if (lastRunAt != null) 'lastRunAt': lastRunAt!.toIso8601String(),
        if (lastStatus != null) 'lastStatus': lastStatus,
      };

  factory AgyAutomation.fromJson(Map<String, dynamic> json) {
    final tierName = json['modelTier'] as String?;
    return AgyAutomation(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Scheduled Task',
      prompt: json['prompt'] as String? ?? '',
      scheduleLabel: json['scheduleLabel'] as String? ?? 'Daily · 09:00',
      projectId: json['projectId'] as String? ?? 'default',
      modelTier: AutomationModelTier.values.firstWhere(
        (t) => t.name == tierName,
        orElse: () => AutomationModelTier.flash,
      ),
      enabled: json['enabled'] as bool? ?? true,
      lastRunAt: json['lastRunAt'] != null
          ? DateTime.tryParse(json['lastRunAt'] as String)
          : null,
      lastStatus: json['lastStatus'] as String?,
    );
  }
}
