# Codex Usage Meter

A compact Windows 11 glass-style companion widget for tracking Codex subscription limits.

It reads the real `rate_limits` events that Codex writes locally and shows:

- current 5-hour session usage;
- weekly usage;
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

The widget refreshes every 15 seconds.

## Controls

- Drag anywhere on the glass panel to move it.
- Double-click the panel to minimize it to the taskbar.
- Use the tray icon menu for `Show` and `Exit`.
- Double-click the tray icon to show the widget.

## Files

- `usage-widget.ps1` - WPF widget implementation.
- `start-usage-widget.cmd` - double-click launcher.
- `assets/codex-usage-meter.ico` - Lucide-inspired gauge icon for the tray/window.
- `tools/create-icon.ps1` - regenerates the icon.
- `usage-widget.state.json` - local window state, generated automatically and ignored by git.

## Privacy

The app only reads local Codex session JSONL files. It does not send usage data anywhere.
