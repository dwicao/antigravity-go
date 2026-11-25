# Changelog

All notable changes to **Antigravity Go** are documented in this file.

## [1.0.35] - 2026-11-26

### Added
- **GitHub-Style Diff Viewer:** Added `GitHubDiffViewer` & `GitHubDiffPage` (`DiffReviewView` default mode + `ChangeCard` launcher + Command Palette) with changed-files tree/jump sheet, search & `All / Modified / Added / Deleted` filters, 5-block GitHub diffstat bars, collapsible file cards with **Viewed** checkboxes, dual-gutter line numbers, and **Unified / Split** (side-by-side) diff modes.
- **Full Working-Tree & Shadow Git Diffs:** Upgraded `WorkspaceOps.gitDiff` to combine staged/unstaged diffs, synthesize unified diffs for untracked text files, and diff non-git workspaces against their Shadow Git checkpoints.

## [1.0.34] - 2026-11-25

### Added
- **Actionable Approval Notifications:** Background tool permission prompts (`session/request_permission`) now post high-priority notifications with **Approve** and **Deny** action buttons handled directly by `ApprovalNotificationReceiver` & `ApprovalNotificationHelper`.
- **Android Share Sheet (`ACTION_SEND` / `ACTION_SEND_MULTIPLE`):** Share error logs, code snippets, images, or files from any Android app directly into the Antigravity Go chat composer (`MainActivity` + `SharedInboxNotifier`).
- **Swipe Per-Hunk Diff Review:** Added `DiffHunkParser` / `DiffHunkReverter` and swipe-to-accept / swipe-to-revert (`Dismissible` + tap controls) hunk cards inside `DiffReviewView`.
- **Extended Shizuku Developer Tools:** Added `phone_shizuku_logcat`, `phone_shizuku_install`, and `phone_shizuku_ui_dump` MCP tools and quick buttons in `PhoneControlPage`.
- **Workspace-Aware Voice & Audio Summaries:** Added `VoicePromptNormalizer` to map spoken coding phrases & workspace filenames and clean markdown replies for Android `TextToSpeech` playback (**Listen** button in `MessageBubble`).
- **Shadow Git Checkpoints & 1-Tap Undo Turn:** `WorkspaceOps.createCheckpoint` / `restoreCheckpoint` now fall back to an isolated Shadow Git repository (`shadow_git/`) when a workspace has no `.git` folder, paired with an **Undo Last Turn** button in `ChatScreen`.
- **Smart Context Repo Map, Lifecycle Hooks & Auto-Compact:** Added `RepoMapBuilder` (`<repo_map>` multi-language symbol indexer), configurable `PreToolUse` / `PostToolUse` `LifecycleHooksManager` (blocking `.env`/keystores/personal media and running post-edit formatters), and automatic post-turn `/compact` at >=80% context usage.
- **In-App WebView Preview + Mini Console:** Added `WebPreviewPage` side-panel tab with injected `AgyConsole` (`console.log`/`warn`/`error`, `window.onerror`) capture and 1-tap **Fix errors** prompt dispatch.
- **Hybrid Offline Fallback, Cost Meter, HTTP/SSE MCP & Eco Policy:** Added local LLM offline fallback in `CustomProvidersNotifier`, `ModelPricingCatalog` USD cost estimates in `MessageMetricsFooter` & `UsagePage`, `McpHttpClient` HTTP/SSE handshake & tool discovery in `CustomizationsPage`, `Plan / Ask Only · Standard · Auto-Dev` profile clarity, and `DevicePolicyNotifier` battery (<15%) & cellular eco policy warnings.

## [1.0.33] - 2026-11-25

### Fixed
- **Anchored Mobile Slash (`/`) & `@` Mention Overlays:** Moved `/` command and `@` file autocomplete popups out of the main `Column` into a `Positioned` overlay inside the chat `Stack` (`ChatScreen`), preventing the composer bar from jumping halfway up the screen with blank space below when typing `/` on mobile keyboards.

