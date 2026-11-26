import 'dart:convert';
import 'dart:io';

import 'package:agy_client/agy_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../ui/chat/secret_mask.dart';
import 'chat_message_store.dart';
import 'chat_models.dart';
import 'draft_store.dart';
import 'session_export_helper.dart';

/// Strategy applied when restoring a conversation whose ID already exists
/// in local storage.
enum ChatRestoreConflictMode {
  mergeKeepNewer(
    label: 'Merge (Keep Newer)',
    description: 'Import missing chats; update existing only if backup is newer or longer',
  ),
  skipExisting(
    label: 'Skip Existing',
    description: 'Only import chats not already on this device',
  ),
  importAsCopy(
    label: 'Import as Copies',
    description: 'Create new copies for every chat so existing threads stay untouched',
  ),
  overwriteExisting(
    label: 'Overwrite Existing',
    description: 'Replace local chats and transcripts with versions from backup',
  );

  const ChatRestoreConflictMode({
    required this.label,
    required this.description,
  });

  final String label;
  final String description;
}

class ChatBackupEntry {
  const ChatBackupEntry({
    required this.session,
    required this.messages,
    this.draftText,
    this.draftUpdatedAt,
  });

  final AgySessionSummary session;
  final List<ChatMessage> messages;
  final String? draftText;
  final DateTime? draftUpdatedAt;

  int get totalTokens => messages.fold<int>(
        0,
        (sum, m) => sum + (m.usage?.totalTokens ?? 0),
      );

  Map<String, dynamic> toJson() {
    final maskedSession = session.copyWith(
      lastPreview: session.lastPreview != null
          ? AgySecretMask.mask(session.lastPreview!)
          : null,
    );
    final maskedDraft =
        draftText != null && draftText!.isNotEmpty ? AgySecretMask.mask(draftText!) : null;
    return {
      'session': maskedSession.toJson(),
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'draftText': ?maskedDraft,
      if (maskedDraft != null && draftUpdatedAt != null)
        'draftUpdatedAt': draftUpdatedAt!.toIso8601String(),
    };
  }

  factory ChatBackupEntry.fromJson(Map<String, dynamic> json) {
    final sessionRaw = json['session'];
    if (sessionRaw is! Map<String, dynamic>) {
      throw const FormatException('Backup entry missing valid session object');
    }
    final msgsRaw = json['messages'];
    final msgs = msgsRaw is List
        ? msgsRaw
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList()
        : const <ChatMessage>[];
    final parsedSession = AgySessionSummary.fromJson(sessionRaw);
    final normalizedSession = parsedSession.messageCount == 0 && msgs.isNotEmpty
        ? parsedSession.copyWith(messageCount: msgs.length)
        : parsedSession;
    return ChatBackupEntry(
      session: normalizedSession,
      messages: msgs,
      draftText: json['draftText'] as String?,
      draftUpdatedAt:
          DateTime.tryParse(json['draftUpdatedAt'] as String? ?? ''),
    );
  }
}

/// Self-contained portable backup bundle for Antigravity Go chats.
/// Accepts both full backup files and single-chat exports produced by
/// `SessionExportHelper.toJsonString`.
class ChatBackupBundle {
  const ChatBackupBundle({
    this.schemaVersion = currentSchemaVersion,
    required this.appVersion,
    required this.exportedAt,
    this.projects = const [],
    required this.entries,
  });

  static const int currentSchemaVersion = 1;

  final int schemaVersion;
  final String appVersion;
  final DateTime exportedAt;
  final List<AgyProject> projects;
  final List<ChatBackupEntry> entries;

  int get sessionCount => entries.length;
  int get totalMessages =>
      entries.fold<int>(0, (sum, e) => sum + e.messages.length);
  int get archivedCount => entries.where((e) => e.session.archived).length;
  int get pinnedCount => entries.where((e) => e.session.pinned).length;
  int get totalTokens => entries.fold<int>(0, (sum, e) => sum + e.totalTokens);

  Map<String, dynamic> toJson() => {
        'kind': 'antigravity_go_chat_backup',
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'exportedAt': exportedAt.toIso8601String(),
        'sessionCount': sessionCount,
        'messageCount': totalMessages,
        if (projects.isNotEmpty)
          'projects': projects.map((p) => p.toJson()).toList(growable: false),
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
      };

