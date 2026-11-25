/// Agent execution mode matching `agy --mode` (`default`, `accept-edits`, `auto`, `plan`).
enum AgyExecutionMode {
  standard('default', 'Standard', 'Runs with your configured permission preset (no OS sandbox required)'),
  acceptEdits('accept-edits', 'Accept Edits', 'Auto-approves file edits, asks before commands'),
  plan('plan', 'Plan', 'Explores workspace and produces an implementation plan first'),
  auto('auto', 'Auto (Sandbox)', 'Uses desktop OS terminal sandbox (unsupported on unrooted Android)');

  const AgyExecutionMode(this.cliValue, this.label, this.description);

  final String cliValue;
  final String label;
  final String description;

  /// Returns an execution mode safe for unrooted Android (maps `auto` -> `default`).
  AgyExecutionMode get androidSafe =>
      this == AgyExecutionMode.auto ? AgyExecutionMode.standard : this;

  static AgyExecutionMode fromCli(String? value) {
    return switch (value?.toLowerCase().trim()) {
      'accept-edits' => AgyExecutionMode.acceptEdits,
      'plan' => AgyExecutionMode.plan,
      'auto' => AgyExecutionMode.auto,
      _ => AgyExecutionMode.standard,
    };
  }
}
