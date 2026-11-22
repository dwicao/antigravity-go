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
  final String scope; // 'Global' or 'Project'
  final String pathOrCommand;
  final String description;
  final bool enabled;
  final String? content;
}
