/// Agent execution mode matching `agy --mode` (`default`, `accept-edits`, `auto`, `plan`).
enum AgyExecutionMode {
  auto('auto', 'Auto', 'Edits workspace files & runs safe commands automatically'),
  standard('default', 'Default', 'Asks permission before editing files or running commands'),
  acceptEdits('accept-edits', 'Accept Edits', 'Auto-approves file edits, asks before commands'),
  plan('plan', 'Plan', 'Explores codebase and produces an implementation plan first');

  const AgyExecutionMode(this.cliValue, this.label, this.description);

  final String cliValue;
  final String label;
  final String description;

  static AgyExecutionMode fromCli(String? value) {
    return switch (value?.toLowerCase().trim()) {
      'default' || 'request-review' => AgyExecutionMode.standard,
      'accept-edits' => AgyExecutionMode.acceptEdits,
      'plan' => AgyExecutionMode.plan,
      _ => AgyExecutionMode.auto,
    };
  }
}
