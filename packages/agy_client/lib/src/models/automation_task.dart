enum AutomationModelTier {
  flashLite('Flash Lite', 'gemini-3.8-flash'),
  flash('Flash', 'gemini-4-hydrogen'),
  pro('Pro', 'gemini-4-neon');

  const AutomationModelTier(this.label, this.modelId);

  final String label;
  final String modelId;
}

enum AutomationTriggerType {
  schedule('Schedule / Cron'),
  fileWatch('File Watch'),
  githubPr('GitHub PRs'),
  githubIssue('GitHub Issues'),
  batteryBelow('Battery Below %');

  const AutomationTriggerType(this.label);

  final String label;
}

class AgyAutomation {
  const AgyAutomation({
    required this.id,
    required this.name,
    required this.prompt,
    required this.scheduleLabel,
    this.projectId = 'default',
    this.modelTier = AutomationModelTier.flash,
    this.triggerType = AutomationTriggerType.schedule,
    this.triggerTarget = '',
    this.notifyOnComplete = true,
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
  final AutomationTriggerType triggerType;
  final String triggerTarget;
  final bool notifyOnComplete;
  final bool enabled;
  final DateTime? lastRunAt;
  final String? lastStatus;

  /// Parses [scheduleLabel] (e.g. `Every 15m`, `Every 2h`, `Hourly`,
  /// `Daily · 09:00`, or 5-field cron `*/15 * * * *`) and returns whether
  /// this schedule automation is due at [now].
  bool isDueAt(DateTime now) {
    if (!enabled || triggerType != AutomationTriggerType.schedule) return false;
    final raw = scheduleLabel.trim().toLowerCase();
    if (raw.isEmpty) return false;

    final minMatch = RegExp(r'every\s+(\d+)\s*m').firstMatch(raw);
    if (minMatch != null) {
      final mins = int.tryParse(minMatch.group(1)!) ?? 0;
      if (mins <= 0) return false;
      return lastRunAt == null ||
          now.difference(lastRunAt!) >= Duration(minutes: mins);
    }

    final hourMatch = RegExp(r'every\s+(\d+)\s*h').firstMatch(raw);
    if (hourMatch != null) {
      final hrs = int.tryParse(hourMatch.group(1)!) ?? 0;
      if (hrs <= 0) return false;
      return lastRunAt == null ||
          now.difference(lastRunAt!) >= Duration(hours: hrs);
    }

    if (raw.contains('hourly')) {
      return lastRunAt == null ||
          now.difference(lastRunAt!) >= const Duration(hours: 1);
    }

    // 5-field standard cron expression (minute hour dom month dow)
    final cronParts = raw.split(RegExp(r'\s+'));
    if (cronParts.length == 5) {
      final local = now.toLocal();
      if (_matchesCron(cronParts, local)) {
        if (lastRunAt == null) return true;
        final lastLocal = lastRunAt!.toLocal();
        return lastLocal.year != local.year ||
            lastLocal.month != local.month ||
            lastLocal.day != local.day ||
            lastLocal.hour != local.hour ||
            lastLocal.minute != local.minute;
      }
      return false;
    }

    final timeMatch = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(raw);
    if (timeMatch != null) {
      final targetHour = int.tryParse(timeMatch.group(1)!) ?? 9;
      final targetMin = int.tryParse(timeMatch.group(2)!) ?? 0;
      if (targetHour < 0 || targetHour > 23 || targetMin < 0 || targetMin > 59) {
        return false;
      }
      final localNow = now.toLocal();
      final scheduledToday = DateTime(
        localNow.year,
        localNow.month,
        localNow.day,
        targetHour,
        targetMin,
      );
      if (localNow.isBefore(scheduledToday)) return false;
      if (lastRunAt == null) return true;
      return lastRunAt!.toLocal().isBefore(scheduledToday);
    }

    return false;
  }

  static bool _matchesCron(List<String> fields, DateTime local) {
    final values = [
      local.minute,
      local.hour,
      local.day,
      local.month,
      local.weekday % 7,
    ];
    for (var i = 0; i < 5; i++) {
      if (!_matchesCronField(fields[i], values[i])) return false;
    }
    return true;
  }

  static bool _matchesCronField(String expr, int value) {
    for (final part in expr.split(',')) {
      final trimmed = part.trim();
      if (trimmed == '*') return true;
      if (trimmed.contains('/')) {
        final pieces = trimmed.split('/');
        final step = int.tryParse(pieces.last) ?? 0;
        if (step <= 0) continue;
        final base = pieces.first;
        if (base == '*' && value % step == 0) return true;
        if (base.contains('-')) {
          final bounds = base.split('-');
          final lo = int.tryParse(bounds.first) ?? -1;
          final hi = int.tryParse(bounds.last) ?? -1;
          if (value >= lo && value <= hi && (value - lo) % step == 0) {
            return true;
          }
        }
      } else if (trimmed.contains('-')) {
        final bounds = trimmed.split('-');
        final lo = int.tryParse(bounds.first) ?? -1;
        final hi = int.tryParse(bounds.last) ?? -1;
        if (value >= lo && value <= hi) return true;
      } else {
        if (int.tryParse(trimmed) == value) return true;
      }
    }
    return false;
  }

  AgyAutomation copyWith({
    String? name,
    String? prompt,
    String? scheduleLabel,
    String? projectId,
    AutomationModelTier? modelTier,
    AutomationTriggerType? triggerType,
    String? triggerTarget,
    bool? notifyOnComplete,
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
      triggerType: triggerType ?? this.triggerType,
      triggerTarget: triggerTarget ?? this.triggerTarget,
      notifyOnComplete: notifyOnComplete ?? this.notifyOnComplete,
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
        'triggerType': triggerType.name,
        if (triggerTarget.isNotEmpty) 'triggerTarget': triggerTarget,
        'notifyOnComplete': notifyOnComplete,
        'enabled': enabled,
        if (lastRunAt != null) 'lastRunAt': lastRunAt!.toIso8601String(),
        if (lastStatus != null) 'lastStatus': lastStatus,
      };

  factory AgyAutomation.fromJson(Map<String, dynamic> json) {
    final tierName = json['modelTier'] as String?;
    final trigName = json['triggerType'] as String?;
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
      triggerType: AutomationTriggerType.values.firstWhere(
        (t) => t.name == trigName,
        orElse: () => AutomationTriggerType.schedule,
      ),
      triggerTarget: json['triggerTarget'] as String? ?? '',
      notifyOnComplete: json['notifyOnComplete'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
      lastRunAt: json['lastRunAt'] != null
          ? DateTime.tryParse(json['lastRunAt'] as String)
          : null,
      lastStatus: json['lastStatus'] as String?,
    );
  }
}
