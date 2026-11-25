enum CustomizationKind {
  rule('Rule'),
  skill('Skill'),
  mcpServer('MCP Server'),
  hook('Hook'),
  plugin('Plugin');

  const CustomizationKind(this.label);
  final String label;
}

class CustomizationItem {
  const CustomizationItem({
    required this.kind,
    required this.name,
    required this.scope,
    required this.pathOrCommand,
    this.description = '',
    this.enabled = true,
    this.content,
  });

  final CustomizationKind kind;
  final String name;
  final String scope; // 'Global', 'Project', or 'Built-in'
  final String pathOrCommand;
  final String description;
  final bool enabled;
  final String? content;
}

/// Parsed YAML frontmatter + body from a `SKILL.md` file.
class SkillFrontmatter {
  const SkillFrontmatter({
    required this.name,
    required this.description,
    required this.body,
  });

  final String name;
  final String description;
  final String body;

  static SkillFrontmatter parse(
    String raw, {
    required String fallbackName,
  }) {
    final normalized = raw.replaceAll('\r\n', '\n');
    final trimmedStart = normalized.trimLeft();
    if (!trimmedStart.startsWith('---')) {
      final body = normalized.trim();
      final firstLine = body
          .split('\n')
          .map((l) => l.trim())
          .firstWhere(
            (l) => l.isNotEmpty && !l.startsWith('#'),
            orElse: () => 'SKILL.md loaded',
          );
      return SkillFrontmatter(
        name: fallbackName,
        description: firstLine,
        body: body,
      );
    }

    final afterOpen = trimmedStart.indexOf('\n');
    if (afterOpen < 0) {
      return SkillFrontmatter(
        name: fallbackName,
        description: 'SKILL.md loaded',
        body: normalized.trim(),
      );
    }
    final rest = trimmedStart.substring(afterOpen + 1);
    final closeMatch =
        RegExp(r'^---\s*$', multiLine: true).firstMatch(rest);
    if (closeMatch == null) {
      return SkillFrontmatter(
        name: fallbackName,
        description: 'SKILL.md loaded',
        body: normalized.trim(),
      );
    }

    final yamlBlock = rest.substring(0, closeMatch.start);
    final body = rest.substring(closeMatch.end).trim();
    String? name;
    String? description;

    for (final line in yamlBlock.split('\n')) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toLowerCase();
      var val = line.substring(idx + 1).trim();
      if ((val.startsWith('"') && val.endsWith('"') && val.length >= 2) ||
          (val.startsWith("'") && val.endsWith("'") && val.length >= 2)) {
        val = val.substring(1, val.length - 1);
      }
      if (key == 'name' && val.isNotEmpty) name = val;
      if (key == 'description' && val.isNotEmpty) description = val;
    }

    return SkillFrontmatter(
      name: name ?? fallbackName,
      description: description ?? 'SKILL.md loaded',
      body: body,
    );
  }

  static String scaffold({
    required String name,
    required String description,
  }) {
    final cleanName = sanitizeSlug(name);
    final cleanDesc = description.trim().isEmpty
        ? 'Describe what this skill does and when the agent should use it.'
        : description.trim();
    return '''---
name: $cleanName
description: $cleanDesc
---

# $cleanName

## When to Use
- $cleanDesc

## Instructions
1. Inspect relevant files in the workspace first.
2. Follow project conventions in `AGENTS.md`.
3. Verify any edits before reporting completion.
''';
  }

  static String sanitizeSlug(String raw) {
    final slug = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'custom-skill' : slug;
  }
}

/// Pure Dart helpers for loading `AGENTS.md` instructions and invoking `SKILL.md` skills.
class AgentCustomizationHelper {
  const AgentCustomizationHelper._();

  static bool isAgentsFile(CustomizationItem item) {
    if (item.kind != CustomizationKind.rule) return false;
    final lower = item.pathOrCommand.toLowerCase();
    return lower.endsWith('/agents.md') ||
        lower.endsWith('\\agents.md') ||
        lower == 'agents.md' ||
        lower.endsWith('/agents.override.md') ||
        lower.endsWith('\\agents.override.md');
  }

  static String _stripManagedMarker(String content) {
    return content
        .replaceFirst(RegExp(r'^<!--\s*antigravity-go:managed[^\n]*-->\s*\n?'), '')
        .trim();
  }

