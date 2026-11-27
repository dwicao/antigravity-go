import 'dart:io';
import 'dart:typed_data';

import 'package:agy_client/agy_client.dart';
import 'package:antigravity_go/state/chat_backup_service.dart';
import 'package:antigravity_go/state/chat_message_store.dart';
import 'package:antigravity_go/state/chat_models.dart';
import 'package:antigravity_go/state/draft_store.dart';
import 'package:antigravity_go/state/session_export_helper.dart';
import 'package:antigravity_go/state/sessions_state.dart';
import 'package:antigravity_go/ui/backup/chat_backup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AgySessionSummary _makeSession({
  required String id,
  required String title,
  DateTime? updatedAt,
  int messageCount = 2,
  bool archived = false,
  bool pinned = false,
  String folder = '',
  String projectId = 'default',
  String? lastPreview,
}) {
  return AgySessionSummary(
    id: id,
    title: title,
    hostId: 'local',
    hostName: 'On Device',
    hostKind: AgyHostKind.local,
    workspacePath: '/sdcard/Projects/app',
    modelId: 'gemini-4-hydrogen',
    updatedAt: updatedAt ?? DateTime.utc(2026, 11, 27, 6, 0),
    projectId: projectId,
    messageCount: messageCount,
    archived: archived,
    pinned: pinned,
    folder: folder,
    lastPreview: lastPreview,
  );
}