  factory ChatBackupBundle.fromJson(Map<String, dynamic> json) {
    // Support single-chat JSON export: { "session": {...}, "messages": [...] }
    if (json['entries'] == null && json['session'] is Map<String, dynamic>) {
      final single = ChatBackupEntry.fromJson(json);
      return ChatBackupBundle(
        schemaVersion: currentSchemaVersion,
        appVersion: json['appVersion'] as String? ?? 'export',
        exportedAt: single.session.updatedAt,
        entries: [single],
      );
    }

    final entriesRaw = json['entries'];
    if (entriesRaw is! List) {
      throw const FormatException(
        'Invalid chat backup file: missing "entries" list',
      );
    }
    final entries = entriesRaw
        .whereType<Map<String, dynamic>>()
        .map(ChatBackupEntry.fromJson)
        .toList();
    final projects = (json['projects'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AgyProject.fromJson)
        .toList();

    return ChatBackupBundle(
      schemaVersion:
          (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
      appVersion: json['appVersion'] as String? ?? 'unknown',
      exportedAt: DateTime.tryParse(json['exportedAt'] as String? ?? '') ??
          DateTime.now(),
      projects: projects,
      entries: entries,
    );
  }

  String toPrettyJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  Uint8List encodeBytes({bool compressed = true}) {
    final raw = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (!compressed) return raw;
    return Uint8List.fromList(gzip.encode(raw));
  }

  static ChatBackupBundle decodeBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw const FormatException('Backup file is empty');
    }
    final isGzip = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    final jsonBytes = isGzip ? gzip.decode(bytes) : bytes;
    final decoded = jsonDecode(utf8.decode(jsonBytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup root must be a JSON object');
    }
    return ChatBackupBundle.fromJson(decoded);
  }

  static ChatBackupBundle decodeJsonString(String rawJson) {
    final trimmed = rawJson.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Backup JSON is empty');
    }
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup root must be a JSON object');
    }
    return ChatBackupBundle.fromJson(decoded);
  }

  String toMarkdownDigest() {
    final buf = StringBuffer()
      ..writeln('# Antigravity Go — Chat Backup Archive')
      ..writeln()
      ..writeln('- **Exported:** ${exportedAt.toIso8601String()}')
      ..writeln('- **Chats:** $sessionCount ($archivedCount archived)')
      ..writeln('- **Total Messages:** $totalMessages')
      ..writeln()
      ..writeln('---')
      ..writeln();

    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (i > 0) {
        buf.writeln('\n---\n');
      }
      buf.write(SessionExportHelper.toMarkdown(entry.session, entry.messages));
    }
    return buf.toString();
  }
}

class ChatBackupSnapshotInfo {
  const ChatBackupSnapshotInfo({
    required this.id,
    required this.filePath,
    required this.fileName,
    required this.createdAt,
    required this.sessionCount,
    required this.messageCount,
    required this.byteLength,
    this.appVersion = '',
  });

  final String id;
  final String filePath;
  final String fileName;
  final DateTime createdAt;
  final int sessionCount;
  final int messageCount;
  final int byteLength;
  final String appVersion;

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'createdAt': createdAt.toIso8601String(),
        'sessionCount': sessionCount,
        'messageCount': messageCount,
        'byteLength': byteLength,
        if (appVersion.isNotEmpty) 'appVersion': appVersion,
      };

  static ChatBackupSnapshotInfo? fromJson(
    Map<String, dynamic> json, {
    required String filePath,
  }) {
    final fileName = json['fileName'] as String? ?? '';
    if (fileName.isEmpty) return null;
    return ChatBackupSnapshotInfo(
      id: json['id'] as String? ?? fileName,
      filePath: filePath,
      fileName: fileName,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      sessionCount: (json['sessionCount'] as num?)?.toInt() ?? 0,
      messageCount: (json['messageCount'] as num?)?.toInt() ?? 0,
      byteLength: (json['byteLength'] as num?)?.toInt() ?? 0,
      appVersion: json['appVersion'] as String? ?? '',
    );
  }
}

class ChatRestorePlanSummary {
  const ChatRestorePlanSummary({
    required this.newSessions,
    required this.updatedSessions,
    required this.copiedSessions,
    required this.skippedSessions,
    required this.totalMessagesToWrite,
  });

  final int newSessions;
  final int updatedSessions;
  final int copiedSessions;
  final int skippedSessions;
  final int totalMessagesToWrite;

  int get restoredTotal => newSessions + updatedSessions + copiedSessions;
}

