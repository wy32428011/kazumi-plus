param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

Add-Type -AssemblyName System.Drawing

# 从独立的几何标识生成应用图标，不使用上游授权插画。
function New-PlusBitmap([int]$Size) {
    $bitmap = [System.Drawing.Bitmap]::new($Size, $Size)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $graphics.ScaleTransform($Size / 512.0, $Size / 512.0)
    $tile = [System.Drawing.Drawing2D.GraphicsPath]::new()
    $tile.AddArc(16, 16, 224, 224, 180, 90)
    $tile.AddArc(272, 16, 224, 224, 270, 90)
    $tile.AddArc(272, 272, 224, 224, 0, 90)
    $tile.AddArc(16, 272, 224, 224, 90, 90)
    $tile.CloseFigure()
    $background = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#11262A'))
    $accent = [System.Drawing.SolidBrush]::new([System.Drawing.ColorTranslator]::FromHtml('#70E0CF'))
    $white = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $graphics.FillPath($background, $tile)
    $points = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(166, 142),
        [System.Drawing.PointF]::new(166, 370),
        [System.Drawing.PointF]::new(336, 256)
    )
    $graphics.FillPolygon($accent, $points)
    $graphics.FillRectangle($white, 338, 310, 32, 116)
    $graphics.FillRectangle($white, 296, 352, 116, 32)
    $background.Dispose()
    $accent.Dispose()
    $white.Dispose()
    $tile.Dispose()
    $graphics.Dispose()
    return $bitmap
}

function Save-PlusPng([string]$Path, [int]$Size) {
    $bitmap = New-PlusBitmap $Size
    try { $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
}

function Save-PlusIco([string]$Path) {
    $sizes = @(16, 32, 48, 64, 128, 256)
    $payloads = @()
    foreach ($size in $sizes) {
        $bitmap = New-PlusBitmap $size
        $stream = [System.IO.MemoryStream]::new()
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $payloads += ,$stream.ToArray()
        } finally { $bitmap.Dispose(); $stream.Dispose() }
    }
    $file = [System.IO.File]::Create($Path)
    $writer = [System.IO.BinaryWriter]::new($file)
    try {
        $writer.Write([uint16]0)
        $writer.Write([uint16]1)
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
            $writer.Write([byte]$dimension)
            $writer.Write([byte]$dimension)
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            $writer.Write([uint16]1)
            $writer.Write([uint16]32)
            $writer.Write([uint32]$payloads[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $payloads[$index].Length
        }
        foreach ($payload in $payloads) { $writer.Write([byte[]]$payload) }
    } finally { $writer.Dispose() }
}

$logoDirectory = Join-Path $ProjectRoot 'assets/images/logo'
foreach ($name in @('logo_android.png', 'logo_ios.png', 'logo_rounded.png', 'logo_linux.png')) {
    Save-PlusPng (Join-Path $logoDirectory $name) 512
}
foreach ($name in @('logo_lanczos.ico', 'logo_windows.ico')) {
    Save-PlusIco (Join-Path $logoDirectory $name)
}
Save-PlusIco (Join-Path $ProjectRoot 'windows/runner/resources/app_icon.ico')

$androidResources = Join-Path $ProjectRoot 'android/app/src/main/res'
$densities = @{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($density in $densities.Keys) {
    Save-PlusPng (Join-Path $androidResources "mipmap-$density/ic_launcher.png") $densities[$density]
    $foreground = Join-Path $androidResources "drawable-$density/ic_launcher_foreground.png"
    if (Test-Path -LiteralPath $foreground) { Save-PlusPng $foreground ([int]($densities[$density] * 2.25)) }
    $monochrome = Join-Path $androidResources "drawable-$density/ic_launcher_monochrome.png"
    if (Test-Path -LiteralPath $monochrome) { Save-PlusPng $monochrome ([int]($densities[$density] * 2.25)) }
}
Write-Output 'Kazumi Plus 图标已生成。'
