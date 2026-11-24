import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_models.dart';

class RuntimeUiState {
  const RuntimeUiState({
    this.status = const RuntimeStatus.initial(),
    this.logs = const [],
    this.busy = false,
    this.initialized = true,
    this.backgroundTasks = const [],
  });

  final RuntimeStatus status;
  final List<String> logs;
  final bool busy;
  final bool initialized;
  final List<NativeBackgroundTask> backgroundTasks;

  RuntimeUiState copyWith({
    RuntimeStatus? status,
    List<String>? logs,
    bool? busy,
    bool? initialized,
    List<NativeBackgroundTask>? backgroundTasks,
  }) {
    return RuntimeUiState(
      status: status ?? this.status,
      logs: logs ?? this.logs,
      busy: busy ?? this.busy,
      initialized: initialized ?? this.initialized,
      backgroundTasks: backgroundTasks ?? this.backgroundTasks,
    );
  }
}

final runtimeProvider =
    NotifierProvider<RuntimeNotifier, RuntimeUiState>(RuntimeNotifier.new);

class RuntimeNotifier extends Notifier<RuntimeUiState> {
  StreamSubscription<RuntimeEvent>? _sub;
  bool _autoStartAttempted = false;
  bool _manuallyStopped = false;

  @override
  RuntimeUiState build() {
    _sub?.cancel();
    _sub = RuntimeBridge.instance.events.listen((evt) {
      if (evt.status != null) {
        state = state.copyWith(status: evt.status);
      }
      if (evt.kind == 'background_tasks') {
        state = state.copyWith(backgroundTasks: evt.backgroundTasks);
      }
      if (evt.logLine != null) {
        final next = [...state.logs, evt.logLine!];
        if (next.length > 250) {
          next.removeRange(0, next.length - 250);
        }
        state = state.copyWith(logs: next);
      }
    });
    ref.onDispose(() => _sub?.cancel());
    Future.microtask(refresh);
    return const RuntimeUiState(initialized: false);
  }

  Future<void> refresh() async {
    var status = await RuntimeBridge.instance.getStatus();
    if (status.phase == RuntimePhase.stopped &&
        !_autoStartAttempted &&
        !_manuallyStopped) {
      _autoStartAttempted = true;
      try {
        await RuntimeBridge.instance.startService();
        status = await RuntimeBridge.instance.getStatus();
      } catch (_) {
        // Keep stopped state if foreground service launch is unavailable.
      }
    }
    final logs = await RuntimeBridge.instance.getLogs();
    final tasks = await RuntimeBridge.instance.getBackgroundTasks();
    if (!ref.mounted) return;
    state = state.copyWith(
      status: status,
      logs: logs,
      initialized: true,
      backgroundTasks: tasks,
    );
  }

  Future<void> ensureRunningOnResume() async {
    if (_manuallyStopped ||
        !state.initialized ||
        state.busy ||
        state.status.phase != RuntimePhase.stopped) {
      return;
    }
    try {
      await start();
    } catch (_) {}
  }

  Future<bool> cancelBackgroundTask(String taskId) async {
    final ok = await RuntimeBridge.instance.cancelBackgroundTask(taskId);
    await refresh();
    return ok;
  }

  Future<int> forceStopAllBackgroundTasks() async {
    final count = await RuntimeBridge.instance.forceStopAllBackgroundTasks();
    await refresh();
    return count;
  }

  Future<void> installAndStart() async {
    _manuallyStopped = false;
    _autoStartAttempted = true;
    state = state.copyWith(busy: true);
    try {
      await RuntimeBridge.instance.installRuntime();
      await RuntimeBridge.instance.startService();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> start() async {
    _manuallyStopped = false;
    _autoStartAttempted = true;
    state = state.copyWith(busy: true);
    try {
      await RuntimeBridge.instance.startService();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> stop() async {
    _manuallyStopped = true;
    state = state.copyWith(busy: true);
    try {
      await RuntimeBridge.instance.stopService();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> reset() async {
    state = state.copyWith(busy: true);
    try {
      await RuntimeBridge.instance.resetRuntime();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> setSafeMode(bool enabled) async {
    await RuntimeBridge.instance.setSafeMode(enabled);
    await refresh();
  }
}
