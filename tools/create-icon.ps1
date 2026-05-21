Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root "assets"
$outPath = Join-Path $outDir "codex-usage-meter.ico"

if (-not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir | Out-Null
}

function New-GaugeBitmap($size) {
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $scale = $size / 64.0
    $rect = New-Object System.Drawing.RectangleF (8 * $scale), (8 * $scale), (48 * $scale), (48 * $scale)

    $gradientStart = New-Object System.Drawing.PointF -ArgumentList 0, 0
    $gradientEnd = New-Object System.Drawing.PointF -ArgumentList $size, $size
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList @(
        $gradientStart,
        $gradientEnd,
        [System.Drawing.Color]::FromArgb(245, 13, 25, 34),
        [System.Drawing.Color]::FromArgb(245, 28, 45, 58)
    )
    $graphics.FillEllipse($bgBrush, $rect)

    $rimPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(140, 214, 226, 232)), (2.0 * $scale)
    $graphics.DrawEllipse($rimPen, $rect)

    # Lucide-inspired Gauge: a clean arc plus a small needle.
    $trackPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(82, 141, 156, 166)), (5.0 * $scale)
    $trackPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $trackPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $arcRect = New-Object System.Drawing.RectangleF (15 * $scale), (18 * $scale), (34 * $scale), (34 * $scale)
    $graphics.DrawArc($trackPen, $arcRect, 190, 160)

    $accentPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(248, 166, 255, 79)), (5.0 * $scale)
    $accentPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $accentPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawArc($accentPen, $arcRect, 190, 48)

    $needlePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(245, 226, 239, 244)), (4.0 * $scale)
    $needlePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $needlePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine($needlePen, (32 * $scale), (36 * $scale), (43 * $scale), (25 * $scale))

    $hubBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(245, 226, 239, 244))
    $graphics.FillEllipse($hubBrush, (29.5 * $scale), (33.5 * $scale), (5 * $scale), (5 * $scale))

    $graphics.Dispose()
    return $bitmap
}

$bitmap = New-GaugeBitmap 64
$handle = $bitmap.GetHicon()
$icon = [System.Drawing.Icon]::FromHandle($handle)
$stream = [System.IO.File]::Create($outPath)
$icon.Save($stream)
$stream.Dispose()
$icon.Dispose()
$bitmap.Dispose()

Write-Host "Created $outPath"
