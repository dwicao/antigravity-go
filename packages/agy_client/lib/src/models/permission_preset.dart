/// Antigravity Desktop permission presets matching `antigravity.google/docs/permissions`.
enum AntigravityPermissionPreset {
  requestReview(
    'request-review',
    'Request Review',
    'Always asks before commands & file writes',
  ),
  standard(
    'default',
    'Default',
    'Allowed in sandbox; asks outside sandbox',
  ),
  auto(
    'auto',
    'Auto',
    'Automatically evaluates safe commands & edits',
  ),
  turbo(
    'always-proceed',
    'Turbo',
    'Always proceed without prompting (full access)',
  );

  const AntigravityPermissionPreset(this.cliValue, this.label, this.description);

  final String cliValue;
  final String label;
  final String description;

  static AntigravityPermissionPreset fromString(String? value) {
    return switch (value) {
      'request-review' || 'requestReview' => AntigravityPermissionPreset.requestReview,
      'default' || 'standard' => AntigravityPermissionPreset.standard,
      'always-proceed' || 'turbo' => AntigravityPermissionPreset.turbo,
      _ => AntigravityPermissionPreset.auto,
    };
  }
}

/// Interface layout matching Antigravity App v2.30+ (`Software Engineering` vs `Knowledge Work`).
enum AntigravityLayoutMode {
  softwareEngineering('Software Engineering'),
  knowledgeWork('Knowledge Work');

  const AntigravityLayoutMode(this.label);

  final String label;
}
