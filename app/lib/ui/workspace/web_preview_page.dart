import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../state/chat_state.dart';
import '../../state/projects_state.dart';
import '../../state/runtime_state.dart';
import '../../state/sessions_state.dart';
import '../../theme/app_theme.dart';

class WebConsoleEntry {
  const WebConsoleEntry({
    required this.level,
    required this.message,
    required this.timestamp,
  });

  final String level;
  final String message;
  final DateTime timestamp;
}

/// In-app WebView Preview with an injected JS console logger (`console.log`,
/// `console.warn`, `console.error`, `window.onerror`, `unhandledrejection`)
/// and a 1-tap "Send Errors to Agent" action.
class WebPreviewPage extends ConsumerStatefulWidget {
  const WebPreviewPage({
    super.key,
    this.initialUrl = 'http://127.0.0.1:3000',
  });

  final String initialUrl;

  @override
  ConsumerState<WebPreviewPage> createState() => _WebPreviewPageState();
}

class _WebPreviewPageState extends ConsumerState<WebPreviewPage> {
  static const String _consoleHookJs = r'''
(function() {
  if (window.__agyConsoleHooked) return;
  window.__agyConsoleHooked = true;
  function send(level, args) {
    try {
      var msg = Array.prototype.slice.call(args).map(function(a) {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === 'object') {
          try { return JSON.stringify(a); } catch (_) { return String(a); }
        }
        return String(a);
      }).join(' ');
      if (window.AgyConsole && window.AgyConsole.postMessage) {
        window.AgyConsole.postMessage(JSON.stringify({ level: level, message: msg }));
      }
    } catch (_) {}
  }
  ['log', 'info', 'warn', 'error'].forEach(function(lvl) {
    var orig = console[lvl];
    console[lvl] = function() {
      send(lvl, arguments);
      if (orig) return orig.apply(console, arguments);
    };
  });
  window.addEventListener('error', function(e) {
    send('error', [(e.message || 'Uncaught error') + ' @ ' + (e.filename || '') + ':' + (e.lineno || 0)]);
  });
  window.addEventListener('unhandledrejection', function(e) {
    var reason = e.reason;
    send('error', ['UnhandledPromiseRejection:', reason instanceof Error ? (reason.stack || reason.message) : reason]);
  });
})();
''';

