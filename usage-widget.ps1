Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("NativeWindowTools" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindowTools {
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

    public const UInt32 SWP_NOSIZE = 0x0001;
    public const UInt32 SWP_NOMOVE = 0x0002;
    public const UInt32 SWP_NOACTIVATE = 0x0010;
    public const UInt32 SWP_SHOWWINDOW = 0x0040;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        UInt32 uFlags);
}
"@
}

$ErrorActionPreference = "Continue"

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StatePath = Join-Path $script:AppDir "usage-widget.state.json"
$script:ConfigPath = Join-Path $script:AppDir "usage-widget.config.json"
$script:LocalConfigPath = Join-Path $script:AppDir "usage-widget.local.json"
$script:LogPath = Join-Path $script:AppDir "usage-widget.log"
$script:CodexSessionsDir = Join-Path $env:USERPROFILE ".codex\sessions"
$script:IconPath = Join-Path $script:AppDir "assets\codex-usage-meter.ico"
$script:CodexUsageDashboardUrl = "https://chatgpt.com/codex/settings/usage"
$script:WidgetWidth = 360
$script:WidgetHeight = 450
$script:CompactSingleWidth = 300
$script:CompactDoubleWidth = 570
$script:CompactHeight = 62
$script:StaleAfterSeconds = 900
$script:MinimaxDefaultRefreshSeconds = 300
$script:MinimaxTokenPlanUrl = "https://api.minimax.io/v1/token_plan/remains"
$script:MinimaxRemoteState = @{
    LastFetch = $null
    Usage = $null
    Error = $null
}
$script:CodexEnabled = $true
$script:MinimaxEnabled = $true
$script:CompactMode = $false
$script:TopmostEnabled = $true
$script:UsageSnapshot = $null
$script:StartupRefreshTimer = $null
$script:CompactTopmostTimer = $null
$script:FullWidgetHeight = $script:WidgetHeight
$script:UsageFloorState = @{
    WindowKey = ""
    PrimaryUsed = $null
    SecondaryUsed = $null
}
$script:MinimaxFloorState = @{
    WindowKey = ""
    PrimaryUsed = $null
    SecondaryUsed = $null
}

