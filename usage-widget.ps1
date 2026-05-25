Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:StatePath = Join-Path $script:AppDir "usage-widget.state.json"
$script:ConfigPath = Join-Path $script:AppDir "usage-widget.config.json"
$script:LocalConfigPath = Join-Path $script:AppDir "usage-widget.local.json"
$script:LogPath = Join-Path $script:AppDir "usage-widget.log"
$script:CodexSessionsDir = Join-Path $env:USERPROFILE ".codex\sessions"
$script:IconPath = Join-Path $script:AppDir "assets\codex-usage-meter.ico"
$script:CodexUsageDashboardUrl = "https://chatgpt.com/codex/settings/usage"
$script:WidgetWidth = 360
$script:WidgetHeight = 240
$script:CompactWidth = 292
$script:CompactHeight = 42
$script:StaleAfterSeconds = 900
$script:MinimaxDefaultRefreshSeconds = 300
$script:MinimaxRemoteState = @{
    LastFetch = $null
    Usage = $null
    Error = $null
}
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

            return @($text -split "`r?`n" | Where-Object { $_ })
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
        usageFloor = $null
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

function Save-State($window) {
    try {
        $state = [ordered]@{
            left = [Math]::Round($window.Left)
            top = [Math]::Round($window.Top)
            topmost = [bool]$window.Topmost
            opacity = 1.0
            refreshSeconds = 3
            usageFloor = [ordered]@{
                windowKey = if ($script:UsageFloorState.WindowKey) { [string]$script:UsageFloorState.WindowKey } else { "" }
                primaryUsed = if ($null -ne $script:UsageFloorState.PrimaryUsed) { [double]$script:UsageFloorState.PrimaryUsed } else { $null }
                secondaryUsed = if ($null -ne $script:UsageFloorState.SecondaryUsed) { [double]$script:UsageFloorState.SecondaryUsed } else { $null }
            }
        }
        $json = $state | ConvertTo-Json -Depth 4
        [System.IO.File]::WriteAllText($script:StatePath, $json, [System.Text.Encoding]::UTF8)
    } catch {
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

    return [Math]::Max(0, [Math]::Min(100, ($remainingSeconds / $windowSeconds) * 100))
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

    if (-not $source) {
        if ($filePath) {
            $source = "file"
        } elseif ($sshCommand -or $sshTarget) {
            $source = "ssh"
        } else {
            $source = "http"
        }
    }

    $enabledValue = Get-EnvValue "MINIMAX_QUOTA_ENABLED"
    $envHasSource = ($envUrl -or $envFilePath -or $envSshCommand -or $envSshTarget)
    if (-not $enabledValue -and -not $envHasSource) {
        $enabledValue = Get-ObjectValue $minimax "enabled" $null
    }

    $hasSource = ($url -or $filePath -or $sshCommand -or $sshTarget)
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

    $authToken = Get-EnvValue "MINIMAX_QUOTA_TOKEN"
    if (-not $authToken) {
        $authToken = Get-FirstObjectValue $minimax @("authToken", "token")
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

    return [pscustomobject]@{
        Enabled = [bool]$enabled
        Source = $source.ToString().ToLowerInvariant()
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

function Get-MinimaxModelQuotaObject($root) {
    $items = Get-FirstObjectValue $root @("model_remains", "modelRemains", "models")
    if (-not $items) {
        return $null
    }

    $usable = @($items) | Where-Object {
        (Get-FirstNumberValue $_ @("current_interval_total_count", "current_weekly_total_count", "total_count", "total")) -ne $null
    } | Sort-Object {
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
        $durationSeconds = Get-FirstNumberValue $source $durationNames
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
        used_percent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
        resets_at = $resetSeconds
        window_minutes = $defaultWindowMinutes
        total = if ($null -ne $total) { [double]$total } else { $null }
        remaining = if ($null -ne $remaining) { [double]$remaining } else { $null }
        used = if ($null -ne $used) { [double]$used } else { $null }
    }
}

function Convert-MinimaxQuota($raw, $sourceName) {
    $root = Get-MinimaxPayloadRoot $raw
    $model = Get-MinimaxModelQuotaObject $root
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
        $usage = Convert-MinimaxQuota $raw $settings.Source
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
    $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
    $row.percent = $safePercent
    $row.fill.Width = [Math]::Max(5, $row.track.ActualWidth * ($safePercent / 100))
}

function Set-TimeProgress($row, $percent) {
    $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
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

function Show-UsageWindow($window) {
    $window.Show()
    $window.WindowState = "Normal"
    $window.Activate() | Out-Null
}

function Set-CompactWindowPlacement($window, $anchorWindow) {
    $screen = $null
    if ($anchorWindow) {
        $point = New-Object System.Drawing.Point ([int]$anchorWindow.Left + 8), ([int]$anchorWindow.Top + 8)
        $screen = [System.Windows.Forms.Screen]::FromPoint($point)
    }

    if (-not $screen) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    }

    $area = $screen.WorkingArea
    $window.Left = $area.Right - $window.Width - 12
    $window.Top = $area.Bottom - $window.Height - 8
}

function Show-CompactAtPrimaryBottom($window) {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $window.Left = $area.Right - $window.Width - 12
    $window.Top = $area.Bottom - $window.Height - 8
    $window.Show()
    $window.Activate() | Out-Null
}

function New-CompactBar {
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 3
    $track.CornerRadius = 1.5
    $track.Background = Get-Brush "#60717B"
    $track.Opacity = 0.4

    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 3
    $fill.CornerRadius = 1.5
    $fill.HorizontalAlignment = "Left"
    $fill.Background = Get-Brush "#A6FF4F"

    $bar = New-Object System.Windows.Controls.Grid
    $bar.Children.Add($track) | Out-Null
    $bar.Children.Add($fill) | Out-Null

    $row = [pscustomobject]@{
        Bar = $bar
        Fill = $fill
        Percent = 0
    }

    $bar.Tag = $row
    $bar.Add_SizeChanged({
        param($sender)
        $data = $sender.Tag
        $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$data.Percent))
        $data.Fill.Width = if ($safePercent -le 0) { 0 } else { [Math]::Max(4, $sender.ActualWidth * ($safePercent / 100)) }
    })

    return $row
}

function Set-CompactProgress($row, $percent, $enabled) {
    $safePercent = [Math]::Max(0, [Math]::Min(100, [double]$percent))
    $row.Percent = $safePercent
    $accent = if ($enabled) { Get-LimitAccent $safePercent } else { "#6F7D85" }
    $row.Fill.Background = Get-Brush $accent
    $row.Fill.Width = if ($safePercent -le 0) { 0 } else { [Math]::Max(4, $row.Bar.ActualWidth * ($safePercent / 100)) }
}

function New-CompactStatusWindow($detailWindow) {
    $compact = New-Object System.Windows.Window
    $compact.Title = "Codex Usage Meter Compact"
    $compact.Width = $script:CompactWidth
    $compact.Height = $script:CompactHeight
    $compact.MinWidth = $script:CompactWidth
    $compact.MaxWidth = $script:CompactWidth
    $compact.MinHeight = $script:CompactHeight
    $compact.MaxHeight = $script:CompactHeight
    $compact.WindowStyle = "None"
    $compact.AllowsTransparency = $true
    $compact.Background = [System.Windows.Media.Brushes]::Transparent
    $compact.UseLayoutRounding = $true
    $compact.SnapsToDevicePixels = $true
    $compact.ResizeMode = "NoResize"
    $compact.Topmost = $true
    $compact.ShowInTaskbar = $false
    Set-CompactWindowPlacement $compact $detailWindow

    $outer = New-Object System.Windows.Controls.Border
    $outer.Margin = "3"
    $outer.Padding = "10,6,10,6"
    $outer.CornerRadius = 10
    $outer.BorderThickness = 1
    $outer.BorderBrush = Get-Brush "#B8C7CF"
    $outer.Background = Get-Brush "#EA1A2630"
    $outer.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{
        BlurRadius = 6
        ShadowDepth = 0
        Opacity = 0.16
        Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#02080E")
    }

    $root = New-Object System.Windows.Controls.Grid
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

    $line = New-Object System.Windows.Controls.Grid
    $line.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))
    $line.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $line.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "Auto" }))

    $brand = New-TextBlock "Codex" 10 "SemiBold" "#F6FAFC"
    $brand.Opacity = 0.72
    $brand.Margin = "0,0,10,0"
    $status = New-TextBlock "S --   W --" 12 "SemiBold" "#D6E2E8"
    [System.Windows.Controls.Grid]::SetColumn($status, 1)
    $time = New-TextBlock "--" 10 "Regular" "#C8D2D8"
    $time.Margin = "10,1,0,0"
    [System.Windows.Controls.Grid]::SetColumn($time, 2)
    $line.Children.Add($brand) | Out-Null
    $line.Children.Add($status) | Out-Null
    $line.Children.Add($time) | Out-Null

    $bars = New-Object System.Windows.Controls.Grid
    $bars.Margin = "0,5,0,0"
    $bars.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $bars.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "8" }))
    $bars.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    [System.Windows.Controls.Grid]::SetRow($bars, 1)

    $sessionBar = New-CompactBar
    $weeklyBar = New-CompactBar
    [System.Windows.Controls.Grid]::SetColumn($weeklyBar.Bar, 2)
    $bars.Children.Add($sessionBar.Bar) | Out-Null
    $bars.Children.Add($weeklyBar.Bar) | Out-Null

    $root.Children.Add($line) | Out-Null
    $root.Children.Add($bars) | Out-Null
    $outer.Child = $root
    $compact.Content = $outer

    $outer.Add_MouseLeftButtonDown({
        param($sender, $event)
        if ($event.ClickCount -ge 2) {
            Show-UsageWindow $detailWindow
        }
    })

    $compact.Show()

    return [pscustomobject]@{
        Window = $compact
        Status = $status
        Time = $time
        SessionBar = $sessionBar
        WeeklyBar = $weeklyBar
    }
}

