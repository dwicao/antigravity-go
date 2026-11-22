import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/services.dart';

import 'runtime_models.dart';

/// Platform bridge to Kotlin `RuntimePlugin` (`agy/runtime` & `agy/runtime/events`).
class RuntimeBridge {
  RuntimeBridge._();
  static final RuntimeBridge instance = RuntimeBridge._();

  static const MethodChannel _method = MethodChannel('agy/runtime');
  static const EventChannel _events = EventChannel('agy/runtime/events');

  Stream<RuntimeEvent>? _broadcast;

  Stream<RuntimeEvent> get events {
    _broadcast ??= _events
        .receiveBroadcastStream()
        .where((e) => e is Map)
        .map((e) => RuntimeEvent.fromMap(e as Map<Object?, Object?>))
        .asBroadcastStream();
    return _broadcast!;
  }

  Future<RuntimeStatus> getStatus() async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>('status');
      if (raw == null) return const RuntimeStatus.initial();
      return RuntimeStatus.fromMap(raw);
    } on MissingPluginException {
      return const RuntimeStatus.initial();
    }
  }

  Future<void> installRuntime({String? customManifestUrl}) async {
    await _method.invokeMethod<void>('install', {
      'manifestUrl': ?customManifestUrl,
    });
  }

  Future<void> startService() async {
    await _method.invokeMethod<void>('start');
  }

  Future<void> stopService() async {
    await _method.invokeMethod<void>('stop');
  }

  Future<void> resetRuntime() async {
    await _method.invokeMethod<void>('reset');
  }

  Future<void> setSafeMode(bool enabled) async {
    await _method.invokeMethod<void>('setSafeMode', {'enabled': enabled});
  }

  Future<List<String>> getLogs() async {
    try {
      final raw = await _method.invokeMethod<List<Object?>>('logs');
      return raw?.map((e) => e.toString()).toList() ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<void> writeCliSettings(Map<String, dynamic> settings) async {
    await _method.invokeMethod<void>('writeSettings', {'settings': settings});
  }

  Future<Map<String, dynamic>> readCliSettings() async {
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('readSettings');
      if (raw == null) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {};
    }
  }

  Future<Map<String, dynamic>> checkAuthStatus() async {
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('authStatus');
      if (raw == null) return const {'isAuthenticated': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'isAuthenticated': false};
    }
  }

  Future<void> startGoogleLogin({bool enterprise = false}) async {
    await _method.invokeMethod<void>('startLogin', {
      'enterprise': enterprise,
    });
  }

  Future<void> submitLoginCode(String code) async {
    await _method.invokeMethod<void>('submitLoginCode', {'code': code});
  }

  Future<void> logout() async {
    await _method.invokeMethod<void>('logout');
  }

  Future<String> runCommandCapture({
    required List<String> args,
    String? cwd,
    Map<String, String>? env,
    int timeoutSeconds = 20,
  }) async {
    final result = await _method.invokeMethod<String>('runCapture', {
      'args': args,
      'cwd': ?cwd,
      'env': ?env,
      'timeoutSeconds': timeoutSeconds,
    });
    return result ?? '';
  }

  Future<String> runShellCommand({
    required String command,
    String? cwd,
  }) async {
    final result = await _method.invokeMethod<String>('runShell', {
      'command': command,
      'cwd': ?cwd,
    });
    return result ?? '';
  }

  /// Starts a streaming `agy -p ... --output-format stream-json` turn on device.
  Stream<AgyChatEvent> runPrompt(AgyPromptRequest request, String turnId) async* {
    final controller = StreamController<AgyChatEvent>();
    late final StreamSubscription<RuntimeEvent> sub;

    sub = events.listen((evt) {
      if (evt.turnId != turnId) return;
      if (evt.kind == 'turn_stdout' && evt.stdoutLine != null) {
        final parsed = StreamJsonParser.parseLine(evt.stdoutLine!);
        if (parsed != null) {
          controller.add(parsed);
        }
      } else if (evt.kind == 'turn_stderr' && evt.stderrLine != null) {
        final line = evt.stderrLine!.trim();
        if (line.isNotEmpty) {
          if (line.toLowerCase().contains('authentication required') ||
              line.toLowerCase().contains('not signed in')) {
            controller.add(AgyErrorEvent(message: line, requiresAuth: true));
          }
        }
      } else if (evt.kind == 'turn_exit') {
        if ((evt.exitCode ?? 0) != 0 && !controller.isClosed) {
          controller.add(
            AgyErrorEvent(
              message: 'agy exited with code ${evt.exitCode}',
            ),
          );
        }
        controller.close();
      }
    });

    try {
      await _method.invokeMethod<void>('startTurn', {
        'turnId': turnId,
        'prompt': request.prompt,
        'cwd': request.workspacePath,
        'conversationId': ?request.conversationId,
        'model': ?request.modelId,
        'effort': ?request.effortCliValue,
        'mode': request.mode.cliValue,
        'skipPermissions': request.dangerouslySkipPermissions,
        'geminiApiKey': ?request.geminiApiKey,
      });

      await for (final evt in controller.stream) {
        yield evt;
      }
    } finally {
      await sub.cancel();
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  Future<void> cancelTurn(String turnId) async {
    await _method.invokeMethod<void>('cancelTurn', {'turnId': turnId});
  }

  Future<List<Map<String, String>>> listWorkspaceEntries(String path) async {
    try {
      final raw = await _method.invokeMethod<List<Object?>>(
        'listWorkspace',
        {'path': path},
      );
      if (raw == null) return const [];
      return raw.whereType<Map<Object?, Object?>>().map((m) {
        return m.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }).toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<String> readWorkspaceFile(String path) async {
    return await _method.invokeMethod<String>('readFile', {'path': path}) ??
        '';
  }
}