class ChatRestoreApplyResult {
  const ChatRestoreApplyResult({
    required this.summary,
    required this.upsertedSessions,
    required this.restoredSessionIds,
    required this.restoredDrafts,
    required this.missingProjects,
  });

  final ChatRestorePlanSummary summary;
  final List<AgySessionSummary> upsertedSessions;
  final List<String> restoredSessionIds;
  final Map<String, ChatDraft> restoredDrafts;
  final List<AgyProject> missingProjects;
}

/// Builds, stores, exports, and restores full or filtered chat backups.
class ChatBackupService {
  ChatBackupService({
    @visibleForTesting Directory? backupDirectoryOverride,
  }) : _backupDirectoryOverride = backupDirectoryOverride;

  static final ChatBackupService instance = ChatBackupService();

  static const String lastBackupAtPrefsKey = 'agy_last_chat_backup_at_v1';
  final Directory? _backupDirectoryOverride;

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String suggestedFileName({
    required DateTime at,
    required bool compressed,
    bool markdown = false,
  }) {
    final stamp =
        '${at.year.toString().padLeft(4, '0')}'
        '${at.month.toString().padLeft(2, '0')}'
        '${at.day.toString().padLeft(2, '0')}-'
        '${at.hour.toString().padLeft(2, '0')}'
        '${at.minute.toString().padLeft(2, '0')}'
        '${at.second.toString().padLeft(2, '0')}';
    if (markdown) return 'antigravity-chats-$stamp.md';
    return compressed
        ? 'antigravity-chats-$stamp.agychats.json.gz'
        : 'antigravity-chats-$stamp.agychats.json';
  }