function Update-CompactStatus($compact, $usage, $activity) {
    if (-not $compact) {
        return
    }

    if (-not $usage.ok) {
        $compact.Status.Text = "Waiting for limits"
        $compact.Status.Foreground = Get-Brush "#D6E2E8"
        $compact.Time.Text = "WAIT"
        Set-CompactProgress $compact.SessionBar 0 $false
        Set-CompactProgress $compact.WeeklyBar 0 $false
        $compact.Window.ToolTip = Format-ActivityTooltip $null $activity
        return
    }

    $sessionPercent = [Math]::Round([double]$usage.primary.used_percent)
    $weeklyPercent = [Math]::Round([double]$usage.secondary.used_percent)
    $compact.Status.Text = "S {0}%   W {1}%" -f $sessionPercent, $weeklyPercent
    $compact.Status.Foreground = Get-Brush (Get-LimitAccent ([Math]::Max($sessionPercent, $weeklyPercent)))
    $compact.Time.Text = Format-Remaining $usage.primary.resets_at
    Set-CompactProgress $compact.SessionBar $sessionPercent $true
    Set-CompactProgress $compact.WeeklyBar $weeklyPercent $true
    $compact.Window.ToolTip = Format-ActivityTooltip $usage $activity
}

function Update-Widget($controls) {
    $usage = Get-CodexUsage
    $activity = Get-TokenActivitySummary

    if (-not $usage.ok) {
        Update-LimitRow $controls.Current $null "Waiting for Codex" "No fresh data"
        Update-LimitRow $controls.Weekly $null "Waiting for Codex" ""
        Update-LimitRow $controls.MinimaxCurrent $null "Waiting for Minimax" ""
        Update-LimitRow $controls.MinimaxWeekly $null "" ""
        $hint = Get-UsageHint $null $null $false
        $controls.Hint.Text = $hint.Text
        $controls.Hint.Foreground = Get-Brush $hint.Color
        $controls.Activity.Text = Format-ActivityText $null $activity
        $controls.Activity.ToolTip = Format-ActivityTooltip $null $activity
        $controls.Updated.Text = "Updated " + (Get-Date).ToString("HH:mm:ss")
        Update-CompactStatus $controls.Compact $usage $activity
        return
    }

    $currentReset = Format-BaliReset $usage.primary.resets_at
    $currentLeft = Format-Remaining $usage.primary.resets_at
    $weeklyReset = Format-LocalReset $usage.secondary.resets_at
    $weeklyLeft = Format-Remaining $usage.secondary.resets_at
    Update-LimitRow $controls.Current $usage.primary $currentReset $currentLeft
    Update-LimitRow $controls.Weekly $usage.secondary $weeklyReset $weeklyLeft

    $minimax = Get-MinimaxUsage
    if ($minimax.ok) {
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

    $hint = Get-UsageHint $usage.primary $usage.secondary $usage.isStale
    $controls.Hint.Text = $hint.Text
    $controls.Hint.Foreground = Get-Brush $hint.Color
    $controls.Activity.Text = Format-ActivityText $usage $activity
    $controls.Activity.ToolTip = Format-ActivityTooltip $usage $activity
    $controls.Updated.Text = "Updated " + $usage.updated.ToString("HH:mm:ss")
    Update-CompactStatus $controls.Compact $usage $activity
}

function New-TrayIcon($window, $compact) {
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
    $compactItem = New-Object System.Windows.Forms.ToolStripMenuItem "Hide Compact Status"
    $showCompactItem = New-Object System.Windows.Forms.ToolStripMenuItem "Show Compact Now"
    $locateCompactItem = New-Object System.Windows.Forms.ToolStripMenuItem "Locate Compact Status"
    $dashboardItem = New-Object System.Windows.Forms.ToolStripMenuItem "Open Codex Usage Dashboard"
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "Exit"
    $menu.Items.Add($showItem) | Out-Null
    $menu.Items.Add($compactItem) | Out-Null
    $menu.Items.Add($showCompactItem) | Out-Null
    $menu.Items.Add($locateCompactItem) | Out-Null
    $menu.Items.Add($dashboardItem) | Out-Null
    $menu.Items.Add($exitItem) | Out-Null
    $tray.ContextMenuStrip = $menu

    $showAction = {
        Show-UsageWindow $window
    }

    $showItem.Add_Click($showAction)
    $tray.Add_DoubleClick($showAction)
    $compactItem.Add_Click({
        try {
            if ($null -eq $compact -or $null -eq $compact.Window) {
                return
            }

            if ($compact.Window.IsVisible) {
                $compact.Window.Hide()
            } else {
                Set-CompactWindowPlacement $compact.Window $window
                $compact.Window.Show()
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                ("Compact status toggle failed: {0}" -f $_.Exception.Message),
                "Codex Usage Meter",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })
    $showCompactItem.Add_Click({
        if ($null -eq $compact -or $null -eq $compact.Window) {
            return
        }

        Set-CompactWindowPlacement $compact.Window $window
        $compact.Window.Show()
        $compact.Window.Activate() | Out-Null
    })
    $locateCompactItem.Add_Click({
        if ($null -eq $compact -or $null -eq $compact.Window) {
            return
        }

        Show-CompactAtPrimaryBottom $compact.Window
        [System.Windows.Forms.MessageBox]::Show(
            ("Compact status at X={0}, Y={1}, W={2}, H={3}" -f [int]$compact.Window.Left, [int]$compact.Window.Top, [int]$compact.Window.Width, [int]$compact.Window.Height),
            "Codex Usage Meter",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    })
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
    $window.UseLayoutRounding = $true
    $window.SnapsToDevicePixels = $true
    $window.ResizeMode = "NoResize"
    $window.Topmost = [bool]$state.topmost
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
    $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = "Auto" }))

    $content = New-Object System.Windows.Controls.StackPanel
    $content.Margin = "0,0,0,0"
    [System.Windows.Controls.Grid]::SetRow($content, 0)

    # Two column layout for Codex and Minimax side by side
    $sectionsGrid = New-Object System.Windows.Controls.Grid
    $sectionsGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $sectionsGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = "6" }))
    $sectionsGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
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
    $codexInner.Margin = "10,6,10,6"

    $codexLabel = New-TextBlock "CODEX" 9.5 "SemiBold" "#6FE8FF"
    $codexLabel.Opacity = 0.85

    $current = New-LimitRow "CURRENT SESSION" $false 5
    $weekly = New-LimitRow "WEEKLY" $false 7
    $codexInner.Children.Add($codexLabel) | Out-Null
    $codexInner.Children.Add($current.panel) | Out-Null
    $codexInner.Children.Add($weekly.panel) | Out-Null

    $codexSection.Child = $codexInner
    [System.Windows.Controls.Grid]::SetColumn($codexSection, 0)
    $sectionsGrid.Children.Add($codexSection) | Out-Null

    # Minimax section with orange border
    $minimaxSection = New-Object System.Windows.Controls.Border
    $minimaxSection.Margin = "0,0,0,0"
    $minimaxSection.Padding = "0"
    $minimaxSection.BorderThickness = 1
    $minimaxSection.CornerRadius = 10
    $minimaxSection.BorderBrush = Get-Brush "#FF8A3D"
    $minimaxSection.BorderBrush.Opacity = 0.35
    $minimaxSection.Background = [System.Windows.Media.Brushes]::Transparent

    $minimaxInner = New-Object System.Windows.Controls.StackPanel
    $minimaxInner.Margin = "10,6,10,6"

    $minimaxLabel = New-TextBlock "MINIMAX" 9.5 "SemiBold" "#FF8A3D"
    $minimaxLabel.Opacity = 0.85

    $minimaxCurrent = New-LimitRow "CURRENT SESSION" $false 5
    $minimaxWeekly = New-LimitRow "WEEKLY" $false 7
    $minimaxInner.Children.Add($minimaxLabel) | Out-Null
    $minimaxInner.Children.Add($minimaxCurrent.panel) | Out-Null
    $minimaxInner.Children.Add($minimaxWeekly.panel) | Out-Null

    $minimaxSection.Child = $minimaxInner
    [System.Windows.Controls.Grid]::SetColumn($minimaxSection, 2)
    $sectionsGrid.Children.Add($minimaxSection) | Out-Null

    $content.Children.Add($sectionsGrid) | Out-Null

    $activity = New-TextBlock "Last activity: waiting for token details" 9 "Regular" "#E2E9EC"
    $activity.Margin = "0,4,0,0"
    $activity.Opacity = 0.74

    $hint = New-TextBlock "Usage pace looks balanced." 9.5 "Regular" "#D6E2E8"
    $hint.Margin = "0,2,0,0"
    $hint.Opacity = 0.78

    $content.Children.Add($activity) | Out-Null
    $content.Children.Add($hint) | Out-Null
    $root.Children.Add($content) | Out-Null

    $updated = New-TextBlock "" 1 "Normal" "#AAB4BB"
    $updated.Visibility = "Collapsed"

    $outer.Child = $root
    $window.Content = $outer

    $compact = New-CompactStatusWindow $window

    $controls = [pscustomobject]@{
        Current = $current
        Weekly = $weekly
        MinimaxCurrent = $minimaxCurrent
        MinimaxWeekly = $minimaxWeekly
        Activity = $activity
        Hint = $hint
        Updated = $updated
        Compact = $compact
    }

    $tray = New-TrayIcon $window $compact

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

    $window.Add_LocationChanged({
        Save-State $window
        if ($null -ne $compact -and $null -ne $compact.Window -and $compact.Window.IsVisible) {
            Set-CompactWindowPlacement $compact.Window $window
        }
    })
    $window.Add_Closed({
        Save-State $window
        if ($null -ne $compact -and $null -ne $compact.Window) {
            $compact.Window.Close()
        }
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