List<ChatMessage> _makeMessages(String prefix, {int count = 2}) {
  return [
    for (var i = 0; i < count; i++)
      ChatMessage(
        id: '$prefix-m$i',
        role: i.isEven ? ChatRole.user : ChatRole.assistant,
        text: i.isEven
            ? 'Prompt $i with token sk-ant-secret1234567890abcd'
            : 'Answer $i for $prefix',
        createdAt: DateTime.utc(2026, 11, 27, 6, i),
        thoughts: i.isOdd ? 'Internal reasoning step' : '',
        usage: i.isOdd
            ? const TokenUsage(inputTokens: 120, outputTokens: 80)
            : null,
      ),
  ];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('ChatBackupBundle roundtrips plain JSON and gzipped bytes with masking', () {
    final s1 = _makeSession(
      id: 's1',
      title: 'Auth Migration',
      lastPreview: 'Used key ghp_1234567890abcdefghijklmnopqrstuvwx',
    );
    final bundle = ChatBackupBundle(
      appVersion: '1.0.57',
      exportedAt: DateTime.utc(2026, 11, 27, 6, 30),
      projects: const [
        AgyProject(
          id: 'proj-x',
          name: 'Backend API',
          folders: ['/sdcard/Projects/api'],
        ),
      ],
      entries: [
        ChatBackupEntry(
          session: s1,
          messages: _makeMessages('s1'),
          draftText: 'Draft using sk-ant-99998888777766665555',
          draftUpdatedAt: DateTime.utc(2026, 11, 27, 6, 29),
        ),
      ],
    );

    final gzBytes = bundle.encodeBytes(compressed: true);
    final plainBytes = bundle.encodeBytes(compressed: false);
    expect(gzBytes[0], 0x1f);
    expect(gzBytes[1], 0x8b);
    expect(gzBytes.length, lessThan(plainBytes.length));

    final decodedGz = ChatBackupBundle.decodeBytes(gzBytes);
    expect(decodedGz.sessionCount, 1);
    expect(decodedGz.totalMessages, 2);
    expect(decodedGz.projects.single.id, 'proj-x');
    expect(decodedGz.entries.single.session.title, 'Auth Migration');
    expect(decodedGz.entries.single.messages.first.text, isNot(contains('sk-ant-secret1234567890abcd')));
    expect(decodedGz.entries.single.draftText, isNot(contains('sk-ant-99998888777766665555')));
    expect(decodedGz.entries.single.session.lastPreview, isNot(contains('ghp_1234567890abcdefghijklmnopqrstuvwx')));

    final decodedPlain = ChatBackupBundle.decodeBytes(plainBytes);
    expect(decodedPlain.entries.single.messages.last.usage?.totalTokens, 200);

    final md = decodedGz.toMarkdownDigest();
    expect(md, contains('# Antigravity Go — Chat Backup Archive'));
    expect(md, contains('# Auth Migration'));
  });

  test('ChatBackupBundle parses single-chat Replay JSON export seamlessly', () {
    final s1 = _makeSession(id: 'replay-1', title: 'Single Chat');
    final msgs = _makeMessages('r1');
    final rawJson = SessionExportHelper.toJsonString(s1, msgs);

    final bundle = ChatBackupBundle.decodeJsonString(rawJson);
    expect(bundle.sessionCount, 1);
    expect(bundle.entries.single.session.id, 'replay-1');
    expect(bundle.entries.single.messages.length, 2);
  });

  test('previewRestorePlan & prepareAndPersistRestore handle all conflict strategies', () async {
    final localOld = _makeSession(
      id: 'same',
      title: 'Local Shorter',
      updatedAt: DateTime.utc(2026, 11, 26, 10, 0),
      messageCount: 1,
    );
    await ChatMessageStore.instance.save('same', _makeMessages('local', count: 1));

    final bundle = ChatBackupBundle(
      appVersion: '1.0.57',
      exportedAt: DateTime.utc(2026, 11, 27, 6, 30),
      projects: const [
        AgyProject(id: 'custom-proj', name: 'Custom', folders: ['/tmp/custom']),
      ],
      entries: [
        ChatBackupEntry(
          session: _makeSession(
            id: 'same',
            title: 'Backup Longer',
            updatedAt: DateTime.utc(2026, 11, 27, 6, 0),
            messageCount: 3,
            projectId: 'custom-proj',
          ),
          messages: _makeMessages('same-bk', count: 3),
          draftText: 'Continue refactor',
        ),
        ChatBackupEntry(
          session: _makeSession(
            id: 'brand-new',
            title: 'New Session',
            messageCount: 2,
          ),
          messages: _makeMessages('new-bk', count: 2),
        ),
      ],
    );

    final service = ChatBackupService();

    // 1. skipExisting
    final skipPlan = ChatBackupService.previewRestorePlan(
      bundle: bundle,
      existingSessions: [localOld],
      mode: ChatRestoreConflictMode.skipExisting,
    );
    expect(skipPlan.newSessions, 1);
    expect(skipPlan.skippedSessions, 1);
    expect(skipPlan.updatedSessions, 0);

    // 2. mergeKeepNewer -> 'same' has 3 msgs vs local 1 msg -> updates
    final mergePlan = ChatBackupService.previewRestorePlan(
      bundle: bundle,
      existingSessions: [localOld],
      mode: ChatRestoreConflictMode.mergeKeepNewer,
    );
    expect(mergePlan.newSessions, 1);
    expect(mergePlan.updatedSessions, 1);
    expect(mergePlan.totalMessagesToWrite, 5);

    final appliedMerge = await service.prepareAndPersistRestore(
      bundle: bundle,
      existingSessions: [localOld],
      existingProjects: const [
        AgyProject(id: 'default', name: 'Default', folders: []),
      ],
      mode: ChatRestoreConflictMode.mergeKeepNewer,
    );
    expect(appliedMerge.summary.restoredTotal, 2);
    expect(appliedMerge.missingProjects.single.id, 'custom-proj');
    expect(appliedMerge.restoredDrafts['same']?.text, 'Continue refactor');
    final savedSame = await ChatMessageStore.instance.load('same');
    final savedNew = await ChatMessageStore.instance.load('brand-new');
    expect(savedSame.length, 3);
    expect(savedNew.length, 2);

    // 3. importAsCopy -> generates fresh UUIDs & '(Restored)' suffix
    final appliedCopy = await service.prepareAndPersistRestore(
      bundle: bundle,
      existingSessions: [localOld],
      existingProjects: const [],
      mode: ChatRestoreConflictMode.importAsCopy,
    );
    expect(appliedCopy.summary.copiedSessions, 2);
    expect(appliedCopy.upsertedSessions.first.id, isNot('same'));
    expect(appliedCopy.upsertedSessions.first.title, 'Backup Longer (Restored)');
    expect(appliedCopy.upsertedSessions.last.title, 'New Session');
  });

  test('Local snapshot save, list, read, and delete lifecycle works', () async {
    final tempDir = await Directory.systemTemp.createTemp('agy_backup_test_');
    addTearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    final service = ChatBackupService(backupDirectoryOverride: tempDir);
    final bundle = ChatBackupBundle(
      appVersion: '1.0.57',
      exportedAt: DateTime.utc(2026, 11, 27, 6, 45, 12),
      entries: [
        ChatBackupEntry(
          session: _makeSession(id: 'snap-1', title: 'Snapshot Session'),
          messages: _makeMessages('snap', count: 2),
        ),
      ],
    );

    final info = await service.saveLocalSnapshot(bundle);
    expect(info, isNotNull);
    expect(info!.sessionCount, 1);
    expect(info.messageCount, 2);

    final listed = await service.listLocalSnapshots();
    expect(listed.length, 1);
    expect(listed.single.fileName, info.fileName);

    final readBack = await service.readSnapshotFile(info.filePath);
    expect(readBack.entries.single.session.title, 'Snapshot Session');
    expect(readBack.entries.single.messages.length, 2);

    await service.deleteLocalSnapshot(info);
    expect(await service.listLocalSnapshots(), isEmpty);
  });

  testWidgets('ChatBackupPage fits 360px phone screen and creates & restores snapshot', (tester) async {
    final service = _InMemoryBackupService();

    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final session = _makeSession(id: 'ui-s1', title: 'Backup Demo Chat');
    await container.read(sessionsProvider.notifier).importSessions([session]);
    container.read(draftStoreProvider.notifier).save('ui-s1', 'Unsent draft');
    await container.read(draftStoreProvider.notifier).flush();
    await ChatMessageStore.instance.save('ui-s1', _makeMessages('ui-s1', count: 2));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ChatBackupPage(backupService: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Chat Backup & Restore'), findsOneWidget);
    expect(find.text('Local Chat Vault'), findsOneWidget);
    expect(find.text('Save Snapshot'), findsOneWidget);

    await tester.tap(find.text('Save Snapshot'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await service.listLocalSnapshots()).length, 1);

    // Delete the session locally, then restore from the snapshot row
    await container.read(sessionsProvider.notifier).deleteSession('ui-s1');
    await container.read(draftStoreProvider.notifier).flush();
    await tester.pumpAndSettle();
    expect(
      container.read(sessionsProvider).sessions.any((s) => s.id == 'ui-s1'),
      isFalse,
    );

    final restoreBtn = find.widgetWithText(FilledButton, 'Restore').first;
    await tester.scrollUntilVisible(
      restoreBtn,
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(restoreBtn);
    await tester.pumpAndSettle();

    expect(find.text('Restore Preview'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore (1)'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      container.read(sessionsProvider).sessions.any((s) => s.id == 'ui-s1'),
      isTrue,
    );
    final restoredMsgs = await ChatMessageStore.instance.load('ui-s1');
    expect(restoredMsgs.length, 2);
    expect(container.read(draftStoreProvider.notifier).draftFor('ui-s1'), 'Unsent draft');
  });
}

class _InMemoryBackupService extends ChatBackupService {
  final Map<String, ({ChatBackupSnapshotInfo info, Uint8List bytes})> _store =
      {};

  @override
  Future<ChatBackupSnapshotInfo?> saveLocalSnapshot(
    ChatBackupBundle bundle,
  ) async {
    final name = ChatBackupService.suggestedFileName(
      at: bundle.exportedAt,
      compressed: true,
    );
    final path = 'mem://$name';
    final bytes = bundle.encodeBytes(compressed: true);
    final info = ChatBackupSnapshotInfo(
      id: name,
      filePath: path,
      fileName: name,
      createdAt: bundle.exportedAt,
      sessionCount: bundle.sessionCount,
      messageCount: bundle.totalMessages,
      byteLength: bytes.length,
      appVersion: bundle.appVersion,
    );
    _store[path] = (info: info, bytes: bytes);
    await recordLastBackupAt(bundle.exportedAt);
    return info;
  }

  @override
  Future<List<ChatBackupSnapshotInfo>> listLocalSnapshots() async {
    final list = _store.values.map((e) => e.info).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  @override
  Future<ChatBackupBundle> readSnapshotFile(String filePath) async {
    final hit = _store[filePath];
    if (hit == null) throw FileSystemException('Missing', filePath);
    return ChatBackupBundle.decodeBytes(hit.bytes);
  }

  @override
  Future<void> deleteLocalSnapshot(ChatBackupSnapshotInfo info) async {
    _store.remove(info.filePath);
  }
}