function Get-Brush($hex) {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function Get-Color($hex) {
    return [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function Get-LimitAccent($usedPercent) {
    $used = [Math]::Max([double]0, [Math]::Min([double]100, [double]$usedPercent))
    if ($used -ge 90) {
        return "#FF8A3D"
    }

    if ($used -ge 75) {
        return "#FFC857"
    }

    if ($used -ge 50) {
        return "#D7F85A"
    }

    return "#A6FF4F"
}

function Set-LimitAccent($row, $usedPercent, $enabled) {
    $accent = if ($enabled) { Get-LimitAccent $usedPercent } else { "#6F7D85" }
    $row.fill.Background = Get-Brush $accent
    $row.value.Foreground = Get-Brush $accent
    if ($row.fill.Effect) {
        $row.fill.Effect.Color = Get-Color $accent
        $row.fill.Effect.Opacity = if ($enabled) { 0.42 } else { 0.12 }
    }
}

function New-TextBlock($text, $fontSize, $weight, $color) {
    $block = New-Object System.Windows.Controls.TextBlock
    $block.Text = $text
    $block.FontSize = $fontSize
    $block.FontWeight = $weight
    $block.Foreground = Get-Brush $color
    $block.FontFamily = "Segoe UI Variable Text, Segoe UI"
    $block.TextTrimming = "CharacterEllipsis"
    return $block
}

function New-Hairline($topMargin, $bottomMargin) {
    $line = New-Object System.Windows.Controls.Border
    $line.Height = 1
    $line.Margin = "0,$topMargin,0,$bottomMargin"
    $line.Background = Get-Brush "#CAD4D9"
    $line.Opacity = 0.11
    return $line
}

function Write-WidgetLog($message) {
    try {
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        [System.IO.File]::AppendAllText($script:LogPath, "[$stamp] $message`r`n", [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Get-FileTailLines($path, $maxBytes) {
    try {
        $stream = [System.IO.File]::Open(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        try {
            $length = $stream.Length
            $bytesToRead = [Math]::Min([int64]$maxBytes, $length)
            $offset = $length - $bytesToRead
            $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null

            $buffer = New-Object byte[] ([int]$bytesToRead)
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                return @()
            }

            $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            if ($offset -gt 0) {
                $firstNewline = $text.IndexOf("`n")
                if ($firstNewline -ge 0 -and $firstNewline + 1 -lt $text.Length) {
                    $text = $text.Substring($firstNewline + 1)
                }
            }

            $lineArray = $text.Split([char]10)
            return @($lineArray | Where-Object { $_ })
        } finally {
            $stream.Dispose()
        }
    } catch {
        return @()
    }
}

function Test-IsInsideButton($source) {
    $current = $source
    while ($null -ne $current) {
        if ($current -is [System.Windows.Controls.Button]) {
            return $true
        }

        try {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        } catch {
            return $false
        }
    }

    return $false
}

function Read-State {
    $default = [pscustomobject]@{
        left = 120
        top = 90
        topmost = $true
        opacity = 1.0
        refreshSeconds = 3
        compactMode = $false
        usageSnapshot = $null
        usageFloor = $null
        providers = [ordered]@{
            codex = $true
            minimax = $true
        }
    }

    if (-not (Test-Path $script:StatePath)) {
        return $default
    }

    try {
        $raw = [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8)
        $state = $raw | ConvertFrom-Json
        if ($null -eq $state.left -or $null -eq $state.top) {
            return $default
        }

        return $state
    } catch {
        return $default
    }
}

function Get-ObjectValue($object, $name, $fallback = $null) {
    if ($null -eq $object) {
        return $fallback
    }

    $property = $object.PSObject.Properties[$name]
    if ($null -eq $property) {
        return $fallback
    }

    return $property.Value
}

function Set-WindowTopmost($window) {
    if ($null -eq $window) {
        return
    }

    $isTopmost = ($script:CompactMode -or $script:TopmostEnabled)
    $window.Topmost = $isTopmost

    try {
        $handle = ([System.Windows.Interop.WindowInteropHelper]::new($window)).Handle
        if ($handle -ne [IntPtr]::Zero) {
            $insertAfter = if ($isTopmost) { [NativeWindowTools]::HWND_TOPMOST } else { [NativeWindowTools]::HWND_NOTOPMOST }
            [NativeWindowTools]::SetWindowPos(
                $handle,
                $insertAfter,
                0,
                0,
                0,
                0,
                [NativeWindowTools]::SWP_NOMOVE -bor [NativeWindowTools]::SWP_NOSIZE -bor [NativeWindowTools]::SWP_NOACTIVATE -bor [NativeWindowTools]::SWP_SHOWWINDOW
            ) | Out-Null
        }
    } catch {
    }
}

function Sync-CompactTopmostTimer($window) {
    if ($script:CompactMode) {
        if ($null -eq $script:CompactTopmostTimer) {
            $script:CompactTopmostTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:CompactTopmostTimer.Interval = [TimeSpan]::FromMilliseconds(700)
            $script:CompactTopmostTimer.Tag = $window
            $script:CompactTopmostTimer.Add_Tick({
                param($sender)
                if (-not $script:CompactMode) {
                    $sender.Stop()
                    $script:CompactTopmostTimer = $null
                    return
                }

                Set-WindowTopmost $sender.Tag
            })
        } else {
            $script:CompactTopmostTimer.Tag = $window
        }

        if (-not $script:CompactTopmostTimer.IsEnabled) {
            $script:CompactTopmostTimer.Start()
        }
        Set-WindowTopmost $window
        return
    }

    if ($null -ne $script:CompactTopmostTimer) {
        $script:CompactTopmostTimer.Stop()
        $script:CompactTopmostTimer = $null
    }

    Set-WindowTopmost $window
}

function Read-Config {
    $config = [pscustomobject]@{}

    if (Test-Path $script:ConfigPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
            $config = $raw | ConvertFrom-Json
        } catch {
            $config = [pscustomobject]@{}
        }
    }

    if (Test-Path $script:LocalConfigPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:LocalConfigPath, [System.Text.Encoding]::UTF8)
            $localConfig = $raw | ConvertFrom-Json
            foreach ($property in $localConfig.PSObject.Properties) {
                if ($property.Name -eq "minimax" -and (Get-ObjectValue $config "minimax" $null)) {
                    $miniMax = Get-ObjectValue $config "minimax" $null
                    foreach ($miniMaxProperty in $property.Value.PSObject.Properties) {
                        $miniMax | Add-Member -MemberType NoteProperty -Name $miniMaxProperty.Name -Value $miniMaxProperty.Value -Force
                    }
                } else {
                    $config | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
                }
            }
        } catch {
        }
    }

    return $config
}

function Build-ProviderContextMenu($window, $controls) {
    $menu = New-Object System.Windows.Controls.ContextMenu

    $codexItem = New-Object System.Windows.Controls.MenuItem
    $codexItem.Header = "Show Codex"
    $codexItem.IsCheckable = $true
    $codexItem.IsChecked = $script:CodexEnabled
    $codexItem.Add_Click({
        if ($script:CodexEnabled -and -not $script:MinimaxEnabled) {
            return
        }
        $script:CodexEnabled = -not $script:CodexEnabled
        Sync-ProviderVisibility $controls
        Sync-ProviderState
    })

    $minimaxItem = New-Object System.Windows.Controls.MenuItem
    $minimaxItem.Header = "Show MiniMax"
    $minimaxItem.IsCheckable = $true
    $minimaxItem.IsChecked = $script:MinimaxEnabled
    $minimaxItem.Add_Click({
        if ($script:MinimaxEnabled -and -not $script:CodexEnabled) {
            return
        }
        $script:MinimaxEnabled = -not $script:MinimaxEnabled
        Sync-ProviderVisibility $controls
        Sync-ProviderState
    })

    $separator = New-Object System.Windows.Controls.Separator

    $topmostItem = New-Object System.Windows.Controls.MenuItem
    $topmostItem.Header = "Always on Top"
    $topmostItem.IsCheckable = $true
    $topmostItem.IsChecked = ($script:CompactMode -or $script:TopmostEnabled)
    $topmostItem.IsEnabled = -not $script:CompactMode
    $topmostItem.Add_Click({
        $script:TopmostEnabled = -not $script:TopmostEnabled
        Set-WindowTopmost $window
        Sync-ProviderState
    })

    $exitItem = New-Object System.Windows.Controls.MenuItem
    $exitItem.Header = "Exit"
    $exitItem.Add_Click({
        $window.Close()
    })

    $menu.Items.Add($codexItem) | Out-Null
    $menu.Items.Add($minimaxItem) | Out-Null
    $menu.Items.Add($separator) | Out-Null
    $menu.Items.Add($topmostItem) | Out-Null
    $menu.Items.Add($exitItem) | Out-Null

    return $menu
}

function Sync-ProviderVisibility($controls) {
    $codexSection = $controls.CodexSection
    $minimaxSection = $controls.MinimaxSection
    $compactCodex = $controls.CompactCodex
    $compactMinimax = $controls.CompactMinimax

    if (-not $script:CodexEnabled -and -not $script:MinimaxEnabled) {
        $script:CodexEnabled = $true
    }

    if ($script:CodexEnabled) {
        $codexSection.Visibility = "Visible"
        $compactCodex.panel.Visibility = "Visible"
    } else {
        $codexSection.Visibility = "Collapsed"
        $compactCodex.panel.Visibility = "Collapsed"
    }

    if ($script:MinimaxEnabled) {
        $minimaxSection.Visibility = "Visible"
        $compactMinimax.panel.Visibility = "Visible"
    } else {
        $minimaxSection.Visibility = "Collapsed"
        $compactMinimax.panel.Visibility = "Collapsed"
    }

    if ($script:CodexEnabled -and $script:MinimaxEnabled) {
        $controls.CompactContent.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $controls.CompactContent.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(8)
        $controls.CompactContent.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        [System.Windows.Controls.Grid]::SetColumn($compactCodex.panel, 0)
        [System.Windows.Controls.Grid]::SetColumn($compactMinimax.panel, 2)
    } else {
        $controls.CompactContent.ColumnDefinitions[0].Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        $controls.CompactContent.ColumnDefinitions[1].Width = [System.Windows.GridLength]::new(0)
        $controls.CompactContent.ColumnDefinitions[2].Width = [System.Windows.GridLength]::new(0)
        if ($script:CodexEnabled) {
            [System.Windows.Controls.Grid]::SetColumn($compactCodex.panel, 0)
        } else {
            [System.Windows.Controls.Grid]::SetColumn($compactMinimax.panel, 0)
        }
    }

    Set-WidgetMode $controls.Window $controls $script:CompactMode $false
}

function Sync-ProviderState {
    $state = Read-State
    $state.providers.codex = $script:CodexEnabled
    $state.providers.minimax = $script:MinimaxEnabled
    $state | Add-Member -MemberType NoteProperty -Name compactMode -Value $script:CompactMode -Force
    $state | Add-Member -MemberType NoteProperty -Name topmost -Value $script:TopmostEnabled -Force

    $json = $state | ConvertTo-Json -Depth 8
    try {
        [System.IO.File]::WriteAllText($script:StatePath, $json, [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Save-State($window) {
    try {
        $state = [ordered]@{
            left = [Math]::Round($window.Left)
            top = [Math]::Round($window.Top)
            topmost = [bool]$script:TopmostEnabled
            opacity = 1.0
            refreshSeconds = 3
            compactMode = $script:CompactMode
            usageSnapshot = $script:UsageSnapshot
            usageFloor = [ordered]@{
                windowKey = if ($script:UsageFloorState.WindowKey) { [string]$script:UsageFloorState.WindowKey } else { "" }
                primaryUsed = if ($null -ne $script:UsageFloorState.PrimaryUsed) { [double]$script:UsageFloorState.PrimaryUsed } else { $null }
                secondaryUsed = if ($null -ne $script:UsageFloorState.SecondaryUsed) { [double]$script:UsageFloorState.SecondaryUsed } else { $null }
            }
            providers = [ordered]@{
                codex = $script:CodexEnabled
                minimax = $script:MinimaxEnabled
            }
        }
        $json = $state | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($script:StatePath, $json, [System.Text.Encoding]::UTF8)
    } catch {
    }
}

function Convert-ToDateTimeOrNull($value) {
    if ($null -eq $value) {
        return $null
    }

    if ($value -is [DateTime]) {
        return [DateTime]$value
    }

    if ($value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$value).LocalDateTime
    }

    try {
        return ([DateTimeOffset]::Parse($value.ToString(), [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
    } catch {
        try {
            return [DateTime]::Parse($value.ToString(), [Globalization.CultureInfo]::InvariantCulture)
        } catch {
            return $null
        }
    }
}

function New-LimitSnapshot($limit) {
    if (-not $limit) {
        return $null
    }

    return [ordered]@{
        used_percent = Convert-ToNumber (Get-ObjectValue $limit "used_percent" 0)
        resets_at = Convert-ToInt64 (Get-ObjectValue $limit "resets_at" 0)
        window_minutes = Convert-ToInt64 (Get-ObjectValue $limit "window_minutes" 0)
        total = Convert-ToNullableNumber (Get-ObjectValue $limit "total" $null)
        remaining = Convert-ToNullableNumber (Get-ObjectValue $limit "remaining" $null)
        used = Convert-ToNullableNumber (Get-ObjectValue $limit "used" $null)
    }
}

function Restore-LimitSnapshot($snapshot) {
    if (-not $snapshot) {
        return $null
    }

    return [pscustomobject]@{
        used_percent = Convert-ToNumber (Get-ObjectValue $snapshot "used_percent" 0)
        resets_at = Convert-ToInt64 (Get-ObjectValue $snapshot "resets_at" 0)
        window_minutes = Convert-ToInt64 (Get-ObjectValue $snapshot "window_minutes" 0)
        total = Convert-ToNullableNumber (Get-ObjectValue $snapshot "total" $null)
        remaining = Convert-ToNullableNumber (Get-ObjectValue $snapshot "remaining" $null)
        used = Convert-ToNullableNumber (Get-ObjectValue $snapshot "used" $null)
    }
}

function New-TokenUsageSnapshot($usage) {
    if (-not $usage) {
        return $null
    }

    return [ordered]@{
        input = Convert-ToInt64 (Get-ObjectValue $usage "input" 0)
        cached = Convert-ToInt64 (Get-ObjectValue $usage "cached" 0)
        output = Convert-ToInt64 (Get-ObjectValue $usage "output" 0)
        reasoning = Convert-ToInt64 (Get-ObjectValue $usage "reasoning" 0)
        total = Convert-ToInt64 (Get-ObjectValue $usage "total" 0)
    }
}

function Restore-TokenUsageSnapshot($snapshot) {
    if (-not $snapshot) {
        return $null
    }

    return [pscustomobject]@{
        input = Convert-ToInt64 (Get-ObjectValue $snapshot "input" 0)
        cached = Convert-ToInt64 (Get-ObjectValue $snapshot "cached" 0)
        output = Convert-ToInt64 (Get-ObjectValue $snapshot "output" 0)
        reasoning = Convert-ToInt64 (Get-ObjectValue $snapshot "reasoning" 0)
        total = Convert-ToInt64 (Get-ObjectValue $snapshot "total" 0)
    }
}

function New-UsageObjectSnapshot($usage) {
    if (-not $usage) {
        return $null
    }

    $updated = Get-ObjectValue $usage "updated" (Get-Date)
    if ($updated -and -not ($updated -is [DateTime]) -and -not ($updated -is [DateTimeOffset])) {
        $updated = Convert-ToDateTimeOrNull $updated
    }
    if (-not $updated) {
        $updated = Get-Date
    }

    return [ordered]@{
        ok = [bool](Get-ObjectValue $usage "ok" $false)
        configured = Get-ObjectValue $usage "configured" $null
        message = Get-ObjectValue $usage "message" $null
        plan = Get-ObjectValue $usage "plan" $null
        source = Get-ObjectValue $usage "source" $null
        updated = $updated.ToString("o")
        isStale = [bool](Get-ObjectValue $usage "isStale" $false)
        staleText = Get-ObjectValue $usage "staleText" ""
        error = Get-ObjectValue $usage "error" $null
        primaryDelta = Convert-ToNullableNumber (Get-ObjectValue $usage "primaryDelta" $null)
        secondaryDelta = Convert-ToNullableNumber (Get-ObjectValue $usage "secondaryDelta" $null)
        primaryDeltaText = Get-ObjectValue $usage "primaryDeltaText" $null
        secondaryDeltaText = Get-ObjectValue $usage "secondaryDeltaText" $null
        primary = New-LimitSnapshot (Get-ObjectValue $usage "primary" $null)
        secondary = New-LimitSnapshot (Get-ObjectValue $usage "secondary" $null)
    }
}

function Restore-UsageObjectSnapshot($snapshot) {
    if (-not $snapshot) {
        return $null
    }

    $updated = Convert-ToDateTimeOrNull (Get-ObjectValue $snapshot "updated" $null)
    if (-not $updated) {
        $updated = Get-Date
    }

    return [pscustomobject]@{
        ok = [bool](Get-ObjectValue $snapshot "ok" $false)
        configured = Get-ObjectValue $snapshot "configured" $null
        message = Get-ObjectValue $snapshot "message" $null
        plan = Get-ObjectValue $snapshot "plan" $null
        source = Get-ObjectValue $snapshot "source" $null
        updated = $updated
        isStale = [bool](Get-ObjectValue $snapshot "isStale" $false)
        staleText = Get-ObjectValue $snapshot "staleText" ""
        error = Get-ObjectValue $snapshot "error" $null
        primaryDelta = Convert-ToNullableNumber (Get-ObjectValue $snapshot "primaryDelta" $null)
        secondaryDelta = Convert-ToNullableNumber (Get-ObjectValue $snapshot "secondaryDelta" $null)
        primaryDeltaText = Get-ObjectValue $snapshot "primaryDeltaText" $null
        secondaryDeltaText = Get-ObjectValue $snapshot "secondaryDeltaText" $null
        primary = Restore-LimitSnapshot (Get-ObjectValue $snapshot "primary" $null)
        secondary = Restore-LimitSnapshot (Get-ObjectValue $snapshot "secondary" $null)
    }
}

function New-UsageSnapshot($codex, $minimax, $activity) {
    return [ordered]@{
        savedAt = (Get-Date).ToString("o")
        codex = New-UsageObjectSnapshot $codex
        minimax = New-UsageObjectSnapshot $minimax
        activity = [ordered]@{
            latestCall = New-TokenUsageSnapshot (Get-ObjectValue $activity "LatestCall" $null)
            latestTurn = New-TokenUsageSnapshot (Get-ObjectValue $activity "LatestTurn" $null)
            recent = New-TokenUsageSnapshot (Get-ObjectValue $activity "Recent" $null)
            observedAt = if ($activity -and $activity.ObservedAt) { $activity.ObservedAt.ToString("o") } else { $null }
        }
    }
}

function Restore-UsageSnapshot($snapshot) {
    if (-not $snapshot) {
        return $null
    }

    $activity = Get-ObjectValue $snapshot "activity" $null
    $observedAt = if ($activity) { Convert-ToDateTimeOrNull (Get-ObjectValue $activity "observedAt" $null) } else { $null }
    return [pscustomobject]@{
        Codex = Restore-UsageObjectSnapshot (Get-ObjectValue $snapshot "codex" $null)
        Minimax = Restore-UsageObjectSnapshot (Get-ObjectValue $snapshot "minimax" $null)
        Activity = [pscustomobject]@{
            LatestCall = Restore-TokenUsageSnapshot (Get-ObjectValue $activity "latestCall" $null)
            LatestTurn = Restore-TokenUsageSnapshot (Get-ObjectValue $activity "latestTurn" $null)
            Recent = Restore-TokenUsageSnapshot (Get-ObjectValue $activity "recent" $null)
            ObservedAt = $observedAt
        }
    }
}

function Initialize-UsageFloorState($state) {
    $script:UsageFloorState = @{
        WindowKey = ""
        PrimaryUsed = $null
        SecondaryUsed = $null
    }

    if (-not $state -or -not $state.usageFloor) {
        return
    }

    $floor = $state.usageFloor
    $script:UsageFloorState.WindowKey = if ($floor.windowKey) { [string]$floor.windowKey } else { "" }
    $script:UsageFloorState.PrimaryUsed = if ($null -ne $floor.primaryUsed) { Convert-ToNumber $floor.primaryUsed } else { $null }
    $script:UsageFloorState.SecondaryUsed = if ($null -ne $floor.secondaryUsed) { Convert-ToNumber $floor.secondaryUsed } else { $null }
}

function Convert-UnixSeconds($seconds) {
    if (-not $seconds) {
        return $null
    }

    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$seconds)
}

function Format-Remaining($resetSeconds) {
    $resetAt = Convert-UnixSeconds $resetSeconds
    if (-not $resetAt) {
        return "reset unknown"
    }

    $span = $resetAt.LocalDateTime - (Get-Date)
    if ($span.TotalSeconds -le 0) {
        return "reset due"
    }

    if ($span.TotalDays -ge 1) {
        return ("{0}d {1}h left" -f [Math]::Floor($span.TotalDays), $span.Hours)
    }

    if ($span.TotalHours -ge 1) {
        return ("{0}h {1}m left" -f [Math]::Floor($span.TotalHours), $span.Minutes)
    }

    return ("{0}m left" -f [Math]::Max(1, [Math]::Ceiling($span.TotalMinutes)))
}

function Format-BaliReset($resetSeconds) {
    $resetAt = Convert-UnixSeconds $resetSeconds
    if (-not $resetAt) {
        return "Reset unknown"
    }

    $bali = $resetAt.UtcDateTime.AddHours(8)
    return ("Reset {0} Bali" -f $bali.ToString("h:mm tt", [Globalization.CultureInfo]::InvariantCulture))
}

function Format-LocalReset($resetSeconds) {
    $resetAt = Convert-UnixSeconds $resetSeconds
    if (-not $resetAt) {
        return "Reset unknown"
    }

    return ("Reset {0}" -f $resetAt.LocalDateTime.ToString("MMM d, h:mm tt", [Globalization.CultureInfo]::InvariantCulture))
}

function Get-TimeLeftPercent($limit) {
    if (-not $limit -or -not $limit.resets_at -or -not $limit.window_minutes) {
        return 0
    }

    $resetAt = Convert-UnixSeconds $limit.resets_at
    if (-not $resetAt) {
        return 0
    }

    $remainingSeconds = ($resetAt.LocalDateTime - (Get-Date)).TotalSeconds
    $windowSeconds = [double]$limit.window_minutes * 60
    if ($windowSeconds -le 0) {
        return 0
    }

    return [Math]::Max([double]0, [Math]::Min([double]100, ($remainingSeconds / $windowSeconds) * 100))
}

function Get-ElapsedPercent($limit) {
    return 100 - (Get-TimeLeftPercent $limit)
}

function Get-UsageHint($primary, $secondary, $isStale) {
    if ($isStale) {
        return [pscustomobject]@{
            Text = "Telemetry paused. Values may lag until Codex reports again."
            Color = "#FFC857"
        }
    }

    if (-not $primary -or -not $secondary) {
        return [pscustomobject]@{
            Text = "Waiting for fresh Codex limit telemetry."
            Color = "#D6E2E8"
        }
    }

    $sessionUsed = [double]$primary.used_percent
    $sessionElapsed = Get-ElapsedPercent $primary
    $weeklyUsed = [double]$secondary.used_percent
    $weeklyElapsed = Get-ElapsedPercent $secondary
    $sessionDelta = $sessionUsed - $sessionElapsed
    $weeklyDelta = $weeklyUsed - $weeklyElapsed

    if ($sessionUsed -ge 92) {
        return [pscustomobject]@{
            Text = "Session limit is nearly spent. Save heavy work for reset."
            Color = "#FF8A3D"
        }
    }

    if ($sessionElapsed -le 12 -and $sessionUsed -ge 30) {
        return [pscustomobject]@{
            Text = "Fast start: session usage is ahead of the clock."
            Color = "#FFC857"
        }
    }

    if ($sessionDelta -ge 25) {
        return [pscustomobject]@{
            Text = "High burn rate. Slow down or switch to lighter tasks."
            Color = "#FFC857"
        }
    }

    if ($sessionElapsed -ge 70 -and $sessionUsed -le 45) {
        return [pscustomobject]@{
            Text = "Plenty left in this session. No need to economize."
            Color = "#A6FF4F"
        }
    }

    if ($weeklyElapsed -ge 75 -and $weeklyUsed -le 35) {
        return [pscustomobject]@{
            Text = "Week is late and usage is low. You have room to spend."
            Color = "#A6FF4F"
        }
    }

    if ($weeklyDelta -ge 20) {
        return [pscustomobject]@{
            Text = "Weekly pace is hot. Keep an eye on large runs."
            Color = "#FFC857"
        }
    }

    if ($weeklyElapsed -ge 45 -and $weeklyUsed -le 25) {
        return [pscustomobject]@{
            Text = "Weekly limit is underused for this point in the week."
            Color = "#A6FF4F"
        }
    }

    if ($sessionDelta -le -20 -and $sessionUsed -le 55) {
        return [pscustomobject]@{
            Text = "Comfortable pace. You can keep working normally."
            Color = "#A6FF4F"
        }
    }

    return [pscustomobject]@{
        Text = "Usage pace looks balanced."
        Color = "#D6E2E8"
    }
}

function Convert-ToNumber($value) {
    if ($null -eq $value) {
        return 0
    }

    try {
        return [double]$value
    } catch {
        return 0
    }
}

function Convert-ToInt64($value) {
    if ($null -eq $value) {
        return [int64]0
    }

    try {
        return [int64]$value
    } catch {
        return [int64]0
    }
}

function Convert-ToNullableNumber($value) {
    if ($null -eq $value) {
        return $null
    }

    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    try {
        return [double]$value
    } catch {
        return $null
    }
}

function Convert-ToBoolean($value, $default) {
    if ($null -eq $value) {
        return [bool]$default
    }

    if ($value -is [bool]) {
        return [bool]$value
    }

    $text = $value.ToString().Trim().ToLowerInvariant()
    if (@("1", "true", "yes", "on") -contains $text) {
        return $true
    }

    if (@("0", "false", "no", "off") -contains $text) {
        return $false
    }

    return [bool]$default
}

function Get-EnvValue($name) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }

    return $value
}

function Get-FirstObjectValue($object, [string[]]$names) {
    foreach ($name in $names) {
        $value = Get-ObjectValue $object $name $null
        if ($null -ne $value) {
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
                continue
            }

            return $value
        }
    }

    return $null
}

function Get-FirstNumberValue($object, [string[]]$names) {
    foreach ($name in $names) {
        $value = Convert-ToNullableNumber (Get-ObjectValue $object $name $null)
        if ($null -ne $value) {
            return $value
        }
    }

    return $null
}

function Get-FirstStringValue($object, [string[]]$names) {
    foreach ($name in $names) {
        $value = Get-ObjectValue $object $name $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace($value.ToString())) {
            return $value.ToString()
        }
    }

    return $null
}

function Get-MinimaxRemoteSettings {
    $config = Read-Config
    $minimax = Get-ObjectValue $config "minimax" $null

    $envUrl = Get-EnvValue "MINIMAX_QUOTA_URL"
    $url = $envUrl
    if (-not $url) {
        $url = Get-FirstObjectValue $minimax @("url", "quotaUrl", "endpoint")
    }

    $envSource = Get-EnvValue "MINIMAX_QUOTA_SOURCE"
    $source = $envSource
    if (-not $source) {
        $source = Get-FirstStringValue $minimax @("source", "mode")
    }

    $envFilePath = Get-EnvValue "MINIMAX_QUOTA_FILE"
    $filePath = $envFilePath
    if (-not $filePath) {
        $filePath = Get-FirstObjectValue $minimax @("file", "filePath", "jsonPath")
    }

    $envSshCommand = Get-EnvValue "MINIMAX_QUOTA_SSH_COMMAND"
    $sshCommand = $envSshCommand
    if (-not $sshCommand) {
        $sshCommand = Get-FirstObjectValue $minimax @("sshCommand")
    }

    $envSshTarget = Get-EnvValue "MINIMAX_QUOTA_SSH_TARGET"
    $sshTarget = $envSshTarget
    if (-not $sshTarget) {
        $sshTarget = Get-FirstObjectValue $minimax @("sshTarget", "sshHost", "ssh")
    }

    $authToken = Get-EnvValue "MINIMAX_QUOTA_TOKEN"
    if (-not $authToken) {
        $authToken = Get-EnvValue "MINIMAX_TOKEN_PLAN_KEY"
    }
    if (-not $authToken) {
        $authToken = Get-EnvValue "MINIMAX_API_KEY"
    }
    if (-not $authToken) {
        $authToken = Get-FirstObjectValue $minimax @("authToken", "token", "tokenPlanKey", "apiKey")
    }

    if (-not $source) {
        if ($filePath) {
            $source = "file"
        } elseif ($sshCommand -or $sshTarget) {
            $source = "ssh"
        } elseif ($authToken) {
            $source = "token_plan"
        } else {
            $source = "http"
        }
    }

    $normalizedSource = $source.ToString().ToLowerInvariant()
    if (-not $url -and ($normalizedSource -in @("token_plan", "token-plan", "api"))) {
        $url = $script:MinimaxTokenPlanUrl
    }

    $enabledValue = Get-EnvValue "MINIMAX_QUOTA_ENABLED"
    $envHasSource = ($envUrl -or $envFilePath -or $envSshCommand -or $envSshTarget -or $authToken)
    if (-not $enabledValue -and -not $envHasSource) {
        $enabledValue = Get-ObjectValue $minimax "enabled" $null
    }

    $hasSource = ($url -or $filePath -or $sshCommand -or $sshTarget -or $authToken)
    $enabled = Convert-ToBoolean $enabledValue $hasSource

    $refreshSeconds = Convert-ToNullableNumber (Get-EnvValue "MINIMAX_QUOTA_REFRESH_SECONDS")
    if ($null -eq $refreshSeconds) {
        $refreshSeconds = Convert-ToNullableNumber (Get-ObjectValue $minimax "refreshSeconds" $script:MinimaxDefaultRefreshSeconds)
    }
    if ($null -eq $refreshSeconds -or $refreshSeconds -le 0) {
        $refreshSeconds = $script:MinimaxDefaultRefreshSeconds
    }

    $timeoutSeconds = Convert-ToNullableNumber (Get-EnvValue "MINIMAX_QUOTA_TIMEOUT_SECONDS")
    if ($null -eq $timeoutSeconds) {
        $timeoutSeconds = Convert-ToNullableNumber (Get-ObjectValue $minimax "timeoutSeconds" 10)
    }
    if ($null -eq $timeoutSeconds -or $timeoutSeconds -le 0) {
        $timeoutSeconds = 10
    }

    $authHeaderName = Get-EnvValue "MINIMAX_QUOTA_AUTH_HEADER"
    if (-not $authHeaderName) {
        $authHeaderName = Get-FirstObjectValue $minimax @("authHeaderName", "tokenHeader")
    }
    if (-not $authHeaderName) {
        $authHeaderName = "Authorization"
    }

    $authHeaderScheme = Get-EnvValue "MINIMAX_QUOTA_AUTH_SCHEME"
    if (-not $authHeaderScheme) {
        $authHeaderScheme = Get-FirstObjectValue $minimax @("authHeaderScheme")
    }
    if ($null -eq $authHeaderScheme) {
        $authHeaderScheme = "Bearer"
    }

    $sshPath = Get-EnvValue "MINIMAX_QUOTA_SSH_PATH"
    if (-not $sshPath) {
        $sshPath = Get-FirstObjectValue $minimax @("sshPath")
    }
    if (-not $sshPath) {
        $sshPath = "ssh"
    }

    $sshRemoteCommand = Get-EnvValue "MINIMAX_QUOTA_SSH_REMOTE_COMMAND"
    if (-not $sshRemoteCommand) {
        $sshRemoteCommand = Get-FirstObjectValue $minimax @("sshRemoteCommand", "remoteCommand")
    }
    if (-not $sshRemoteCommand) {
        $sshRemoteCommand = "mmx quota --output json --non-interactive"
    }

    $modelPattern = Get-EnvValue "MINIMAX_QUOTA_MODEL_PATTERN"
    if (-not $modelPattern) {
        $modelPattern = Get-FirstObjectValue $minimax @("modelPattern", "quotaModelPattern")
    }
    if (-not $modelPattern) {
        $modelPattern = "MiniMax-M*"
    }

    return [pscustomobject]@{
        Enabled = [bool]$enabled
        Source = $normalizedSource
        Url = if ($url) { $url.ToString() } else { "" }
        FilePath = if ($filePath) { $filePath.ToString() } else { "" }
        AuthToken = if ($authToken) { $authToken.ToString() } else { "" }
        AuthHeaderName = $authHeaderName.ToString()
        AuthHeaderScheme = if ($authHeaderScheme) { $authHeaderScheme.ToString() } else { "" }
        RefreshSeconds = [int][Math]::Max(10, [Math]::Round([double]$refreshSeconds))
        TimeoutSeconds = [int][Math]::Max(2, [Math]::Round([double]$timeoutSeconds))
        SshCommand = if ($sshCommand) { $sshCommand.ToString() } else { "" }
        SshPath = $sshPath.ToString()
        SshTarget = if ($sshTarget) { $sshTarget.ToString() } else { "" }
        SshRemoteCommand = $sshRemoteCommand.ToString()
        ModelPattern = $modelPattern.ToString()
    }
}

function Quote-ProcessArgument($value) {
    if ($null -eq $value) {
        return '""'
    }

    $text = $value.ToString()
    if ($text -notmatch '[\s"]') {
        return $text
    }

    return '"' + $text.Replace('"', '\"') + '"'
}

function Invoke-ExternalTextCommand($fileName, $arguments, $timeoutSeconds) {
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $process.StartInfo.FileName = $fileName
    $process.StartInfo.Arguments = $arguments
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true

    $process.Start() | Out-Null
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $completed = $process.WaitForExit([int]($timeoutSeconds * 1000))
    if (-not $completed) {
        try {
            $process.Kill()
        } catch {
        }
        throw "Minimax quota command timed out."
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($process.ExitCode -ne 0) {
        $message = if ($stderr) { $stderr.Trim() } else { "exit code $($process.ExitCode)" }
        throw "Minimax quota command failed: $message"
    }

    return $stdout
}

function Invoke-MinimaxHttpQuota($settings) {
    if (-not $settings.Url) {
        throw "Minimax HTTP quota URL is not configured."
    }

    $headers = @{}
    if ($settings.AuthToken) {
        $scheme = $settings.AuthHeaderScheme
        if ($settings.AuthHeaderName -eq "Authorization" -and $scheme -and $scheme.ToLowerInvariant() -ne "none") {
            $headers[$settings.AuthHeaderName] = ("{0} {1}" -f $scheme, $settings.AuthToken)
        } else {
            $headers[$settings.AuthHeaderName] = $settings.AuthToken
        }
    }

    return Invoke-RestMethod -Method Get -Uri $settings.Url -Headers $headers -TimeoutSec $settings.TimeoutSeconds
}

function Invoke-MinimaxSshQuota($settings) {
    if ($settings.SshCommand) {
        $arguments = "-NoProfile -ExecutionPolicy Bypass -Command " + (Quote-ProcessArgument $settings.SshCommand)
        $stdout = Invoke-ExternalTextCommand "powershell.exe" $arguments $settings.TimeoutSeconds
        return $stdout | ConvertFrom-Json
    }

    if (-not $settings.SshTarget) {
        throw "Minimax SSH target is not configured."
    }

    $arguments = (Quote-ProcessArgument $settings.SshTarget) + " " + (Quote-ProcessArgument $settings.SshRemoteCommand)
    $stdout = Invoke-ExternalTextCommand $settings.SshPath $arguments $settings.TimeoutSeconds
    return $stdout | ConvertFrom-Json
}

function Invoke-MinimaxQuotaRaw($settings) {
    switch ($settings.Source) {
        "ssh" {
            return Invoke-MinimaxSshQuota $settings
        }
        "file" {
            if (-not $settings.FilePath -or -not (Test-Path $settings.FilePath)) {
                throw "Minimax quota file is not configured or does not exist."
            }

            return ([System.IO.File]::ReadAllText($settings.FilePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
        }
        "token_plan" {
            return Invoke-MinimaxHttpQuota $settings
        }
        "token-plan" {
            return Invoke-MinimaxHttpQuota $settings
        }
        "api" {
            return Invoke-MinimaxHttpQuota $settings
        }
        default {
            return Invoke-MinimaxHttpQuota $settings
        }
    }
}

function Convert-MinimaxTimestamp($value) {
    if ($null -eq $value) {
        return [int64]0
    }

    if ($value -is [DateTime]) {
        return ([DateTimeOffset]$value).ToUnixTimeSeconds()
    }

    $number = Convert-ToNullableNumber $value
    if ($null -ne $number) {
        if ($number -le 0) {
            return [int64]0
        }

        if ($number -gt 9999999999) {
            return [int64][Math]::Floor($number / 1000)
        }

        return [int64][Math]::Floor($number)
    }

    try {
        return ([DateTimeOffset]::Parse($value.ToString())).ToUnixTimeSeconds()
    } catch {
        return [int64]0
    }
}

function Convert-MinimaxDurationSeconds($value, $defaultWindowMinutes) {
    $number = Convert-ToNullableNumber $value
    if ($null -eq $number -or $number -le 0) {
        return $null
    }

    $windowSeconds = [Math]::Max(1, [double]$defaultWindowMinutes * 60)
    if ($number -gt ($windowSeconds * 2)) {
        return [double]$number / 1000
    }

    return [double]$number
}

function Get-MinimaxPayloadRoot($raw) {
    $current = $raw
    for ($index = 0; $index -lt 3; $index++) {
        $child = Get-FirstObjectValue $current @("data", "quota", "quotas", "usage", "result")
        if ($null -eq $child -or $child -is [string]) {
            break
        }

        $current = $child
    }

    return $current
}

function Get-MinimaxModelQuotaObject($root, $modelPattern) {
    $items = Get-FirstObjectValue $root @("model_remains", "modelRemains", "models")
    if (-not $items) {
        return $null
    }

    $usableItems = @($items) | Where-Object {
        (Get-FirstNumberValue $_ @("current_interval_total_count", "current_weekly_total_count", "total_count", "total")) -ne $null
    }

    if ($modelPattern) {
        $matched = $usableItems | Where-Object {
            $modelName = Get-FirstStringValue $_ @("model_name", "modelName", "name")
            $modelName -and ($modelName -like $modelPattern)
        }
        if ($matched) {
            $usableItems = $matched
        }
    }

    $usable = $usableItems | Sort-Object {
        $total = Get-FirstNumberValue $_ @("current_interval_total_count", "current_weekly_total_count", "total_count", "total")
        if ($null -eq $total) { 0 } else { $total }
    } -Descending | Select-Object -First 1

    return $usable
}

function Convert-MinimaxQuotaWindow($source, $prefix, $defaultWindowMinutes, $allowGenericTime) {
    if (-not $source) {
        return $null
    }

    $total = Get-FirstNumberValue $source @("${prefix}_total_count", "total_count", "total", "limit", "entitlement", "quota")
    $used = Get-FirstNumberValue $source @(
        "${prefix}_usage_count",
        "${prefix}_used_count",
        "usage_count",
        "used_count",
        "used"
    )
    $remaining = Get-FirstNumberValue $source @(
        "${prefix}_remaining_count",
        "${prefix}_remains_count",
        "${prefix}_left_count",
        "remaining_count",
        "remaining",
        "remains",
        "left"
    )

    if ($null -eq $used -and $null -ne $total -and $null -ne $remaining) {
        $used = [Math]::Max(0, $total - $remaining)
    }

    if ($null -eq $remaining -and $null -ne $total -and $null -ne $used) {
        $remaining = [Math]::Max(0, $total - $used)
    }

    $percent = $null
    if ($null -ne $used -and $null -ne $total -and $total -gt 0) {
        $percent = ($used / $total) * 100
    } else {
        $percent = Get-FirstNumberValue $source @("${prefix}_used_percent", "used_percent", "usage_percent", "usagePercentage")
    }

    if ($null -eq $percent) {
        return $null
    }

    $endNames = @("${prefix}_end_time", "${prefix}_reset_at", "${prefix}_resets_at", "${prefix}_reset_time")
    $startNames = @("${prefix}_start_time", "${prefix}_starts_at", "${prefix}_started_at")
    $durationNames = @("${prefix}_remains_time", "${prefix}_remaining_time", "${prefix}_ttl_seconds")
    if ($prefix -eq "current_weekly") {
        $endNames += @("weekly_end_time", "week_end_time")
        $startNames += @("weekly_start_time", "week_start_time")
        $durationNames += @("weekly_remains_time", "weekly_remaining_time", "week_remains_time")
    }
    if ($allowGenericTime) {
        $endNames += @("end_time", "reset_at", "resets_at", "reset_time", "endAt")
        $startNames += @("start_time", "starts_at", "started_at", "startAt")
        $durationNames += @("remains_time", "remaining_time", "time_remaining", "ttl_seconds")
    }

    $resetSeconds = Convert-MinimaxTimestamp (Get-FirstObjectValue $source $endNames)
    if ($resetSeconds -le 0) {
        $durationSeconds = Convert-MinimaxDurationSeconds (Get-FirstObjectValue $source $durationNames) $defaultWindowMinutes
        if ($null -ne $durationSeconds -and $durationSeconds -gt 0) {
            $resetSeconds = [DateTimeOffset]::Now.AddSeconds($durationSeconds).ToUnixTimeSeconds()
        }
    }
    if ($resetSeconds -le 0) {
        $startSeconds = Convert-MinimaxTimestamp (Get-FirstObjectValue $source $startNames)
        if ($startSeconds -gt 0 -and $defaultWindowMinutes -gt 0) {
            $resetSeconds = [int64]($startSeconds + ([double]$defaultWindowMinutes * 60))
        }
    }

    return [pscustomobject]@{
        used_percent = [Math]::Max([double]0, [Math]::Min([double]100, [double]$percent))
        resets_at = $resetSeconds
        window_minutes = $defaultWindowMinutes
        total = if ($null -ne $total) { [double]$total } else { $null }
        remaining = if ($null -ne $remaining) { [double]$remaining } else { $null }
        used = if ($null -ne $used) { [double]$used } else { $null }
    }
}

function Convert-MinimaxQuota($raw, $sourceName, $modelPattern = "MiniMax-M*") {
    $root = Get-MinimaxPayloadRoot $raw
    $model = Get-MinimaxModelQuotaObject $root $modelPattern
    $primarySource = if ($model) { $model } else { $root }

    $intervalSource = Get-FirstObjectValue $root @("interval", "current_interval", "session", "five_hour", "rolling_interval")
    if (-not $intervalSource) {
        $intervalSource = $primarySource
    }

    $weeklySource = Get-FirstObjectValue $root @("weekly", "current_weekly", "week")
    if (-not $weeklySource) {
        $weeklySource = $primarySource
    }

    $sameSource = [Object]::ReferenceEquals($intervalSource, $weeklySource)
    $interval = Convert-MinimaxQuotaWindow $intervalSource "current_interval" 300 $true
    $weekly = Convert-MinimaxQuotaWindow $weeklySource "current_weekly" 10080 (-not $sameSource)

    if (-not $interval -or -not $weekly) {
        throw "Minimax quota JSON does not contain usable interval and weekly counts."
    }

    $plan = Get-FirstStringValue $primarySource @("current_subscribe_title", "subscribe_title", "plan_name", "plan", "title", "name", "model_name")
    if (-not $plan) {
        $plan = Get-FirstStringValue $root @("current_subscribe_title", "subscribe_title", "plan_name", "plan", "title", "name")
    }

    return [pscustomobject]@{
        ok = $true
        message = $null
        plan = if ($plan) { $plan } else { "Minimax" }
        source = $sourceName
        updated = Get-Date
        isStale = $false
        error = $null
        primary = $interval
        secondary = $weekly
    }
}

function Convert-ToTokenUsage($usage) {
    if (-not $usage) {
        return $null
    }

    return [pscustomobject]@{
        input = Convert-ToInt64 $usage.input_tokens
        cached = Convert-ToInt64 $usage.cached_input_tokens
        output = Convert-ToInt64 $usage.output_tokens
        reasoning = Convert-ToInt64 $usage.reasoning_output_tokens
        total = Convert-ToInt64 $usage.total_tokens
    }
}

function Get-TokenDelta($current, $previous) {
    if (-not $current) {
        return $null
    }

    if (-not $previous) {
        return $current
    }

    return [pscustomobject]@{
        input = [Math]::Max(0, $current.input - $previous.input)
        cached = [Math]::Max(0, $current.cached - $previous.cached)
        output = [Math]::Max(0, $current.output - $previous.output)
        reasoning = [Math]::Max(0, $current.reasoning - $previous.reasoning)
        total = [Math]::Max(0, $current.total - $previous.total)
    }
}

function Add-TokenUsage($left, $right) {
    if (-not $left) {
        $left = [pscustomobject]@{ input = 0; cached = 0; output = 0; reasoning = 0; total = 0 }
    }

    if (-not $right) {
        return $left
    }

    return [pscustomobject]@{
        input = $left.input + $right.input
        cached = $left.cached + $right.cached
        output = $left.output + $right.output
        reasoning = $left.reasoning + $right.reasoning
        total = $left.total + $right.total
    }
}

function Format-TokenCount($value) {
    $number = [double](Convert-ToInt64 $value)
    $absolute = [Math]::Abs($number)
    $prefix = if ($number -lt 0) { "-" } else { "" }
    $culture = [Globalization.CultureInfo]::InvariantCulture

    if ($absolute -ge 1000000) {
        return $prefix + ($absolute / 1000000).ToString("0.0", $culture) + "M"
    }

    if ($absolute -ge 1000) {
        return $prefix + ($absolute / 1000).ToString("0.0", $culture) + "K"
    }

    return ("{0}" -f [int64]$number)
}

function Format-PercentDelta($value) {
    if ($null -eq $value) {
        return $null
    }

    $rounded = [Math]::Round([double]$value, 1)
    if ([Math]::Abs($rounded) -lt 0.1) {
        return "0%"
    }

    $sign = if ($rounded -gt 0) { "+" } else { "" }
    if ([Math]::Abs($rounded - [Math]::Round($rounded)) -lt 0.01) {
        return ("{0}{1}%" -f $sign, [int]$rounded)
    }

    return $sign + $rounded.ToString("0.0", [Globalization.CultureInfo]::InvariantCulture) + "%"
}

function Test-UsableCodexRateLimits($limits) {
    if (-not $limits) {
        return $false
    }

    if ($limits.limit_id -and $limits.limit_id -ne "codex") {
        return $false
    }

    if (-not $limits.primary -or -not $limits.secondary) {
        return $false
    }

    if ($null -eq $limits.primary.used_percent -or $null -eq $limits.secondary.used_percent) {
        return $false
    }

    return $true
}

function Test-UsableMinimaxRateLimits($limits) {
    if (-not $limits) {
        return $false
    }

    if ($limits.limit_id -and $limits.limit_id -ne "minimax") {
        return $false
    }

    if (-not $limits.primary -or -not $limits.secondary) {
        return $false
    }

    if ($null -eq $limits.primary.used_percent -or $null -eq $limits.secondary.used_percent) {
        return $false
    }

    return $true
}

function Get-RateLimitHistory($limitId = "codex") {
    if (-not (Test-Path $script:CodexSessionsDir)) {
        return $null
    }

    $files = Get-ChildItem -Path $script:CodexSessionsDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 30

    $snapshots = @()
    $testLimitsFunc = if ($limitId -eq "minimax") { ${function:Test-UsableMinimaxRateLimits} } else { ${function:Test-UsableCodexRateLimits} }

    foreach ($file in $files) {
        $lines = Get-FileTailLines $file.FullName (512 * 1024)
        foreach ($line in $lines) {
            if ($line -notmatch '"rate_limits"') {
                continue
            }

            try {
                $event = $line | ConvertFrom-Json
                $limits = $event.payload.rate_limits
                if (-not (& $testLimitsFunc $limits)) {
                    continue
                }

                $stamp = [DateTimeOffset]::Parse($event.timestamp)
                $snapshots += [pscustomobject]@{
                    Stamp = $stamp
                    Event = $event
                    File = $file.FullName
                    PrimaryUsed = Convert-ToNumber $limits.primary.used_percent
                    SecondaryUsed = Convert-ToNumber $limits.secondary.used_percent
                    PrimaryReset = Convert-ToInt64 $limits.primary.resets_at
                    SecondaryReset = Convert-ToInt64 $limits.secondary.resets_at
                }
            } catch {
                continue
            }
        }
    }

    $sorted = $snapshots | Sort-Object Stamp -Descending
    $latest = $sorted | Select-Object -First 1
    if (-not $latest) {
        return $null
    }

    $sameWindow = $sorted | Where-Object {
        ($_.PrimaryReset -eq $latest.PrimaryReset) -and
        ($_.SecondaryReset -eq $latest.SecondaryReset)
    }
    $windowPrimaryMax = ($sameWindow | Measure-Object -Property PrimaryUsed -Maximum).Maximum
    $windowSecondaryMax = ($sameWindow | Measure-Object -Property SecondaryUsed -Maximum).Maximum

    if ($null -eq $windowPrimaryMax) {
        $windowPrimaryMax = $latest.PrimaryUsed
    }
    if ($null -eq $windowSecondaryMax) {
        $windowSecondaryMax = $latest.SecondaryUsed
    }

    # In the same reset window the consumed percentage should not move backwards.
    if ($windowPrimaryMax -gt $latest.PrimaryUsed) {
        $latest.PrimaryUsed = $windowPrimaryMax
        $latest.Event.payload.rate_limits.primary.used_percent = $windowPrimaryMax
    }
    if ($windowSecondaryMax -gt $latest.SecondaryUsed) {
        $latest.SecondaryUsed = $windowSecondaryMax
        $latest.Event.payload.rate_limits.secondary.used_percent = $windowSecondaryMax
    }

    $previous = $sorted |
        Select-Object -Skip 1 |
        Where-Object {
            ([Math]::Abs($_.PrimaryUsed - $latest.PrimaryUsed) -ge 0.01) -or
            ([Math]::Abs($_.SecondaryUsed - $latest.SecondaryUsed) -ge 0.01)
        } |
        Select-Object -First 1

    return [pscustomobject]@{
        Latest = $latest
        PreviousDistinct = $previous
    }
}

function Apply-UsageFloor($limits) {
    if (-not $limits -or -not $limits.primary -or -not $limits.secondary) {
        return
    }

    $windowKey = "{0}:{1}" -f (Convert-ToInt64 $limits.primary.resets_at), (Convert-ToInt64 $limits.secondary.resets_at)
    $primaryCurrent = Convert-ToNumber $limits.primary.used_percent
    $secondaryCurrent = Convert-ToNumber $limits.secondary.used_percent

    if ($script:UsageFloorState.WindowKey -ne $windowKey) {
        $script:UsageFloorState.WindowKey = $windowKey
        $script:UsageFloorState.PrimaryUsed = $primaryCurrent
        $script:UsageFloorState.SecondaryUsed = $secondaryCurrent
    } else {
        if ($null -eq $script:UsageFloorState.PrimaryUsed) {
            $script:UsageFloorState.PrimaryUsed = $primaryCurrent
        } else {
            $script:UsageFloorState.PrimaryUsed = [Math]::Max($script:UsageFloorState.PrimaryUsed, $primaryCurrent)
        }

        if ($null -eq $script:UsageFloorState.SecondaryUsed) {
            $script:UsageFloorState.SecondaryUsed = $secondaryCurrent
        } else {
            $script:UsageFloorState.SecondaryUsed = [Math]::Max($script:UsageFloorState.SecondaryUsed, $secondaryCurrent)
        }
    }

    $limits.primary.used_percent = $script:UsageFloorState.PrimaryUsed
    $limits.secondary.used_percent = $script:UsageFloorState.SecondaryUsed
}

function Get-TokenActivitySummary {
    if (-not (Test-Path $script:CodexSessionsDir)) {
        return $null
    }

    $files = Get-ChildItem -Path $script:CodexSessionsDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 6

    $sessionScans = @()

    foreach ($file in $files) {
        $sequence = 0
        $taskStarts = @()
        $tokenEvents = @()

        $lines = Get-FileTailLines $file.FullName (1024 * 1024)
        foreach ($line in $lines) {
            $sequence++
            if (($line -notmatch '"token_count"') -and ($line -notmatch '"task_started"')) {
                continue
            }

            try {
                $event = $line | ConvertFrom-Json
                $stamp = [DateTimeOffset]::Parse($event.timestamp)
                $payload = $event.payload
                if (-not $payload -or -not $payload.type) {
                    continue
                }

                if ($payload.type -eq "task_started") {
                    $taskStarts += $stamp
                    continue
                }

                if ($payload.type -ne "token_count" -or -not $payload.info) {
                    continue
                }

                $total = Convert-ToTokenUsage $payload.info.total_token_usage
                $last = Convert-ToTokenUsage $payload.info.last_token_usage
                if (-not $total -or -not $last) {
                    continue
                }

                $tokenEvents += [pscustomobject]@{
                    File = $file.FullName
                    Stamp = $stamp
                    Sequence = $sequence
                    Total = $total
                    Last = $last
                }
            } catch {
                continue
            }
        }

        if ($taskStarts.Count -gt 0 -or $tokenEvents.Count -gt 0) {
            $sessionScans += [pscustomobject]@{
                File = $file.FullName
                TaskStarts = $taskStarts
                TokenEvents = $tokenEvents
            }
        }
    }

    $allTokenEvents = @($sessionScans | ForEach-Object { $_.TokenEvents } | Where-Object { $_ })
    $latestCall = $allTokenEvents |
        Sort-Object Stamp, Sequence -Descending |
        Select-Object -First 1

    $latestTask = $sessionScans |
        ForEach-Object {
            $scan = $_
            $scan.TaskStarts | ForEach-Object {
                [pscustomobject]@{
                    File = $scan.File
                    Stamp = $_
                }
            }
        } |
        Sort-Object Stamp -Descending |
        Select-Object -First 1

    $latestTurnUsage = $null
    if ($latestTask) {
        $scan = $sessionScans | Where-Object { $_.File -eq $latestTask.File } | Select-Object -First 1
        if ($scan) {
            $events = @($scan.TokenEvents | Sort-Object Stamp, Sequence)
            $latestAfterStart = $events | Where-Object { $_.Stamp -ge $latestTask.Stamp } | Select-Object -Last 1
            if ($latestAfterStart) {
                $previousBeforeStart = $events | Where-Object { $_.Stamp -lt $latestTask.Stamp } | Select-Object -Last 1
                if ($previousBeforeStart) {
                    $latestTurnUsage = Get-TokenDelta $latestAfterStart.Total $previousBeforeStart.Total
                } else {
                    $firstAfterStart = $events | Where-Object { $_.Stamp -ge $latestTask.Stamp } | Select-Object -First 1
                    if ($firstAfterStart -and $firstAfterStart.Sequence -ne $latestAfterStart.Sequence) {
                        $latestTurnUsage = Get-TokenDelta $latestAfterStart.Total $firstAfterStart.Total
                    } else {
                        $latestTurnUsage = $latestAfterStart.Last
                    }
                }
            }
        }
    }

    $cutoff = (Get-Date).AddMinutes(-3)
    $recentUsage = [pscustomobject]@{ input = 0; cached = 0; output = 0; reasoning = 0; total = 0 }
    foreach ($scan in $sessionScans) {
        $events = @($scan.TokenEvents | Sort-Object Stamp, Sequence)
        $previous = $null
        foreach ($event in $events) {
            if ($event.Stamp.LocalDateTime -ge $cutoff -and $previous) {
                $delta = Get-TokenDelta $event.Total $previous.Total
                if ($delta -and $delta.total -gt 0) {
                    $recentUsage = Add-TokenUsage $recentUsage $delta
                }
            }

            $previous = $event
        }
    }

    return [pscustomobject]@{
        LatestCall = if ($latestCall) { $latestCall.Last } else { $null }
        LatestTurn = $latestTurnUsage
        Recent = $recentUsage
        ObservedAt = if ($latestCall) { $latestCall.Stamp.LocalDateTime } else { $null }
    }
}

function Format-ActivityText($usage, $activity) {
    $parts = @()

    if ($usage -and $null -ne $usage.primaryDelta) {
        if ($usage.primaryDelta -gt 0.05) {
            $parts += ("session {0}" -f $usage.primaryDeltaText)
        } elseif ($usage.primaryDelta -lt -0.05) {
            $parts += "session reset"
        }
    }

    if ($usage -and $null -ne $usage.secondaryDelta) {
        if ($usage.secondaryDelta -gt 0.05) {
            $parts += ("week {0}" -f $usage.secondaryDeltaText)
        } elseif ($usage.secondaryDelta -lt -0.05) {
            $parts += "week reset"
        }
    }

    $tokenUsage = $null
    $usageLabel = if ($activity -and $activity.LatestCall -and $activity.LatestCall.total -gt 0) {
        $tokenUsage = $activity.LatestCall
        "request {0} tok" -f (Format-TokenCount $tokenUsage.total)
    } elseif ($activity -and $activity.LatestTurn -and $activity.LatestTurn.total -gt 0) {
        $tokenUsage = $activity.LatestTurn
        "turn {0} tok" -f (Format-TokenCount $tokenUsage.total)
    } else {
        $null
    }

    if ($usageLabel) {
        $parts += $usageLabel
    }

    if ($tokenUsage -and $tokenUsage.output -gt 0) {
        $parts += ("out {0}" -f (Format-TokenCount $tokenUsage.output))
    }

    if ($parts.Count -eq 0) {
        return "Last activity: waiting for token details"
    }

    return "Last activity: " + ($parts -join " | ")
}

function Format-TokenUsageDetail($label, $usage) {
    if (-not $usage -or $usage.total -le 0) {
        return "${label}: unknown"
    }

    return "{0}: {1} tok (in {2}, out {3})" -f `
        $label,
        (Format-TokenCount $usage.total),
        (Format-TokenCount $usage.input),
        (Format-TokenCount $usage.output)
}

function Format-ActivityTooltip($usage, $activity) {
    $lines = @((Format-ActivityText $usage $activity))

    if ($activity) {
        $lines += Format-TokenUsageDetail "Last turn" $activity.LatestTurn
        $lines += Format-TokenUsageDetail "Latest call" $activity.LatestCall
        $lines += Format-TokenUsageDetail "Last 3 min" $activity.Recent
    }

    return $lines -join [Environment]::NewLine
}

function Get-CodexUsage {
    $history = Get-RateLimitHistory
    if (-not $history) {
        return [pscustomobject]@{
            ok = $false
            message = "Waiting for Codex limits"
            plan = "unknown"
            updated = Get-Date
            primary = $null
            secondary = $null
        }
    }

    $latest = $history.Latest
    $previous = $history.PreviousDistinct
    $limits = $latest.Event.payload.rate_limits
    Apply-UsageFloor $limits
    $age = (Get-Date) - $latest.Stamp.LocalDateTime
    $primaryDelta = if ($previous) { $latest.PrimaryUsed - $previous.PrimaryUsed } else { $null }
    $secondaryDelta = if ($previous) { $latest.SecondaryUsed - $previous.SecondaryUsed } else { $null }
    return [pscustomobject]@{
        ok = $true
        message = $null
        plan = $limits.plan_type
        updated = $latest.Stamp.LocalDateTime
        isStale = ($age.TotalSeconds -gt $script:StaleAfterSeconds)
        staleText = if ($age.TotalSeconds -gt $script:StaleAfterSeconds) { "Updated {0}m ago" -f [Math]::Max(1, [Math]::Floor($age.TotalMinutes)) } else { "" }
        primaryDelta = $primaryDelta
        secondaryDelta = $secondaryDelta
        primaryDeltaText = Format-PercentDelta $primaryDelta
        secondaryDeltaText = Format-PercentDelta $secondaryDelta
        primary = $limits.primary
        secondary = $limits.secondary
    }
}

function Apply-MinimaxFloor($limits) {
    if (-not $limits -or -not $limits.primary -or -not $limits.secondary) {
        return
    }

    $windowKey = "{0}:{1}" -f (Convert-ToInt64 $limits.primary.resets_at), (Convert-ToInt64 $limits.secondary.resets_at)
    $primaryCurrent = Convert-ToNumber $limits.primary.used_percent
    $secondaryCurrent = Convert-ToNumber $limits.secondary.used_percent

    if ($script:MinimaxFloorState.WindowKey -ne $windowKey) {
        $script:MinimaxFloorState.WindowKey = $windowKey
        $script:MinimaxFloorState.PrimaryUsed = $primaryCurrent
        $script:MinimaxFloorState.SecondaryUsed = $secondaryCurrent
    } else {
        if ($null -eq $script:MinimaxFloorState.PrimaryUsed) {
            $script:MinimaxFloorState.PrimaryUsed = $primaryCurrent
        } else {
            $script:MinimaxFloorState.PrimaryUsed = [Math]::Max($script:MinimaxFloorState.PrimaryUsed, $primaryCurrent)
        }

        if ($null -eq $script:MinimaxFloorState.SecondaryUsed) {
            $script:MinimaxFloorState.SecondaryUsed = $secondaryCurrent
        } else {
            $script:MinimaxFloorState.SecondaryUsed = [Math]::Max($script:MinimaxFloorState.SecondaryUsed, $secondaryCurrent)
        }
    }

    $limits.primary.used_percent = $script:MinimaxFloorState.PrimaryUsed
    $limits.secondary.used_percent = $script:MinimaxFloorState.SecondaryUsed
}

function Get-MinimaxUsage {
    $settings = Get-MinimaxRemoteSettings
    if (-not $settings.Enabled) {
        return [pscustomobject]@{
            ok = $false
            configured = $false
            message = "Minimax not configured"
            plan = "unknown"
            updated = Get-Date
            primary = $null
            secondary = $null
        }
    }

    $now = Get-Date
    if ($script:MinimaxRemoteState.Usage -and $script:MinimaxRemoteState.LastFetch) {
        $age = $now - $script:MinimaxRemoteState.LastFetch
        if ($age.TotalSeconds -lt $settings.RefreshSeconds) {
            return $script:MinimaxRemoteState.Usage
        }
    }

    try {
        $raw = Invoke-MinimaxQuotaRaw $settings
        $usage = Convert-MinimaxQuota $raw $settings.Source $settings.ModelPattern
        $script:MinimaxRemoteState.LastFetch = $now
        $script:MinimaxRemoteState.Usage = $usage
        $script:MinimaxRemoteState.Error = $null
        Write-WidgetLog ("Minimax quota refreshed via {0}: interval {1:N1}%, weekly {2:N1}%." -f $settings.Source, [double]$usage.primary.used_percent, [double]$usage.secondary.used_percent)
        return $usage
    } catch {
        $script:MinimaxRemoteState.LastFetch = $now
        $script:MinimaxRemoteState.Error = $_.Exception.Message
        Write-WidgetLog ("Minimax quota refresh failed via {0}: {1}" -f $settings.Source, $_.Exception.Message)
        if ($script:MinimaxRemoteState.Usage) {
            $script:MinimaxRemoteState.Usage.isStale = $true
            $script:MinimaxRemoteState.Usage.error = $_.Exception.Message
            return $script:MinimaxRemoteState.Usage
        }

        return [pscustomobject]@{
            ok = $false
            configured = $true
            message = "Minimax unavailable"
            plan = "unknown"
            updated = $now
            error = $_.Exception.Message
            primary = $null
            secondary = $null
        }
    }
}

function Set-Progress($row, $percent) {
    $safePercent = [Math]::Max([double]0, [Math]::Min([double]100, [double]$percent))
    $row.percent = $safePercent
    $row.fill.Width = [Math]::Max([double]5, $row.track.ActualWidth * ($safePercent / 100))
}

function Set-TimeProgress($row, $percent) {
    $safePercent = [Math]::Max([double]0, [Math]::Min([double]100, [double]$percent))
    $elapsedPercent = 100 - $safePercent
    $row.timePercent = $safePercent
    $accent = if ($elapsedPercent -ge 88) {
        "#FF8A3D"
    } elseif ($elapsedPercent -ge 70) {
        "#FFC857"
    } else {
        "#D6E2E8"
    }

    $trackWidth = $row.timeTrack.ActualWidth
    $row.timeElapsed.Width = 0
    $row.timeFill.Width = if ($elapsedPercent -le 0) { 0 } else { [Math]::Max(7, $trackWidth * ($elapsedPercent / 100)) }
    $row.timeFill.Background = Get-Brush $accent
    $row.timeFill.Opacity = if ($elapsedPercent -ge 70) { 0.86 } else { 0.64 }
    if ($row.timeFill.Effect) {
        $row.timeFill.Effect.Color = Get-Color $accent
        $row.timeFill.Effect.Opacity = if ($elapsedPercent -ge 70) { 0.42 } else { 0.18 }
    }
}

function Update-TimeTicks($timeBar) {
    foreach ($child in $timeBar.Children) {
        if ($null -eq $child.Tag -or $null -eq $child.Tag.Segments) {
            continue
        }

        $x = $timeBar.ActualWidth * ($child.Tag.Index / $child.Tag.Segments)
        $child.Margin = ("{0},0,0,0" -f [Math]::Round($x))
    }
}

function New-LimitRow($title, $large, $timeSegments) {
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = "0,8,0,0"

    $header = New-Object System.Windows.Controls.Grid
    $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $header.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $titleSize = 10.5
    $valueSize = 17
    $barHeight = 7
    $barRadius = 3.5

    $titleBlock = New-TextBlock $title $titleSize "SemiBold" "#F1F5F7"
    $titleBlock.Opacity = 0.76
    $value = New-TextBlock "%0" $valueSize "Light" "#9DFF58"
    $value.Margin = "12,0,2,0"
    [System.Windows.Controls.Grid]::SetColumn($value, 1)

    $header.Children.Add($titleBlock) | Out-Null
    $header.Children.Add($value) | Out-Null

    $track = New-Object System.Windows.Controls.Border
    $track.Height = $barHeight
    $track.CornerRadius = $barRadius
    $track.Background = Get-Brush "#5D7F4C"
    $track.Opacity = 0.42

    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = $barHeight
    $fill.CornerRadius = $barRadius
    $fill.HorizontalAlignment = "Left"
    $fill.Background = Get-Brush "#A6FF4F"
    $fill.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 10
        ShadowDepth = 0
        Opacity = 0.42
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#A6FF4F")
    }

    $bar = New-Object System.Windows.Controls.Grid
    $bar.Margin = "0,5,0,0"
    $bar.Children.Add($track) | Out-Null
    $bar.Children.Add($fill) | Out-Null

    $reset = New-TextBlock "" 9 "Regular" "#D0D5D6"
    $reset.Margin = "0,5,0,0"
    $reset.Opacity = 0.58

    $left = New-TextBlock "" 9 "Regular" "#D0D5D6"
    $left.Margin = "0,5,0,0"
    $left.HorizontalAlignment = "Right"
    $left.Opacity = 0.58

    $timeTextGrid = New-Object System.Windows.Controls.Grid
    $timeTextGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $timeTextGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    [System.Windows.Controls.Grid]::SetColumn($left, 1)
    $timeTextGrid.Children.Add($reset) | Out-Null
    $timeTextGrid.Children.Add($left) | Out-Null

    $timeTrack = New-Object System.Windows.Controls.Border
    $timeTrack.Height = 5
    $timeTrack.CornerRadius = 2.5
    $timeTrack.Background = Get-Brush "#62737D"
    $timeTrack.Opacity = 0.28

    $timeFill = New-Object System.Windows.Controls.Border
    $timeFill.Height = 5
    $timeFill.CornerRadius = 2.5
    $timeFill.HorizontalAlignment = "Left"
    $timeFill.Background = Get-Brush "#D6E2E8"
    $timeFill.Opacity = 0.64
    $timeFill.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 8
        ShadowDepth = 0
        Opacity = 0.18
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#D6E2E8")
    }

    $timeElapsed = New-Object System.Windows.Controls.Border
    $timeElapsed.Height = 5
    $timeElapsed.CornerRadius = 2.5
    $timeElapsed.HorizontalAlignment = "Left"
    $timeElapsed.Background = Get-Brush "#435865"
    $timeElapsed.Opacity = 0.26

    $timeBar = New-Object System.Windows.Controls.Grid
    $timeBar.Margin = "0,5,0,0"
    $timeBar.Children.Add($timeTrack) | Out-Null
    $timeBar.Children.Add($timeElapsed) | Out-Null
    $timeBar.Children.Add($timeFill) | Out-Null

    if ($timeSegments -gt 1) {
        for ($tickIndex = 1; $tickIndex -lt $timeSegments; $tickIndex++) {
            $tick = New-Object System.Windows.Controls.Border
            $tick.Width = 1
            $tick.Height = 7
            $tick.CornerRadius = 0.5
            $tick.Background = Get-Brush "#EAF3F7"
            $tick.Opacity = 0.38
            $tick.HorizontalAlignment = "Left"
            $tick.VerticalAlignment = "Center"
            $tick.Tag = [pscustomobject]@{
                Index = $tickIndex
                Segments = $timeSegments
            }
            $timeBar.Children.Add($tick) | Out-Null
        }
    }

    $panel.Children.Add($header) | Out-Null
    $panel.Children.Add($bar) | Out-Null
    $panel.Children.Add($timeTextGrid) | Out-Null
    $panel.Children.Add($timeBar) | Out-Null

    $row = [pscustomobject]@{
        panel = $panel
        title = $titleBlock
        value = $value
        track = $track
        fill = $fill
        reset = $reset
        left = $left
        percent = 0
        timeTrack = $timeTrack
        timeElapsed = $timeElapsed
        timeFill = $timeFill
        timePercent = 0
    }

    $bar.Tag = $row
    $bar.Add_SizeChanged({
        param($sender)
        $data = $sender.Tag
        Set-Progress $data $data.percent
    })

    $timeBar.Tag = $row
    $timeBar.Add_SizeChanged({
        param($sender)
        $data = $sender.Tag
        Set-TimeProgress $data $data.timePercent
        Update-TimeTicks $sender
    })

    return $row
}

function Set-CompactProgress($panel, $percent) {
    $safePercent = [Math]::Max([double]0, [Math]::Min([double]100, [double]$percent))
    $panel.percent = $safePercent
    $panel.fill.Width = if ($safePercent -le 0) { 0 } else { [Math]::Max(4, $panel.track.ActualWidth * ($safePercent / 100)) }
}

function Set-CompactAccent($panel, $usedPercent, $enabled) {
    $accent = if ($enabled) { Get-LimitAccent $usedPercent } else { "#6F7D85" }
    $panel.fill.Background = Get-Brush $accent
    $panel.percentText.Foreground = Get-Brush $accent
    if ($panel.fill.Effect) {
        $panel.fill.Effect.Color = Get-Color $accent
        $panel.fill.Effect.Opacity = if ($enabled) { 0.42 } else { 0.12 }
    }
}

function Set-CompactWeeklyAccent($panel, $usedPercent, $enabled) {
    $accent = if ($enabled) { Get-LimitAccent $usedPercent } else { "#6F7D85" }
    $panel.weeklyText.Foreground = Get-Brush $accent
}

function New-CompactProviderPanel($name, $accentColor) {
    $panelBorder = New-Object System.Windows.Controls.Border
    $panelBorder.Padding = "9,4,9,4"
    $panelBorder.BorderThickness = 1
    $panelBorder.CornerRadius = 9
    $panelBorder.BorderBrush = Get-Brush $accentColor
    $panelBorder.BorderBrush.Opacity = 0.35
    $panelBorder.Background = [System.Windows.Media.Brushes]::Transparent

    $grid = New-Object System.Windows.Controls.Grid
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $label = New-TextBlock $name 9.5 "SemiBold" $accentColor
    $label.Opacity = 0.9
    $label.VerticalAlignment = "Center"

    $percentText = New-TextBlock "--" 16 "Light" "#A6FF4F"
    $percentText.Margin = "10,-2,0,0"
    $percentText.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($percentText, 1)

    $timeText = New-TextBlock "--" 9.5 "Regular" "#D6E2E8"
    $timeText.Margin = "10,1,0,0"
    $timeText.Opacity = 0.74
    $timeText.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($timeText, 2)

    $weeklyText = New-TextBlock "W --" 9.5 "SemiBold" "#D6E2E8"
    $weeklyText.Margin = "12,1,0,0"
    $weeklyText.Opacity = 0.78
    $weeklyText.VerticalAlignment = "Center"
    [System.Windows.Controls.Grid]::SetColumn($weeklyText, 3)

    $track = New-Object System.Windows.Controls.Border
    $track.Height = 7
    $track.CornerRadius = 3.5
    $track.Background = Get-Brush "#5D7F4C"
    $track.Opacity = 0.42

    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 7
    $fill.CornerRadius = 3.5
    $fill.HorizontalAlignment = "Left"
    $fill.Background = Get-Brush "#A6FF4F"
    $fill.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 10
        ShadowDepth = 0
        Opacity = 0.42
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#A6FF4F")
    }

    $bar = New-Object System.Windows.Controls.Grid
    $bar.Margin = "0,4,0,0"
    $bar.Children.Add($track) | Out-Null
    $bar.Children.Add($fill) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($bar, 1)
    [System.Windows.Controls.Grid]::SetColumnSpan($bar, 4)

    $grid.Children.Add($label) | Out-Null
    $grid.Children.Add($percentText) | Out-Null
    $grid.Children.Add($timeText) | Out-Null
    $grid.Children.Add($weeklyText) | Out-Null
    $grid.Children.Add($bar) | Out-Null

    $panelBorder.Child = $grid

    $panel = [pscustomobject]@{
        panel = $panelBorder
        label = $label
        percentText = $percentText
        timeText = $timeText
        weeklyText = $weeklyText
        track = $track
        fill = $fill
        percent = 0
    }

    $bar.Tag = $panel
    $bar.Add_SizeChanged({
        param($sender)
        $data = $sender.Tag
        Set-CompactProgress $data $data.percent
    })

    return $panel
}

function Format-CompactRemaining($resetSeconds) {
    $text = Format-Remaining $resetSeconds
    return $text -replace " left$", ""
}

function Format-CompactTooltip($name, $usage, $activity) {
    if (-not $usage -or -not $usage.ok -or -not $usage.primary -or -not $usage.secondary) {
        return "{0}: waiting for telemetry" -f $name
    }

    $lines = @(
        ("{0} current: {1:N0}% ({2})" -f $name, [double]$usage.primary.used_percent, (Format-Remaining $usage.primary.resets_at)),
        ("{0} weekly: {1:N0}% ({2})" -f $name, [double]$usage.secondary.used_percent, (Format-Remaining $usage.secondary.resets_at))
    )

    if ($usage.isStale) {
        $lines += "Telemetry may be stale."
    }

    if ($name -eq "Codex") {
        $lines += Format-ActivityTooltip $usage $activity
    }

    return $lines -join [Environment]::NewLine
}

function Update-CompactProviderPanel($panel, $usage, $name, $activity) {
    if (-not $usage -or -not $usage.ok -or -not $usage.primary) {
        $panel.percentText.Text = "--"
        $panel.timeText.Text = "waiting"
        $panel.weeklyText.Text = "W --"
        $panel.panel.ToolTip = "{0}: waiting for telemetry" -f $name
        Set-CompactAccent $panel 0 $false
        Set-CompactWeeklyAccent $panel 0 $false
        Set-CompactProgress $panel 0
        return
    }

    $percent = [Math]::Round([double]$usage.primary.used_percent)
    $weeklyPercent = if ($usage.secondary) { [Math]::Round([double]$usage.secondary.used_percent) } else { $null }
    $panel.percentText.Text = "$percent%"
    $panel.timeText.Text = Format-CompactRemaining $usage.primary.resets_at
    $panel.weeklyText.Text = if ($null -ne $weeklyPercent) { "W $weeklyPercent%" } else { "W --" }
    $panel.panel.ToolTip = Format-CompactTooltip $name $usage $activity
    Set-CompactAccent $panel $percent $true
    Set-CompactWeeklyAccent $panel $weeklyPercent ($null -ne $weeklyPercent)
    Set-CompactProgress $panel $percent
}

function Update-LimitRow($row, $limit, $resetText, $timeText) {
    if (-not $limit) {
        $row.value.Text = "--"
        $row.reset.Text = $resetText
        $row.left.Text = $timeText
        Set-LimitAccent $row 0 $false
        Set-Progress $row 0
        Set-TimeProgress $row 0
        return
    }

    $percent = [Math]::Round([double]$limit.used_percent)
    $row.value.Text = "%$percent"
    $row.value.UpdateLayout()
    $row.reset.Text = $resetText
    $row.left.Text = $timeText
    Set-LimitAccent $row $percent $true
    Set-Progress $row $percent
    Set-TimeProgress $row (Get-TimeLeftPercent $limit)
}

function Show-UsageWindow($window) {
    $window.Show()
    $window.WindowState = "Normal"
    $window.Activate() | Out-Null
}

function Get-VisibleProviderCount {
    $count = 0
    if ($script:CodexEnabled) { $count++ }
    if ($script:MinimaxEnabled) { $count++ }
    return [Math]::Max(1, $count)
}

function Get-FullWidgetHeight($controls) {
    $availableWidth = [Math]::Max(1, $script:WidgetWidth - 36)
    $controls.FullContent.Measure([System.Windows.Size]::new($availableWidth, [double]::PositiveInfinity))
    $height = $controls.FullContent.DesiredSize.Height

    if ($height -le 0) {
        $controls.FullContent.UpdateLayout()
        $height = $controls.FullContent.ActualHeight
    }

    if ($height -le 0) {
        return $script:WidgetHeight
    }

    return [Math]::Max(120, [Math]::Min(600, [Math]::Ceiling($height + 28)))
}

function Move-WindowKeepingBottom($window, $oldBottom) {
    if ($oldBottom -le 0) {
        return
    }

    $newTop = $oldBottom - $window.Height
    if ($script:CompactMode) {
        $screenTop = [System.Windows.SystemParameters]::VirtualScreenTop
        $screenBottom = $screenTop + [System.Windows.SystemParameters]::VirtualScreenHeight
    } else {
        $workArea = [System.Windows.SystemParameters]::WorkArea
        $screenTop = $workArea.Top
        $screenBottom = $workArea.Bottom
    }

    if ($newTop -lt $screenTop) {
        $newTop = $screenTop
    }

    $maxTop = $screenBottom - $window.Height
    if ($newTop -gt $maxTop) {
        $newTop = $maxTop
    }

    $window.Top = [Math]::Round($newTop)
}

function Set-WidgetMode($window, $controls, $compact, $saveState = $true, $preserveBottom = $false) {
    $oldHeight = if ($window.ActualHeight -gt 0) { $window.ActualHeight } else { $window.Height }
    $oldBottom = if ($preserveBottom) { $window.Top + $oldHeight } else { 0 }
    $script:CompactMode = [bool]$compact

    if ($script:CompactMode) {
        $controls.FullContent.Visibility = "Collapsed"
        $controls.CompactContent.Visibility = "Visible"
        $controls.Outer.Padding = "8,4,8,4"
        $controls.Outer.CornerRadius = 14

        $width = if ((Get-VisibleProviderCount) -gt 1) { $script:CompactDoubleWidth } else { $script:CompactSingleWidth }
        $window.SizeToContent = "Manual"
        $window.Width = $width
        $window.MinWidth = $width
        $window.MaxWidth = $width
        $window.Height = $script:CompactHeight
        $window.MinHeight = $script:CompactHeight
        $window.MaxHeight = $script:CompactHeight
    } else {
        $controls.CompactContent.Visibility = "Collapsed"
        $controls.FullContent.Visibility = "Visible"
        $controls.Outer.Padding = "12,10,12,4"
        $controls.Outer.CornerRadius = 16

        $window.SizeToContent = "Manual"
        $window.Width = $script:WidgetWidth
        $window.MinWidth = $script:WidgetWidth
        $window.MaxWidth = $script:WidgetWidth
        $height = Get-FullWidgetHeight $controls
        $script:FullWidgetHeight = $height
        $window.Height = $height
        $window.MinHeight = $height
        $window.MaxHeight = $height
    }

    if ($preserveBottom) {
        Move-WindowKeepingBottom $window $oldBottom
    }

    Sync-CompactTopmostTimer $window

    if ($saveState) {
        Save-State $window
    }
}

function Toggle-WidgetMode($window, $controls) {
    $wasCompact = $script:CompactMode
    Set-WidgetMode $window $controls (-not $script:CompactMode) $true $wasCompact
}

function Format-ProviderUpdatedText($usage) {
    if (-not $usage -or -not $usage.ok -or -not $usage.updated) {
        return "not updated"
    }

    $updated = Convert-ToDateTimeOrNull $usage.updated
    if (-not $updated) {
        return "not updated"
    }

    return $updated.ToString("HH:mm:ss")
}

function Apply-WidgetData($controls, $usage, $minimax, $activity) {
    if (-not $usage -or -not $usage.ok -or -not $usage.primary -or -not $usage.secondary) {
        Update-LimitRow $controls.Current $null "Waiting for Codex" "No fresh data"
        Update-LimitRow $controls.Weekly $null "Waiting for Codex" ""
        $hint = Get-UsageHint $null $null $false
        $controls.CodexHint.Text = $hint.Text
        $controls.CodexHint.Foreground = Get-Brush $hint.Color
        $controls.CodexActivity.Text = Format-ActivityText $null $activity
        $controls.CodexActivity.ToolTip = Format-ActivityTooltip $null $activity
        Update-CompactProviderPanel $controls.CompactCodex $null "Codex" $activity
    } else {
        $currentReset = Format-BaliReset $usage.primary.resets_at
        $currentLeft = Format-Remaining $usage.primary.resets_at
        $weeklyReset = Format-LocalReset $usage.secondary.resets_at
        $weeklyLeft = Format-Remaining $usage.secondary.resets_at
        Update-LimitRow $controls.Current $usage.primary $currentReset $currentLeft
        Update-LimitRow $controls.Weekly $usage.secondary $weeklyReset $weeklyLeft

        $hint = Get-UsageHint $usage.primary $usage.secondary $usage.isStale
        $controls.CodexHint.Text = $hint.Text
        $controls.CodexHint.Foreground = Get-Brush $hint.Color
        $controls.CodexActivity.Text = Format-ActivityText $usage $activity
        $controls.CodexActivity.ToolTip = Format-ActivityTooltip $usage $activity
        Update-CompactProviderPanel $controls.CompactCodex $usage "Codex" $activity
    }

    if ($minimax -and $minimax.ok -and $minimax.primary -and $minimax.secondary) {
        $currentReset = Format-LocalReset $minimax.primary.resets_at
        $currentLeft = Format-Remaining $minimax.primary.resets_at
        $weeklyReset = Format-LocalReset $minimax.secondary.resets_at
        $weeklyLeft = Format-Remaining $minimax.secondary.resets_at
        Update-LimitRow $controls.MinimaxCurrent $minimax.primary $currentReset $currentLeft
        Update-LimitRow $controls.MinimaxWeekly $minimax.secondary $weeklyReset $weeklyLeft
    } else {
        Update-LimitRow $controls.MinimaxCurrent $null "Waiting for Minimax" ""
        Update-LimitRow $controls.MinimaxWeekly $null "" ""
    }

    Update-CompactProviderPanel $controls.CompactMinimax $minimax "MiniMax" $null
    $controls.CodexUpdated.Text = Format-ProviderUpdatedText $usage
    $controls.MinimaxUpdated.Text = Format-ProviderUpdatedText $minimax
    $controls.Updated.Text = if ($usage -and $usage.ok) { "Updated " + (Format-ProviderUpdatedText $usage) } else { "Updated " + (Get-Date).ToString("HH:mm:ss") }
}

function Apply-CachedUsageSnapshot($controls, $snapshot) {
    $restored = Restore-UsageSnapshot $snapshot
    if (-not $restored) {
        return $false
    }

    Apply-WidgetData $controls $restored.Codex $restored.Minimax $restored.Activity
    return $true
}

function Update-Widget($controls) {
    $usage = Get-CodexUsage
    $activity = Get-TokenActivitySummary
    $minimax = if ($script:MinimaxEnabled) {
        Get-MinimaxUsage
    } else {
        $script:MinimaxRemoteState.Usage
    }

    Apply-WidgetData $controls $usage $minimax $activity

    if (($usage -and $usage.ok) -or ($minimax -and $minimax.ok)) {
        $script:UsageSnapshot = New-UsageSnapshot $usage $minimax $activity
        Save-State $controls.Window
    }
}

function New-TrayIcon($window) {
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Text = "Codex Usage Meter"
    if (Test-Path $script:IconPath) {
        $tray.Icon = New-Object System.Drawing.Icon $script:IconPath
    } else {
        $tray.Icon = [System.Drawing.SystemIcons]::Application
    }
    $tray.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $showItem = New-Object System.Windows.Forms.ToolStripMenuItem "Show"
    $dashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem "Open Codex Usage Dashboard"
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "Exit"
    $menu.Items.Add($showItem) | Out-Null
    $menu.Items.Add($dashboardItem) | Out-Null
    $menu.Items.Add($exitItem) | Out-Null
    $tray.ContextMenuStrip = $menu
    $tray.Tag = $menu

    $showAction = {
        Show-UsageWindow $window
    }

    $showItem.Add_Click($showAction)
    $dashboardItem.Add_Click({
        [System.Diagnostics.Process]::Start($script:CodexUsageDashboardUrl) | Out-Null
    })
    $exitItem.Add_Click({
        $window.Close()
    })

    return $tray
}

function Build-Widget {
    $state = Read-State
    Initialize-UsageFloorState $state

    # Load provider visibility state
    if ($state.providers) {
        $script:CodexEnabled = [bool]$state.providers.codex
        $script:MinimaxEnabled = [bool]$state.providers.minimax
    }
    if (-not $script:CodexEnabled -and -not $script:MinimaxEnabled) {
        $script:CodexEnabled = $true
    }
    $script:CompactMode = [bool](Get-ObjectValue $state "compactMode" $false)
    $script:TopmostEnabled = [bool](Get-ObjectValue $state "topmost" $true)
    $script:UsageSnapshot = Get-ObjectValue $state "usageSnapshot" $null

    $window = New-Object System.Windows.Window
    $window.Title = "Codex Usage Meter"
    if (Test-Path $script:IconPath) {
        $iconStream = [System.IO.File]::OpenRead($script:IconPath)
        $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create($iconStream)
    }
    $window.Width = $script:WidgetWidth
    $window.Height = $script:WidgetHeight
    $window.MinWidth = $script:WidgetWidth
    $window.MaxWidth = $script:WidgetWidth
    $window.MinHeight = 200
    $window.MaxHeight = 600
    $window.SizeToContent = "Manual"
    $window.WindowStyle = "None"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.UseLayoutRounding = $true
    $window.SnapsToDevicePixels = $true
    $window.ResizeMode = "NoResize"
    Set-WindowTopmost $window
    $window.Left = [double]$state.left
    $window.Top = [double]$state.top
    $window.Opacity = 1.0
    $window.ShowInTaskbar = $false

    $outer = New-Object System.Windows.Controls.Border
    $outer.Margin = "6"
    $outer.Padding = "12,10,12,4"
    $outer.CornerRadius = 16
    $outer.BorderThickness = 1
    $outer.BorderBrush = Get-Brush "#AAB7BD"
    $outer.Background = Get-Brush "#E00E1821"
    $outer.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 8
        ShadowDepth = 0
        Opacity = 0.18
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#02080E")
    }

    $root = New-Object System.Windows.Controls.Grid
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

    $content = New-Object System.Windows.Controls.StackPanel
    $content.Margin = "0,0,0,0"
    [System.Windows.Controls.Grid]::SetRow($content, 0)

    # Vertical layout: Codex on top, Minimax below
    $sectionsGrid = New-Object System.Windows.Controls.Grid
    $sectionsGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
    $sectionsGrid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $sectionsGrid.Margin = "0,0,0,4"

    # Codex section with cyan border
    $codexSection = New-Object System.Windows.Controls.Border
    $codexSection.Margin = "0,0,0,0"
    $codexSection.Padding = "0"
    $codexSection.BorderThickness = 1
    $codexSection.CornerRadius = 10
    $codexSection.BorderBrush = Get-Brush "#6FE8FF"
    $codexSection.BorderBrush.Opacity = 0.35
    $codexSection.Background = [System.Windows.Media.Brushes]::Transparent

    $codexInner = New-Object System.Windows.Controls.StackPanel
    $codexInner.Margin = "10,8,10,8"

    $codexHeader = New-Object System.Windows.Controls.Grid
    $codexHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $codexHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $codexLabel = New-TextBlock "CODEX" 9.5 "SemiBold" "#6FE8FF"
    $codexLabel.Opacity = 0.85
    $codexUpdated = New-TextBlock "not updated" 9 "Regular" "#AAB7BD"
    $codexUpdated.Margin = "8,0,0,0"
    $codexUpdated.Opacity = 0.62
    [System.Windows.Controls.Grid]::SetColumn($codexUpdated, 1)
    $codexHeader.Children.Add($codexLabel) | Out-Null
    $codexHeader.Children.Add($codexUpdated) | Out-Null

    $current = New-LimitRow "CURRENT SESSION" $false 5
    $weekly = New-LimitRow "WEEKLY" $false 7

    $codexActivity = New-TextBlock "Last activity: waiting for token details" 9 "Regular" "#E2E9EC"
    $codexActivity.Margin = "0,6,0,0"
    $codexActivity.Opacity = 0.74

    $codexHint = New-TextBlock "Usage pace looks balanced." 9.5 "Regular" "#D6E2E8"
    $codexHint.Margin = "0,2,0,0"
    $codexHint.Opacity = 0.78

    $codexInner.Children.Add($codexHeader) | Out-Null
    $codexInner.Children.Add($current.panel) | Out-Null
    $codexInner.Children.Add($weekly.panel) | Out-Null
    $codexInner.Children.Add($codexActivity) | Out-Null
    $codexInner.Children.Add($codexHint) | Out-Null

    $codexSection.Child = $codexInner
    [System.Windows.Controls.Grid]::SetRow($codexSection, 0)
    $sectionsGrid.Children.Add($codexSection) | Out-Null

    # Minimax section with orange border
    $minimaxSection = New-Object System.Windows.Controls.Border
    $minimaxSection.Margin = "0,8,0,0"
    $minimaxSection.Padding = "0"
    $minimaxSection.BorderThickness = 1
    $minimaxSection.CornerRadius = 10
    $minimaxSection.BorderBrush = Get-Brush "#FF8A3D"
    $minimaxSection.BorderBrush.Opacity = 0.35
    $minimaxSection.Background = [System.Windows.Media.Brushes]::Transparent

    $minimaxInner = New-Object System.Windows.Controls.StackPanel
    $minimaxInner.Margin = "10,6,10,6"

    $minimaxHeader = New-Object System.Windows.Controls.Grid
    $minimaxHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $minimaxHeader.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $minimaxLabel = New-TextBlock "MINIMAX" 9.5 "SemiBold" "#FF8A3D"
    $minimaxLabel.Opacity = 0.85
    $minimaxUpdated = New-TextBlock "not updated" 9 "Regular" "#AAB7BD"
    $minimaxUpdated.Margin = "8,0,0,0"
    $minimaxUpdated.Opacity = 0.62
    [System.Windows.Controls.Grid]::SetColumn($minimaxUpdated, 1)
    $minimaxHeader.Children.Add($minimaxLabel) | Out-Null
    $minimaxHeader.Children.Add($minimaxUpdated) | Out-Null

    $minimaxCurrent = New-LimitRow "CURRENT SESSION" $false 5
    $minimaxWeekly = New-LimitRow "WEEKLY" $false 7
    $minimaxInner.Children.Add($minimaxHeader) | Out-Null
    $minimaxInner.Children.Add($minimaxCurrent.panel) | Out-Null
    $minimaxInner.Children.Add($minimaxWeekly.panel) | Out-Null

    $minimaxSection.Child = $minimaxInner
    [System.Windows.Controls.Grid]::SetRow($minimaxSection, 1)
    $sectionsGrid.Children.Add($minimaxSection) | Out-Null

    $content.Children.Add($sectionsGrid) | Out-Null

    $compactContent = New-Object System.Windows.Controls.Grid
    $compactContent.Visibility = "Collapsed"
    $compactContent.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $compactContent.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "8" }))
    $compactContent.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

    $compactCodex = New-CompactProviderPanel "CODEX" "#6FE8FF"
    $compactMinimax = New-CompactProviderPanel "MINIMAX" "#FF8A3D"
    [System.Windows.Controls.Grid]::SetColumn($compactCodex.panel, 0)
    [System.Windows.Controls.Grid]::SetColumn($compactMinimax.panel, 2)
    $compactContent.Children.Add($compactCodex.panel) | Out-Null
    $compactContent.Children.Add($compactMinimax.panel) | Out-Null

    $root.Children.Add($content) | Out-Null
    $root.Children.Add($compactContent) | Out-Null

    $updated = New-TextBlock "" 1 "Normal" "#AAB4BB"
    $updated.Visibility = "Collapsed"

    $outer.Child = $root
    $window.Content = $outer
    $window.Visibility = "Visible"

    $root.Add_Loaded({
        Sync-ProviderVisibility $controls
        Apply-CachedUsageSnapshot $controls $script:UsageSnapshot | Out-Null

        $script:StartupRefreshTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:StartupRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:StartupRefreshTimer.Add_Tick({
            param($sender)
            $sender.Stop()
            $script:StartupRefreshTimer = $null
            Update-Widget $controls
        })
        $script:StartupRefreshTimer.Start()
    })

    $controls = [pscustomobject]@{
        Window = $window
        Outer = $outer
        FullContent = $content
        CompactContent = $compactContent
        CodexSection = $codexSection
        MinimaxSection = $minimaxSection
        Current = $current
        Weekly = $weekly
        MinimaxCurrent = $minimaxCurrent
        MinimaxWeekly = $minimaxWeekly
        CompactCodex = $compactCodex
        CompactMinimax = $compactMinimax
        CodexActivity = $codexActivity
        CodexHint = $codexHint
        CodexUpdated = $codexUpdated
        MinimaxUpdated = $minimaxUpdated
        Updated = $updated
    }

    $tray = New-TrayIcon $window

    $contextMenuOpeningHandler = {
        param($sender, $event)
        $sender.ContextMenu = Build-ProviderContextMenu $window $controls
    }

    $outer.ContextMenu = Build-ProviderContextMenu $window $controls
    $root.ContextMenu = Build-ProviderContextMenu $window $controls
    $content.ContextMenu = Build-ProviderContextMenu $window $controls
    $compactContent.ContextMenu = Build-ProviderContextMenu $window $controls
    $outer.Add_ContextMenuOpening($contextMenuOpeningHandler)
    $root.Add_ContextMenuOpening($contextMenuOpeningHandler)
    $content.Add_ContextMenuOpening($contextMenuOpeningHandler)
    $compactContent.Add_ContextMenuOpening($contextMenuOpeningHandler)

    $dragHandler = {
        param($sender, $event)
        if ($event.ClickCount -ge 2) {
            Toggle-WidgetMode $window $controls
            $event.Handled = $true
            return
        }

        if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            try { $window.DragMove() } catch { }
        }
    }
    $outer.Add_MouseLeftButtonDown($dragHandler)

    $window.Add_LocationChanged({
        if ($script:CompactMode) {
            Sync-CompactTopmostTimer $window
        }
        Save-State $window
    })
    $window.Add_Deactivated({
        if ($script:CompactMode) {
            Sync-CompactTopmostTimer $window
        }
    })
    $window.Add_Activated({
        if ($script:CompactMode) {
            Sync-CompactTopmostTimer $window
        }
    })
    $window.Add_Closed({
        if ($null -ne $script:CompactTopmostTimer) {
            $script:CompactTopmostTimer.Stop()
            $script:CompactTopmostTimer = $null
        }
        Save-State $window
        if ($null -ne $tray) {
            $tray.Visible = $false
            $tray.Dispose()
        }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, [int]$state.refreshSeconds))
    $timer.Add_Tick({ Update-Widget $controls })
    $timer.Start()

    $window.ShowDialog()
}

Build-Widget | Out-Null
