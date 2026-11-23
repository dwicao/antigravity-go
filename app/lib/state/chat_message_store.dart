import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_models.dart';

/// Persists redacted per-session chat transcripts into individual atomic JSON files
/// inside application support storage, migrating legacy `SharedPreferences` keys and
/// falling back cleanly when platform plugins are unavailable (e.g. unit tests).
class ChatMessageStore {
  ChatMessageStore._();
  static final ChatMessageStore instance = ChatMessageStore._();

  static const _legacyPrefix = 'agy_msgs_';

  Future<Directory?> _sessionsDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/agy_sessions');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      return dir;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  String _safeFileName(String sessionId) =>
      sessionId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<List<ChatMessage>> load(String sessionId) async {
    final dir = await _sessionsDir();
    final safeId = _safeFileName(sessionId);
    if (dir != null) {
      final file = File('${dir.path}/$safeId.json');
      if (file.existsSync()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is List) {
            return decoded
                .whereType<Map<String, dynamic>>()
                .map(ChatMessage.fromJson)
                .toList();
          }
        } catch (_) {}
      }
    }

    // Legacy SharedPreferences read + automatic one-time migration to file storage.
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_legacyPrefix$sessionId');
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(ChatMessage.fromJson)
          .toList();
      if (dir != null) {
        await save(sessionId, list);
        await prefs.remove('$_legacyPrefix$sessionId');
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(String sessionId, List<ChatMessage> msgs) async {
    final encoded = jsonEncode(msgs.map((m) => m.toJson()).toList());
    final dir = await _sessionsDir();
    if (dir == null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_legacyPrefix$sessionId', encoded);
      return;
    }
    final safeId = _safeFileName(sessionId);
    final target = File('${dir.path}/$safeId.json');
    final tmp = File('${dir.path}/.$safeId.tmp');
    try {
      await tmp.writeAsString(encoded, flush: true);
      if (target.existsSync()) {
        await tmp.rename(target.path);
      } else {
        await tmp.rename(target.path);
      }
    } catch (_) {
      try {
        await target.writeAsString(encoded, flush: true);
      } catch (_) {}
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync();
        } catch (_) {}
      }
    }
  }

  Future<void> delete(String sessionId) async {
    final dir = await _sessionsDir();
    if (dir != null) {
      final safeId = _safeFileName(sessionId);
      final target = File('${dir.path}/$safeId.json');
      try {
        if (target.existsSync()) target.deleteSync();
      } catch (_) {}
      final tmp = File('${dir.path}/.$safeId.tmp');
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_legacyPrefix$sessionId');
  }
}
