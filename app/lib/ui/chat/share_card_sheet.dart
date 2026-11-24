import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../state/chat_models.dart';
import '../../state/session_export_helper.dart';
import '../../theme/app_theme.dart';
import 'message_metrics_footer.dart';
import 'render/agy_markdown.dart';

enum _ShareCardStyle { dark, light, indigo }

/// Styled reply Share Card sheet modeled on DSH Go's share card generator:
/// renders any response into a clean visual card that can be saved as PNG or shared as text.
class ShareCardSheet extends StatefulWidget {
  const ShareCardSheet({super.key, required this.message});

  final ChatMessage message;

  static Future<void> show(BuildContext context, ChatMessage message) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ShareCardSheet(message: message),
    );
  }

  @override
  State<ShareCardSheet> createState() => _ShareCardSheetState();
}

class _ShareCardSheetState extends State<ShareCardSheet> {
  final GlobalKey _cardKey = GlobalKey();
  _ShareCardStyle _style = _ShareCardStyle.dark;
  bool _savingPng = false;

  Future<void> _savePng() async {
    setState(() => _savingPng = true);
    try {
      final boundary = _cardKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      final bytes = data.buffer.asUint8List();
      final saved = await SessionExportHelper.saveBytesToDownloads(
        filename: 'antigravity-card-${DateTime.now().millisecondsSinceEpoch}.png',
        bytes: bytes,
        mimeType: 'image/png',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved != null
                ? 'Saved share card to $saved'
                : 'PNG saving is unavailable on this device',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingPng = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = switch (_style) {
      _ShareCardStyle.dark => const Color(0xFF0E1420),
      _ShareCardStyle.light => const Color(0xFFF8FAFC),
      _ShareCardStyle.indigo => const Color(0xFF191D3A),
    };
    final fg = _style == _ShareCardStyle.light
        ? const Color(0xFF0F172A)
        : const Color(0xFFF1F5F9);
    final sub = _style == _ShareCardStyle.light
        ? const Color(0xFF475569)
        : const Color(0xFF94A3B8);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Reply Share Card',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                SegmentedButton<_ShareCardStyle>(
                  segments: const [
                    ButtonSegment(value: _ShareCardStyle.dark, label: Text('Dark')),
                    ButtonSegment(value: _ShareCardStyle.light, label: Text('Light')),
                    ButtonSegment(value: _ShareCardStyle.indigo, label: Text('Indigo')),
                  ],
                  selected: {_style},
                  onSelectionChanged: (s) => setState(() => _style = s.first),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                child: RepaintBoundary(
                  key: _cardKey,
                  child: Theme(
                    data: AgyTheme.build(
                      brightness: _style == _ShareCardStyle.light
                          ? Brightness.light
                          : Brightness.dark,
                      accent: AgyAccentPreset.indigo,
                    ),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: bg,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: sub.withOpacity(0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.auto_awesome,
                                size: 18,
                                color: Color(0xFF8AA2FF),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Antigravity Go',
                                style: TextStyle(
                                  color: fg,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              const Spacer(),
                              if (widget.message.modelId != null)
                                Text(
                                  widget.message.modelId!,
                                  style: TextStyle(color: sub, fontSize: 12),
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          AgyMarkdown(text: widget.message.text),
                          const SizedBox(height: 14),
                          Divider(color: sub.withOpacity(0.2)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Text(
                                formatChatTimestamp(
                                  widget.message.completedAt ??
                                      widget.message.createdAt,
                                ),
                                style: TextStyle(color: sub, fontSize: 11),
                              ),
                              const Spacer(),
                              if (widget.message.tokensPerSecond != null)
                                Text(
                                  '${widget.message.tokensPerSecond!.toStringAsFixed(1)} tok/s',
                                  style: TextStyle(color: sub, fontSize: 11),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.message.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Reply copied')),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 18),
                    label: const Text('Copy Text'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => SessionExportHelper.shareText(
                      'Antigravity Go Reply',
                      widget.message.text,
                    ),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _savingPng ? null : _savePng,
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(_savingPng ? 'Saving…' : 'Save PNG'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
