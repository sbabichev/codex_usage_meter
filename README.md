# Codex Usage Meter

A compact Windows 11 glass-style companion widget for tracking Codex subscription limits.

It reads the real `rate_limits` events that Codex writes locally and shows:

- current 5-hour session usage;
- weekly usage;
- optional MiniMax subscription interval and weekly limits from `mmx quota --output json`;
- last activity impact, combining the latest visible limit movement with local token usage;
- exact reset time;
- time remaining until reset;
- a green usage bar and a subtle time-remaining bar.

This is a small WPF desktop app styled like a widget. It is not a native Windows Widgets board extension.

## Screenshot

The UI is a frameless, fixed-size, Apple-like glass panel with a minimal `Codex PLUS` wordmark.

## Requirements

- Windows 11
- Windows PowerShell 5.1 or PowerShell with WPF support
- Codex installed and used at least once, so local session logs exist
- Optional: SSH access to a VPS where `mmx-cli` is installed and already authenticated

## Run

Double-click:

```text
start-usage-widget.cmd
```

Or run from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\usage-widget.ps1
```

## How It Works

Codex writes session events under:

```text
%USERPROFILE%\.codex\sessions\**\*.jsonl
```

The widget scans the newest session files, finds the latest `token_count` event with a `rate_limits` block, and uses:

- `primary` for the current 5-hour session;
- `secondary` for the weekly limit;
- `used_percent` for usage progress;
- `resets_at` and `window_minutes` for reset and time-remaining progress;
- `plan_type` for the wordmark tier.

It also compares the latest usable rate-limit snapshot with the previous distinct snapshot and reads local `token_count` / `task_started` events to estimate the most recent turn, latest model call, and last 3 minutes of token usage. The widget keeps this compact on-screen and exposes the fuller token summary in the last-activity tooltip. These token numbers are local estimates from Codex logs, not official billing records.

The widget refreshes every 3 seconds and ignores non-Codex or incomplete rate-limit events.

## MiniMax Limits

MiniMax quota fetching is configured through `usage-widget.config.json`, ignored `usage-widget.local.json`, or environment variables. Prefer `usage-widget.local.json` for machine-specific SSH aliases and secrets.

Example local config:

```json
{
  "minimax": {
    "enabled": true,
    "source": "ssh",
    "sshTarget": "contabo",
    "sshRemoteCommand": "/home/jarvis/.npm-global/bin/mmx quota --output json --non-interactive",
    "refreshSeconds": 300,
    "timeoutSeconds": 10
  }
}
```

The widget treats `current_interval_usage_count` and `current_weekly_usage_count` as used counts and calculates usage as `usage_count / total`.

## Controls

- Drag anywhere on the glass panel to move it.
- Double-click the panel to hide it to the tray.
- Use the tray icon menu for `Show`, `Open Codex Usage Dashboard`, and `Exit`.
- Double-click the tray icon to show the widget.

## Files

- `usage-widget.ps1` - WPF widget implementation.
- `start-usage-widget.cmd` - double-click launcher.
- `assets/codex-usage-meter.ico` - Lucide-inspired gauge icon for the tray/window.
- `tools/create-icon.ps1` - regenerates the icon.
- `usage-widget.config.json` - checked-in settings and MiniMax placeholders.
- `usage-widget.local.json` - optional local MiniMax settings, ignored by git.
- `usage-widget.state.json` - local window state, generated automatically and ignored by git.

## Privacy

By default, the app reads local Codex session JSONL files. If MiniMax is enabled, it also runs the configured HTTPS or SSH quota fetch.
