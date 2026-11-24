# Changelog

All notable changes to **Antigravity Go** are documented in this file.

## [1.0.24] - 2026-11-24

### Fixed
- **Chronological milestone cards:** Rendered `MilestoneStackCard` and markdown response segments in exact chronological order via `ChatMilestoneKind.text`, keeping follow-up milestones (including completed background task steps) positioned naturally below the preceding chat result text instead of pinned above it.
- **Pinned bottom streaming indicator:** Moved the live `[Antigravity (spinner) X tok/s]` indicator to the very bottom of the chat viewport right above the composer so active streaming speed and status stay visible without scrolling back up.
- **False 3-minute idle warning with active background tasks:** Deferred `stallWatchdog` and cleared stale idle warnings whenever running tools, active subagents, native `terminal` background processes, or CI watches are still running.

## [1.0.23] - 2026-11-24

### Added
- **Expanded Device Gateway MCP & Hardware Controls:** Added 8 new loopback MCP tools alongside screen inspection (`phone_device_info`, `phone_notify`, `phone_clipboard`, `phone_torch`, `phone_vibrate`, `phone_toast`, `phone_open_url`, and SafetyGuard-checked `phone_shizuku_exec` via `rish`), plus `TorchReceiver`, `DeviceGatewayHelper`, and quick-test controls inside **Phone Control & SafetyGate**.
- **Daemon-style Automation Triggers:** Added standard 5-field **cron expressions**, **File Watch**, **GitHub PR/Issue Watch**, **Battery Below %** triggers, and notification alerts on completion in **Automations**.
- **Runtime Shell Wrappers & Log Export:** Provisioned `torch`, `agy-notify`, `agy-fix-paths`, `xdg-open`, `open`, and `cs` helpers into `runtime/bin`, exported `TERM=xterm-256color`, `$PREFIX`, and `ANDROID_DATA=/data`, and added **Copy Logs** & **Save Logs** in **On-Device Antigravity Runtime**.
- **Workspace Layout Override & Haptic Feedback:** Added an instant **Auto / Desktop / Mobile** workspace layout toggle and reply-completion haptic feedback toggle in **Settings -> Appearance**.

## [1.0.22] - 2026-11-24

### Updated
- **Merged Gemini Models quota & catalog:** Updated `UsagePage`, `UsageOutputParser`, `UsageLedger`, and `AgyModelCatalog` for Antigravity's unified **Gemini Models** quota pool (`Neon`, `Carbon`, `Argon`, `Hydrogen`, `Orchestrator`, `3.8 Flash`) alongside **Claude and GPT models** (`Claude Opus 5.5`, `Sonnet 5.5`, `GPT-OSS 120B`), preserved clean tab-separated model display names, and surfaced the `Upgrade` link on the credits card.

### Fixed
- **Meaningful step summaries in chat milestones:** Cleaned noisy `file ../../../../../../...` paths in `MilestoneStackCard` & `FoldedToolsBar` via `ChatTurnHelpers.formatDisplayPath` so file reads, searches, and edits display concise repo-relative filenames with optional line ranges and accurate step summary headers (`Read N files`, `Completed X steps · ...`).
- **Composer vertical alignment:** Shrunk action `IconButton` tap targets to match the 36×36 Attach button and centered the single-line `TextField` vertically in `ChatComposerBar`.

## [1.0.21] - 2026-11-24

### Fixed
- **Follow button stability:** Prevented the chat **Follow / Following** toggle from unexpectedly disabling when scrolling horizontal code/diff views inside messages, when content layout shrinks, or when a new chat transitions to its created session ID. Follow now pauses only when intentionally scrolling up on the main vertical message list away from the bottom.
- **Accurate update version check:** Replaced the stale hardcoded `'1.0.14'` app version check with dynamic installed-version detection (`PackageManager` + bundled `assets/version.json`) and remote `version.json` comparison so up-to-date installs no longer show false pending updates.

### Added
- **`version.json` & in-app release notes:** Added synchronized `version.json` metadata (bundled + release asset), structured `CHANGELOG.md`, and automated GitHub Release notes rendered directly inside the in-app **UpdateSheet** (`Current vs Latest`).
- **Faster release builds:** Added `shell-tools` workflow artifact reuse (`retention-days: 90`), parallelized `x86_64` / `arm64-v8a` native builds on cold runs, and enabled Gradle parallel & build cache in `gradle.properties`.

## [1.0.20] - 2026-11-24

### Added
- **Live subagent UI feedback:** Added `SubagentsActivityBanner` above the chat composer with live elapsed timer, active/spawning status chips, Stop/Dismiss controls, background task tracking (`N bg`), inline `_SpawnedSubagentsStrip` badges on messages, and subagent verbs/targets in `MilestoneStackCard`.

## [1.0.19] - 2026-11-24

### Fixed
- **Android 13 and older compatibility (`SIGSYS` 159):** Wrapped `faccessat` in bundled static `busybox`, `bash`, and `pty_host` via `-Wl,--wrap=faccessat` (`libseccomp_compat.a`) so musl `SYS_faccessat2` never triggers seccomp kills on devices like Samsung S20 5G, plus improved shell health probes and stale ACP worker invalidation.

## [1.0.18] - 2026-11-24

### Added
- Compact **Copy** button below completed assistant responses.

### Fixed
- Accurate JSON `/usage` quota parsing (`left` vs `used`), glog noise filtering, and `PermissionsNotifier` disposal guards.

## [1.0.17] - 2026-11-23

### Added
- Support for custom OpenAI-compatible `/v1` models, custom provider persistence serialization fixes, and reliability hardening.

## [1.0.16] - 2026-11-23

### Added
- Phone MCP server, interactive PTY terminal, SSH ACP & host key reset, persistent file store, concurrent sessions, native automations, and queued prompt safeguards.

## [1.0.15] - 2026-11-23

### Fixed
- BusyBox seccomp `SIGSYS` fixes, 1M context budget counter, security hardening, and UI/UX parity updates.
