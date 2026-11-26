import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Embedded portal for Antigravity Remote Control (`https://antigravity.google.com`)
/// and loopback localhost preview (`http://127.0.0.1:<port>`), adopted from PR #37.
class RemoteWebPage extends StatefulWidget {
  const RemoteWebPage({
    super.key,
    this.initialUrl = 'https://antigravity.google.com',
  });

  final String initialUrl;

  @override
  State<RemoteWebPage> createState() => _RemoteWebPageState();
}

class _RemoteWebPageState extends State<RemoteWebPage> {
  late final WebViewController _controller;
  int _progress = 0;
  late String _currentUrl;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (mounted) setState(() => _currentUrl = url);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  Future<void> _openLocalhostPreviewPrompt() async {
    final ctrl = TextEditingController(text: 'http://127.0.0.1:3000');
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Localhost Live Preview'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Loopback URL (e.g. http://127.0.0.1:3000)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('Load'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (target == null || target.isEmpty) return;
    final parsed = Uri.tryParse(target);
    if (parsed == null ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return;
    }
    setState(() => _currentUrl = target);
    await _controller.loadRequest(parsed);
  }

  Future<void> _openInExternalBrowser() async {
    final uri = Uri.tryParse(_currentUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Antigravity Web & Preview'),
            Text(
              _currentUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Localhost Preview (127.0.0.1)',
            onPressed: _openLocalhostPreviewPrompt,
            icon: const Icon(Icons.dns_outlined),
          ),
          IconButton(
            tooltip: 'Open in Browser / Custom Tab',
            onPressed: _openInExternalBrowser,
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
          IconButton(
            tooltip: 'Back',
            onPressed: () async {
              if (await _controller.canGoBack()) {
                await _controller.goBack();
              }
            },
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(value: _progress / 100.0),
              )
            : null,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
