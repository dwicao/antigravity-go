import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/chat_message_store.dart';
import '../../state/sessions_state.dart';
import '../replay/conversation_replay_page.dart';

/// Full-text search across every saved conversation transcript and folder tag.
class SessionSearchPage extends ConsumerStatefulWidget {
  const SessionSearchPage({super.key});

  @override
  ConsumerState<SessionSearchPage> createState() => _SessionSearchPageState();
}

class _SessionSearchPageState extends ConsumerState<SessionSearchPage> {
  final TextEditingController _controller = TextEditingController();
  List<SessionSearchHit> _hits = const [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _hits = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final sessions = ref.read(sessionsProvider).sessions;
      final results =
          await ChatMessageStore.instance.searchSessions(value, sessions);
      if (!mounted) return;
      setState(() {
        _hits = results;
        _searching = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessions = ref.watch(sessionsProvider).sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('Search All Conversations')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onQueryChanged,
              decoration: InputDecoration(
                hintText: 'Search messages, folders, or titles…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _controller.clear();
                          _onQueryChanged('');
                        },
                      ),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _controller.text.trim().isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text(
                        'Recent & Pinned (${sessions.length})',
                        style: theme.textTheme.labelMedium,
                      ),
                      const SizedBox(height: 8),
                      for (final s in sessions.take(20))
                        Card(
                          child: ListTile(
                            leading: Icon(
                              s.pinned
                                  ? Icons.push_pin
                                  : Icons.chat_bubble_outline,
                              size: 18,
                            ),
                            title: Text(s.title),
                            subtitle: Text(
                              [
                                if (s.folder.isNotEmpty) '[${s.folder}]',
                                s.lastPreview ?? s.modelId,
                              ].join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: 'Replay & Export',
                              icon: const Icon(Icons.play_circle_outline),
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        ConversationReplayPage(session: s),
                                  ),
                                );
                              },
                            ),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              ref
                                  .read(sessionsProvider.notifier)
                                  .selectSession(s.id);
                              Navigator.of(context).pop();
                            },
                          ),
                        ),
                    ],
                  )
                : _hits.isEmpty && !_searching
                    ? const Center(
                        child: Text('No matching messages found.'),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _hits.length,
                        itemBuilder: (context, index) {
                          final hit = _hits[index];
                          return Card(
                            child: ListTile(
                              leading: Icon(
                                hit.session.pinned
                                    ? Icons.push_pin
                                    : Icons.forum_outlined,
                                size: 18,
                              ),
                              title: Text(hit.session.title),
                              subtitle: Text(
                                hit.snippet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                ref
                                    .read(sessionsProvider.notifier)
                                    .selectSession(hit.session.id);
                                Navigator.of(context).pop();
                              },
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
