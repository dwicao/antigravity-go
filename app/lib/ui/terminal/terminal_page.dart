import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import '../../runtime/runtime_bridge.dart';
import '../../runtime/runtime_models.dart';
import '../../state/auth_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/usage_state.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final _cmdController = TextEditingController();
  final String _sessionId = const Uuid().v4();
  StreamSubscription<RuntimeEvent>? _termSub;
  bool _running = false;
  bool _sessionActive = false;

  @override
  void initState() {
    super.initState();
    _terminal.write('Antigravity Go Interactive Shell\r\n');
    _terminal.write(
      'Run commands or `agy` interactively (Ctrl+C, Tab, Esc keys above keyboard).\r\n\r\n',
    );
    _terminal.onOutput = (data) {
      if (_sessionActive) {
        RuntimeBridge.instance.writeTerminalInput(_sessionId, data);
      }
    };
    _termSub = RuntimeBridge.instance.events
        .where((e) => e.sessionId == _sessionId)
        .listen((evt) {
      if (!mounted) return;
      if (evt.kind == 'terminal_output' && evt.stdoutLine != null) {
        _terminal.write(evt.stdoutLine!.replaceAll('\n', '\r\n'));
      } else if (evt.kind == 'terminal_exit') {
        _terminal.write('\r\n[shell exited (${evt.exitCode ?? 0})]\r\n');
        setState(() => _sessionActive = false);
      }
    });
    Future.microtask(_startInteractiveShell);
  }

  Future<void> _startInteractiveShell() async {
    final proj = ref.read(projectsProvider).activeProject.primaryFolder;
    final cwd = proj.isNotEmpty
        ? proj
        : ref.read(runtimeProvider).status.workspaceRoot;
    await RuntimeBridge.instance.startTerminalSession(_sessionId, cwd: cwd);
    if (mounted) {
      setState(() => _sessionActive = true);
    }
  }

  @override
  void dispose() {
    _termSub?.cancel();
    RuntimeBridge.instance.closeTerminalSession(_sessionId);
    _cmdController.dispose();
    super.dispose();
  }

  Future<void> _sendRaw(String bytes) async {
    if (!_sessionActive) {
      await _startInteractiveShell();
    }
    await RuntimeBridge.instance.writeTerminalInput(_sessionId, bytes);
  }

  Future<void> _exec(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    _cmdController.clear();
    _terminal.write('\$ $trimmed\r\n');
    if (_sessionActive) {
      final sent = await RuntimeBridge.instance.writeTerminalInput(
        _sessionId,
        '$trimmed\n',
      );
      if (sent) {
        if (trimmed.contains('agy')) {
          Future.delayed(const Duration(seconds: 2), () {
            if (!mounted) return;
            ref.read(authProvider.notifier).refresh(verifyWithCli: true);
            ref.read(usageProvider.notifier).refreshFromRuntime();
          });
        }
        return;
      }
    }

    setState(() => _running = true);
    try {
      final cwd = ref.read(runtimeProvider).status.workspaceRoot;
      final out = await RuntimeBridge.instance.runShellCommand(
        command: trimmed,
        cwd: cwd,
      );
      if (out.isNotEmpty) {
        _terminal.write('${out.replaceAll('\n', '\r\n')}\r\n');
      }
      if (trimmed.contains('agy')) {
        await ref.read(authProvider.notifier).refresh(verifyWithCli: true);
        await ref.read(usageProvider.notifier).refreshFromRuntime();
      }
    } catch (e) {
      _terminal.write('Error: $e\r\n');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terminal & agy Shell'),
        actions: [
          IconButton(
            tooltip: 'Restart Shell',
            onPressed: _startInteractiveShell,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () => _terminal.buffer.clear(),
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: TerminalView(
              _terminal,
              autofocus: false,
            ),
          ),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              children: [
                for (final item in const [
                  ('Ctrl+C', '\x03'),
                  ('Ctrl+D', '\x04'),
                  ('Tab', '\t'),
                  ('Esc', '\x1b'),
                  ('↑', '\x1b[A'),
                  ('↓', '\x1b[B'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(item.$1),
                      onPressed: () => _sendRaw(item.$2),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cmdController,
                      onSubmitted: _exec,
                      decoration: const InputDecoration(
                        hintText: 'Run command (e.g. agy --version)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed:
                        _running ? null : () => _exec(_cmdController.text),
                    child: Text(_running ? '…' : 'Run'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
