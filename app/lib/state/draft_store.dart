import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ChatDraft {
  const ChatDraft({
    this.text = '',
    required this.updatedAt,
  });

  final String text;
  final DateTime updatedAt;
}

/// Guards against accidentally pasted NUL/binary blobs slowing down startup or
/// polluting saved composer drafts (modeled on DSH-Go's `draft_store.dart`).
String sanitizeDraftText(String text) {
  final nul = text.indexOf('\u0000');
  if (nul >= 0) {
    return text.substring(0, nul);
  }
  return text;
}

final draftStoreProvider =
    NotifierProvider<DraftStoreNotifier, Map<String, ChatDraft>>(
  DraftStoreNotifier.new,
);

class DraftStoreNotifier extends Notifier<Map<String, ChatDraft>> {
  static const _prefsKey = 'agy_composer_drafts_v1';
  static const _maxSessions = 30;

  Timer? _debounce;
  late Future<void> _loaded;

  @override
  Map<String, ChatDraft> build() {
    ref.onDispose(() => _debounce?.cancel());
    _loaded = _restore();
    return const {};
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final restored = <String, ChatDraft>{};
      for (final entry in decoded.entries) {
        final key = entry.key.toString();
        final value = entry.value;
        if (value is Map) {
          final clean = sanitizeDraftText(value['t']?.toString() ?? '');
          if (clean.isEmpty) continue;
          final ms = (value['at'] as num?)?.toInt() ?? 0;
          restored[key] = ChatDraft(
            text: clean,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(ms),
          );
        }
      }
      if (!ref.mounted) return;
      state = _capped({...restored, ...state});
    } catch (_) {
      // Ignore corrupt or unavailable preferences in widget tests.
    }
  }

  Map<String, ChatDraft> _capped(Map<String, ChatDraft> source) {
    final entries = source.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return Map.unmodifiable(Map.fromEntries(entries.take(_maxSessions)));
  }

  String draftFor(String sessionId) => state[sessionId]?.text ?? '';

  void save(String sessionId, String rawText) {
    final clean = sanitizeDraftText(rawText);
    if ((state[sessionId]?.text ?? '') == clean) return;

    final next = {...state};
    if (clean.isEmpty) {
      next.remove(sessionId);
    } else {
      next[sessionId] = ChatDraft(text: clean, updatedAt: DateTime.now());
    }
    state = _capped(next);

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  void clear(String sessionId) => save(sessionId, '');

  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    await _loaded;
    if (!ref.mounted) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode({
        for (final entry in state.entries)
          if (entry.value.text.isNotEmpty)
            entry.key: {
              't': entry.value.text,
              'at': entry.value.updatedAt.millisecondsSinceEpoch,
            },
      });
      await prefs.setString(_prefsKey, jsonStr);
    } catch (_) {}
  }
}
