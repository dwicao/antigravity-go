/// Antigravity Desktop & Mobile permission profiles:
/// - `requestReview`: Plan / Ask Only (read-only / always asks before edits or commands)
/// - `standard`: Standard (auto-read; confirms before file writes or shell commands)
/// - `turbo`: Auto-Dev (proceeds automatically except destructive commands blocked by SafetyGuard)
enum AntigravityPermissionPreset {
  requestReview(
    'request-review',
    'Plan / Ask Only',
    'Read-only exploration; always asks before commands & writes',
  ),
  standard(
    'default',
    'Standard',
    'Auto-read; confirms before file writes & shell commands',
  ),
  auto(
    'auto',
    'Auto',
    'Automatically evaluates safe commands & edits',
  ),
  turbo(
    'always-proceed',
    'Auto-Dev',
    'Runs continuously except destructive commands (rm -rf, mkfs, force-push)',
  );

  const AntigravityPermissionPreset(this.cliValue, this.label, this.description);

  final String cliValue;
  final String label;
  final String description;

  /// Canonical mobile-friendly profiles surfaced in quick switchers.
  static const List<AntigravityPermissionPreset> mobileProfiles = [
    AntigravityPermissionPreset.requestReview,
    AntigravityPermissionPreset.standard,
    AntigravityPermissionPreset.turbo,
  ];

  /// On unrooted Android there is no OS terminal sandbox (`auto` fails), so
  /// map `auto` to `turbo` when full proceed is desired or `standard` (`default`).
  AntigravityPermissionPreset get androidSafe =>
      this == AntigravityPermissionPreset.auto
          ? AntigravityPermissionPreset.turbo
          : this;

  static AntigravityPermissionPreset fromString(String? value) {
    return switch (value) {
      'request-review' || 'requestReview' || 'plan' || 'ask-only' =>
        AntigravityPermissionPreset.requestReview,
      'default' || 'standard' => AntigravityPermissionPreset.standard,
      'auto' => AntigravityPermissionPreset.auto,
      'always-proceed' || 'turbo' || 'auto-dev' =>
        AntigravityPermissionPreset.turbo,
      _ => AntigravityPermissionPreset.turbo,
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