  Future<DateTime?> getLastBackupAt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(lastBackupAtPrefsKey);
      return raw == null ? null : DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> recordLastBackupAt(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(lastBackupAtPrefsKey, at.toIso8601String());
    } catch (_) {}
  }

  Future<ChatBackupBundle> buildBundle({
    required List<AgySessionSummary> sessions,
    required Map<String, ChatDraft> drafts,
    required List<AgyProject> projects,
    required String appVersion,
    Set<String>? selectedSessionIds,
    bool includeArchived = true,
    bool includeDraftsAndProjects = true,
  }) async {
    final filteredSessions = sessions.where((s) {
      if (selectedSessionIds != null && !selectedSessionIds.contains(s.id)) {
        return false;
      }
      if (selectedSessionIds == null && !includeArchived && s.archived) {
        return false;
      }
      return true;
    }).toList();

    final entries = <ChatBackupEntry>[];
    final referencedProjectIds = <String>{};
    for (final session in filteredSessions) {
      final msgs = await ChatMessageStore.instance.load(session.id);
      final draft = includeDraftsAndProjects ? drafts[session.id] : null;
      referencedProjectIds.add(session.projectId);
      entries.add(
        ChatBackupEntry(
          session: session.copyWith(
            messageCount: msgs.isNotEmpty ? msgs.length : session.messageCount,
          ),
          messages: msgs,
          draftText: draft?.text,
          draftUpdatedAt: draft?.updatedAt,
        ),
      );
    }

    final bundleProjects = includeDraftsAndProjects
        ? projects
            .where((p) => referencedProjectIds.contains(p.id))
            .toList(growable: false)
        : const <AgyProject>[];

    return ChatBackupBundle(
      appVersion: appVersion,
      exportedAt: DateTime.now(),
      projects: bundleProjects,
      entries: entries,
    );
  }

  static ChatRestorePlanSummary previewRestorePlan({
    required ChatBackupBundle bundle,
    required List<AgySessionSummary> existingSessions,
    required ChatRestoreConflictMode mode,
    Set<String>? selectedSessionIds,
  }) {
    final byId = {for (final s in existingSessions) s.id: s};
    var newCount = 0;
    var updatedCount = 0;
    var copiedCount = 0;
    var skippedCount = 0;
    var messagesToWrite = 0;

    for (final entry in bundle.entries) {
      if (selectedSessionIds != null &&
          !selectedSessionIds.contains(entry.session.id)) {
        continue;
      }
      final existing = byId[entry.session.id];
      if (mode == ChatRestoreConflictMode.importAsCopy) {
        copiedCount++;
        messagesToWrite += entry.messages.length;
        continue;
      }
      if (existing == null) {
        newCount++;
        messagesToWrite += entry.messages.length;
        continue;
      }
      final shouldReplace = switch (mode) {
        ChatRestoreConflictMode.skipExisting => false,
        ChatRestoreConflictMode.overwriteExisting => true,
        ChatRestoreConflictMode.mergeKeepNewer =>
          _isBackupEntryNewer(entry, existing),
        ChatRestoreConflictMode.importAsCopy => true,
      };
      if (shouldReplace) {
        updatedCount++;
        messagesToWrite += entry.messages.length;
      } else {
        skippedCount++;
      }
    }

    return ChatRestorePlanSummary(
      newSessions: newCount,
      updatedSessions: updatedCount,
      copiedSessions: copiedCount,
      skippedSessions: skippedCount,
      totalMessagesToWrite: messagesToWrite,
    );
  }

  static bool _isBackupEntryNewer(
    ChatBackupEntry backup,
    AgySessionSummary local,
  ) {
    final backupCount = backup.messages.length;
    if (backupCount > local.messageCount) return true;
    if (backupCount < local.messageCount &&
        local.updatedAt.isAfter(backup.session.updatedAt)) {
      return false;
    }
    return backup.session.updatedAt.isAfter(local.updatedAt);
  }

  /// Writes restored session transcripts into `ChatMessageStore` and returns the
  /// exact session metadata / drafts / missing projects for state notifiers to apply.
  Future<ChatRestoreApplyResult> prepareAndPersistRestore({
    required ChatBackupBundle bundle,
    required List<AgySessionSummary> existingSessions,
    required List<AgyProject> existingProjects,
    required ChatRestoreConflictMode mode,
    Set<String>? selectedSessionIds,
  }) async {
    final existingById = {for (final s in existingSessions) s.id: s};
    final existingProjectIds = {for (final p in existingProjects) p.id};
    const uuid = Uuid();

    final upsertedSessions = <AgySessionSummary>[];
    final restoredIds = <String>[];
    final restoredDrafts = <String, ChatDraft>{};

    var newCount = 0;
    var updatedCount = 0;
    var copiedCount = 0;
    var skippedCount = 0;
    var messagesToWrite = 0;

    for (final entry in bundle.entries) {
      if (selectedSessionIds != null &&
          !selectedSessionIds.contains(entry.session.id)) {
        continue;
      }
      final existing = existingById[entry.session.id];
      final sanitizedMsgs = entry.messages
          .map((m) => m.copyWith(isStreaming: false))
          .toList(growable: false);

      late final String targetId;
      late final AgySessionSummary targetSession;

      if (mode == ChatRestoreConflictMode.importAsCopy) {
        targetId = uuid.v4();
        final needsSuffix = existing != null;
        final copyTitle = needsSuffix && !entry.session.title.endsWith('(Restored)')
            ? '${entry.session.title} (Restored)'
            : entry.session.title;
        targetSession = AgySessionSummary(
          id: targetId,
          title: copyTitle,
          hostId: entry.session.hostId,
          hostName: entry.session.hostName,
          hostKind: entry.session.hostKind,
          workspacePath: entry.session.workspacePath,
          modelId: entry.session.modelId,
          updatedAt: entry.session.updatedAt,
          projectId: entry.session.projectId,
          remoteConversationId: null,
          messageCount: sanitizedMsgs.length,
          lastPreview: entry.session.lastPreview,
          pinned: entry.session.pinned,
          archived: entry.session.archived,
          folder: entry.session.folder,
        );
        copiedCount++;
      } else if (existing == null) {
        targetId = entry.session.id;
        targetSession = entry.session.copyWith(
          clearRemoteConversationId: true,
          messageCount: sanitizedMsgs.length,
        );
        newCount++;
      } else {
        final shouldReplace = switch (mode) {
          ChatRestoreConflictMode.skipExisting => false,
          ChatRestoreConflictMode.overwriteExisting => true,
          ChatRestoreConflictMode.mergeKeepNewer =>
            _isBackupEntryNewer(entry, existing),
          ChatRestoreConflictMode.importAsCopy => true,
        };
        if (!shouldReplace) {
          skippedCount++;
          continue;
        }
        targetId = entry.session.id;
        targetSession = entry.session.copyWith(
          clearRemoteConversationId: true,
          messageCount: sanitizedMsgs.length,
        );
        updatedCount++;
      }

      await ChatMessageStore.instance.save(targetId, sanitizedMsgs);
      messagesToWrite += sanitizedMsgs.length;
      upsertedSessions.add(targetSession);
      restoredIds.add(targetId);

      final draftText = entry.draftText;
      if (draftText != null && draftText.trim().isNotEmpty) {
        restoredDrafts[targetId] = ChatDraft(
          text: sanitizeDraftText(draftText),
          updatedAt: entry.draftUpdatedAt ?? entry.session.updatedAt,
        );
      }
    }

    final missingProjects = bundle.projects
        .where((p) => !existingProjectIds.contains(p.id))
        .toList(growable: false);

    return ChatRestoreApplyResult(
      summary: ChatRestorePlanSummary(
        newSessions: newCount,
        updatedSessions: updatedCount,
        copiedSessions: copiedCount,
        skippedSessions: skippedCount,
        totalMessagesToWrite: messagesToWrite,
      ),
      upsertedSessions: upsertedSessions,
      restoredSessionIds: restoredIds,
      restoredDrafts: restoredDrafts,
      missingProjects: missingProjects,
    );
  }

  Future<Directory?> _backupsDir() async {
    if (_backupDirectoryOverride != null) {
      if (!await _backupDirectoryOverride.exists()) {
        await _backupDirectoryOverride.create(recursive: true);
      }
      return _backupDirectoryOverride;
    }
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/agy_chat_backups');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<ChatBackupSnapshotInfo?> saveLocalSnapshot(
    ChatBackupBundle bundle,
  ) async {
    final dir = await _backupsDir();
    if (dir == null) return null;

    final fileName = suggestedFileName(at: bundle.exportedAt, compressed: true);
    final id = fileName.replaceAll('.agychats.json.gz', '');
    final dataFile = File('${dir.path}/$fileName');
    final metaFile = File('${dir.path}/$id.meta.json');
    final bytes = bundle.encodeBytes(compressed: true);
    await dataFile.writeAsBytes(bytes, flush: true);

    final info = ChatBackupSnapshotInfo(
      id: id,
      filePath: dataFile.path,
      fileName: fileName,
      createdAt: bundle.exportedAt,
      sessionCount: bundle.sessionCount,
      messageCount: bundle.totalMessages,
      byteLength: bytes.length,
      appVersion: bundle.appVersion,
    );
    await metaFile.writeAsString(jsonEncode(info.toJson()), flush: true);
    await recordLastBackupAt(bundle.exportedAt);
    return info;
  }

  Future<List<ChatBackupSnapshotInfo>> listLocalSnapshots() async {
    final dir = await _backupsDir();
    if (dir == null || !await dir.exists()) return const [];
    final items = <ChatBackupSnapshotInfo>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.agychats.json.gz')) {
        continue;
      }
      final fileName = entity.uri.pathSegments.last;
      final id = fileName.replaceAll('.agychats.json.gz', '');
      final metaFile = File('${dir.path}/$id.meta.json');
      ChatBackupSnapshotInfo? parsed;
      if (await metaFile.exists()) {
        try {
          final decoded = jsonDecode(await metaFile.readAsString());
          if (decoded is Map<String, dynamic>) {
            parsed = ChatBackupSnapshotInfo.fromJson(
              decoded,
              filePath: entity.path,
            );
          }
        } catch (_) {}
      }
      if (parsed == null) {
        try {
          final bytes = await entity.readAsBytes();
          final bundle = ChatBackupBundle.decodeBytes(bytes);
          parsed = ChatBackupSnapshotInfo(
            id: id,
            filePath: entity.path,
            fileName: fileName,
            createdAt: bundle.exportedAt,
            sessionCount: bundle.sessionCount,
            messageCount: bundle.totalMessages,
            byteLength: bytes.length,
            appVersion: bundle.appVersion,
          );
        } catch (_) {
          continue;
        }
      }
      items.add(parsed);
    }
    items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return items;
  }

  Future<ChatBackupBundle> readSnapshotFile(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException('Backup snapshot not found', filePath);
    }
    final bytes = await file.readAsBytes();
    return ChatBackupBundle.decodeBytes(bytes);
  }

  Future<void> deleteLocalSnapshot(ChatBackupSnapshotInfo info) async {
    final dataFile = File(info.filePath);
    if (await dataFile.exists()) {
      await dataFile.delete();
    }
    final metaPath = info.filePath.replaceAll('.agychats.json.gz', '.meta.json');
    final metaFile = File(metaPath);
    if (await metaFile.exists()) {
      await metaFile.delete();
    }
  }
}
