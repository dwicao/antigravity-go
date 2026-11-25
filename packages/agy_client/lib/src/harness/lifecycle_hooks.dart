import 'dart:convert';

/// Execution phase for a user-configurable harness lifecycle hook.
enum LifecycleHookPhase {
  preToolUse('preToolUse', 'PreToolUse'),
  postToolUse('postToolUse', 'PostToolUse');

  const LifecycleHookPhase(this.id, this.label);
  final String id;
  final String label;

  static LifecycleHookPhase fromString(String? value) {
    return value == 'postToolUse'
        ? LifecycleHookPhase.postToolUse
        : LifecycleHookPhase.preToolUse;
  }
}

/// Action taken when a [LifecycleHookRule] matches.
enum LifecycleHookAction {
  block('block', 'Block'),
  command('command', 'Run Command');

  const LifecycleHookAction(this.id, this.label);
  final String id;
  final String label;

  static LifecycleHookAction fromString(String? value) {
    return value == 'command'
        ? LifecycleHookAction.command
        : LifecycleHookAction.block;
  }
}

/// Single deterministic PreToolUse / PostToolUse lifecycle hook rule.
class LifecycleHookRule {
  const LifecycleHookRule({
    required this.id,
    required this.name,
    required this.phase,
    required this.toolMatcher,
    required this.pathPattern,
    required this.action,
    this.enabled = true,
    this.command = '',
    this.reason = '',
  });

  final String id;
  final String name;
  final LifecycleHookPhase phase;
  final String toolMatcher; // 'write_file', 'shell', or '*'
  final String pathPattern; // Comma-separated glob/substring patterns
  final LifecycleHookAction action;
  final bool enabled;
  final String command;
  final String reason;

  LifecycleHookRule copyWith({
    String? name,
    LifecycleHookPhase? phase,
    String? toolMatcher,
    String? pathPattern,
    LifecycleHookAction? action,
    bool? enabled,
    String? command,
    String? reason,
  }) {
    return LifecycleHookRule(
      id: id,
      name: name ?? this.name,
      phase: phase ?? this.phase,
      toolMatcher: toolMatcher ?? this.toolMatcher,
      pathPattern: pathPattern ?? this.pathPattern,
      action: action ?? this.action,
      enabled: enabled ?? this.enabled,
      command: command ?? this.command,
      reason: reason ?? this.reason,
    );
  }

  bool matchesTool(String tool) {
    final m = toolMatcher.trim().toLowerCase();
    return m == '*' || m.isEmpty || m == tool.trim().toLowerCase();
  }

  bool matchesTarget(String target) {
    final raw = pathPattern.trim();
    if (raw.isEmpty || raw == '*') return true;
    final lowerTarget = target.replaceAll('\\', '/').toLowerCase();
    final fileName = lowerTarget.split('/').last;
    for (final part in raw.split(',')) {
      final token = part.trim().toLowerCase();
      if (token.isEmpty) continue;
      if (_globMatches(token, lowerTarget) || _globMatches(token, fileName)) {
        return true;
      }
      if (!token.contains('*') && lowerTarget.contains(token)) {
        return true;
      }
    }
    return false;
  }

  static bool _globMatches(String pattern, String value) {
    final escaped = RegExp.escape(pattern).replaceAll(r'\*', '.*');
    return RegExp('^$escaped\$', caseSensitive: false).hasMatch(value);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phase': phase.id,
        'toolMatcher': toolMatcher,
        'pathPattern': pathPattern,
        'action': action.id,
        'enabled': enabled,
        'command': command,
        'reason': reason,
      };

  factory LifecycleHookRule.fromJson(Map<String, dynamic> json) {
    return LifecycleHookRule(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Custom Hook',
      phase: LifecycleHookPhase.fromString(json['phase']?.toString()),
      toolMatcher: json['toolMatcher']?.toString() ?? '*',
      pathPattern: json['pathPattern']?.toString() ?? '*',
      action: LifecycleHookAction.fromString(json['action']?.toString()),
      enabled: json['enabled'] as bool? ?? true,
      command: json['command']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
    );
  }
}

