import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  test('AgyCliCatalog includes all Antigravity CLI slash commands and subcommands', () {
    final cmds = AgyCliCatalog.slashCommands.map((c) => c.command).toSet();
    expect(cmds, containsAll([
      '/plan',
      '/goal',
      '/boost',
      '/swarm',
      '/teamwork',
      '/grill-me',
      '/fast',
      '/compact',
      '/context',
      '/rsi',
      '/btw',
      '/clear',
      '/rewind',
      '/fork',
      '/resume',
      '/config',
      '/permissions',
      '/model',
      '/usage',
      '/credits',
      '/agents',
      '/statusline',
      '/mcp',
      '/plugin',
      '/changelog',
      '/diff',
      '/export',
      '/help',
    ]));

    final subs = AgyCliCatalog.subcommands.map((s) => s.name).toSet();
    expect(subs, containsAll([
      'acp',
      'agent',
      'changelog',
      'mcp',
      'mic-serve',
      'models',
      'plugin',
      'remote-control',
      'update',
    ]));
  });

  test('FileChangeEntry.parseGitNumstat parses added/removed counts and flags', () {
    const raw = '18\t4\tapp/lib/ui/chat/chat_screen.dart\n'
        '6\t0\tapp/lib/ui/chat/change_card.dart\n'
        '0\t12\tapp/lib/old.dart\n';
    final entries = FileChangeEntry.parseGitNumstat(
      raw,
      createdPaths: {'app/lib/ui/chat/change_card.dart'},
      deletedPaths: {'app/lib/old.dart'},
    );
    expect(entries, hasLength(3));
    expect(entries[0].fileName, 'chat_screen.dart');
    expect(entries[0].added, 18);
    expect(entries[0].removed, 4);
    expect(entries[1].created, isTrue);
    expect(entries[2].deleted, isTrue);
  });

  test('FileChangeEntry.attachUnifiedDiffs splits git diff hunks by file', () {
    const numstat = '2\t1\tapp/a.dart\n1\t0\tapp/b.dart\n';
    const patch = '''
diff --git a/app/a.dart b/app/a.dart
index 111..222 100644
--- a/app/a.dart
+++ b/app/a.dart
@@ -1,2 +1,3 @@
-old
+new
+added
diff --git a/app/b.dart b/app/b.dart
new file mode 100644
--- /dev/null
+++ b/app/b.dart
@@ -0,0 +1 @@
+hello
''';
    final base = FileChangeEntry.parseGitNumstat(numstat);
    final enriched = FileChangeEntry.attachUnifiedDiffs(base, patch);
    expect(enriched[0].diff, contains('+new'));
    expect(enriched[0].diff, isNot(contains('+hello')));
    expect(enriched[1].diff, contains('+hello'));
  });

  test('AgyCliManagedItem.parseListOutput parses enabled and disabled entries', () {
    const raw = '''
No previous warnings
- filesystem: npx -y @modelcontextprotocol/server-filesystem (enabled)
- github: https://api.githubcopilot.com/mcp (disabled)
''';
    final parsed = AgyCliManagedItem.parseListOutput(raw);
    expect(parsed, hasLength(2));
    expect(parsed[0].name, 'filesystem');
    expect(parsed[0].enabled, isTrue);
    expect(parsed[1].name, 'github');
    expect(parsed[1].enabled, isFalse);
  });

  test('FileChangeEntry.fromGitOutputs preserves leading-space deletions and renames', () {
    const status = ' D app/lib/removed_first.dart\nR  app/lib/old.dart -> app/lib/new.dart\nD app/lib/trimmed_del.dart';
    const numstat = '0\t9\tapp/lib/removed_first.dart\n1\t4\tapp/lib/{old.dart => new.dart}';
    const diff = '''
diff --git a/app/lib/removed_first.dart b/app/lib/removed_first.dart
deleted file mode 100644
--- a/app/lib/removed_first.dart
+++ /dev/null
@@ -1,2 +0,0 @@
-line1
-line2
diff --git a/app/lib/old.dart b/app/lib/new.dart
similarity index 60%
rename from app/lib/old.dart
rename to app/lib/new.dart
--- a/app/lib/old.dart
+++ b/app/lib/new.dart
@@ -1,4 +1,1 @@
-a
+b
''';
    final files = FileChangeEntry.fromGitOutputs(
      status: status,
      numstat: numstat,
      diff: diff,
    );
    expect(files.map((f) => f.path), containsAll([
      'app/lib/removed_first.dart',
      'app/lib/new.dart',
      'app/lib/trimmed_del.dart',
    ]));
    final first = files.firstWhere((f) => f.path == 'app/lib/removed_first.dart');
    expect(first.deleted, isTrue);
    expect(first.removed, 9);
    final renamed = files.firstWhere((f) => f.path == 'app/lib/new.dart');
    expect(renamed.removed, 4);
    expect(renamed.diff, contains('-a'));
    final trimmedDel = files.firstWhere((f) => f.path == 'app/lib/trimmed_del.dart');
    expect(trimmedDel.deleted, isTrue);
  });
}
