#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory,
    [string]$FlutterRoot = ''
)

# 依赖准备发生在打包源码冻结之前；全程只通过成功输出流返回一个结果对象。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
. (Join-Path $PSScriptRoot 'flutter_version_json.ps1')
$utf8 = [Text.UTF8Encoding]::new($false)
$logsRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.tools/logs'))
$preparationDirectory = [IO.Path]::GetFullPath($LogDirectory, $projectRoot)
$logsPrefix = $logsRoot + [IO.Path]::DirectorySeparatorChar
if (-not $preparationDirectory.StartsWith($logsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '依赖准备证据目录必须位于项目 .tools/logs 内。'
}
if (Test-Path -LiteralPath $preparationDirectory) {
    throw '依赖准备证据目录已存在，拒绝覆盖历史记录。'
}
New-Item -ItemType Directory -Path $preparationDirectory -Force | Out-Null

# Flutter 允许刷新这些平台注册文件；其他源码及锁文件都必须保持不变。
$generatedPaths = @(
    'windows/flutter/generated_plugin_registrant.cc',
    'windows/flutter/generated_plugin_registrant.h',
    'windows/flutter/generated_plugins.cmake',
    'linux/flutter/generated_plugin_registrant.cc',
    'linux/flutter/generated_plugin_registrant.h',
    'linux/flutter/generated_plugins.cmake',
    'macos/Flutter/GeneratedPluginRegistrant.swift'
)

function Write-PreparationJson([string]$Name, [object]$Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 12
    [IO.File]::WriteAllText((Join-Path $preparationDirectory $Name), $json + "`n", $utf8)
}

function Get-PreparationSourceManifest {
    # 使用 NUL 分隔读取 Git 路径，保留带空格或换行的真实文件名。
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.WorkingDirectory = $projectRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    foreach ($argument in @('ls-files', '--cached', '--others', '--exclude-standard', '-z')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $outputText = $stdoutTask.GetAwaiter().GetResult()
        $errorText = $stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "无法读取 Git 源码清单：$errorText" }
    } finally {
        $process.Dispose()
    }
    $paths = @($outputText.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries) | Sort-Object -Unique)
    if ($paths.Count -eq 0) { throw 'Git 源码清单为空，无法建立依赖准备前后快照。' }
    foreach ($relativePath in $paths) {
        $absolutePath = Join-Path $projectRoot $relativePath
        $exists = Test-Path -LiteralPath $absolutePath -PathType Leaf
        [pscustomobject][ordered]@{
            path = $relativePath
            exists = $exists
            sha256 = if ($exists) { (Get-FileHash -LiteralPath $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        }
    }
}

function Get-PreparationChanges([object[]]$Before, [object[]]$After) {
    $beforeMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $afterMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($record in $Before) { $beforeMap[$record.path] = $record }
    foreach ($record in $After) { $afterMap[$record.path] = $record }
    $allPaths = @(@($beforeMap.Keys) + @($afterMap.Keys) | Sort-Object -Unique)
    foreach ($relativePath in $allPaths) {
        $beforeRecord = if ($beforeMap.ContainsKey($relativePath)) { $beforeMap[$relativePath] } else { $null }
        $afterRecord = if ($afterMap.ContainsKey($relativePath)) { $afterMap[$relativePath] } else { $null }
        $beforeExists = $null -ne $beforeRecord -and $beforeRecord.exists
        $afterExists = $null -ne $afterRecord -and $afterRecord.exists
        $beforeHash = if ($null -ne $beforeRecord) { $beforeRecord.sha256 } else { $null }
        $afterHash = if ($null -ne $afterRecord) { $afterRecord.sha256 } else { $null }
        if ($beforeHash -eq $afterHash -and $beforeExists -eq $afterExists -and
            ($null -eq $beforeRecord) -eq ($null -eq $afterRecord)) { continue }
        $changeType = if (-not $beforeExists -and $afterExists) { 'added' } elseif ($beforeExists -and -not $afterExists) { 'deleted' } else { 'modified' }
        [pscustomobject][ordered]@{
            path = $relativePath
            change = $changeType
            before_sha256 = $beforeHash
            after_sha256 = $afterHash
            allowed = $changeType -eq 'modified' -and $generatedPaths -ccontains $relativePath
        }
    }
}

$beforeManifest = @()
$changes = @()
$generatedChanges = @()
$nativeCacheInvalidations = @()
$packageCount = 0
$flutterCommand = $null
$preparationError = $null
$offlineExitCode = $null
$onlineExitCode = $null
$snapshotAvailable = $false
Push-Location $projectRoot
try {
    $beforeManifest = @(Get-PreparationSourceManifest)
    Write-PreparationJson 'source-before.json' $beforeManifest
    $snapshotAvailable = $true

    # 一并保存依赖路径和插件元数据，便于定位桌面启动时的暂时性读取问题。
    $metadataPaths = @('.dart_tool/package_config.json', '.dart_tool/package_graph.json', '.flutter-plugins-dependencies')
    $backupRecords = @(foreach ($relativePath in ($generatedPaths + $metadataPaths)) {
        $sourcePath = Join-Path $projectRoot $relativePath
        $exists = Test-Path -LiteralPath $sourcePath -PathType Leaf
        if ($exists) {
            $backupPath = Join-Path $preparationDirectory ('backup/' + $relativePath)
            New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $sourcePath -Destination $backupPath
        }
        [ordered]@{path = $relativePath; existed = $exists}
    })
    Write-PreparationJson 'backup-manifest.json' $backupRecords
    $lockPath = Join-Path $projectRoot 'pubspec.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw '缺少 pubspec.lock，无法按冻结依赖准备构建。' }
    $lockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash
    Copy-Item -LiteralPath $lockPath -Destination (Join-Path $preparationDirectory 'pubspec.lock.before')

    # 与 build_plus.ps1 一致：项目独立 SDK 优先，找不到时才查询 PATH。
    $isWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $flutterFileName = if ($isWindowsHost) { 'flutter.bat' } else { 'flutter' }
    if ([string]::IsNullOrWhiteSpace($FlutterRoot)) { $FlutterRoot = Join-Path $projectRoot '.tools/flutter' }
    $flutterCommand = [IO.Path]::GetFullPath((Join-Path $FlutterRoot "bin/$flutterFileName"), $projectRoot)
    if (-not (Test-Path -LiteralPath $flutterCommand -PathType Leaf)) {
        $installedFlutter = Get-Command $flutterFileName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $installedFlutter) { throw '未找到 Flutter SDK，请通过 -FlutterRoot 指定 Flutter 3.47.7。' }
        $flutterCommand = [IO.Path]::GetFullPath($installedFlutter.Source)
    }
    $flutterVersionOutputPath = Join-Path $preparationDirectory 'flutter-version-output.log'
    & $flutterCommand --version --machine 2>&1 | Out-File -LiteralPath $flutterVersionOutputPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "无法读取 Flutter 版本，退出码 $LASTEXITCODE；原始输出：$flutterVersionOutputPath" }
    try {
        $versionJson = ConvertTo-FlutterVersionJson ([IO.File]::ReadAllText($flutterVersionOutputPath, $utf8))
        $version = ConvertFrom-Json -InputObject $versionJson
    } catch {
        throw "无法解析 Flutter 版本；原始输出：$flutterVersionOutputPath；错误：$($_.Exception.Message)"
    }
    [IO.File]::WriteAllText((Join-Path $preparationDirectory 'flutter-version.json'), $versionJson + "`n", $utf8)
    if ($version.frameworkVersion -ne '3.47.7') { throw '本项目冻结使用 Flutter 3.47.7，拒绝其他 SDK。' }

    # 优先复用本地依赖；离线失败时才联网重试，两个阶段都强制遵守现有锁文件。
    Write-Host '正在准备冻结依赖并刷新平台注册文件……'
    $offlineLog = Join-Path $preparationDirectory 'pub-get-offline.log'
    & $flutterCommand pub get --offline --enforce-lockfile 2>&1 | Tee-Object -FilePath $offlineLog | ForEach-Object { Write-Host $_ }
    $offlineExitCode = $LASTEXITCODE
    if ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -ne $lockHash) {
        throw '离线依赖准备改变了 pubspec.lock，已停止；原锁文件备份保留在准备证据目录。'
    }
    if ($offlineExitCode -ne 0) {
        Write-Host "离线依赖准备未成功（退出码 $offlineExitCode），正在按同一锁文件重试联网获取。"
        $onlineLog = Join-Path $preparationDirectory 'pub-get-online.log'
        & $flutterCommand pub get --enforce-lockfile 2>&1 | Tee-Object -FilePath $onlineLog | ForEach-Object { Write-Host $_ }
        $onlineExitCode = $LASTEXITCODE
        if ($onlineExitCode -ne 0) { throw "依赖准备失败，退出码 $onlineExitCode；请查看 $onlineLog" }
    }
    if ((Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash -ne $lockHash) {
        throw '依赖准备改变了 pubspec.lock，已停止；原锁文件备份保留在准备证据目录。'
    }

    # 使用同一 SDK 的 Dart 可执行文件，从实际构建进程环境验证依赖可读性。
    $dartName = if ($isWindowsHost) { 'dart.exe' } else { 'dart' }
    $dartCommand = Join-Path (Split-Path -Parent $flutterCommand) "cache/dart-sdk/bin/$dartName"
    if (-not (Test-Path -LiteralPath $dartCommand -PathType Leaf)) { throw "Flutter SDK 内未找到 Dart：$dartCommand" }
    $dependencyCheckPath = Join-Path $preparationDirectory 'dependency-check.json'
    $dependencyErrorPath = Join-Path $preparationDirectory 'dependency-check-stderr.log'
    & $dartCommand (Join-Path $PSScriptRoot 'inspect_build_dependencies.dart') $projectRoot 2> $dependencyErrorPath |
        Out-File -LiteralPath $dependencyCheckPath -Encoding utf8
    $dependencyExitCode = $LASTEXITCODE
    if ($dependencyExitCode -ne 0) {
        throw "依赖文件无法由 Dart 读取，已阻止编译；检查结果：$dependencyCheckPath；错误日志：$dependencyErrorPath"
    }
    $dependencyResult = Get-Content -LiteralPath $dependencyCheckPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($dependencyResult.status -ne 'readable' -or $dependencyResult.package_count -le 0 -or
        $dependencyResult.failure_count -ne 0 -or $dependencyResult.readable_pubspec_count -ne $dependencyResult.package_count) {
        throw "依赖可读性检查没有通过，请查看 $dependencyCheckPath"
    }
    $packageCount = [int]$dependencyResult.package_count

    # 注册表必须包含可解析的 Windows 插件记录，防止空注册表延迟到编译时才暴露。
    $pluginManifestPath = Join-Path $projectRoot '.flutter-plugins-dependencies'
    $pluginManifest = Get-Content -LiteralPath $pluginManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($pluginManifest -isnot [Collections.IDictionary] -or -not $pluginManifest.ContainsKey('plugins') -or
        $pluginManifest.plugins -isnot [Collections.IDictionary] -or -not $pluginManifest.plugins.ContainsKey('windows') -or
        $pluginManifest.plugins.windows -isnot [array] -or $pluginManifest.plugins.windows.Count -eq 0) {
        throw 'Flutter 平台注册表缺少非空的 plugins.windows 数组，已阻止编译。'
    }
    foreach ($plugin in $pluginManifest.plugins.windows) {
        if ($plugin -isnot [Collections.IDictionary] -or -not $plugin.ContainsKey('name') -or -not $plugin.ContainsKey('path') -or
            $plugin.name -isnot [string] -or [string]::IsNullOrWhiteSpace($plugin.name) -or
            $plugin.path -isnot [string] -or [string]::IsNullOrWhiteSpace($plugin.path)) {
            throw 'Flutter 的 Windows 插件记录缺少有效的 name 或 path，已阻止编译。'
        }
    }
    Copy-Item -LiteralPath $pluginManifestPath -Destination (Join-Path $preparationDirectory 'flutter-plugins-dependencies.json')

    # 依赖曾不可读时，Flutter 可能把缺少插件 hook 的结果记为成功并长期复用。
    # 仅归档可再生成的发现阶段标记，让各目标重新发现原生库，保留已下载的库与编译缓存。
    $nativeBuildCacheRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.dart_tool/flutter_build'))
    if (Test-Path -LiteralPath $nativeBuildCacheRoot -PathType Container) {
        $cachePrefix = $nativeBuildCacheRoot + [IO.Path]::DirectorySeparatorChar
        foreach ($cacheDirectory in Get-ChildItem -LiteralPath $nativeBuildCacheRoot -Directory) {
            if (($cacheDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '原生构建缓存目录不能是重解析点。' }
            $stampPath = [IO.Path]::GetFullPath((Join-Path $cacheDirectory.FullName 'build_hooks.stamp'))
            if (-not $stampPath.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw '原生构建标记路径越过项目缓存边界。' }
            if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) { continue }
            $backupRelative = 'native-cache/' + $cacheDirectory.Name + '/build_hooks.stamp'
            $stampBackup = Join-Path $preparationDirectory $backupRelative
            New-Item -ItemType Directory -Path (Split-Path -Parent $stampBackup) -Force | Out-Null
            foreach ($cacheEvidenceName in @('build_hooks_result.json', 'build_hooks.d', 'native_assets.json', 'link_hooks_result.json')) {
                $cacheEvidencePath = Join-Path $cacheDirectory.FullName $cacheEvidenceName
                if (Test-Path -LiteralPath $cacheEvidencePath -PathType Leaf) {
                    Copy-Item -LiteralPath $cacheEvidencePath -Destination (Join-Path (Split-Path -Parent $stampBackup) $cacheEvidenceName)
                }
            }
            $stampHash = (Get-FileHash -LiteralPath $stampPath -Algorithm SHA256).Hash.ToLowerInvariant()
            Move-Item -LiteralPath $stampPath -Destination $stampBackup
            $nativeCacheInvalidations += [ordered]@{cache = $cacheDirectory.Name; backup = $backupRelative; sha256 = $stampHash}
        }
    }
    Write-Host "原生库发现记录已刷新：$($nativeCacheInvalidations.Count) 项；下载缓存和其他编译缓存保留。"
} catch {
    $preparationError = $_.Exception.Message
} finally {
    # 即使 pub 或可读性检查失败，也保存执行后的源码变化，保留可追溯的失败证据。
    if ($snapshotAvailable) {
        try {
            $afterManifest = @(Get-PreparationSourceManifest)
            Write-PreparationJson 'source-after.json' $afterManifest
            $changes = @(Get-PreparationChanges -Before $beforeManifest -After $afterManifest)
            $generatedChanges = @($changes | Where-Object allowed)
            $unexpectedChanges = @($changes | Where-Object { -not $_.allowed })
            if ($unexpectedChanges.Count -gt 0) {
                $changeError = '依赖准备期间出现不允许的源码、锁文件或新增/删除变化：' + ($unexpectedChanges.path -join '、')
                $preparationError = if ($preparationError) { "$preparationError；$changeError" } else { $changeError }
            }
        } catch {
            $snapshotError = '无法完成准备后源码核对：' + $_.Exception.Message
            $preparationError = if ($preparationError) { "$preparationError；$snapshotError" } else { $snapshotError }
        }
    }
    Pop-Location
    $result = [pscustomobject][ordered]@{
        status = if ($preparationError) { 'failed' } else { 'prepared' }
        flutter_command = $flutterCommand
        package_count = $packageCount
        generated_changes = $generatedChanges
        native_cache_invalidations = $nativeCacheInvalidations
        source_changes = $changes
        offline_exit_code = $offlineExitCode
        online_exit_code = $onlineExitCode
        log_directory = $preparationDirectory
        error = $preparationError
    }
    Write-PreparationJson 'result.json' $result
}
if ($preparationError) { throw "依赖准备失败：$preparationError；完整证据：$preparationDirectory" }
Write-Host "依赖准备完成：$packageCount 个依赖可读；证据：$preparationDirectory"
return $result
