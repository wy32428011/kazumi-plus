# 生成自有测试图案和正弦音轨，不下载外部媒体。
param([string]$OutputDirectory = '.tools/quality-fixture-4k')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory
} else {
    Join-Path $projectRoot $OutputDirectory
}
if (Test-Path -LiteralPath $output) {
    throw "测试输出目录已存在，请指定新的目录：$output"
}
$ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $output | Out-Null
& $ffmpeg -hide_banner -loglevel error `
    -f lavfi -i 'testsrc2=size=3840x2160:rate=12' `
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 16 `
    -filter_complex '[0:v]split=2[v1][v2];[v1]scale=1920:1080[low];[v2]null[high]' `
    -map '[low]' -map '1:a' -map '[high]' -map '1:a' `
    -c:v libx264 -preset ultrafast -b:v:0 1500k -b:v:1 5000k `
    -g 24 -sc_threshold 0 -c:a aac -b:a 64k `
    -f hls -hls_time 2 -hls_playlist_type vod `
    -var_stream_map 'v:0,a:0 v:1,a:1' -master_pl_name master.m3u8 `
    -hls_segment_filename (Join-Path $output 'v%v_%03d.ts') `
    (Join-Path $output 'v%v.m3u8')
if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg 生成测试视频失败：$LASTEXITCODE"
}
Write-Output (Join-Path $output 'master.m3u8')