### Improved
- **Chat UI & UX Polish:** Refined `ChatComposerBar` and `ChatPickerPill` borders/radii/chevrons, polished `ChatEmptyHero` icon badge and suggestion chips, styled user message bubbles and header dividers, formatted streaming token counts `>= 1,000,000` cleanly as `M tok` (e.g. `106.8M tok`), and hid floating turn-navigation buttons while `/` or `@` menus are open.
- **Long Chat History & Streaming Performance:** Windowed initial chat rendering to the latest 40 messages with **Load earlier / Show all** controls, wrapped message rows in `RepaintBoundary`, collapsed `MilestoneStackCard` details on older messages (`globalIdx < totalCount - 4`), memoized `_StreamingAgentStatusBar` stats across 1-second timer ticks, skipped `SelectionArea` wrapping while streaming markdown, and coalesced `ChatNotifier` delta UI emits to 33ms batches.

## [1.0.32] - 2026-11-25

### Added
- **`AGENTS.md` & `SKILL.md` Full Support:** Added discovery across Global, Project, and Built-in directories (`~/.agents/`, `~/.gemini/`, `.agents/skills/`, `.gemini/skills/`, `.claude/skills/`), YAML frontmatter parsing (`name`, `description`), in-app creation & editing in `CustomizationsPage`, `/` slash command autocomplete & expansion in chat, `<agents_instructions>` context injection for new `agy`/SSH sessions, and system prompt integration for `/v1` OpenAI-compatible models.

## [1.0.31] - 2026-11-25

### Added
- **Inline Image Attachment Previews & Sent Chat Images:** Added `AttachmentPreviewStrip`, `AttachmentImageThumbnail`, and full-screen zoom preview (`showAttachmentImagePreviewDialog`) above the chat text input, multi-image gallery picking (`pickMultiImage`), empty-text image sending, and inline image rendering inside sent user chat bubbles (`MessageBubble`).

### Docs
- **Complete Feature List & Mobile Screenshot:** Expanded `README.md` with all implemented capabilities through `v1.0.31` and added a mobile screenshot (`docs/screenshots/mobile-chat.jpg`) alongside Samsung DeX.

## [1.0.30] - 2026-11-25

### Added
- **Multi-Account Vault & Multi-File Credential Import:** Added `MultiAccountVault` (`runtime/accounts/` with owner-only `0600`/`0700` permissions) and updated `GoogleLoginSheet` & `SessionsDrawer` so users can import one or multiple `.agycreds.json` backups, automatically preserve any already signed-in account, switch accounts in one tap without re-running Google OAuth, export individual saved accounts, or remove accounts cleanly.

### Improved
- **Automatic Local Runtime Startup:** Automatically starts `AgyService` when opening or resuming the app whenever the local `agy` runtime is installed and stopped (while respecting explicit manual stops), removing the `"Local runtime is stopped"` startup warning.

## [1.0.29] - 2026-11-25

### Added
- **Encrypted Credential Transfer (Export & Import):** Added `CredentialTransferHelper` (`AES-256-GCM` + `PBKDF2WithHmacSHA256`, 120,000 iterations) in Kotlin alongside `exportCredentials` / `importCredentials` bridges and UI controls inside `GoogleLoginSheet` (`Transfer Credentials`). Signed-in users can export all `.gemini` OAuth tokens (`antigravity-oauth-token`, `acp-auth-state.json`, `settings.json`, `jetski_state.pbtxt`, `antigravity-go-auth.json`), optional Gemini API keys, and account metadata into a passphrase-protected `.agycreds.json` file (Save to Downloads, Share, or Copy), and import it on any other Android phone via File Picker or paste to sign in immediately without repeating Google OAuth.

## [1.0.28] - 2026-11-25

### Improved
- **Compact & Organized Left Sidebar:** Redesigned `SessionsDrawer` (`home_shell.dart` & `sessions_drawer.dart`) so chat titles receive nearly full sidebar width (`_CompactSessionRow` with `14px` status icon, `28px` menu button, and metadata/triage badges moved cleanly to line 2), consolidated Project & Execution Host dropdowns into slim side-by-side `_CompactPickerPill` controls, streamlined bottom navigation menus (`Automations`, `Customizations`, `Usage Limits`, `Settings`) with a compact single-row account footer, and freed ~215px+ of vertical space so conversations are clearly visible on both phones and Samsung DeX.

