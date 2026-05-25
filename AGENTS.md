# Codex Usage Meter Agent Instructions

This repository contains a Windows PowerShell + WPF tray-style widget for monitoring Codex usage limits.

## Project Context

- GitHub: https://github.com/sbabichev/codex_usage_meter
- Main app: `usage-widget.ps1`
- Launcher: `start-usage-widget.cmd`
- Tray/window icon: `assets/codex-usage-meter.ico`
- Icon generator: `tools/create-icon.ps1`
- User-facing docs: `README.md`
- Local state: `usage-widget.state.json` is ignored by git and should remain local.

## Current Behavior

- Reads Codex telemetry from `%USERPROFILE%\.codex\sessions\**\*.jsonl`.
- Uses only valid `rate_limits` events where `limit_id=codex` and both primary and secondary limits are populated.
- Treats `primary` as the current 5-hour session limit.
- Treats `secondary` as the weekly limit.
- Compares the latest usable rate-limit snapshot with the previous distinct snapshot to show last activity impact.
- Reads local `token_count` and `task_started` events to estimate recent turn, latest call, and last-3-minute token usage.
- Refreshes every 3 seconds.
- Shows stale warning only after 15 minutes without a fresh Codex rate-limit event.
- Ignores premium/null events.
- Runs as a tray-only UI and does not show in the taskbar.
- Double-clicking the panel hides the window.
- Double-clicking the tray icon shows the window.
- Tray menu contains `Show`, `Open Codex Usage Dashboard`, and `Exit`.

## UI Notes

- The UI is a single glassmorphic container.
- Wordmark is `Codex PLUS` without a badge.
- It has two blocks: `CURRENT SESSION` and `WEEKLY LIMIT`.
- The main usage bar changes color by `used_percent`:
  - `0-49`: lime
  - `50-74`: yellow-green
  - `75-89`: amber
  - `90+`: orange
- The lower time bar is segmented:
  - current session: 5 sections / 4 ticks
  - weekly limit: 7 sections / 6 ticks
- Time bars fill left-to-right by elapsed time:
  - filled = how much of the time window has passed
  - empty right side = time remaining
- Smart hints at the bottom analyze usage pace vs elapsed time and weekly pace.
- Last-activity line shows recent limit movement and local token estimates; its tooltip can contain fuller token details.

## Recent Baseline Commits

- `9932f86` Add smart usage hints
- `08b8e7e` Relax stale telemetry warning
- `3d6ddeb` Make time bars fill by elapsed time
- `018b9ec` Improve tray icon and rate limit freshness

## Working Conventions

- Keep changes small and focused.
- Preserve the tray-first behavior unless explicitly asked otherwise.
- Do not commit or track `usage-widget.state.json`.
- Prefer matching the existing PowerShell/WPF style in `usage-widget.ps1`.
- Before changing layout values, inspect the nearby margins, padding, and fixed widget dimensions.
- When changing UI spacing, verify that the fixed widget height still fits the content cleanly.
