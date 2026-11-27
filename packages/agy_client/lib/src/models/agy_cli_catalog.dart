/// Catalog of all official Antigravity CLI (`agy`) slash commands, subcommands,
/// and changed-file summary models shared across client, chat, and Git review.
class AgySlashCommand {
  const AgySlashCommand({
    required this.command,
    required this.description,
    this.argHint,
    this.aliases = const [],
    this.handledLocally = false,
  });

  final String command;
  final String description;
  final String? argHint;
  final List<String> aliases;
  final bool handledLocally;

  bool matches(String input) {
    final lower = input.toLowerCase();
    if (command.startsWith(lower)) return true;
    return aliases.any((a) => a.startsWith(lower));
  }
}

class AgyCliSubcommand {
  const AgyCliSubcommand({
    required this.name,
    required this.summary,
    required this.defaultArgs,
    this.actions = const [],
  });

  final String name;
  final String summary;
  final List<String> defaultArgs;
  final List<String> actions;
}

class AgyCliCatalog {
  const AgyCliCatalog._();

  static const List<AgySlashCommand> slashCommands = [
    AgySlashCommand(
      command: '/plan',
      aliases: ['/planning'],
      argHint: '<task>',
      description: 'Explore codebase and draft an implementation plan',
    ),
    AgySlashCommand(
      command: '/goal',
      argHint: '<objective>',
      description: 'Run autonomously until objective is verified complete',
    ),
    AgySlashCommand(
      command: '/boost',
      argHint: '<task>',
      description: 'Deep reasoning with strategic planning & verification',
    ),
    AgySlashCommand(
      command: '/swarm',
      argHint: '<task>',
      description: 'Coordinate a swarm of specialized parallel agents',
    ),
    AgySlashCommand(
      command: '/teamwork',
      argHint: '<task>',
      description: 'Launch collaborative multi-agent team workflow',
    ),
    AgySlashCommand(
      command: '/grill-me',
      argHint: '<topic>',
      description: 'Interactive interview to resolve architecture/design decisions',
    ),
    AgySlashCommand(
      command: '/fast',
      argHint: '<task>',
      description: 'Fast lightweight execution mode',
    ),
    AgySlashCommand(
      command: '/compact',
      argHint: '[instructions]',
      description: 'Summarize conversation history to free context window',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/context',
      description: 'Show context window token breakdown & usage',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/harness',
      description: 'Open Harness Engineering (loop guard, checkpoints & ledger)',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/rsi',
      aliases: ['/self-improve', '/evolve'],
      argHint: '[objective | status | stop]',
      description:
          'Auto recursive self-improve → CI watch → GitHub APK release loop',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/btw',
      argHint: '<side question>',
      description: 'Ask a quick side question without cluttering the thread',
    ),
    AgySlashCommand(
      command: '/clear',
      aliases: ['/new'],
      description: 'Clear current conversation or start a fresh thread',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/rewind',
      aliases: ['/undo'],
      description: 'Rewind / undo the last turn and changes',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/fork',
      aliases: ['/branch'],
      description: 'Fork this conversation into a new branch',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/resume',
      argHint: '[session-id]',
      description: 'Resume a previous Antigravity session',
    ),
    AgySlashCommand(
      command: '/config',
      aliases: ['/settings'],
      description: 'Open Antigravity configuration & CLI flags',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/permissions',
      description: 'Inspect or update tool permission preset',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/model',
      argHint: '[model-id]',
      description: 'List or switch the active reasoning model',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/usage',
      aliases: ['/quota'],
      description: 'Inspect 5-hour & weekly model quotas',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/credits',
      description: 'Check Google AI credits balance & status',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/agents',
      argHint: '[agent-name]',
      description: 'List or select subagents & custom CLI agents',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/statusline',
      description: 'Configure bottom / status bar metrics',
    ),
    AgySlashCommand(
      command: '/mcp',
      description: 'Manage Model Context Protocol (MCP) servers',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/plugin',
      description: 'List, install, or manage agy plugins',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/changelog',
      description: 'View Antigravity CLI changelog notes',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/diff',
      description: 'Review uncommitted Git changes & file diffs',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/export',
      description: 'Export or share Markdown conversation transcript',
      handledLocally: true,
    ),
    AgySlashCommand(
      command: '/help',
      aliases: ['/?'],
      description: 'Show all supported Antigravity CLI commands & flags',
      handledLocally: true,
    ),
  ];

