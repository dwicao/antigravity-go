enum RuntimePhase {
  uninstalled,
  installing,
  stopped,
  starting,
  running,
  error,
}

class RuntimeStatus {
  const RuntimeStatus({
    required this.phase,
    this.agyVersion,
    this.binaryPath,
    this.workspaceRoot,
    this.installProgress = 0.0,
    this.statusMessage = '',
    this.errorMessage,
    this.safeMode = false,
  });

  const RuntimeStatus.initial()
      : phase = RuntimePhase.uninstalled,
        agyVersion = null,
        binaryPath = null,
        workspaceRoot = null,
        installProgress = 0.0,
        statusMessage = 'Not installed',
        errorMessage = null,
        safeMode = false;

  final RuntimePhase phase;
  final String? agyVersion;
  final String? binaryPath;
  final String? workspaceRoot;
  final double installProgress;
  final String statusMessage;
  final String? errorMessage;
  final bool safeMode;

  bool get isReady =>
      phase == RuntimePhase.running || phase == RuntimePhase.stopped;

  factory RuntimeStatus.fromMap(Map<Object?, Object?> map) {
    final phaseRaw = map['phase']?.toString() ?? 'uninstalled';
    final phase = RuntimePhase.values.firstWhere(
      (p) => p.name == phaseRaw,
      orElse: () => RuntimePhase.uninstalled,
    );
    return RuntimeStatus(
      phase: phase,
      agyVersion: map['agyVersion']?.toString(),
      binaryPath: map['binaryPath']?.toString(),
      workspaceRoot: map['workspaceRoot']?.toString(),
      installProgress: (map['installProgress'] as num?)?.toDouble() ?? 0.0,
      statusMessage: map['statusMessage']?.toString() ?? '',
      errorMessage: map['errorMessage']?.toString(),
      safeMode: map['safeMode'] as bool? ?? false,
    );
  }
}

class NativeBackgroundTask {
  const NativeBackgroundTask({
    required this.id,
    required this.turnId,
    required this.kind,
    required this.title,
    required this.status,
    required this.startedAt,
  });

  final String id;
  final String turnId;
  final String kind;
  final String title;
  final String status;
  final DateTime startedAt;

  factory NativeBackgroundTask.fromMap(Map<Object?, Object?> map) {
    final ms = (map['startedAtMs'] as num?)?.toInt() ?? 0;
    return NativeBackgroundTask(
      id: map['id']?.toString() ?? '',
      turnId: map['turnId']?.toString() ?? '',
      kind: map['kind']?.toString() ?? 'terminal',
      title: map['title']?.toString() ?? 'Background task',
      status: map['status']?.toString() ?? 'running',
      startedAt: ms > 0
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : DateTime.now(),
    );
  }
}

class RuntimeEvent {
  const RuntimeEvent({
    required this.kind,
    this.status,
    this.logLine,
    this.turnId,
    this.sessionId,
    this.stdoutLine,
    this.stderrLine,
    this.exitCode,
    this.backgroundTasks = const [],
  });

  final String kind;
  final RuntimeStatus? status;
  final String? logLine;
  final String? turnId;
  final String? sessionId;
  final String? stdoutLine;
  final String? stderrLine;
  final int? exitCode;
  final List<NativeBackgroundTask> backgroundTasks;

  factory RuntimeEvent.fromMap(Map<Object?, Object?> map) {
    final kind = map['kind']?.toString() ?? 'log';
    final statusRaw = map['status'];
    final rawTasks = map['tasks'];
    final tasks = rawTasks is List
        ? rawTasks
            .whereType<Map<Object?, Object?>>()
            .map(NativeBackgroundTask.fromMap)
            .toList()
        : const <NativeBackgroundTask>[];
    return RuntimeEvent(
      kind: kind,
      status: statusRaw is Map<Object?, Object?>
          ? RuntimeStatus.fromMap(statusRaw)
          : null,
      logLine: map['logLine']?.toString(),
      turnId: map['turnId']?.toString(),
      sessionId: map['sessionId']?.toString(),
      stdoutLine: map['stdoutLine']?.toString(),
      stderrLine: map['stderrLine']?.toString(),
      exitCode: (map['exitCode'] as num?)?.toInt(),
      backgroundTasks: tasks,
    );
  }
}
