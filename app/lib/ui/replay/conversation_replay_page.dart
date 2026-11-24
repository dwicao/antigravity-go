import 'dart:async';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/chat_message_store.dart';
import '../../state/chat_models.dart';
import '../../state/session_export_helper.dart';
import '../chat/message_bubble.dart';

/// Step-by-step playback viewer & exporter for saved conversations,
/// modeled on DSH Go's Replay + Session Export experience.
class ConversationReplayPage extends StatefulWidget {
  const ConversationReplayPage({
    super.key,
    required this.session,
    this.initialMessages,
  });

  final AgySessionSummary session;
  final List<ChatMessage>? initialMessages;

  @override
  State<ConversationReplayPage> createState() => _ConversationReplayPageState();
}

class _ConversationReplayPageState extends State<ConversationReplayPage> {
  List<ChatMessage> _messages = const [];
  bool _loading = true;
  int _visibleCount = 1;
  bool _playing = false;
  int _speedMultiplier = 1;
  Timer? _playTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final msgs = widget.initialMessages ??
        await ChatMessageStore.instance.load(widget.session.id);
    if (!mounted) return;
    setState(() {
      _messages = msgs;
      _visibleCount = msgs.isEmpty ? 0 : 1;
      _loading = false;
    });
  }

  void _togglePlay() {
    if (_messages.isEmpty) return;
    if (_playing) {
      _playTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_visibleCount >= _messages.length) {
      _visibleCount = 1;
    }
    setState(() => _playing = true);
    _scheduleNextTick();
  }

  void _scheduleNextTick() {
    _playTimer?.cancel();
    final delayMs = (1400 / _speedMultiplier).round().clamp(250, 2000);
    _playTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted || !_playing) return;
      if (_visibleCount >= _messages.length) {
        setState(() => _playing = false);
        return;
      }
      setState(() => _visibleCount++);
      _scheduleNextTick();
    });
  }

  Future<void> _exportMarkdown({required bool saveFile}) async {
    final md = SessionExportHelper.toMarkdown(widget.session, _messages);
    if (saveFile) {
      final path = await SessionExportHelper.saveTextToDownloads(
        filename: 'antigravity-${widget.session.id.substring(0, 8)}.md',
        content: md,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            path != null ? 'Saved to $path' : 'Saved unavailable — copied instead',
          ),
        ),
      );
      if (path != null) return;
    }
    await Clipboard.setData(ClipboardData(text: md));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Conversation Markdown copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _messages.length;
    final shown = _visibleCount.clamp(0, total);
    return Scaffold(
      appBar: AppBar(
        title: Text('Replay · ${widget.session.title}'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Export / Share',
            onSelected: (v) async {
              if (v == 'copy_md') {
                await _exportMarkdown(saveFile: false);
              } else if (v == 'save_md') {
                await _exportMarkdown(saveFile: true);
              } else if (v == 'share_md') {
                final md =
                    SessionExportHelper.toMarkdown(widget.session, _messages);
                await SessionExportHelper.shareText(widget.session.title, md);
              } else if (v == 'copy_json') {
                final json =
                    SessionExportHelper.toJsonString(widget.session, _messages);
                await Clipboard.setData(ClipboardData(text: json));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Conversation JSON copied')),
                  );
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'copy_md', child: Text('Copy Markdown')),
              PopupMenuItem(value: 'save_md', child: Text('Save Markdown to Downloads')),
              PopupMenuItem(value: 'share_md', child: Text('Share via Android')),
              PopupMenuItem(value: 'copy_json', child: Text('Copy Raw JSON')),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : total == 0
              ? const Center(
                  child: Text('No messages recorded in this session yet.'),
                )
              : Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        itemCount: shown,
                        itemBuilder: (context, index) => MessageBubble(
                          message: _messages[index],
                        ),
                      ),
                    ),
                    Material(
                      elevation: 2,
                      color: theme.colorScheme.surfaceContainerHigh,
                      child: SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    'Step $shown of $total',
                                    style: theme.textTheme.labelMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Expanded(
                                    child: Slider(
                                      min: 1,
                                      max: total.toDouble(),
                                      divisions: total > 1 ? total - 1 : null,
                                      value: shown.toDouble().clamp(1, total.toDouble()),
                                      onChanged: (v) {
                                        _playTimer?.cancel();
                                        setState(() {
                                          _playing = false;
                                          _visibleCount = v.round();
                                        });
                                      },
                                    ),
                                  ),
                                  DropdownButton<int>(
                                    value: _speedMultiplier,
                                    underline: const SizedBox.shrink(),
                                    items: const [
                                      DropdownMenuItem(value: 1, child: Text('1x')),
                                      DropdownMenuItem(value: 2, child: Text('2x')),
                                      DropdownMenuItem(value: 4, child: Text('4x')),
                                    ],
                                    onChanged: (v) {
                                      if (v == null) return;
                                      setState(() => _speedMultiplier = v);
                                      if (_playing) _scheduleNextTick();
                                    },
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  IconButton(
                                    tooltip: 'First step',
                                    onPressed: shown > 1
                                        ? () => setState(() => _visibleCount = 1)
                                        : null,
                                    icon: const Icon(Icons.first_page),
                                  ),
                                  IconButton(
                                    tooltip: 'Previous step',
                                    onPressed: shown > 1
                                        ? () => setState(() => _visibleCount--)
                                        : null,
                                    icon: const Icon(Icons.skip_previous),
                                  ),
                                  FilledButton.icon(
                                    onPressed: _togglePlay,
                                    icon: Icon(
                                      _playing ? Icons.pause : Icons.play_arrow,
                                    ),
                                    label: Text(_playing ? 'Pause' : 'Play'),
                                  ),
                                  IconButton(
                                    tooltip: 'Next step',
                                    onPressed: shown < total
                                        ? () => setState(() => _visibleCount++)
                                        : null,
                                    icon: const Icon(Icons.skip_next),
                                  ),
                                  IconButton(
                                    tooltip: 'Show all',
                                    onPressed: shown < total
                                        ? () =>
                                            setState(() => _visibleCount = total)
                                        : null,
                                    icon: const Icon(Icons.last_page),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