  static const List<AgyCliSubcommand> subcommands = [
    AgyCliSubcommand(
      name: 'models',
      summary: 'List available Antigravity models & reasoning tiers',
      defaultArgs: ['models'],
    ),
    AgyCliSubcommand(
      name: 'agent',
      summary: 'List and inspect configured CLI agents (--agent)',
      defaultArgs: ['agent'],
    ),
    AgyCliSubcommand(
      name: 'agents',
      summary: 'Alias for agent subcommand',
      defaultArgs: ['agents'],
    ),
    AgyCliSubcommand(
      name: 'mcp',
      summary: 'List, add, enable, or remove MCP servers',
      defaultArgs: ['mcp', 'list'],
      actions: ['list', 'add', 'remove', 'enable', 'disable'],
    ),
    AgyCliSubcommand(
      name: 'plugin',
      summary: 'Manage agy plugins and marketplace extensions',
      defaultArgs: ['plugin', 'list'],
      actions: ['list', 'install', 'uninstall', 'enable', 'disable', 'validate'],
    ),
    AgyCliSubcommand(
      name: 'plugins',
      summary: 'Alias for plugin management',
      defaultArgs: ['plugins', 'list'],
      actions: ['list', 'install', 'uninstall', 'enable', 'disable'],
    ),
    AgyCliSubcommand(
      name: 'install',
      summary: 'Configure environment paths and shell settings',
      defaultArgs: ['install'],
    ),
    AgyCliSubcommand(
      name: 'remote-control',
      summary: 'Start, check, or stop agy remote-control daemon',
      defaultArgs: ['remote-control', 'status'],
      actions: ['status', 'start', 'stop'],
    ),
    AgyCliSubcommand(
      name: 'changelog',
      summary: 'Display Antigravity CLI release changelog',
      defaultArgs: ['changelog'],
    ),
    AgyCliSubcommand(
      name: 'update',
      summary: 'Update the bundled agy CLI binary',
      defaultArgs: ['update'],
    ),
    AgyCliSubcommand(
      name: 'acp',
      summary: 'Run Agent Client Protocol stdio bridge server',
      defaultArgs: ['acp', '--help'],
    ),
    AgyCliSubcommand(
      name: 'mic-serve',
      summary: 'Start local microphone dictation server',
      defaultArgs: ['mic-serve', '--help'],
    ),
  ];
}

class FileChangeEntry {
  const FileChangeEntry({
    required this.path,
    this.added = 0,
    this.removed = 0,
    this.created = false,
    this.deleted = false,
    this.diff,
  });

  final String path;
  final int added;
  final int removed;
  final bool created;
  final bool deleted;
  final String? diff;

  String get fileName {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx >= 0 ? norm.substring(idx + 1) : norm;
  }

  String get directory {
    final norm = path.replaceAll('\\', '/');
    final idx = norm.lastIndexOf('/');
    return idx > 0 ? norm.substring(0, idx) : '';
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'added': added,
        'removed': removed,
        'created': created,
        'deleted': deleted,
        if (diff != null) 'diff': diff,
      };

  factory FileChangeEntry.fromJson(Map<String, dynamic> json) =>
      FileChangeEntry(
        path: json['path']?.toString() ?? '',
        added: (json['added'] as num?)?.toInt() ?? 0,
        removed: (json['removed'] as num?)?.toInt() ?? 0,
        created: json['created'] as bool? ?? false,
        deleted: json['deleted'] as bool? ?? false,
        diff: json['diff']?.toString(),
      );

