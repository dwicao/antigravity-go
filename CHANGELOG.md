# Changelog

All notable changes to **Antigravity Go** are documented in this file.

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
