#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('WindowsDebug', 'WindowsRelease', 'AndroidDebug', 'AndroidRelease', 'AndroidTvDebug', 'AndroidTvRelease')]
    [string]$Target = 'WindowsDebug',
    [string]$FlutterRoot = '',
    [switch]$AllowDirty,
    [string]$EvidenceDirectory = '',
    [string]$UpdateUrl = ''
)

# 构建设置仅作用于本次进程，结束后恢复调用者原来的环境变量。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'flutter_version_json.ps1')
. (Join-Path $PSScriptRoot 'update_url.ps1')
$isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$flutterFileName = if ($isWindowsHost) { 'flutter.bat' } else { 'flutter' }

# 默认复用项目隔离的 SDK，也允许通过参数或 PATH 指定已安装的 SDK。
if ([string]::IsNullOrWhiteSpace($FlutterRoot)) {
    $FlutterRoot = Join-Path $projectRoot '.tools/flutter'
}
$flutterCommand = Join-Path $FlutterRoot "bin/$flutterFileName"
if (-not (Test-Path -LiteralPath $flutterCommand -PathType Leaf)) {
    $installedFlutter = Get-Command $flutterFileName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $installedFlutter) {
        throw '未找到 Flutter SDK，请通过 -FlutterRoot 指定符合 pubspec.yaml 的 SDK。'
    }
    $flutterCommand = $installedFlutter.Source
}

# 默认只构建干净提交；开发时可显式允许工作区改动，但产物会如实标记 dirty。
$sourceCommit = (& git -C $projectRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw '无法读取 Git 提交，拒绝生成缺少来源的产物。' }
$sourceDirty = @(git -C $projectRoot status --porcelain=v1 --untracked-files=normal).Count -gt 0
if ($sourceDirty -and -not $AllowDirty) { throw '工作区存在未提交改动。请先提交全部源码，或仅开发构建显式传入 -AllowDirty。' }
function Get-SourceManifest {
    $paths = @(git -C $projectRoot -c core.quotepath=false ls-files --cached --others --exclude-standard) | Sort-Object -Unique
    return @(foreach ($relativePath in $paths) {
        $absolutePath = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            [ordered]@{path = $relativePath; sha256 = (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
    })
}

# Flutter 也允许只在 local.properties 中配置 SDK，按 Java Properties 规则还原路径。
function ConvertFrom-JavaPropertyEscapes([string]$Value) {
    $decoded = [Text.StringBuilder]::new()
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -ne '\' -or $index + 1 -ge $Value.Length) {
            [void]$decoded.Append($character)
            continue
        }
        $index++
        switch ($Value[$index]) {
            't' { [void]$decoded.Append("`t") }
            'r' { [void]$decoded.Append("`r") }
            'n' { [void]$decoded.Append("`n") }
            'f' { [void]$decoded.Append([char]12) }
            'u' {
                if ($index + 4 -ge $Value.Length) { throw 'local.properties 中的 Unicode 转义不完整。' }
                [void]$decoded.Append([char][Convert]::ToInt32($Value.Substring($index + 1, 4), 16))
                $index += 4
            }
            default { [void]$decoded.Append($Value[$index]) }
        }
    }
    return $decoded.ToString()
}
$sourceManifest = Get-SourceManifest
$sourceManifestText = ConvertTo-Json -InputObject $sourceManifest -Depth 4 -Compress
$sourceDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sourceManifestText))).ToLowerInvariant()

# 追加 Git 的进程级配置，保留调用者可能已经传入的其他 Git 参数。
$gitConfigCountText = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
$gitConfigCount = 0
if (-not [string]::IsNullOrEmpty($gitConfigCountText) -and
    (-not [int]::TryParse($gitConfigCountText, [ref]$gitConfigCount) -or $gitConfigCount -lt 0)) {
    throw '现有 GIT_CONFIG_COUNT 无效，无法安全追加本次构建配置。'
}
$gitConfigKey = "GIT_CONFIG_KEY_$gitConfigCount"
$gitConfigValue = "GIT_CONFIG_VALUE_$gitConfigCount"
$environmentUpdates = @{
    'GIT_CONFIG_COUNT' = [string]($gitConfigCount + 1)
    $gitConfigKey = 'core.longpaths'
    $gitConfigValue = 'true'
}

