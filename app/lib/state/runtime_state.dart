import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_models.dart';

class RuntimeUiState {
  const RuntimeUiState({
    this.status = const RuntimeStatus.initial(),
    this.logs = const [],
    this.busy = false,
    this.backgroundTasks = const [],
  });

  final RuntimeStatus status;
  final List<String> logs;
  final bool busy;
  final List<NativeBackgroundTask> backgroundTasks;

  RuntimeUiState copyWith({
    RuntimeStatus? status,
    List<String>? logs,
    bool? busy,
    List<NativeBackgroundTask>? backgroundTasks,
  }) {
    return RuntimeUiState(
      status: status ?? this.status,
      logs: logs ?? this.logs,
      busy: busy ?? this.busy,
      backgroundTasks: backgroundTasks ?? this.backgroundTasks,
    );
  }
}

final runtimeProvider =
    NotifierProvider<RuntimeNotifier, RuntimeUiState>(RuntimeNotifier.new);

class RuntimeNotifier extends Notifier<RuntimeUiState> {
  StreamSubscription<RuntimeEvent>? _sub;

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
    return const RuntimeUiState();
  }

  Future<void> refresh() async {
    final status = await RuntimeBridge.instance.getStatus();
    final logs = await RuntimeBridge.instance.getLogs();
    final tasks = await RuntimeBridge.instance.getBackgroundTasks();
    if (!ref.mounted) return;
    state = state.copyWith(
      status: status,
      logs: logs,
      backgroundTasks: tasks,
    );
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
    state = state.copyWith(busy: true);
    try {
      await RuntimeBridge.instance.startService();
      await refresh();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> stop() async {
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
