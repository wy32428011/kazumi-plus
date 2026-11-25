#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WindowsZipPath,
    [Parameter(Mandatory)][string]$WindowsZipSha256,
    [Parameter(Mandatory)][string]$ApplicationVersion,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$LogDirectory,
    [Parameter(Mandatory)][object]$Toolchain
)

# 安装载荷只来自本次已验证的 ZIP 与 Visual Studio 的可再分发运行库。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent $PSScriptRoot
$utf8 = [Text.UTF8Encoding]::new($false)
$stageRoot = Join-Path $projectRoot ('.tools/windows-installer-staging/' + [guid]::NewGuid().ToString('N'))
$stagePrefix = [IO.Path]::GetFullPath($stageRoot) + [IO.Path]::DirectorySeparatorChar
$completed = $false

function Get-InstallerHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-InstallerJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 10) + "`n", $utf8)
}

function Get-PeMachine([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d -or $stream.Length -lt 64) { throw "运行库不是有效 PE：$Path" }
        $stream.Position = 60
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset + 6 -gt $stream.Length) { throw "运行库 PE 头无效：$Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "运行库 PE 签名无效：$Path" }
        return $reader.ReadUInt16()
    } finally { $reader.Dispose(); $stream.Dispose() }
}

try {
    foreach ($directory in @($OutputDirectory, $LogDirectory)) {
        $fullDirectory = [IO.Path]::GetFullPath($directory, $projectRoot)
        if (-not $fullDirectory.StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw '安装包输出或证据目录越过项目边界。'
        }
    }
    if (Test-Path -LiteralPath $LogDirectory) { throw '安装包证据目录已存在，拒绝覆盖。' }
    New-Item -ItemType Directory -Path $LogDirectory, $stageRoot -Force | Out-Null
    if ((Get-InstallerHash $WindowsZipPath) -ne $WindowsZipSha256) { throw 'Windows ZIP 已变化，拒绝生成安装包。' }
    if ($Toolchain.status -ne 'ready' -or (Get-InstallerHash $Toolchain.compiler_path) -ne $Toolchain.compiler_sha256) {
        throw '安装包编译器与已验证的工具记录不符。'
    }

    $payload = [ordered]@{}
    $archive = [IO.Compression.ZipFile]::OpenRead($WindowsZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrEmpty($entry.Name)) { continue }
            $relativePath = $entry.FullName.Replace('\', '/')
            $destination = [IO.Path]::GetFullPath($relativePath, $stageRoot)
            if (-not $destination.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase) -or $payload.Contains($relativePath)) {
                throw 'Windows ZIP 包含越界路径或重复文件。'
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            if ((Get-Item -LiteralPath $destination).Length -ne $entry.Length) { throw "载荷解压长度不符：$relativePath" }
            $payload[$relativePath] = [ordered]@{path = $relativePath; bytes = $entry.Length; sha256 = (Get-InstallerHash $destination); origin = 'verified_windows_zip'}
        }
    } finally { $archive.Dispose() }
    if ((Get-InstallerHash $WindowsZipPath) -ne $WindowsZipSha256) { throw '载荷解压期间 Windows ZIP 发生变化。' }
    $application = Get-Item -LiteralPath (Join-Path $stageRoot 'kazumi_plus.exe')
    if ($application.VersionInfo.CompanyName -ne 'KazumiPlus' -or $application.VersionInfo.ProductName -ne 'Kazumi Plus') {
        throw 'Windows 程序的数据身份与安装方案不符。'
    }

    # 从 Visual Studio 官方可再分发目录查找 x64 CRT，不依赖目标电脑预装它们。
    $vswhere = Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Microsoft Visual Studio/Installer/vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw '未找到 vswhere，请确认 Windows C++ 构建工具已安装。' }
    $visualStudioPath = @(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if ($LASTEXITCODE -ne 0 -or $visualStudioPath.Count -ne 1) { throw '无法定位本次 Windows 工具链的 Visual Studio。' }
    $redistRoot = Join-Path $visualStudioPath[0].Trim() 'VC/Redist/MSVC'
    $versions = @(Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending)
    $crtDirectory = $null
    foreach ($version in $versions) {
        $candidate = Join-Path $version.FullName 'x64/Microsoft.VC143.CRT'
        if (Test-Path -LiteralPath $candidate -PathType Container) { $crtDirectory = $candidate; break }
    }
    if (-not $crtDirectory) { throw 'Visual Studio 中未找到 x64 Release 可再分发 CRT。' }
    $runtimeRecords = @()
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        if ($payload.Contains($name)) { throw "ZIP 已包含同名 CRT，请核对运行库来源后再打包：$name" }
        $source = Join-Path $crtDirectory $name
        if ((Get-PeMachine $source) -ne 0x8664) { throw "运行库不是 Windows x64：$name" }
        $signature = Get-AuthenticodeSignature -LiteralPath $source
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "Visual C++ 运行库签名不符：$name"
        }
        $sourceFile = Get-Item -LiteralPath $source
        $hash = Get-InstallerHash $source
        $destination = Join-Path $stageRoot $name
        [IO.File]::Copy($source, $destination, $false)
        if ((Get-InstallerHash $destination) -ne $hash) { throw "运行库复制后摘要不符：$name" }
        $record = [ordered]@{path = $name; bytes = $sourceFile.Length; sha256 = $hash; origin = 'visual_studio_redist'; source = $source; version = $sourceFile.VersionInfo.FileVersion; machine = 'x64'}
        $payload[$name] = $record
        $runtimeRecords += $record
    }

    $payloadRecords = @($payload.Values)
    $payloadManifest = [ordered]@{schema_version = 1; app_id = 'KazumiPlus.Windows.Desktop'; application_version = $ApplicationVersion; windows_zip_sha256 = $WindowsZipSha256; files = $payloadRecords; app_local_runtime = $runtimeRecords; user_data_policy = 'preserve_roaming_kazumiplus_data'}
    $payloadManifestPath = Join-Path $LogDirectory 'installer-payload.json'
    Write-InstallerJson $payloadManifestPath $payloadManifest
    $baseName = "Kazumi-Plus-$ApplicationVersion-windows-x64-setup"
    $setupPath = Join-Path $OutputDirectory ($baseName + '.exe')
    if (Test-Path -LiteralPath $setupPath) { throw '本批次安装程序已存在，拒绝覆盖。' }
    $arguments = @('/Qp', "/DBundleDir=$stageRoot", "/DAppVersion=$ApplicationVersion", "/DOutputDir=$OutputDirectory", "/DOutputBaseFilename=$baseName", "/DAppIcon=$(Join-Path $projectRoot 'windows/runner/resources/app_icon.ico')", "/DLicenseFile=$(Join-Path $projectRoot 'LICENSE')", (Join-Path $PSScriptRoot 'installer/kazumi_plus.iss'))
    $compilerLog = Join-Path $LogDirectory 'inno-compile.log'
    Write-Host '正在生成 Windows 安装程序……' -ForegroundColor Cyan
    & $Toolchain.compiler_path @arguments 2>&1 | Tee-Object -FilePath $compilerLog | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "安装包编译失败，退出码 $LASTEXITCODE；请查看 $compilerLog" }
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf) -or (Get-Item -LiteralPath $setupPath).Length -le 0) {
        throw 'Inno Setup 没有生成本次安装程序。'
    }
    if ((Get-PeMachine $setupPath) -ne 0x8664) { throw '安装程序不是要求的 Windows x64 架构。' }
    foreach ($record in $payloadRecords) {
        if ((Get-InstallerHash (Join-Path $stageRoot $record.path)) -ne $record.sha256) { throw "编译期间安装载荷发生变化：$($record.path)" }
    }
    $result = [pscustomobject][ordered]@{status = 'installer_generated'; app_id = 'KazumiPlus.Windows.Desktop'; file = [IO.Path]::GetFileName($setupPath); bytes = (Get-Item -LiteralPath $setupPath).Length; sha256 = (Get-InstallerHash $setupPath); payload_file_count = $payloadRecords.Count; payload_manifest = 'installer-payload.json'; compiler_version = $Toolchain.version; compiler_sha256 = $Toolchain.compiler_sha256; signing_status = (Get-AuthenticodeSignature -LiteralPath $setupPath).Status.ToString(); installation_acceptance = 'pending_independent_readback'}
    Write-InstallerJson (Join-Path $LogDirectory 'result.json') $result
    Copy-Item -LiteralPath $Toolchain.receipt_path -Destination (Join-Path $LogDirectory 'compiler-receipt.json')
    $completed = $true
    Write-Host "Windows 安装程序已生成：$setupPath" -ForegroundColor Green
    return $result
} finally {
    # 只清理本次已完成的临时载荷；失败时保留现场便于诊断。
    if ($completed -and (Test-Path -LiteralPath $stageRoot)) {
        $allowedStageRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.tools/windows-installer-staging')) + [IO.Path]::DirectorySeparatorChar
        if (-not [IO.Path]::GetFullPath($stageRoot).StartsWith($allowedStageRoot, [StringComparison]::OrdinalIgnoreCase)) { throw '临时载荷清理路径越界。' }
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
}
