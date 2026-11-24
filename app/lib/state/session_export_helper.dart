import 'dart:convert';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/services.dart';

import '../ui/chat/secret_mask.dart';
import 'chat_models.dart';

/// Formats conversations for Markdown/JSON export and invokes Android's native
/// share sheet or Downloads storage via `agy/performance`.
class SessionExportHelper {
  SessionExportHelper._();

  static const MethodChannel _perfChannel = MethodChannel('agy/performance');

  static String toMarkdown(
    AgySessionSummary session,
    List<ChatMessage> messages,
  ) {
    final buf = StringBuffer()
      ..writeln('# ${session.title}')
      ..writeln()
      ..writeln('- **Host:** ${session.hostName}')
      ..writeln('- **Model:** ${session.modelId}')
      ..writeln('- **Updated:** ${session.updatedAt.toIso8601String()}');
    if (session.folder.isNotEmpty) {
      buf.writeln('- **Folder:** ${session.folder}');
    }
    if (session.workspacePath.isNotEmpty) {
      buf.writeln('- **Workspace:** `${session.workspacePath}`');
    }
    buf.writeln('\n---\n');

    for (final m in messages) {
      final speaker = switch (m.role) {
        ChatRole.user => '## User',
        ChatRole.assistant => '## Antigravity',
        ChatRole.system => '## System',
      };
      buf.writeln(speaker);
      buf.writeln('_${m.createdAt.toIso8601String()}_');
      if (m.thoughts.trim().isNotEmpty) {
        buf.writeln('\n> **Reasoning:**\n> ${AgySecretMask.mask(m.thoughts.trim()).replaceAll('\n', '\n> ')}');
      }
      if (m.tools.isNotEmpty) {
        buf.writeln('\n**Tools:**');
        for (final t in m.tools) {
          buf.writeln('- `${t.toolName}` (${t.state.name})');
        }
      }
      if (m.text.trim().isNotEmpty) {
        buf.writeln('\n${AgySecretMask.mask(m.text.trim())}');
      }
      buf.writeln();
    }
    return buf.toString();
  }

  static String toJsonString(
    AgySessionSummary session,
    List<ChatMessage> messages,
  ) {
    return const JsonEncoder.withIndent('  ').convert({
      'session': session.toJson(),
      'messages': messages.map((m) => m.toJson()).toList(),
    });
  }

  static Future<bool> shareText(String title, String text) async {
    try {
      return await _perfChannel.invokeMethod<bool>('shareText', {
            'title': title,
            'text': text,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> saveTextToDownloads({
    required String filename,
    required String content,
    String mimeType = 'text/markdown',
  }) async {
    try {
      return await _perfChannel.invokeMethod<String>('saveToDownloads', {
        'filename': filename,
        'text': content,
        'mimeType': mimeType,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<String?> saveBytesToDownloads({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    try {
      return await _perfChannel.invokeMethod<String>('saveToDownloads', {
        'filename': filename,
        'bytes': bytes,
        'mimeType': mimeType,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<String> getRecentCrashLog() async {
    try {
      return await _perfChannel.invokeMethod<String>('recentCrashLog') ?? '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> clearCrashLog() async {
    try {
      await _perfChannel.invokeMethod<bool>('clearCrashLog');
    } catch (_) {
      // Safe no-op on non-Android/test environments.
    }
  }
}