$previousEnvironment = @{}
foreach ($environmentName in $environmentUpdates.Keys) {
    $previousEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName, 'Process')
}

$logDirectory = Join-Path $projectRoot '.tools/logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
# 一键打包显式绑定本次目标证据，避免读取历史构建的结果。
if ([string]::IsNullOrWhiteSpace($EvidenceDirectory)) {
    $buildStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $logPath = Join-Path $logDirectory ("build-{0}-{1}.log" -f $Target, $buildStamp)
    $evidenceDirectory = Join-Path $logDirectory ("evidence-{0}-{1}" -f $Target, $buildStamp)
} else {
    $evidenceDirectory = [IO.Path]::GetFullPath($EvidenceDirectory, $projectRoot)
    $logsPrefix = [IO.Path]::GetFullPath($logDirectory) + [IO.Path]::DirectorySeparatorChar
    if (-not $evidenceDirectory.StartsWith($logsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '本次构建证据目录必须位于项目 .tools/logs 内。'
    }
    $logPath = Join-Path $evidenceDirectory 'build.log'
}
if (Test-Path -LiteralPath $evidenceDirectory) { throw '构建证据目录已存在，拒绝覆盖历史记录。' }
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $evidenceDirectory 'source-manifest.json'), $sourceManifestText + "`n", [Text.UTF8Encoding]::new($false))
$outputRelativePath = switch ($Target) {
    'WindowsDebug' { 'build/windows/x64/runner/Debug' }
    'WindowsRelease' { 'build/windows/x64/runner/Release' }
    'AndroidDebug' { 'build/app/outputs/flutter-apk/app-x86_64-mobile-debug.apk' }
    'AndroidRelease' { 'build/app/outputs/flutter-apk/app-arm64-v8a-mobile-release.apk' }
    'AndroidTvDebug' { 'build/app/outputs/flutter-apk/app-x86_64-tv-debug.apk' }
    'AndroidTvRelease' { 'build/app/outputs/flutter-apk/app-tv-release.apk' }
}
$outputPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $outputRelativePath))

