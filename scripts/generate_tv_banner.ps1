param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# 复用由 Plus SVG 几何标识生成的图标，绘制 Android TV 要求的 320×180 横幅。
$outputDirectory = Join-Path $ProjectRoot 'android/app/src/tv/res/drawable-xhdpi'
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$bitmap = [Drawing.Bitmap]::new(320, 180)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$logo = [Drawing.Image]::FromFile((Join-Path $ProjectRoot 'assets/images/logo/logo_rounded.png'))
$titleFont = [Drawing.Font]::new('Segoe UI', 22, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$subtitleFont = [Drawing.Font]::new('Segoe UI', 18, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
$white = [Drawing.SolidBrush]::new([Drawing.Color]::White)
$accent = [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#70E0CF'))
try {
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear([Drawing.ColorTranslator]::FromHtml('#11262A'))
    $graphics.DrawImage($logo, 16, 34, 112, 112)
    $graphics.DrawString('Kazumi Plus', $titleFont, $white, 137, 57)
    $graphics.DrawString('TV', $subtitleFont, $accent, 140, 96)
    $outputPath = Join-Path $outputDirectory 'tv_banner.png'
    $bitmap.Save($outputPath, [Drawing.Imaging.ImageFormat]::Png)
    Write-Output "TV 横幅已生成：$outputPath（320×180）"
} finally {
    $logo.Dispose(); $titleFont.Dispose(); $subtitleFont.Dispose()
    $white.Dispose(); $accent.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
}
