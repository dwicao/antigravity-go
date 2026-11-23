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
}