  static String _unquoteGitPath(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('"') && clean.endsWith('"') && clean.length >= 2) {
      clean = clean.substring(1, clean.length - 1);
    }
    return clean;
  }

  /// Resolves Git numstat rename notation (`dir/{old.dart => new.dart}` or
  /// `old.dart => new.dart`) to its destination path so it matches `diff --git`.
  static String _resolveNumstatPath(String raw) {
    var clean = _unquoteGitPath(raw);
    final braceMatch = RegExp(r'^(.*)\{[^}]* => ([^}]*)\}(.*)$').firstMatch(clean);
    if (braceMatch != null) {
      clean = '${braceMatch.group(1)}${braceMatch.group(2)}${braceMatch.group(3)}'
          .replaceAll('//', '/');
      return clean.trim();
    }
    if (clean.contains(' => ')) {
      clean = _unquoteGitPath(clean.split(' => ').last);
    }
    return clean.trim();
  }

  /// Parses `git diff --numstat` or `git show --numstat --format=""` output.
  static List<FileChangeEntry> parseGitNumstat(
    String raw, {
    Set<String> createdPaths = const {},
    Set<String> deletedPaths = const {},
  }) {
    final out = <FileChangeEntry>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final parts = trimmed.split('\t');
      if (parts.length < 3) continue;
      final added = int.tryParse(parts[0]) ?? 0;
      final removed = int.tryParse(parts[1]) ?? 0;
      final path = _resolveNumstatPath(parts.sublist(2).join('\t'));
      if (path.isEmpty) continue;
      out.add(
        FileChangeEntry(
          path: path,
          added: added,
          removed: removed,
          created: createdPaths.contains(path),
          deleted: deletedPaths.contains(path),
        ),
      );
    }
    return out;
  }

  /// Parses `git status --short` + `git diff --numstat` + unified diff outputs
  /// into enriched [FileChangeEntry] records, preserving both added and deleted files.
  static List<FileChangeEntry> fromGitOutputs({
    required String status,
    required String numstat,
    required String diff,
  }) {
    final created = <String>{};
    final deleted = <String>{};
    for (final rawLine in status.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      String code;
      String rawPath;
      if (line.length >= 4 && line[2] == ' ') {
        code = line.substring(0, 2);
        rawPath = line.substring(3);
      } else if (line.length >= 3 && line[1] == ' ' && line[0] != ' ') {
        // Recover XY code if caller stripped the leading status space (`" D foo"`).
        code = ' ${line[0]}';
        rawPath = line.substring(2);
      } else {
        continue;
      }
      var path = rawPath.trim();
      if (path.contains(' -> ')) {
        path = path.split(' -> ').last.trim();
      }
      path = _unquoteGitPath(path);
      if (path.isEmpty) continue;
      if (code.contains('?') || code.contains('A') || code.contains('R')) {
        created.add(path);
      }
      if (code.contains('D')) {
        deleted.add(path);
      }
    }

    final files = parseGitNumstat(
      numstat,
      createdPaths: created,
      deletedPaths: deleted,
    );
    final seen = files.map((f) => f.path).toSet();
    for (final path in created) {
      if (seen.add(path)) {
        files.add(FileChangeEntry(path: path, created: true));
      }
    }
    for (final path in deleted) {
      if (seen.add(path)) {
        files.add(FileChangeEntry(path: path, deleted: true));
      }
    }
    return attachUnifiedDiffs(files, diff);
  }

  /// Splits a full `git diff` / `git show` patch by `diff --git` sections and
  /// attaches the matching per-file patch snippet to each [FileChangeEntry].
  static List<FileChangeEntry> attachUnifiedDiffs(
    List<FileChangeEntry> entries,
    String unifiedDiff,
  ) {
    if (entries.isEmpty || unifiedDiff.trim().isEmpty) return entries;
    final perFile = <String, ({String patch, int added, int removed, bool created, bool deleted})>{};
    final lines = unifiedDiff.replaceAll('\r\n', '\n').split('\n');
    String? currentPath;
    var added = 0;
    var removed = 0;
    var created = false;
    var deleted = false;
    final buf = StringBuffer();

    void flush() {
      if (currentPath != null && buf.isNotEmpty) {
        perFile[currentPath] = (
          patch: buf.toString().trimRight(),
          added: added,
          removed: removed,
          created: created,
          deleted: deleted,
        );
      }
      buf.clear();
      added = 0;
      removed = 0;
      created = false;
      deleted = false;
    }

    for (final line in lines) {
      if (line.startsWith('diff --git ')) {
        flush();
        final match = RegExp(
          r'^diff --git (?:"a/(.+?)"|a/(.+?)) (?:"b/(.+?)"|b/(.+))$',
        ).firstMatch(line);
        final raw = match?.group(3) ?? match?.group(4);
        currentPath = raw == null ? null : _unquoteGitPath(raw);
        buf.writeln(line);
      } else if (currentPath != null) {
        if (line.startsWith('--- /dev/null')) {
          created = true;
        } else if (line.startsWith('+++ /dev/null')) {
          deleted = true;
        } else if (line.startsWith('+++ b/')) {
          currentPath = _unquoteGitPath(line.substring(6));
        } else if (line.startsWith('+++ "b/') && line.endsWith('"')) {
          currentPath = line.substring(7, line.length - 1).trim();
        } else if (line.startsWith('+') && !line.startsWith('+++')) {
          added++;
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          removed++;
        }
        buf.writeln(line);
      }
    }
    flush();

    return entries.map((e) {
      final info = perFile[e.path] ?? perFile[_unquoteGitPath(e.path)];
      if (info == null) return e;
      return FileChangeEntry(
        path: e.path,
        added: e.added > 0 ? e.added : info.added,
        removed: e.removed > 0 ? e.removed : info.removed,
        created: e.created || info.created,
        deleted: e.deleted || info.deleted,
        diff: info.patch,
      );
    }).toList();
  }
}