## [1.0.27] - 2026-11-24

### Improved
- **Automatic Bottom-Follow Scrolling:** Removed the redundant bottom-right `Follow` / `Following` pill in `ChatScreen`. Being at the bottom of a conversation now auto-follows incoming messages by default; scrolling upward pauses auto-follow and shows only the **Jump to latest** arrow button (`Icons.arrow_downward_rounded`), and scrolling back to the bottom (or tapping the arrow) seamlessly resumes auto-follow.

### Fixed
- **Suppress Misleading Startup Sign-In Prompt When Logged In:** Cached signed-in auth state cleanly via `SharedPreferences` (`agy_auth_profile_json`) and deferred `ChatOnboardingBanner` until initial auth/runtime hydration completes (`auth.initialized` / `runtime.initialized`) so signed-in users no longer see a false `"Google Sign-In"` prompt on launch.

## [1.0.26] - 2026-11-24

### Added
- **Native Crash Safety & URL SSRF Guard:** Added `CrashRecorder` to capture, redact (`LogRedactor`), and expose recent uncaught JVM crashes inside Diagnostics, plus `UrlSafetyGuard` in `DeviceGatewayHelper.openUrl` to block non-HTTP schemes and cloud/link-local metadata endpoints (`169.254.*`, `metadata.google.internal`, `100.100.100.200`).
- **Context Ring, Turn Stopwatch & Session Triage:** Added a circular context-usage ring (`% ctx`) and **Inference Speed Tier (`Regular / Fast / Ultrafast`)** selector in the composer, upgraded the bottom streaming bar with a live `mm:ss` stopwatch + session stats (`rd · tools · tok · % hit`), added cache-hit % pills in `MessageMetricsFooter`, and added running/subagent/archived triage badges in `SessionsDrawer`.
- **Archive & Navigation Upgrade:** Added `archived` session filtering (`Archived (N)` chip + `Archive` / `Restore` actions), docked **Previous / Next User Turn (`↑` / `↓`)** navigation buttons, **Runtime Reconnect Banner**, and **Select & Copy Messages** multi-select export sheet in `ChatScreen`.
- **Code Save, Segmented Quota Gauges, Localization & What's New:** Added **Save** to workspace/Downloads on markdown code blocks (`_AgyCodeBlock`), replaced plain linear usage bars with 10-segment `_SegmentedQuotaBar` gauges, wired live in-app locale switching (`English`, `Bahasa Indonesia`, `中文`, `Español`), and added an in-app **What's New** dialog in Settings.

## [1.0.25] - 2026-11-24

### Added
- **Android OS Integrations (from DSH Go):** Added the **New Chat Quick Settings Tile** (`NewChatTileService`), Android Launcher **App Shortcuts** (`New Chat`, `Terminal`, `Phone Control`, `Usage Limits`), Android 12+ **Follow Wallpaper Dynamic Color**, and `agy/performance` **120Hz+ Display Refresh Rate** control (`Auto` / `Max` / `System`) with **Reduce Motion** & **Reduce Blur** switches.
- **Sessions Folders, Pinning, Full-Text Search, Replay & Export:** Added pinning and folder tags on `AgySessionSummary` and `SessionsDrawer`, cross-session transcript search (`SessionSearchPage`), interactive step-by-step **Conversation Replay**, Markdown/JSON export, styled **Reply Share Cards** (with PNG download), and **Quote in Reply** directly from message bubbles.
- **Phone Control Self-Check, Action Log & Per-App Rules:** Persisted phone control action logs and custom per-package `SafetyGate` rules (`allow` / `confirm` / `block`) alongside a 6-point **Phone Control Self-Check** card.
- **Background Alerts, Battery Keep-Alive Guide, Redacted Diagnostics & Searchable Settings:** Added background notifications for finished replies and tool approvals, an **OEM Background Keep-Alive Guide** (`BackgroundGuidePage`), redacted Markdown **Diagnostics Bundle** export (`DiagnosticsPage`), and live settings search.

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
