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

class RuntimeEvent {
  const RuntimeEvent({
    required this.kind,
    this.status,
    this.logLine,
    this.turnId,
    this.stdoutLine,
    this.stderrLine,
    this.exitCode,
  });

  final String kind;
  final RuntimeStatus? status;
  final String? logLine;
  final String? turnId;
  final String? stdoutLine;
  final String? stderrLine;
  final int? exitCode;

  factory RuntimeEvent.fromMap(Map<Object?, Object?> map) {
    final kind = map['kind']?.toString() ?? 'log';
    final statusRaw = map['status'];
    return RuntimeEvent(
      kind: kind,
      status: statusRaw is Map<Object?, Object?>
          ? RuntimeStatus.fromMap(statusRaw)
          : null,
      logLine: map['logLine']?.toString(),
      turnId: map['turnId']?.toString(),
      stdoutLine: map['stdoutLine']?.toString(),
      stderrLine: map['stderrLine']?.toString(),
      exitCode: (map['exitCode'] as num?)?.toInt(),
    );
  }
}