  late final WebViewController _controller;
  late final TextEditingController _urlCtrl;
  final List<WebConsoleEntry> _consoleLogs = [];
  final List<WebConsoleEntry> _pendingConsoleLogs = [];
  Timer? _consoleFlushTimer;
  int _progress = 0;
  bool _showConsole = true;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.initialUrl);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'AgyConsole',
        onMessageReceived: (msg) {
          _onConsoleMessage(msg.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            _controller.runJavaScript(_consoleHookJs).catchError((_) {});
          },
          onPageFinished: (_) {
            _controller.runJavaScript(_consoleHookJs).catchError((_) {});
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  @override
  void dispose() {
    _consoleFlushTimer?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _onConsoleMessage(String raw) {
    if (!mounted) return;
    var level = 'log';
    var message = raw;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        level = decoded['level']?.toString() ?? 'log';
        message = decoded['message']?.toString() ?? raw;
      }
    } catch (_) {}
    _pendingConsoleLogs.add(
      WebConsoleEntry(
        level: level,
        message: message,
        timestamp: DateTime.now(),
      ),
    );
    _consoleFlushTimer ??= Timer(const Duration(milliseconds: 100), () {
      _consoleFlushTimer = null;
      if (!mounted || _pendingConsoleLogs.isEmpty) return;
      final batch = List<WebConsoleEntry>.of(_pendingConsoleLogs);
      _pendingConsoleLogs.clear();
      setState(() {
        _consoleLogs.addAll(batch);
        if (_consoleLogs.length > 200) {
          _consoleLogs.removeRange(0, _consoleLogs.length - 200);
        }
      });
    });
  }

  Future<void> _loadUrl(String raw) async {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (!trimmed.contains('://') && !trimmed.startsWith('/')) {
      trimmed = 'http://$trimmed';
    }
    _urlCtrl.text = trimmed;
    if (trimmed.startsWith('/')) {
      final file = File(trimmed);
      if (await file.exists()) {
        if (!mounted) return;
        _controller.loadFile(file.path);
        return;
      }
    }
    final uri = Uri.tryParse(trimmed);
    if (uri != null) {
      _controller.loadRequest(uri);
    }
  }

  Future<void> _loadLocalWorkspaceHtml() async {
    final sessionWs =
        ref.read(sessionsProvider).activeSession?.workspacePath.trim() ?? '';
    final projDir = ref.read(projectsProvider).activeProject.primaryFolder;
    final root = sessionWs.isNotEmpty
        ? sessionWs
        : (projDir.isNotEmpty
            ? projDir
            : (ref.read(runtimeProvider).status.workspaceRoot ?? ''));
    if (root.isEmpty) return;
    for (final rel in const ['index.html', 'dist/index.html', 'build/index.html', 'web/index.html']) {
      final f = File('$root/$rel');
      if (await f.exists()) {
        _urlCtrl.text = f.path;
        await _controller.loadFile(f.path);
        return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('No index.html found in $root')),
    );
  }

  Future<void> _sendErrorsToAgent() async {
    final errors = _consoleLogs
        .where((e) => e.level == 'error' || e.level == 'warn')
        .toList();
    final targetLogs = errors.isNotEmpty ? errors : _consoleLogs;
    if (targetLogs.isEmpty) return;
    final snippet = targetLogs
        .take(30)
        .map((e) => '[${e.level.toUpperCase()}] ${e.message}')
        .join('\n');
    final prompt =
        'Fix the runtime errors captured from WebView Preview (${_urlCtrl.text.trim()}):\n\n```\n$snippet\n```';
    await ref.read(chatProvider.notifier).sendPrompt(prompt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = AgySemanticColors.of(context);
    final errorCount =
        _consoleLogs.where((e) => e.level == 'error').length;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(),
                    hintText: 'http://127.0.0.1:3000 or /path/to/index.html',
                  ),
                  onSubmitted: _loadUrl,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Load URL',
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                onPressed: () => _loadUrl(_urlCtrl.text),
              ),
              IconButton(
                tooltip: 'Reload',
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: () => _controller.reload(),
              ),
              IconButton(
                tooltip: _showConsole ? 'Hide Console' : 'Show Console',
                icon: Badge(
                  isLabelVisible: errorCount > 0,
                  label: Text('$errorCount'),
                  child: Icon(
                    Icons.terminal_rounded,
                    size: 18,
                    color: _showConsole ? theme.colorScheme.primary : null,
                  ),
                ),
                onPressed: () => setState(() => _showConsole = !_showConsole),
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              for (final port in const [3000, 5173, 8080]) ...[
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(':$port'),
                  onPressed: () => _loadUrl('http://127.0.0.1:$port'),
                ),
                const SizedBox(width: 6),
              ],
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.html_rounded, size: 14),
                label: const Text('Local index.html'),
                onPressed: _loadLocalWorkspaceHtml,
              ),
            ],
          ),
        ),
        if (_progress < 100)
          LinearProgressIndicator(value: _progress / 100.0, minHeight: 2),
        Expanded(
          flex: 3,
          child: WebViewWidget(controller: _controller),
        ),
        if (_showConsole) ...[
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: Container(
              color: theme.colorScheme.surfaceContainerLowest,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Mini Console (${_consoleLogs.length})',
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        if (_consoleLogs.isNotEmpty)
                          TextButton.icon(
                            onPressed: _sendErrorsToAgent,
                            icon: const Icon(Icons.auto_fix_high, size: 14),
                            label: Text(
                              errorCount > 0
                                  ? 'Fix $errorCount error(s)'
                                  : 'Send Logs to AI',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Clear console',
                          icon: const Icon(Icons.delete_outline, size: 16),
                          onPressed: () =>
                              setState(() => _consoleLogs.clear()),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _consoleLogs.isEmpty
                        ? Center(
                            child: Text(
                              'console.log / uncaught errors appear here automatically.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: semantic.textSecondary,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            itemCount: _consoleLogs.length,
                            itemBuilder: (context, i) {
                              final entry = _consoleLogs[i];
                              final color = switch (entry.level) {
                                'error' => semantic.danger,
                                'warn' => semantic.warning,
                                _ => semantic.textPrimary,
                              };
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: SelectableText(
                                  '[${entry.level}] ${entry.message}',
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: color,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