class AgyCliManagedItem {
  const AgyCliManagedItem({
    required this.name,
    this.detail = '',
    this.enabled = true,
  });

  final String name;
  final String detail;
  final bool enabled;

  /// Parses CLI list output from `agy mcp list`, `agy plugin list`, or `agy agent`.
  static List<AgyCliManagedItem> parseListOutput(String raw) {
    final items = <AgyCliManagedItem>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('error:') ||
          lower.startsWith('i1') ||
          lower.startsWith('w1') ||
          lower.startsWith('e1') ||
          lower.startsWith('no ') ||
          lower.startsWith('usage:')) {
        continue;
      }
      var clean = trimmed
          .replaceFirst(RegExp(r'^[-*•]\s+'), '')
          .trim();
      if (clean.isEmpty) continue;
      final disabled = lower.contains('(disabled)') || lower.contains('[disabled]');
      clean = clean
          .replaceAll(RegExp(r'\s*\((disabled|enabled)\)\s*', caseSensitive: false), ' ')
          .trim();
      final sepIdx = clean.indexOf(RegExp(r'[:\t]|\s{2,}|\s+-\s+|\s+—\s+'));
      if (sepIdx > 0) {
        final name = clean.substring(0, sepIdx).trim();
        final detail = clean
            .substring(sepIdx)
            .replaceFirst(RegExp(r'^[:\-\—\s\t]+'), '')
            .trim();
        if (name.isNotEmpty) {
          items.add(AgyCliManagedItem(name: name, detail: detail, enabled: !disabled));
        }
      } else {
        final firstToken = clean.split(RegExp(r'\s+')).first;
        final rest = clean.length > firstToken.length
            ? clean.substring(firstToken.length).trim()
            : '';
        items.add(
          AgyCliManagedItem(name: firstToken, detail: rest, enabled: !disabled),
        );
      }
    }
    return items;
  }
}

enum ChatMilestoneKind { thought, tool, text }

/// One chronological milestone/progress card inside an assistant turn
/// (e.g. `Thinking - ...`, `Run - cd /sdcard...`, `Thinking - ...`).
class ChatMilestoneStep {
  const ChatMilestoneStep({
    required this.id,
    required this.kind,
    this.text = '',
    this.toolId,
  });

  final String id;
  final ChatMilestoneKind kind;
  final String text;
  final String? toolId;

  ChatMilestoneStep copyWith({String? text}) {
    return ChatMilestoneStep(
      id: id,
      kind: kind,
      text: text ?? this.text,
      toolId: toolId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        if (text.isNotEmpty) 'text': text,
        if (toolId != null) 'toolId': toolId,
      };

  factory ChatMilestoneStep.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind']?.toString() ?? 'thought';
    return ChatMilestoneStep(
      id: json['id']?.toString() ?? '',
      kind: ChatMilestoneKind.values.firstWhere(
        (k) => k.name == kindRaw,
        orElse: () => ChatMilestoneKind.thought,
      ),
      text: json['text']?.toString() ?? '',
      toolId: json['toolId']?.toString(),
    );
  }
}

