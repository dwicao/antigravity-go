import 'package:agy_client/agy_client.dart';
import 'package:test/test.dart';

void main() {
  test('SkillFrontmatter parses YAML frontmatter and scaffolds valid SKILL.md', () {
    const raw = '''---
name: release-check
description: "Verify release checksums and changelog"
---

# Release Check
Run tests first.
''';
    final parsed = SkillFrontmatter.parse(raw, fallbackName: 'fallback');
    expect(parsed.name, 'release-check');
    expect(parsed.description, 'Verify release checksums and changelog');
    expect(parsed.body, contains('# Release Check'));
    expect(parsed.body, isNot(contains('---')));

    final scaffolded = SkillFrontmatter.scaffold(
      name: 'My Cool Skill!',
      description: 'Checks formatting',
    );
    final reparsed =
        SkillFrontmatter.parse(scaffolded, fallbackName: 'fallback');
    expect(reparsed.name, 'my-cool-skill');
    expect(reparsed.description, 'Checks formatting');
  });

  test('AgentCustomizationHelper resolves skill commands, AGENTS.md context, and OpenAI system prompt', () {
    final items = [
      const CustomizationItem(
        kind: CustomizationKind.rule,
        name: 'Global Rules (GEMINI.md)',
        scope: 'Global',
        pathOrCommand: '/home/.gemini/GEMINI.md',
        content: '<!-- antigravity-go:managed -->\nAndroid runtime rule.',
      ),
      const CustomizationItem(
        kind: CustomizationKind.rule,
        name: 'Project Agents (AGENTS.md)',
        scope: 'Project',
        pathOrCommand: '/proj/AGENTS.md',
        content: 'Always run dart test after edits.',
      ),
      const CustomizationItem(
        kind: CustomizationKind.skill,
        name: 'code-review',
        scope: 'Project',
        pathOrCommand: '/proj/.agents/skills/code-review/SKILL.md',
        description: 'Review PR diffs carefully',
        content: '''---
name: code-review
description: Review PR diffs carefully
---
Check null safety and error handling.
''',
      ),
    ];

    final invoked = AgentCustomizationHelper.resolveInvokedSkillPrompt(
      '/code-review check auth.dart',
      items,
    );
    expect(invoked, isNotNull);
    expect(invoked, contains('[Active Skill: code-review'));
    expect(invoked, contains('Check null safety and error handling.'));
    expect(invoked, contains('User request: check auth.dart'));

    final explicitSkill = AgentCustomizationHelper.resolveInvokedSkillPrompt(
      '/skill code-review',
      items,
    );
    expect(explicitSkill, contains('Check null safety and error handling.'));

    final agentsCtx = AgentCustomizationHelper.buildAgentsContextBlock(items);
    expect(agentsCtx, contains('<agents_instructions>'));
    expect(agentsCtx, contains('Always run dart test after edits.'));
    expect(agentsCtx, isNot(contains('Android runtime rule.')));

    final openAiSys =
        AgentCustomizationHelper.buildOpenAiSystemCustomizations(items);
    expect(openAiSys, contains('Android runtime rule.'));
    expect(openAiSys, isNot(contains('antigravity-go:managed')));
    expect(openAiSys, contains('Always run dart test after edits.'));
    expect(openAiSys, contains('Available Skills (SKILL.md)'));
    expect(openAiSys, contains('**code-review**'));
  });
}
