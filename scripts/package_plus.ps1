#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('All', 'Windows', 'WindowsInstaller', 'Android', 'AndroidTv')]
    [string]$Target = 'All',
    [switch]$AllowDirty,
    [switch]$OpenOutput,
    [string]$UpdateUrl = ''
)

# 将已核验的构建结果整理成独立批次，失败批次保留 .partial 后缀。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'update_url.ps1')
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$lockStream = $null
$transcriptStarted = $false
$runDirectory = $null
$logDirectory = $null
$runState = $null

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-JsonFile([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12) + "`n", $utf8)
}

# 构建脚本采用相同的 Git 文件清单；比较真实源码，包含未提交的新文件。
function Get-SourceManifestText {
    $paths = @(& git -C $projectRoot -c core.quotepath=false ls-files --cached --others --exclude-standard) | Sort-Object -Unique
    if ($LASTEXITCODE -ne 0) { throw '无法读取源码文件清单。' }
    $records = @(foreach ($relativePath in $paths) {
        $absolutePath = Join-Path $projectRoot $relativePath
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            [ordered]@{path = $relativePath; sha256 = (Get-Sha256 $absolutePath)}
        }
    })
    return ConvertTo-Json -InputObject $records -Depth 4 -Compress
}

function Assert-FileRecord([string]$Path, $Record) {
    $file = Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or $file.Length -ne $Record.bytes -or (Get-Sha256 $Path) -ne $Record.sha256) {
        throw "产物与本次构建证据不一致：$Path"
    }
}

function Get-ProjectFile([string]$RelativePath) {
    $fullPath = [IO.Path]::GetFullPath($RelativePath, $projectRoot)
    $prefix = $projectRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw '构建文件路径越过项目边界。' }
    return $fullPath
}