  /// Expands `/<skill-name> [task]` or `/skill <skill-name> [task]` using the matching `SKILL.md`.
  static String? resolveInvokedSkillPrompt(
    String userPrompt,
    List<CustomizationItem> items,
  ) {
    final trimmed = userPrompt.trim();
    if (!trimmed.startsWith('/')) return null;

    final enabledSkills = items
        .where((i) => i.kind == CustomizationKind.skill && i.enabled)
        .toList();
    if (enabledSkills.isEmpty) return null;

    final parts = trimmed.split(RegExp(r'\s+'));
    final first = parts.first.substring(1).toLowerCase();
    String targetSkillName = first;
    String remainingTask = trimmed.substring(parts.first.length).trim();

    if (first == 'skill' && parts.length >= 2) {
      targetSkillName = parts[1].toLowerCase();
      final prefixMatch =
          RegExp(r'^/skill\s+\S+\s*').firstMatch(trimmed);
      remainingTask = prefixMatch != null
          ? trimmed.substring(prefixMatch.end).trim()
          : '';
    }

    CustomizationItem? matched;
    for (final s in enabledSkills) {
      final byName = s.name.trim().toLowerCase();
      final bySlug = SkillFrontmatter.sanitizeSlug(s.name);
      if (byName == targetSkillName || bySlug == targetSkillName) {
        matched = s;
        break;
      }
    }
    if (matched == null) return null;

    final raw = matched.content?.trim() ?? '';
    if (raw.isEmpty) return null;
    final parsed = SkillFrontmatter.parse(raw, fallbackName: matched.name);
    final instructions = parsed.body.isNotEmpty ? parsed.body : raw;
    final task = remainingTask.isNotEmpty
        ? remainingTask
        : 'Apply the `${parsed.name}` skill to the current task or workspace.';

    return '[Active Skill: ${parsed.name} (${matched.pathOrCommand})]\n'
        '$instructions\n\n'
        'User request: $task';
  }

  /// Builds an `<agents_instructions>` context block from enabled `AGENTS.md` & workspace rules.
  static String buildAgentsContextBlock(
    List<CustomizationItem> items, {
    int maxChars = 12000,
  }) {
    final relevant = items.where((i) {
      if (i.kind != CustomizationKind.rule || !i.enabled) return false;
      final body = i.content?.trim() ?? '';
      if (body.isEmpty) return false;
      if (isAgentsFile(i)) return true;
      return i.scope == 'Project';
    }).toList();
    if (relevant.isEmpty) return '';

    final buf = StringBuffer('<agents_instructions>\n');
    var remaining = maxChars;
    for (final item in relevant) {
      final text = _stripManagedMarker(item.content ?? '');
      if (text.isEmpty || remaining <= 64) continue;
      final chunk = text.length > remaining
          ? '${text.substring(0, remaining)}\n...[truncated]'
          : text;
      buf.writeln('## ${item.name} (${item.scope}: ${item.pathOrCommand})');
      buf.writeln(chunk);
      buf.writeln();
      remaining -= chunk.length;
    }
    buf.write('</agents_instructions>');
    final out = buf.toString().trim();
    return out == '<agents_instructions>\n</agents_instructions>' ? '' : out;
  }

  /// Builds complete system instructions (`GEMINI.md`, `AGENTS.md`, and `SKILL.md` catalog)
  /// for OpenAI-compatible `/v1` providers that do not natively read `.gemini` / `.agents`.
  static String buildOpenAiSystemCustomizations(
    List<CustomizationItem> items, {
    int maxChars = 14000,
  }) {
    final buf = StringBuffer();
    var remaining = maxChars;

    final rules = items
        .where((i) => i.kind == CustomizationKind.rule && i.enabled)
        .toList();
    for (final rule in rules) {
      final body = _stripManagedMarker(rule.content ?? '');
      if (body.isEmpty || remaining <= 128) continue;
      final chunk = body.length > remaining
          ? '${body.substring(0, remaining)}\n...[truncated]'
          : body;
      buf.writeln('### ${rule.name} (${rule.scope})');
      buf.writeln(chunk);
      buf.writeln();
      remaining -= chunk.length;
    }

    final skills = items
        .where((i) => i.kind == CustomizationKind.skill && i.enabled)
        .toList();
    if (skills.isNotEmpty && remaining > 128) {
      buf.writeln('### Available Skills (SKILL.md)');
      buf.writeln(
        'If a skill matches the user request, read its `SKILL.md` via `read_file` before proceeding:',
      );
      for (final s in skills) {
        final line = '- **${s.name}** (${s.scope}): ${s.description} — `${s.pathOrCommand}`';
        if (line.length > remaining) break;
        buf.writeln(line);
        remaining -= line.length;
      }
    }

    return buf.toString().trim();
  }
}
