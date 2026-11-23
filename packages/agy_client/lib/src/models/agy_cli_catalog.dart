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
    ),
    AgySlashCommand(
      command: '/context',
      description: 'Show context window token breakdown & usage',
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
      defaultArgs: ['agent', 'list'],
      actions: ['list'],
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
      final path = parts.sublist(2).join('\t').trim();
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
}

enum ChatMilestoneKind { thought, tool }

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

