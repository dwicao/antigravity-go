import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../runtime/runtime_bridge.dart';
import '../../state/runtime_state.dart';

class TerminalPage extends ConsumerStatefulWidget {
  const TerminalPage({super.key});

  @override
  ConsumerState<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends ConsumerState<TerminalPage> {
  final Terminal _terminal = Terminal(maxLines: 5000);
  final _cmdController = TextEditingController();
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _terminal.write('Antigravity Go Terminal\r\n');
    _terminal.write(
      'Type any command (e.g. `agy --version`, `agy models`, `ls -la`)\r\n\r\n',
    );
  }

  @override
  void dispose() {
    _cmdController.dispose();
    super.dispose();
  }

  Future<void> _exec(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    _cmdController.clear();
    _terminal.write('\$ $trimmed\r\n');
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