/// Manages configurable PreToolUse / PostToolUse lifecycle hooks.
class LifecycleHooksConfig {
  const LifecycleHooksConfig({required this.rules});

  final List<LifecycleHookRule> rules;

  static const List<LifecycleHookRule> defaults = [
    LifecycleHookRule(
      id: 'block-sensitive-files',
      name: 'Block Sensitive Secrets (.env / Keystore)',
      phase: LifecycleHookPhase.preToolUse,
      toolMatcher: 'write_file',
      pathPattern: '*.env,.env.*,*.keystore,*.jks,*.p12,*id_rsa*',
      action: LifecycleHookAction.block,
      enabled: true,
      reason: 'Blocked by PreToolUse hook: sensitive secret or keystore file.',
    ),
    LifecycleHookRule(
      id: 'block-personal-sdcard',
      name: 'Protect Personal Phone Media (/sdcard/DCIM, Pictures)',
      phase: LifecycleHookPhase.preToolUse,
      toolMatcher: '*',
      pathPattern: '/sdcard/dcim*,/sdcard/pictures*,/storage/emulated/0/dcim*,/storage/emulated/0/pictures*',
      action: LifecycleHookAction.block,
      enabled: true,
      reason: 'Blocked by PreToolUse hook: personal phone media folder protected.',
    ),
    LifecycleHookRule(
      id: 'post-edit-dart-format',
      name: 'PostToolUse Auto-Format Dart Files',
      phase: LifecycleHookPhase.postToolUse,
      toolMatcher: 'write_file',
      pathPattern: '*.dart',
      action: LifecycleHookAction.command,
      enabled: false,
      command: 'dart format {file}',
      reason: 'Format edited Dart files automatically.',
    ),
  ];

  factory LifecycleHooksConfig.initial() =>
      const LifecycleHooksConfig(rules: defaults);

  ({bool allowed, String reason}) evaluatePreToolUse({
    required String tool,
    required String target,
  }) {
    for (final rule in rules) {
      if (!rule.enabled || rule.phase != LifecycleHookPhase.preToolUse) {
        continue;
      }
      if (rule.action == LifecycleHookAction.block &&
          rule.matchesTool(tool) &&
          rule.matchesTarget(target)) {
        return (
          allowed: false,
          reason: rule.reason.isNotEmpty
              ? rule.reason
              : 'Blocked by PreToolUse hook "${rule.name}".',
        );
      }
    }
    return (allowed: true, reason: '');
  }

  List<String> postToolUseCommands({
    required String tool,
    required String filePath,
  }) {
    final out = <String>[];
    for (final rule in rules) {
      if (!rule.enabled || rule.phase != LifecycleHookPhase.postToolUse) {
        continue;
      }
      if (rule.action == LifecycleHookAction.command &&
          rule.command.trim().isNotEmpty &&
          rule.matchesTool(tool) &&
          rule.matchesTarget(filePath)) {
        final quoted = "'${filePath.replaceAll("'", "'\\''")}'";
        out.add(rule.command.replaceAll('{file}', quoted));
      }
    }
    return out;
  }

  String encodeJson() =>
      jsonEncode(rules.map((r) => r.toJson()).toList(growable: false));

  static LifecycleHooksConfig decodeJson(String raw) {
    if (raw.trim().isEmpty) return LifecycleHooksConfig.initial();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return LifecycleHooksConfig.initial();
      final parsed = decoded
          .whereType<Map<String, dynamic>>()
          .map(LifecycleHookRule.fromJson)
          .where((r) => r.id.isNotEmpty)
          .toList();
      return parsed.isEmpty
          ? LifecycleHooksConfig.initial()
          : LifecycleHooksConfig(rules: parsed);
    } catch (_) {
      return LifecycleHooksConfig.initial();
    }
  }
}
