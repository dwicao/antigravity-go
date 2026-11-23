# Antigravity Go

**Google Antigravity Mobile Harness for Android** — run AI agents natively on your phone or drive your computer remotely, signed in with your Google Account.

Inspired by [dsh-Go](https://github.com/ccch1mneyyy/dsh-Go) and powered by the official [Antigravity CLI (`agy`)](https://antigravity.google/docs/cli/reference) and [Agent Client Protocol (ACP)](https://antigravity.google/docs/ide/extensions/acp).

![Antigravity Go running on Samsung DeX](docs/screenshots/dex-workspace.webp)

## Key Features

- **Google Account Sign-In**: Authenticate directly with your personal Google Account (Free, Google AI Pro, Google AI Ultra) via `agy acp --login` / OAuth, Gemini Enterprise (Google Cloud), or Gemini API Key.
- **On-Device Agent Harness (No Root / No Termux)**: Installs and verifies the official `agy` Android arm64 binary with SHA-512 inside app-private storage, managed by a foreground service (`AgyService`) with live logs and safe mode.
- **Usage Limits & Quotas Dashboard**:
  - **5-Hour Rolling Window** & **Weekly Rate Limit** progress bars and reset timers
  - **Gemini Model Limits**: Gemini 4 Argon, Gemini 4 Neon, Gemini 4 Carbon, Gemini 4 Hydrogen, Gemini 3.8 Flash
  - **Claude & GPT Limits**: Claude Opus 5.5 / Sonnet 5.5 / 4.6 (thinking) & GPT-OSS-120b
  - **AI Credits & Overages** toggle (`useG1Credits`) + local SQL/JSON token ledger (`input`, `output`, `thinking`, `cache_read`)
- **AI Agent Chat & Workflows**:
  - Streaming Markdown, syntax-highlighted code blocks, collapsible reasoning thoughts, tool call & diff cards
  - Model & reasoning effort picker (`Low`, `Medium`, `High`, `Extra`), Orchestrator support, and Execution Modes (`auto`, `default`, `accept-edits`, `plan`)
  - Slash commands (`/plan`, `/goal`, `/boost`, `/swarm`, `/teamwork`, `/compact`, `/usage`, `/credits`, `/model`, `/diff`, `/fork`, `/rewind`)
  - Interactive tool permission approvals, steer/queue while streaming, file/image attachments, and voice dictation
- **Remote Connections**:
  - **SSH Remote Hosts**: Connect to your PC/Mac/Linux workstation over SSH (`dartssh2`) to drive `agy` and remote workspaces from your phone
  - **Remote Control Web Portal**: One-tap access to `https://antigravity.google.com` inside the app
- **Phone Control (Accessibility + SafetyGate)**: Optional Android Accessibility Service + local Phone MCP bridge with strict sensitive-app protection and confirmation gates
- **Workspace Explorer & Built-in Terminal**: Browse project files, inspect diffs, and run `agy` TUI or shell commands in the embedded `xterm` terminal

## Build & Release

Release APKs are built and signed with the AOSP release/testkey in GitHub Actions (`.github/workflows/release-apk.yml`) and published to [GitHub Releases](https://github.com/dwicao/antigravity-go/releases).
