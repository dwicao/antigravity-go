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

  Future<void> setGuardrailsEnabled(bool enabled) async {
    try {
      await _method.invokeMethod<void>(
        'setGuardrailsEnabled',
        {'enabled': enabled},
      );
    } on MissingPluginException {
      // No-op in headless widget tests.
    }
  }

  Future<void> setLifecycleHooks(String hooksJson) async {
    try {
      await _method.invokeMethod<void>(
        'setLifecycleHooks',
        {'hooksJson': hooksJson},
      );
    } on MissingPluginException {
      // No-op in headless widget tests.
    }
  }

  Future<void> setPhoneMcpMinimalMode(bool minimal) async {
    try {
      await _method.invokeMethod<void>(
        'setPhoneMcpMinimalMode',
        {'minimal': minimal},
      );
    } on MissingPluginException {
      // No-op in headless widget tests.
    }
  }

  Future<void> prewarmAcpWorker({
    String? cwd,
    List<String> extraDirs = const [],
    bool skipPermissions = true,
    String? agent,
  }) async {
    try {
      await _method.invokeMethod<void>(
        'prewarmAcpWorker',
        {
          'cwd': ?cwd,
          if (extraDirs.isNotEmpty) 'extraDirs': extraDirs,
          'skipPermissions': skipPermissions,
          'agent': ?agent,
        },
      );
    } on MissingPluginException {
      // No-op in headless widget tests.
    }
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

  Future<Map<String, dynamic>> verifyAuth() async {
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('verifyAuth');
      if (raw == null) return const {'isAuthenticated': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'isAuthenticated': false};
    }
  }

  Future<String> exportCredentials({
    required String passphrase,
    String? geminiApiKey,
    String? authProfileJson,
    String? accountId,
  }) async {
    final res = await _method.invokeMethod<String>('exportCredentials', {
      'passphrase': passphrase,
      'geminiApiKey': ?geminiApiKey,
      'authProfileJson': ?authProfileJson,
      'accountId': ?accountId,
    });
    if (res == null || res.isEmpty) {
      throw StateError('Failed to create credentials bundle');
    }
    return res;
  }

  Future<Map<String, dynamic>> importCredentials({
    required String bundleJson,
    required String passphrase,
    bool activate = true,
    String? authProfileJson,
    String? geminiApiKey,
  }) async {
    final raw =
        await _method.invokeMethod<Map<Object?, Object?>>('importCredentials', {
      'bundleJson': bundleJson,
      'passphrase': passphrase,
      'activate': activate,
      'authProfileJson': ?authProfileJson,
      'geminiApiKey': ?geminiApiKey,
    });
    if (raw == null) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<List<Map<String, dynamic>>> listAccounts({
    String? authProfileJson,
    String? geminiApiKey,
  }) async {
    try {
      final raw = await _method.invokeMethod<List<Object?>>('listAccounts', {
        'authProfileJson': ?authProfileJson,
        'geminiApiKey': ?geminiApiKey,
      });
      if (raw == null) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<Map<String, dynamic>?> syncActiveAccount({
    String? authProfileJson,
    String? geminiApiKey,
  }) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'syncActiveAccount',
        {
          'authProfileJson': ?authProfileJson,
          'geminiApiKey': ?geminiApiKey,
        },
      );
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return null;
    }
  }

  Future<Map<String, dynamic>> switchAccount({
    required String accountId,
    String? authProfileJson,
    String? geminiApiKey,
  }) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'switchAccount',
      {
        'accountId': accountId,
        'authProfileJson': ?authProfileJson,
        'geminiApiKey': ?geminiApiKey,
      },
    );
    if (raw == null) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<Map<String, dynamic>> removeAccount({
    required String accountId,
  }) async {
    final raw = await _method.invokeMethod<Map<Object?, Object?>>(
      'removeAccount',
      {'accountId': accountId},
    );
    if (raw == null) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v));
  }

  Future<String> probeUsage() async {
    try {
      return await _method.invokeMethod<String>('probeUsage') ?? '';
    } on MissingPluginException {
      return '';
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

  /// Starts a streaming turn (`agy acp` by default for interactive permissions, or `-p stream-json`).
  Stream<AgyChatEvent> runPrompt(
    AgyPromptRequest request,
    String turnId, {
    bool useAcp = true,
    List<String> attachments = const [],
  }) async* {
    final controller = StreamController<AgyChatEvent>();
    final acpCodec = AcpCodec();
    final stderrTail = <String>[];
    late final StreamSubscription<RuntimeEvent> sub;

    sub = events.listen((evt) {
      if (evt.turnId != turnId) return;
      if (evt.kind == 'turn_acp_line' && evt.stdoutLine != null) {
        final parsed = acpCodec.parseNotificationOrRequest(evt.stdoutLine!);
        if (parsed != null) {
          controller.add(parsed);
        }
      } else if (evt.kind == 'turn_stdout' && evt.stdoutLine != null) {
        final parsed = StreamJsonParser.parseLine(evt.stdoutLine!);
        if (parsed != null) {
          controller.add(parsed);
        }
      } else if (evt.kind == 'turn_stderr' && evt.stderrLine != null) {
        final line = evt.stderrLine!.trim();
        if (line.isNotEmpty) {
          stderrTail.add(line);
          if (stderrTail.length > 6) stderrTail.removeAt(0);
          if (line.toLowerCase().contains('authentication required') ||
              line.toLowerCase().contains('not signed in')) {
            controller.add(AgyErrorEvent(message: line, requiresAuth: true));
          }
        }
      } else if (evt.kind == 'turn_exit') {
        if ((evt.exitCode ?? 0) != 0 && !controller.isClosed) {
          final detail = stderrTail.isNotEmpty
              ? '\n${stderrTail.join('\n')}'
              : '';
          controller.add(
            AgyErrorEvent(
              message: 'agy exited with code ${evt.exitCode}$detail',
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
        'extraDirs': request.extraDirs,
        'conversationId': ?request.conversationId,
        'model': ?request.modelId,
        'effort': ?request.effortCliValue,
        'mode': request.mode.cliValue,
        'skipPermissions': request.dangerouslySkipPermissions,
        'allowNonWorkspaceAccess': request.allowNonWorkspaceAccess,
        'useAcp': useAcp,
        'geminiApiKey': ?request.geminiApiKey,
        'agent': ?request.agentName,
        'printTimeoutSeconds': ?request.printTimeoutSeconds,
        'disableSlashCommands': request.disableSlashCommands,
        'continueLast': request.continueLast,
        'remoteAgent': ?request.remoteAgent,
        if (request.attachments.isNotEmpty) 'attachments': request.attachments,
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

  Future<void> respondPermission({
    required String turnId,
    required Object requestId,
    required String optionId,
  }) async {
    await _method.invokeMethod<void>('respondPermission', {
      'turnId': turnId,
      'requestId': requestId,
      'optionId': optionId,
    });
  }

  Future<void> cancelTurn(String turnId) async {
    await _method.invokeMethod<void>('cancelTurn', {'turnId': turnId});
  }

  Future<bool> closeSessionWorker(String sessionId) async {
    try {
      return await _method.invokeMethod<bool>(
            'closeSessionWorker',
            {'sessionId': sessionId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<List<NativeBackgroundTask>> getBackgroundTasks() async {
    try {
      final raw = await _method.invokeMethod<List<Object?>>('backgroundTasks');
      if (raw == null) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(NativeBackgroundTask.fromMap)
          .toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<bool> cancelBackgroundTask(String taskId) async {
    try {
      return await _method.invokeMethod<bool>(
            'cancelBackgroundTask',
            {'taskId': taskId},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<int> forceStopAllBackgroundTasks() async {
    try {
      return await _method.invokeMethod<int>('forceStopAllBackgroundTasks') ??
          0;
    } on MissingPluginException {
      return 0;
    }
  }

  Future<bool> writeWorkspaceFile(String path, String content) async {
    try {
      return await _method.invokeMethod<bool>('writeFile', {
            'path': path,
            'content': content,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> writeFile(String path, String content) =>
      writeWorkspaceFile(path, content);

  Future<bool> addHttpMcpServer({
    required String name,
    required String url,
    String? authHeader,
  }) async {
    try {
      return await _method.invokeMethod<bool>('addHttpMcpServer', {
            'name': name,
            'url': url,
            'authHeader': ?authHeader,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<List<CustomizationItem>> listCustomizations(String cwd) async {
    try {
      final raw = await _method.invokeMethod<List<Object?>>(
        'listCustomizations',
        {'cwd': cwd},
      );
      if (raw == null) return const [];
      return raw.whereType<Map<Object?, Object?>>().map((m) {
        final kindStr = m['kind']?.toString() ?? 'rule';
        final kind = CustomizationKind.values.firstWhere(
          (k) => k.name == kindStr,
          orElse: () => CustomizationKind.rule,
        );
        return CustomizationItem(
          kind: kind,
          name: m['name']?.toString() ?? '',
          scope: m['scope']?.toString() ?? 'Global',
          pathOrCommand: m['path']?.toString() ?? '',
          description: m['description']?.toString() ?? '',
          enabled: m['enabled'] as bool? ?? true,
          content: m['content']?.toString(),
        );
      }).toList();
    } on MissingPluginException {
      return const [];
    }
  }

  Future<String?> createSkill({
    required String name,
    String description = '',
    String scope = 'Project',
    String? cwd,
    String? content,
  }) async {
    try {
      return await _method.invokeMethod<String>('createSkill', {
        'name': name,
        'description': description,
        'scope': scope,
        'cwd': ?cwd,
        'content': ?content,
      });
    } on MissingPluginException {
      return null;
    }
  }

  Future<(String status, String diff)> gitDiff(String cwd) async {
    final detailed = await gitDiffDetailed(cwd);
    return (detailed.status, detailed.diff);
  }

  Future<
      ({
        String status,
        String diff,
        String branch,
        List<FileChangeEntry> files,
      })> gitDiffDetailed(String cwd) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'gitDiff',
        {'cwd': cwd},
      );
      final status = raw?['status']?.toString() ?? '';
      final diff = raw?['diff']?.toString() ?? '';
      final branch = raw?['branch']?.toString() ?? '';
      final numstat = raw?['numstat']?.toString() ?? '';
      return (
        status: status,
        diff: diff,
        branch: branch,
        files: FileChangeEntry.fromGitOutputs(
          status: status,
          numstat: numstat,
          diff: diff,
        ),
      );
    } on MissingPluginException {
      return (
        status: '',
        diff: '',
        branch: '',
        files: const <FileChangeEntry>[],
      );
    } on PlatformException {
      return (
        status: '',
        diff: '',
        branch: '',
        files: const <FileChangeEntry>[],
      );
    }
  }

  Future<
      ({
        bool ok,
        bool pushed,
        String branch,
        String commitHash,
        String output,
        List<FileChangeEntry> files,
      })> gitCommitAndPush({
    required String cwd,
    required String message,
    bool stageAll = true,
    bool push = true,
  }) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'gitCommitAndPush',
        {
          'cwd': cwd,
          'message': message,
          'stageAll': stageAll,
          'push': push,
        },
      );
      final numstat = raw?['numstat']?.toString() ?? '';
      final nameStatus = raw?['nameStatus']?.toString() ?? '';
      final commitDiff = raw?['commitDiff']?.toString() ?? '';
      final created = <String>{};
      final deleted = <String>{};
      for (final line in nameStatus.split('\n')) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        if (parts.first.startsWith('A')) created.add(parts.sublist(1).join(' '));
        if (parts.first.startsWith('D')) deleted.add(parts.sublist(1).join(' '));
      }
      final parsed = FileChangeEntry.parseGitNumstat(
        numstat,
        createdPaths: created,
        deletedPaths: deleted,
      );
      return (
        ok: raw?['ok'] as bool? ?? false,
        pushed: raw?['pushed'] as bool? ?? false,
        branch: raw?['branch']?.toString() ?? '',
        commitHash: raw?['commitHash']?.toString() ?? '',
        output: raw?['output']?.toString() ?? '',
        files: FileChangeEntry.attachUnifiedDiffs(parsed, commitDiff),
      );
    } on MissingPluginException {
      return (
        ok: false,
        pushed: false,
        branch: '',
        commitHash: '',
        output: 'Native runtime unavailable',
        files: const <FileChangeEntry>[],
      );
    }
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

  Future<bool> createDirectory(String path) async {
    return createWorkspaceDirectory(path);
  }

  Future<void> startTerminalSession(
    String sessionId, {
    String? cwd,
    int cols = 80,
    int rows = 24,
  }) async {
    try {
      await _method.invokeMethod<void>('startTerminalSession', {
        'sessionId': sessionId,
        'cwd': ?cwd,
        'cols': cols,
        'rows': rows,
      });
    } on MissingPluginException {
      // No-op in tests.
    }
  }

  Future<bool> resizeTerminalSession(
    String sessionId, {
    required int cols,
    required int rows,
  }) async {
    try {
      return await _method.invokeMethod<bool>('resizeTerminalSession', {
            'sessionId': sessionId,
            'cols': cols,
            'rows': rows,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> writeTerminalInput(String sessionId, String input) async {
    try {
      return await _method.invokeMethod<bool>('writeTerminalInput', {
            'sessionId': sessionId,
            'input': input,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> closeTerminalSession(String sessionId) async {
    try {
      await _method.invokeMethod<void>('closeTerminalSession', {
        'sessionId': sessionId,
      });
    } on MissingPluginException {
      // No-op in tests.
    }
  }

  Future<bool> createWorkspaceDirectory(String path) async {
    try {
      return await _method.invokeMethod<bool>(
            'createDirectory',
            {'path': path},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> deleteWorkspaceEntry(String path) async {
    try {
      return await _method.invokeMethod<bool>(
            'deleteWorkspaceEntry',
            {'path': path},
          ) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<Map<String, Object?>> diagnoseRuntime() async {
    try {
      final raw =
          await _method.invokeMethod<Map<Object?, Object?>>('diagnoseRuntime');
      if (raw == null) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {};
    }
  }

  Future<Map<String, Object?>> createCheckpoint({String? cwd}) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'createCheckpoint',
        {'cwd': ?cwd},
      );
      if (raw == null) return const {'ok': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'ok': false};
    }
  }

  Future<Map<String, Object?>> restoreCheckpoint({
    String? cwd,
    required String ref,
  }) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'restoreCheckpoint',
        {'cwd': ?cwd, 'ref': ref},
      );
      if (raw == null) return const {'ok': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'ok': false, 'message': 'Native runtime unavailable'};
    }
  }

  Future<Map<String, Object?>> revertPatch({
    String? cwd,
    required String patchText,
  }) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'revertPatch',
        {'cwd': ?cwd, 'patchText': patchText},
      );
      if (raw == null) return const {'ok': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'ok': false, 'message': 'Native runtime unavailable'};
    }
  }

  Future<Map<String, Object?>> initHarnessFiles({
    String? cwd,
    required String featureJson,
    required String progressTxt,
  }) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'initHarnessFiles',
        {
          'cwd': ?cwd,
          'featureJson': featureJson,
          'progressTxt': progressTxt,
        },
      );
      if (raw == null) return const {'ok': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'ok': false};
    }
  }

  Future<Map<String, Object?>> readHarnessFiles({String? cwd}) async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'readHarnessFiles',
        {'cwd': ?cwd},
      );
      if (raw == null) return const {'ok': false};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      return const {'ok': false};
    }
  }

  Future<bool> writeHarnessFile({
    String? cwd,
    required String name,
    required String content,
  }) async {
    try {
      return await _method.invokeMethod<bool>('writeHarnessFile', {
            'cwd': ?cwd,
            'name': name,
            'content': content,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
