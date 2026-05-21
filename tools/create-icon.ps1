Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root "assets"
$outPath = Join-Path $outDir "codex-usage-meter.ico"

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

function New-TrayGaugeBitmap($size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $scale = $size / 16.0
    $bounds = New-Object System.Drawing.RectangleF (1 * $scale), (1 * $scale), (14 * $scale), (14 * $scale)

    $bgBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 13, 22, 30))
    $graphics.FillEllipse($bgBrush, $bounds)

    $rimPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(190, 205, 220, 226)), ([Math]::Max(1.0, 1.1 * $scale))
    $graphics.DrawEllipse($rimPen, $bounds)

    # Lucide-inspired gauge, simplified for the Windows tray's 16px target.
    $trackPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(105, 118, 142, 151)), ([Math]::Max(1.0, 1.7 * $scale))
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcRect = New-Object System.Drawing.RectangleF (4 * $scale), (5 * $scale), (8 * $scale), (8 * $scale)
    $graphics.DrawArc($trackPen, $arcRect, 200, 140)

    $accentPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 166, 255, 79)), ([Math]::Max(1.0, 1.8 * $scale))
    $accentPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $accentPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawArc($accentPen, $arcRect, 200, 58)

    $needlePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 238, 247, 250)), ([Math]::Max(1.0, 1.3 * $scale))
    $needlePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $needlePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($needlePen, (8 * $scale), (9 * $scale), (11 * $scale), (6 * $scale))

    $hubBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 238, 247, 250))
    $graphics.FillEllipse($hubBrush, (7.15 * $scale), (8.15 * $scale), (1.7 * $scale), (1.7 * $scale))

    $graphics.Dispose()
    return $bitmap
}

$bitmap = New-TrayGaugeBitmap 16
$handle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$stream = [System.IO.File]::Create($outPath)
$icon.Save($stream)
$stream.Dispose()
$icon.Dispose()
$bitmap.Dispose()

Write-Host "Created $outPath"