# 只回收本目标旧产物到忽略目录，保留中间缓存；运行中的窗口不会被终止或覆盖。
if (Test-Path -LiteralPath $outputPath) {
    if ($Target.StartsWith('Windows')) {
        if (-not $isWindowsHost) { throw 'Windows 目标只能在 Windows 主机上构建。' }
        $activeOutput = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($outputPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($activeOutput.Count -gt 0) { throw '目标输出目录仍有应用运行，拒绝覆盖；请在用户结束操作后再构建。' }
    }
    $previousRoot = Join-Path $projectRoot ('.tools/previous-artifacts/' + $Target + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    $workspacePrefix = [IO.Path]::GetFullPath($projectRoot) + [IO.Path]::DirectorySeparatorChar
    if (-not $outputPath.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Path]::GetFullPath($previousRoot).StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '产物归档路径越过项目边界。'
    }
    New-Item -ItemType Directory -Path $previousRoot -Force | Out-Null
    Move-Item -LiteralPath $outputPath -Destination (Join-Path $previousRoot ([IO.Path]::GetFileName($outputPath)))
}
# 保留 Flutter 默认的 pub 与平台注册器刷新，确保 debug/release 切换时移除开发专用插件。
# Flutter 3.47.7 在 --no-pub 下会跳过该刷新，导致 Android release 注册不存在的插件类。
$flutterArguments = switch ($Target) {
    'WindowsDebug' { @('build', 'windows', '--debug') }
    'WindowsRelease' { @('build', 'windows', '--release') }
    'AndroidDebug' { @('build', 'apk', '--flavor', 'mobile', '--debug', '--target-platform', 'android-x64', '--split-per-abi') }
    'AndroidRelease' { @('build', 'apk', '--flavor', 'mobile', '--release', '--target-platform', 'android-arm64', '--split-per-abi') }
    'AndroidTvDebug' { @('build', 'apk', '--flavor', 'tv', '--debug', '--target-platform', 'android-x64', '--split-per-abi', '--dart-define=KAZUMI_TELEVISION=true') }
    'AndroidTvRelease' { @('build', 'apk', '--flavor', 'tv', '--release', '--target-platform', 'android-arm,android-arm64', '--dart-define=KAZUMI_TELEVISION=true') }
}
# Windows 跨盘缓存会触发 Kotlin 路径计算异常，直接向本次 Gradle 构建传递项目参数。
# 不改全局 Gradle 配置、不迁移全局 Pub 缓存，也不改变任何依赖版本。
if ($isWindowsHost -and $Target.StartsWith('Android')) {
    $flutterArguments += '--android-project-arg=kotlin.incremental=false'
}
$effectiveUpdateUrl = Resolve-KazumiPlusUpdateUrl -ProjectRoot $projectRoot -ExplicitUpdateUrl $UpdateUrl
$flutterArguments += "--dart-define=KAZUMI_PLUS_UPDATE_URL=$effectiveUpdateUrl"

Push-Location $projectRoot
try {
    foreach ($environmentName in $environmentUpdates.Keys) {
        [Environment]::SetEnvironmentVariable($environmentName, $environmentUpdates[$environmentName], 'Process')
    }
    Write-Output "构建目标：$Target；日志：$logPath"
    Write-Output "更新地址：$effectiveUpdateUrl"
    # 完整保存命令输出；首次遥测提示属于普通文本，不能直接作为 JSON 解析。
    $flutterVersionOutputPath = Join-Path $evidenceDirectory 'flutter-version-output.log'
    $flutterVersionJsonPath = Join-Path $evidenceDirectory 'flutter-version.json'
    & $flutterCommand --version --machine 2>&1 | Out-File -LiteralPath $flutterVersionOutputPath -Encoding utf8
    $flutterVersionExitCode = $LASTEXITCODE
    if ($flutterVersionExitCode -ne 0) { throw "无法读取 Flutter 版本，退出码 $flutterVersionExitCode；原始输出：$flutterVersionOutputPath" }
    try {
        $flutterVersionJson = ConvertTo-FlutterVersionJson (Get-Content -LiteralPath $flutterVersionOutputPath -Raw -Encoding utf8)
    } catch {
        throw "无法解析 Flutter 版本；原始输出：$flutterVersionOutputPath；错误：$($_.Exception.Message)"
    }
    [IO.File]::WriteAllText($flutterVersionJsonPath, $flutterVersionJson + "`n", [Text.UTF8Encoding]::new($false))
    $flutterVersion = Get-Content -LiteralPath $flutterVersionJsonPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($flutterVersion.frameworkVersion -ne '3.47.7') { throw '本项目冻结使用 Flutter 3.47.7，拒绝其他 SDK。' }
    & $flutterCommand @flutterArguments 2>&1 | Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter 构建失败，退出码 $LASTEXITCODE，请查看 $logPath"
    }
    if (-not (Test-Path -LiteralPath $outputPath)) { throw "构建没有生成本次目标产物：$outputRelativePath" }
    $afterManifestText = ConvertTo-Json -InputObject (Get-SourceManifest) -Depth 4 -Compress
    if ($afterManifestText -ne $sourceManifestText) { throw '构建期间源码发生变化；请冻结并提交当前源码后重新构建。' }

    $certificateFingerprint = $null
    if ($Target.StartsWith('Android')) {
        $androidSdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { $env:ANDROID_HOME }
        if ([string]::IsNullOrWhiteSpace($androidSdk)) {
            $localPropertiesPath = Join-Path $projectRoot 'android/local.properties'
            if (Test-Path -LiteralPath $localPropertiesPath) {
                $localPropertiesText = Get-Content -LiteralPath $localPropertiesPath -Raw -Encoding utf8
                if ($localPropertiesText -match '(?m)^[ \t]*sdk\.dir[ \t]*[:=][ \t]*(.*)$') {
                    $androidSdk = ConvertFrom-JavaPropertyEscapes $Matches[1].TrimEnd("`r")
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($androidSdk)) { throw 'ANDROID_SDK_ROOT、ANDROID_HOME 和 local.properties 均未提供 SDK 路径。' }
        $toolsDirectory = Join-Path $androidSdk 'build-tools/36.0.0'
        $signerName = if ($isWindowsHost) { 'apksigner.bat' } else { 'apksigner' }
        $aaptName = if ($isWindowsHost) { 'aapt2.exe' } else { 'aapt2' }
        & (Join-Path $toolsDirectory $signerName) verify --verbose --print-certs $outputPath 2>&1 | Out-File (Join-Path $evidenceDirectory 'apk-signature.txt') -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw 'APK 签名验证失败。' }
        $signatureText = Get-Content (Join-Path $evidenceDirectory 'apk-signature.txt') -Raw
        if ($signatureText -notmatch 'certificate SHA-256 digest:\s*([0-9a-fA-F]{64})') { throw '无法提取 APK 公钥指纹。' }
        $certificateFingerprint = $Matches[1].ToLowerInvariant()
        $pinName = if ($Target -eq 'AndroidTvRelease') { 'tv-release-certificate.json' } elseif ($Target -in @('AndroidDebug', 'AndroidRelease')) { 'mobile-debug-certificate.json' } else { $null }
        if ($pinName) {
            $pin = Get-Content (Join-Path $projectRoot ('scripts/signing/' + $pinName)) -Raw | ConvertFrom-Json
            if ($certificateFingerprint -ne $pin.certificateSha256) {
                throw "APK 实际签名与固定应用身份不一致（实际：$certificateFingerprint，期望：$($pin.certificateSha256)）。"
            }
        }
        & (Join-Path $toolsDirectory $aaptName) dump badging $outputPath 2>&1 | Out-File (Join-Path $evidenceDirectory 'apk-badging.txt') -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw 'APK 清单读取失败。' }
        $badgingText = Get-Content (Join-Path $evidenceDirectory 'apk-badging.txt') -Raw
        $expectedPackage = if ($Target.StartsWith('AndroidTv')) { 'app.kazumiplus.client.tv' } else { 'app.kazumiplus.client' }
        if ($badgingText -notmatch ("package: name='" + [regex]::Escape($expectedPackage) + "'")) { throw 'APK 应用包名不符合目标。' }
        if ($badgingText -notmatch '(?m)^native-code:\s*(.+)$') { throw 'APK 未包含原生 ABI。' }
        $actualAbis = @([regex]::Matches($Matches[1], "'([^']+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
        $expectedAbis = if ($Target -eq 'AndroidTvRelease') { @('arm64-v8a', 'armeabi-v7a') } elseif ($Target.EndsWith('Debug')) { @('x86_64') } else { @('arm64-v8a') }
        if (@(Compare-Object $expectedAbis $actualAbis).Count -gt 0) { throw 'APK 实际 ABI 与目标不一致。' }
    }
    # 保留原手机端产物别名，现有文档和外部安装流程无需因 flavor 切换而失效。
    if ($Target -eq 'AndroidDebug') {
        Copy-Item -LiteralPath $outputPath -Destination 'build/app/outputs/flutter-apk/app-x86_64-debug.apk' -Force
    } elseif ($Target -eq 'AndroidRelease') {
        Copy-Item -LiteralPath $outputPath -Destination 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk' -Force
    }
    $outputFiles = if ($Target.StartsWith('Windows')) { @(Get-ChildItem -LiteralPath $outputPath -Recurse -File | Where-Object Extension -ne '.pdb') } else { @(Get-Item -LiteralPath $outputPath) }
    $artifactRecords = @(foreach ($artifact in $outputFiles) {
        [ordered]@{path = [IO.Path]::GetRelativePath($projectRoot, $artifact.FullName).Replace('\', '/'); bytes = $artifact.Length; sha256 = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    [ordered]@{status = 'built_not_device_accepted'; target = $Target; source_commit = $sourceCommit; source_dirty = $sourceDirty; source_manifest_sha256 = $sourceDigest; signing_certificate_sha256 = $certificateFingerprint; update_url = $effectiveUpdateUrl; update_url_configured = (-not [string]::IsNullOrWhiteSpace($effectiveUpdateUrl)); artifacts = $artifactRecords} |
        ConvertTo-Json -Depth 6 | Set-Content (Join-Path $evidenceDirectory 'result.json') -Encoding utf8
    Write-Output "构建成功：$Target"
    Write-Output "构建证据：$evidenceDirectory"
}
finally {
    foreach ($environmentName in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($environmentName, $previousEnvironment[$environmentName], 'Process')
    }
    Pop-Location
}
