Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StatePath = Join-Path $script:AppDir "usage-widget.state.json"
$script:CodexSessionsDir = Join-Path $env:USERPROFILE ".codex\sessions"
$script:IconPath = Join-Path $script:AppDir "assets\codex-usage-meter.ico"
$script:WidgetWidth = 360
$script:WidgetHeight = 236

function Get-Brush($hex) {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function Get-Color($hex) {
    return [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function Get-LimitAccent($usedPercent) {
    $used = [Math]::Max(0, [Math]::Min(100, [double]$usedPercent))
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
        opacity = 0.96
        refreshSeconds = 3
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

function Save-State($window) {
    try {
        $state = [ordered]@{
            left = [Math]::Round($window.Left)
            top = [Math]::Round($window.Top)
            topmost = [bool]$window.Topmost
            opacity = [double]$window.Opacity
            refreshSeconds = 3
        }
        $json = $state | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:StatePath, $json, [System.Text.Encoding]::UTF8)
    } catch {
    }
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

    return [Math]::Max(0, [Math]::Min(100, ($remainingSeconds / $windowSeconds) * 100))
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

function Get-LatestRateLimitLine {
    if (-not (Test-Path $script:CodexSessionsDir)) {
        return $null
    }

    $files = Get-ChildItem -Path $script:CodexSessionsDir -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 60

    $latest = $null

    foreach ($file in $files) {
        $matches = Select-String -Path $file.FullName -Pattern '"rate_limits"' -ErrorAction SilentlyContinue |
            Select-Object -Last 20
        foreach ($match in $matches) {
            try {
                $event = $match.Line | ConvertFrom-Json
                $limits = $event.payload.rate_limits
                if (-not (Test-UsableCodexRateLimits $limits)) {
                    continue
                }

                $stamp = [DateTimeOffset]::Parse($event.timestamp)
                if (($null -eq $latest) -or ($stamp -gt $latest.Stamp)) {
                    $latest = [pscustomobject]@{
                        Stamp = $stamp
                        Event = $event
                        File = $file.FullName
                    }
                }
            } catch {
                continue
            }
        }
    }

    return $latest
}

function Get-CodexUsage {
    $latest = Get-LatestRateLimitLine
    if (-not $latest) {
        return [pscustomobject]@{
            ok = $false
            message = "Waiting for Codex limits"
            plan = "unknown"
            updated = Get-Date
            primary = $null
            secondary = $null
        }
    }

    $limits = $latest.Event.payload.rate_limits
    $age = (Get-Date) - $latest.Stamp.LocalDateTime
    return [pscustomobject]@{
        ok = $true
        message = $null
        plan = $limits.plan_type
        updated = $latest.Stamp.LocalDateTime
        isStale = ($age.TotalSeconds -gt 90)
        staleText = if ($age.TotalSeconds -gt 90) { "Stale {0}m" -f [Math]::Max(1, [Math]::Floor($age.TotalMinutes)) } else { "" }
        primary = $limits.primary
        secondary = $limits.secondary
    }
}

function Set-Progress($row, $percent) {
    $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
    $row.percent = $safePercent
    $row.fill.Width = [Math]::Max(5, $row.track.ActualWidth * ($safePercent / 100))
}

function Set-TimeProgress($row, $percent) {
    $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
    $elapsedPercent = 100 - $safePercent
    $row.timePercent = $safePercent
    $accent = if ($safePercent -le 12) {
        "#FF8A3D"
    } elseif ($safePercent -le 30) {
        "#FFC857"
    } else {
        "#D6E2E8"
    }

    $trackWidth = $row.timeTrack.ActualWidth
    $row.timeElapsed.Width = if ($elapsedPercent -le 0) { 0 } else { [Math]::Max(3, $trackWidth * ($elapsedPercent / 100)) }
    $row.timeFill.Width = if ($safePercent -le 0) { 0 } else { [Math]::Max(7, $trackWidth * ($safePercent / 100)) }
    $row.timeElapsed.Background = if ($safePercent -le 30) { Get-Brush "#6B3F2D" } else { Get-Brush "#435865" }
    $row.timeElapsed.Opacity = if ($safePercent -le 30) { 0.42 } else { 0.26 }
    $row.timeFill.Background = Get-Brush $accent
    $row.timeFill.Opacity = if ($safePercent -le 30) { 0.86 } else { 0.64 }
    if ($row.timeFill.Effect) {
        $row.timeFill.Effect.Color = Get-Color $accent
        $row.timeFill.Effect.Opacity = if ($safePercent -le 30) { 0.42 } else { 0.18 }
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
    $timeFill.HorizontalAlignment = "Right"
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
    $row.reset.Text = $resetText
    $row.left.Text = $timeText
    Set-LimitAccent $row $percent $true
    Set-Progress $row $percent
    Set-TimeProgress $row (Get-TimeLeftPercent $limit)
}

function Update-Widget($controls) {
    $usage = Get-CodexUsage

    if (-not $usage.ok) {
        $controls.Plan.Text = "WAIT"
        Update-LimitRow $controls.Current $null "Waiting for Codex" "No fresh data"
        Update-LimitRow $controls.Weekly $null "Waiting for Codex" ""
        $controls.Updated.Text = "Updated " + (Get-Date).ToString("HH:mm:ss")
        return
    }

    $plan = if ($usage.plan) { $usage.plan.ToString().ToUpperInvariant() } else { "PLAN" }
    $controls.Plan.Text = $plan
    $currentReset = Format-BaliReset $usage.primary.resets_at
    $currentLeft = Format-Remaining $usage.primary.resets_at
    $weeklyReset = Format-LocalReset $usage.secondary.resets_at
    $weeklyLeft = Format-Remaining $usage.secondary.resets_at
    if ($usage.isStale) {
        $currentLeft = $usage.staleText
        $weeklyLeft = $usage.staleText
    }

    Update-LimitRow $controls.Current $usage.primary $currentReset $currentLeft
    Update-LimitRow $controls.Weekly $usage.secondary $weeklyReset $weeklyLeft
    $controls.Updated.Text = "Updated " + $usage.updated.ToString("HH:mm:ss")
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
    $showItem = $menu.Items.Add("Show")
    $exitItem = $menu.Items.Add("Exit")
    $tray.ContextMenuStrip = $menu

    $showAction = {
        $window.Show()
        $window.WindowState = "Normal"
        $window.Activate() | Out-Null
    }

    $showItem.Add_Click($showAction)
    $tray.Add_DoubleClick($showAction)
    $exitItem.Add_Click({
        $window.Close()
    })

    return $tray
}

function Build-Widget {
    $state = Read-State

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
    $window.MinHeight = $script:WidgetHeight
    $window.MaxHeight = $script:WidgetHeight
    $window.WindowStyle = "None"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.ResizeMode = "NoResize"
    $window.Topmost = [bool]$state.topmost
    $window.Left = [double]$state.left
    $window.Top = [double]$state.top
    $window.Opacity = [double]$state.opacity
    $window.ShowInTaskbar = $false

    $outer = New-Object System.Windows.Controls.Border
    $outer.Margin = "8"
    $outer.Padding = "18,14,18,12"
    $outer.CornerRadius = 20
    $outer.BorderThickness = 1
    $outer.BorderBrush = Get-Brush "#AAB7BD"
    $outer.Background = Get-Brush "#D70E1821"
    $outer.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 34
        ShadowDepth = 0
        Opacity = 0.46
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#02080E")
    }

    $root = New-Object System.Windows.Controls.Grid
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

    $headerPanel = New-Object System.Windows.Controls.StackPanel

    $top = New-Object System.Windows.Controls.Grid
    $top.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))

    $brand = New-Object System.Windows.Controls.StackPanel
    $brand.Orientation = "Horizontal"
    $name = New-TextBlock "Codex" 12 "SemiBold" "#F6FAFC"
    $name.Opacity = 0.78
    $plan = New-TextBlock "PLUS" 8.5 "SemiBold" "#D5DEE3"
    $plan.Margin = "7,2,0,0"
    $plan.Opacity = 0.6
    $brand.Children.Add($name) | Out-Null
    $brand.Children.Add($plan) | Out-Null
    $top.Children.Add($brand) | Out-Null

    $headerLine = New-Object System.Windows.Controls.Border
    $headerLine.Height = 1
    $headerLine.Margin = "0,8,0,0"
    $headerLine.Background = Get-Brush "#D7E0E4"
    $headerLine.Opacity = 0.13

    $headerPanel.Children.Add($top) | Out-Null
    $headerPanel.Children.Add($headerLine) | Out-Null
    $root.Children.Add($headerPanel) | Out-Null

    $content = New-Object System.Windows.Controls.StackPanel
    $content.Margin = "0,0,0,0"
    [System.Windows.Controls.Grid]::SetRow($content, 1)

    $current = New-LimitRow "CURRENT SESSION" $false 5
    $weekly = New-LimitRow "WEEKLY LIMIT" $false 7
    $content.Children.Add($current.panel) | Out-Null

    $content.Children.Add((New-Hairline 9 0)) | Out-Null
    $content.Children.Add($weekly.panel) | Out-Null

    $root.Children.Add($content) | Out-Null

    $updated = New-TextBlock "" 1 "Normal" "#AAB4BB"
    $updated.Visibility = "Collapsed"

    $outer.Child = $root
    $window.Content = $outer

    $controls = [pscustomobject]@{
        Plan = $plan
        Current = $current
        Weekly = $weekly
        Updated = $updated
    }

    $tray = New-TrayIcon $window

    $dragHandler = {
        param($sender, $event)
        if (Test-IsInsideButton $event.OriginalSource) {
            return
        }

        if ($event.ClickCount -ge 2) {
            Save-State $window
            $window.Hide()
            return
        }

        if ([System.Windows.Input.Mouse]::LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
            $window.DragMove()
        }
    }
    $outer.Add_MouseLeftButtonDown($dragHandler)

    $window.Add_LocationChanged({ Save-State $window })
    $window.Add_Closed({
        Save-State $window
        if ($null -ne $tray) {
            $tray.Visible = $false
            $tray.Dispose()
        }
    })

    $window.Add_StateChanged({
        if ($window.WindowState -eq [System.Windows.WindowState]::Minimized) {
            Save-State $window
            $window.Hide()
            $window.WindowState = [System.Windows.WindowState]::Normal
        }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds([Math]::Max(1, [int]$state.refreshSeconds))
    $timer.Add_Tick({ Update-Widget $controls })
    $timer.Start()

    $window.Add_ContentRendered({ Update-Widget $controls })
    $window.ShowDialog()
}

Build-Widget | Out-Null