# ZIP 直接从构建白名单生成，不往 Release 目录写入文件。
function New-VerifiedWindowsZip($BuildResult, [string]$Destination, [string]$SourceManifestText) {
    $bundleRoot = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    $bundlePrefix = $bundleRoot + [IO.Path]::DirectorySeparatorChar
    $expectedEntries = [ordered]@{}
    foreach ($record in $BuildResult.artifacts) {
        $source = Get-ProjectFile $record.path
        if (-not $source.StartsWith($bundlePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Windows 构建证据包含运行目录以外的文件。' }
        Assert-FileRecord $source $record
        $entryName = [IO.Path]::GetRelativePath($bundleRoot, $source).Replace('\', '/')
        if ($expectedEntries.Contains($entryName)) { throw 'Windows 构建清单包含重复文件。' }
        $expectedEntries[$entryName] = [ordered]@{source = $source; bytes = $record.bytes; sha256 = $record.sha256}
    }
    foreach ($requiredFile in @('kazumi_plus.exe', 'flutter_windows.dll', 'libmpv-2.dll', 'media_kit_event_loop.dll', 'ech_http.dll', 'dartjni.dll', 'WebView2Loader.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NativeAssetsManifest.json')) {
        if (-not $expectedEntries.Contains($requiredFile)) { throw "Windows 运行文件缺失：$requiredFile" }
        if ($expectedEntries[$requiredFile].bytes -le 0) { throw "Windows 运行文件为空：$requiredFile" }
    }
    # 安装包必须同时包含原生库及对应绑定，防止不完整的 hook 缓存产出无法播放的程序。
    $nativeManifest = Get-Content -LiteralPath $expectedEntries['data/flutter_assets/NativeAssetsManifest.json'].source -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($nativeManifest -isnot [Collections.IDictionary] -or -not $nativeManifest.ContainsKey('native-assets') -or
        $nativeManifest['native-assets'] -isnot [Collections.IDictionary] -or -not $nativeManifest['native-assets'].ContainsKey('windows_x64') -or
        $nativeManifest['native-assets']['windows_x64'] -isnot [Collections.IDictionary]) {
        throw 'Windows 包缺少 x64 原生库绑定清单。'
    }
    $nativeMappings = $nativeManifest['native-assets']['windows_x64']
    $requiredAssets = [ordered]@{
        'package:media_kit/libmpv' = 'libmpv-2.dll'
        'package:media_kit/src/player/native/core/native_event_loop_bindings.dart' = 'media_kit_event_loop.dll'
        'package:ech_http/ech_http_bindings' = 'ech_http.dll'
    }
    foreach ($assetId in $requiredAssets.Keys) {
        if (-not $nativeMappings.ContainsKey($assetId)) { throw "Windows 原生库绑定缺失：$assetId" }
        $binding = $nativeMappings[$assetId]
        if ($binding -isnot [array] -or $binding.Count -ne 2 -or $binding[0] -ne 'absolute' -or $binding[1] -ne $requiredAssets[$assetId]) {
            throw "Windows 原生库绑定与随包文件不一致：$assetId"
        }
    }
    $licensePath = Join-Path $projectRoot 'LICENSE'
    $licenseRecords = @(($SourceManifestText | ConvertFrom-Json) | Where-Object path -eq 'LICENSE')
    if ($licenseRecords.Count -ne 1 -or (Get-Sha256 $licensePath) -ne $licenseRecords[0].sha256) { throw 'LICENSE 与本次源码清单不符。' }
    $expectedEntries['LICENSE'] = [ordered]@{source = $licensePath; bytes = (Get-Item -LiteralPath $licensePath).Length; sha256 = $licenseRecords[0].sha256}
    $archive = [IO.Compression.ZipFile]::Open($Destination, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $expectedEntries.Keys) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $expectedEntries[$entryName].source, $entryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    $verifiedCount = 0
    $archive = [IO.Compression.ZipFile]::OpenRead($Destination)
    try {
        if ($archive.Entries.Count -ne $expectedEntries.Count) { throw 'Windows ZIP 文件数与构建清单不符。' }
        $seen = @{}
        foreach ($entry in $archive.Entries) {
            if ($seen.ContainsKey($entry.FullName) -or -not $expectedEntries.Contains($entry.FullName)) { throw 'Windows ZIP 含有重复或清单外的条目。' }
            $seen[$entry.FullName] = $true
            $expected = $expectedEntries[$entry.FullName]
            $stream = $entry.Open()
            $hasher = [Security.Cryptography.SHA256]::Create()
            try { $hash = [Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant() }
            finally { $hasher.Dispose(); $stream.Dispose() }
            if ($entry.Length -ne $expected.bytes -or $hash -ne $expected.sha256) { throw "Windows ZIP 文件回读失败：$($entry.FullName)" }
            $verifiedCount++
        }
    } finally { $archive.Dispose() }
    return $verifiedCount
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw '此一键打包入口需要 Windows。' }
    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { throw '未找到 Git，请先安装并加入 PATH。' }
    $logsRoot = Join-Path $projectRoot '.tools/logs'
    New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
    # 句柄随进程退出自动释放，异常退出后无需手动删除锁文件。
    try {
        $lockStream = [IO.File]::Open((Join-Path $logsRoot 'package-plus.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] { throw '已有一键打包任务正在运行，请等待其完成后再启动。' }

    $commitOutput = @(& git -C $projectRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $commitOutput.Count -ne 1) { throw '无法读取项目 Git 提交。' }
    $sourceCommit = $commitOutput[0].Trim()
    $statusOutput = @(& git -C $projectRoot status --porcelain=v1 --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw '无法读取工作区状态。' }
    $sourceDirty = $statusOutput.Count -gt 0
    if ($sourceDirty -and -not $AllowDirty) { throw '工作区有未提交改动。双击入口会打包当前工作区；严格打包请先提交全部源码。' }
    $versionText = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
    if ($versionText -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+\d+)?\s*$') { throw '无法读取 pubspec.yaml 的应用版本。' }
    $applicationVersion = $Matches[1]
    $effectiveUpdateUrl = Resolve-KazumiPlusUpdateUrl -ProjectRoot $projectRoot -ExplicitUpdateUrl $UpdateUrl
    $runId = '{0}-{1}-{2}' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), $sourceCommit.Substring(0, 8), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $packagesRoot = Join-Path $projectRoot 'dist/packages'
    $finalDirectory = Join-Path $packagesRoot $runId
    $runDirectory = $finalDirectory + '.partial'
    $logDirectory = Join-Path $logsRoot ('package-' + $runId)
    New-Item -ItemType Directory -Path $runDirectory, $logDirectory -Force | Out-Null
    Start-Transcript -LiteralPath (Join-Path $logDirectory 'package.log') | Out-Null
    $transcriptStarted = $true
    $runState = [ordered]@{status = 'running'; phase = 'preparing_dependencies'; run_id = $runId; target = $Target; source_commit = $sourceCommit; source_dirty = $sourceDirty; update_url = $effectiveUpdateUrl; output_directory = $runDirectory; started_at = (Get-Date -Format o)}
    Write-JsonFile (Join-Path $logDirectory 'result.json') $runState
    Write-Host "开始打包：Kazumi Plus $applicationVersion" -ForegroundColor Cyan
    Write-Host "源码提交：$sourceCommit；未提交改动：$sourceDirty"
    Write-Host "更新地址：$effectiveUpdateUrl"
    Write-Host "日志目录：$logDirectory"

    $installerToolchain = $null
    if ($Target -eq 'WindowsInstaller') {
        $installerToolchain = & (Join-Path $PSScriptRoot 'prepare_windows_installer.ps1') -LogDirectory (Join-Path $logDirectory 'installer-toolchain')
        if ($installerToolchain.status -ne 'ready') { throw 'Windows 安装包工具准备未完成。' }
    }

    # 先恢复可读取的依赖及平台注册文件，再冻结真正参与编译的源码。
    $preparationDirectory = Join-Path $logDirectory 'preparation'
    $preparation = & (Join-Path $PSScriptRoot 'prepare_plus_build.ps1') -LogDirectory $preparationDirectory
    if ($preparation.status -ne 'prepared') { throw '依赖准备未完成，停止打包。' }
    $preparedFlutterRoot = Split-Path -Parent (Split-Path -Parent $preparation.flutter_command)
    $dartCommand = Join-Path $preparedFlutterRoot 'bin/cache/dart-sdk/bin/dart.exe'
    $preparedCommit = @(& git -C $projectRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $preparedCommit.Count -ne 1 -or $preparedCommit[0].Trim() -ne $sourceCommit) { throw '准备依赖时 Git 提交发生变化。' }
    $statusOutput = @(& git -C $projectRoot status --porcelain=v1 --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) { throw '无法读取准备后的工作区状态。' }
    $sourceDirty = $statusOutput.Count -gt 0
    if ($sourceDirty -and -not $AllowDirty) { throw '依赖准备更新了生成文件；严格模式请先检查并提交这些变更。' }
    $sourceManifestText = Get-SourceManifestText
    $sourceDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes($sourceManifestText))).ToLowerInvariant()
    $runState.source_dirty = $sourceDirty
    $runState['source_manifest_sha256'] = $sourceDigest
    $runState.phase = 'building'
    Write-JsonFile (Join-Path $logDirectory 'result.json') $runState
    Write-Host "依赖准备完成：$($preparation.package_count) 个包；已冻结本次源码。" -ForegroundColor Green
    $packageEvidenceRoot = Join-Path $runDirectory 'evidence'
    New-Item -ItemType Directory -Path $packageEvidenceRoot -Force | Out-Null
    Copy-Item -LiteralPath $preparationDirectory -Destination (Join-Path $packageEvidenceRoot 'preparation') -Recurse
    $buildTargets = @(switch ($Target) {
        'All' { @('WindowsRelease', 'AndroidRelease', 'AndroidTvRelease') }
        'Windows' { @('WindowsRelease') }
        'WindowsInstaller' { @('WindowsRelease') }
        'Android' { @('AndroidRelease') }
        'AndroidTv' { @('AndroidTvRelease') }
    })
    $distributionRecords = @()
    $targetIndex = 0
    foreach ($buildTarget in $buildTargets) {
        $targetIndex++
        Write-Host "`n[$targetIndex/$($buildTargets.Count)] 构建并打包：$buildTarget" -ForegroundColor Cyan
        # 每个目标开始前用同一 Dart SDK 实际读取依赖，防止缓存异常引发连锁编译错误。
        $dependencyCheckPath = Join-Path $logDirectory ("dependencies-$buildTarget.json")
        $dependencyErrorPath = Join-Path $logDirectory ("dependencies-$buildTarget.stderr.log")
        & $dartCommand (Join-Path $PSScriptRoot 'inspect_build_dependencies.dart') $projectRoot 2> $dependencyErrorPath |
            Out-File -LiteralPath $dependencyCheckPath -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw "本次目标的依赖无法读取，已停止编译；检查记录：$dependencyCheckPath；错误日志：$dependencyErrorPath" }
        $targetDependencies = Get-Content -LiteralPath $dependencyCheckPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($targetDependencies.status -ne 'readable' -or $targetDependencies.package_count -le 0 -or
            $targetDependencies.failure_count -ne 0 -or $targetDependencies.readable_pubspec_count -ne $targetDependencies.package_count) {
            throw "本次目标的依赖检查结果未通过，已停止编译：$dependencyCheckPath"
        }
        $evidenceDirectory = Join-Path $logDirectory $buildTarget
        $buildParameters = @{Target = $buildTarget; EvidenceDirectory = $evidenceDirectory; AllowDirty = $AllowDirty; FlutterRoot = $preparedFlutterRoot; UpdateUrl = $effectiveUpdateUrl}
        & (Join-Path $PSScriptRoot 'build_plus.ps1') @buildParameters
        $buildResult = Get-Content -LiteralPath (Join-Path $evidenceDirectory 'result.json') -Raw | ConvertFrom-Json
        if ($buildResult.status -ne 'built_not_device_accepted' -or $buildResult.target -ne $buildTarget -or
            $buildResult.source_commit -ne $sourceCommit -or $buildResult.source_dirty -ne $sourceDirty -or
            $buildResult.source_manifest_sha256 -ne $sourceDigest -or
            $buildResult.update_url -ne $effectiveUpdateUrl) { throw '本次构建来源或更新地址与打包开始时的配置不一致。' }
        $buildManifestText = Get-Content -LiteralPath (Join-Path $evidenceDirectory 'source-manifest.json') -Raw
        if ($buildManifestText.TrimEnd("`r", "`n") -ne $sourceManifestText) { throw '本次构建源码文件清单不一致。' }
        $suffix = switch ($buildTarget) {
            'WindowsRelease' { 'windows-x64.zip' }
            'AndroidRelease' { 'android-arm64.apk' }
            'AndroidTvRelease' { 'android-tv-arm.apk' }
        }
        $fileName = "Kazumi-Plus-$applicationVersion-$suffix"
        $destination = Join-Path $runDirectory $fileName
        $zipVerifiedFiles = $null
        if ($buildTarget -eq 'WindowsRelease') {
            $zipVerifiedFiles = New-VerifiedWindowsZip $buildResult $destination $sourceManifestText
            Write-Host "Windows ZIP 回读通过：$zipVerifiedFiles 个文件。"
        } else {
            if (@($buildResult.artifacts).Count -ne 1) { throw 'APK 构建证据应只包含一个目标文件。' }
            $apkRecord = $buildResult.artifacts[0]
            $apkSource = Get-ProjectFile $apkRecord.path
            Assert-FileRecord $apkSource $apkRecord
            [IO.File]::Copy($apkSource, $destination, $false)
            Assert-FileRecord $destination $apkRecord
            Write-Host 'APK 复制及 SHA256 回读通过。'
        }
        $distributionRecords += [ordered]@{target = $buildTarget; file = $fileName; bytes = (Get-Item -LiteralPath $destination).Length; sha256 = (Get-Sha256 $destination); zip_verified_files = $zipVerifiedFiles; signing_certificate_sha256 = $buildResult.signing_certificate_sha256; evidence_directory = "evidence/$buildTarget"}
        $packageEvidenceRoot = Join-Path $runDirectory 'evidence'
        New-Item -ItemType Directory -Path $packageEvidenceRoot -Force | Out-Null
        Copy-Item -LiteralPath $evidenceDirectory -Destination (Join-Path $packageEvidenceRoot $buildTarget) -Recurse
        Copy-Item -LiteralPath $dependencyCheckPath -Destination (Join-Path $packageEvidenceRoot "$buildTarget/dependency-check.json")
        if ($Target -eq 'WindowsInstaller' -and $buildTarget -eq 'WindowsRelease') {
            $runState.phase = 'building_installer'
            Write-JsonFile (Join-Path $logDirectory 'result.json') $runState
            $installerEvidence = Join-Path $logDirectory 'WindowsInstaller'
            $installerResult = & (Join-Path $PSScriptRoot 'build_windows_installer.ps1') -WindowsZipPath $destination -WindowsZipSha256 (Get-Sha256 $destination) -ApplicationVersion $applicationVersion -OutputDirectory $runDirectory -LogDirectory $installerEvidence -Toolchain $installerToolchain
            $distributionRecords += [ordered]@{target = 'WindowsInstaller'; file = $installerResult.file; bytes = $installerResult.bytes; sha256 = $installerResult.sha256; app_id = $installerResult.app_id; payload_file_count = $installerResult.payload_file_count; signing_status = $installerResult.signing_status; evidence_directory = 'evidence/WindowsInstaller'}
            Copy-Item -LiteralPath $installerEvidence -Destination (Join-Path $packageEvidenceRoot 'WindowsInstaller') -Recurse
            Copy-Item -LiteralPath (Join-Path $logDirectory 'installer-toolchain') -Destination (Join-Path $packageEvidenceRoot 'installer-toolchain') -Recurse
        }
    }

    # 全批次同源才发布成品目录，打包时改动源码也会停止。
    if ((Get-SourceManifestText) -ne $sourceManifestText) { throw '打包期间源码发生变化，请停止修改后重新运行。' }
    $finalCommit = @(& git -C $projectRoot rev-parse HEAD)
    if ($LASTEXITCODE -ne 0 -or $finalCommit.Count -ne 1 -or $finalCommit[0].Trim() -ne $sourceCommit) { throw '打包期间 Git 提交发生变化。' }
    [IO.File]::WriteAllText((Join-Path $runDirectory 'source-manifest.json'), $sourceManifestText + "`n", $utf8)
    $manifest = [ordered]@{schema_version = 1; status = 'packaged_and_verified'; run_id = $runId; application_version = $applicationVersion; completed_at = (Get-Date -Format o); source_commit = $sourceCommit; source_dirty = $sourceDirty; source_manifest_sha256 = $sourceDigest; update_url = $effectiveUpdateUrl; device_accepted = $false; artifacts = $distributionRecords; build_log_directory = [IO.Path]::GetRelativePath($projectRoot, $logDirectory).Replace('\', '/'); note = '本批次完成本机构建及产物核验，设备播放验收沿用独立记录。Apple 平台使用既有云构建流程。'}
    Write-JsonFile (Join-Path $runDirectory 'build-manifest.json') $manifest
    $checksumFiles = @($distributionRecords.file) + @('build-manifest.json', 'source-manifest.json')
    $checksumLines = @($checksumFiles | ForEach-Object { (Get-Sha256 (Join-Path $runDirectory $_)) + '  ' + $_ })
    [IO.File]::WriteAllText((Join-Path $runDirectory 'SHA256SUMS.txt'), ($checksumLines -join "`n") + "`n", $utf8)
    foreach ($line in Get-Content -LiteralPath (Join-Path $runDirectory 'SHA256SUMS.txt')) {
        if ($line -notmatch '^([a-f0-9]{64})  (.+)$') { throw 'SHA256 校验文件格式不正确。' }
        if ((Get-Sha256 (Join-Path $runDirectory $Matches[2])) -ne $Matches[1]) { throw 'SHA256 最终回读不一致。' }
    }
    [IO.Directory]::Move($runDirectory, $finalDirectory)
    $runState.status = 'packaged_and_verified'
    $runState.phase = 'complete'
    $runState.output_directory = $finalDirectory
    $runState['completed_at'] = Get-Date -Format o
    Write-JsonFile (Join-Path $logDirectory 'result.json') $runState
    Write-Host "`n打包完成：$finalDirectory" -ForegroundColor Green
    foreach ($record in $distributionRecords) { Write-Host "  $($record.file)" }
    Write-Host '  SHA256SUMS.txt、build-manifest.json、source-manifest.json 及 evidence/'
    if ($OpenOutput) {
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $finalDirectory + '"') | Out-Null }
        catch { Write-Warning "安装包已生成，打开文件夹失败，请直接访问：$finalDirectory" }
    }
} catch {
    $failureMessage = $_.Exception.Message
    if ($null -ne $runState) {
        $runState.status = 'failed'
        $runState['error'] = $failureMessage
        $runState['failed_at'] = Get-Date -Format o
        Write-JsonFile (Join-Path $logDirectory 'result.json') $runState
    }
    Write-Host "`n打包失败：$failureMessage" -ForegroundColor Red
    if ($logDirectory) { Write-Host "日志目录：$logDirectory" }
    if ($runDirectory) { Write-Host "未完成批次：$runDirectory" }
    exit 1
} finally {
    if ($transcriptStarted) { Stop-Transcript | Out-Null }
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
