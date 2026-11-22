import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Embedded portal for Antigravity Remote Control (`https://antigravity.google.com`).
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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Antigravity Remote Web'),
        actions: [
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
