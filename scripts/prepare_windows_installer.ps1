#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory
)

# 固定版本工具只保存在项目缓存内；日志使用宿主流，成功输出流仅返回一个结果对象。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$utf8 = [Text.UTF8Encoding]::new($false)
$logsRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.tools/logs'))
$evidenceDirectory = [IO.Path]::GetFullPath($LogDirectory, $projectRoot)
if (-not $evidenceDirectory.StartsWith($logsRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw '安装包工具证据目录必须位于项目 .tools/logs 内。'
}
if (Test-Path -LiteralPath $evidenceDirectory) { throw '安装包工具证据目录已存在，拒绝覆盖历史记录。' }
New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
$receiptPath = Join-Path $evidenceDirectory 'receipt.json'
$toolDirectory = Join-Path $projectRoot '.tools/inno-setup/7.1.0'
$cacheRoot = Split-Path -Parent $toolDirectory
$downloadDirectory = Join-Path $projectRoot '.tools/installer-downloads'
$manifestName = 'toolchain-manifest.json'
$cachedReceiptName = 'toolchain-receipt.json'
$manifestPath = Join-Path $toolDirectory $manifestName
$cachedReceiptPath = Join-Path $toolDirectory $cachedReceiptName
$requiredFiles = @('ISCC.exe', 'ISCmplr.dll', 'ISPP.dll', 'Setup.e64', 'SetupLdr.e64', 'Default.isl', 'Languages/ChineseSimplified.isl')
$receipt = [ordered]@{
    status = 'preparing'
    started_at_utc = [DateTime]::UtcNow.ToString('o')
    version = '7.1.0'
    tool_directory = $toolDirectory
    mode = 'portable_current_user'
    reused = $false
    download_attempts = @()
    download = $null
    setup_process = $null
    compiler_process = $null
    compiler = $null
    manifest_sha256 = $null
    cache_rejection = $null
    error = $null
}
$lockStream = $null
$toolchain = $null

function Write-ToolchainJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 12) + "`n", $utf8)
}

function Get-VerifiedSignedFile([string]$Path, [long]$ExpectedBytes = 0, [string]$ExpectedSha256 = '') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "文件不存在：$Path" }
    $file = Get-Item -LiteralPath $Path
    if ($ExpectedBytes -gt 0 -and $file.Length -ne $ExpectedBytes) { throw "文件大小不符合冻结记录：$Path" }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ExpectedSha256 -and $hash -ne $ExpectedSha256) { throw "文件 SHA256 不符合冻结记录：$Path" }
    # 官方 ISCC 的 PE 版本字段为 0.0.0.0；下载包自身的产品版本则可按冻结版本核对。
    if ($ExpectedBytes -gt 0 -and $file.VersionInfo.ProductVersion.Trim() -notmatch '^7\.1\.0(?:[.\s]|$)') {
        throw "官方下载包产品版本不符合 7.1.0：$Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject.IndexOf($toolchain.publisher_contains, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "官方工具签名无效或发布者不符：$Path；签名状态：$($signature.Status)"
    }
    [pscustomobject][ordered]@{
        path = $file.FullName
        bytes = $file.Length
        sha256 = $hash
        product_version = $file.VersionInfo.ProductVersion.Trim()
        signature = [ordered]@{
            status = [string]$signature.Status
            subject = $signature.SignerCertificate.Subject
            issuer = $signature.SignerCertificate.Issuer
            thumbprint = $signature.SignerCertificate.Thumbprint
            certificate_not_before_utc = $signature.SignerCertificate.NotBefore.ToUniversalTime().ToString('o')
            certificate_not_after_utc = $signature.SignerCertificate.NotAfter.ToUniversalTime().ToString('o')
            timestamp_subject = if ($null -ne $signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
        }
    }
}

function Get-VerifiedCompiler {
    $compilerPath = Join-Path $toolDirectory 'ISCC.exe'
    $compiler = Get-VerifiedSignedFile -Path $compilerPath
    # --version 是官方提供的编译引擎版本接口，只读取版本，不编译或运行应用安装器。
    $versionOutputPath = Join-Path $evidenceDirectory 'compiler-version-output.log'
    $versionErrorPath = Join-Path $evidenceDirectory 'compiler-version-stderr.log'
    $receipt.compiler_process = [ordered]@{path = $compilerPath; arguments = @('--version'); status = 'starting'; process_id = $null; exit_code = $null}
    Write-ToolchainJson $receiptPath $receipt
    $versionProcess = Start-Process -FilePath $compilerPath -ArgumentList @('--version') -WindowStyle Hidden -PassThru -RedirectStandardOutput $versionOutputPath -RedirectStandardError $versionErrorPath
    try {
        $receipt.compiler_process.process_id = $versionProcess.Id
        $receipt.compiler_process.status = 'running'
        Write-ToolchainJson $receiptPath $receipt
        $versionProcess.WaitForExit()
        $receipt.compiler_process.exit_code = $versionProcess.ExitCode
        $receipt.compiler_process.status = 'exited'
        Write-ToolchainJson $receiptPath $receipt
        if ($versionProcess.ExitCode -ne 0) { throw "无法读取编译器版本，退出码 $($versionProcess.ExitCode)；日志：$versionOutputPath" }
    } finally {
        $versionProcess.Dispose()
    }
    $engineVersion = [IO.File]::ReadAllText($versionOutputPath).Trim()
    if ($engineVersion -ne '7.1.0') { throw "编译器引擎版本不符合 7.1.0：$engineVersion" }
    $compiler | Add-Member -NotePropertyName engine_version -NotePropertyValue $engineVersion
    return $compiler
}

function Get-ToolchainManifest {
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $toolDirectory $requiredFile) -PathType Leaf)) {
            throw "Inno Setup 工具不完整，缺少 $requiredFile"
        }
    }
    # 固定整个工具目录的文件摘要，涵盖编译 DLL、安装引擎、默认语言及内置图像资源。
    foreach ($file in (Get-ChildItem -LiteralPath $toolDirectory -Recurse -File | Sort-Object FullName)) {
        $relativePath = [IO.Path]::GetRelativePath($toolDirectory, $file.FullName).Replace('\', '/')
        if ($relativePath -in @($manifestName, $cachedReceiptName)) { continue }
        [pscustomobject][ordered]@{
            path = $relativePath
            bytes = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

function Move-ToolCacheAside {
    # 在移动整个缓存前核对最终绝对路径，备份始终留在项目 .tools/inno-setup 内。
    $cachePrefix = [IO.Path]::GetFullPath($cacheRoot) + [IO.Path]::DirectorySeparatorChar
    $archivePath = [IO.Path]::GetFullPath($toolDirectory + '.rejected-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    if (-not [IO.Path]::GetFullPath($toolDirectory).StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not $archivePath.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw '工具缓存备份路径越过项目边界。'
    }
    Move-Item -LiteralPath $toolDirectory -Destination $archivePath
    return $archivePath
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows 安装包工具只能在 Windows 主机上准备。' }
    $metadataPath = Join-Path $PSScriptRoot 'installer/toolchain.json'
    $toolchain = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($toolchain.version -ne '7.1.0' -or $toolchain.architecture -ne 'x64' -or
        $toolchain.filename -ne 'innosetup-7.1.0-x64.exe' -or
        $toolchain.sha256 -notmatch '^[0-9a-f]{64}$' -or $toolchain.bytes -le 0 -or
        $toolchain.publisher_contains -ne 'Pyrsys B.V.' -or @($toolchain.download_urls).Count -eq 0) {
        throw '冻结的 Inno Setup 工具元数据无效。'
    }
    $receipt.metadata_sha256 = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt.verification_urls = $toolchain.verification_urls
    Copy-Item -LiteralPath $metadataPath -Destination (Join-Path $evidenceDirectory 'toolchain.json')
    New-Item -ItemType Directory -Path $cacheRoot, $downloadDirectory -Force | Out-Null
    try {
        $lockStream = [IO.File]::Open((Join-Path $cacheRoot 'prepare-7.1.0.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch {
        throw '已有安装包工具准备进程正在运行，无法同时改写工具缓存。'
    }

    if (Test-Path -LiteralPath $toolDirectory) {
        try {
            $cachedReceipt = Get-Content -LiteralPath $cachedReceiptPath -Raw -Encoding utf8 | ConvertFrom-Json
            if ($cachedReceipt.status -ne 'ready' -or $cachedReceipt.version -ne $toolchain.version -or
                $cachedReceipt.download.sha256 -ne $toolchain.sha256 -or
                $cachedReceipt.download.bytes -ne $toolchain.bytes -or
                $cachedReceipt.download.signature.status -ne 'Valid' -or
                $cachedReceipt.download.signature.subject.IndexOf($toolchain.publisher_contains, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                throw '工具缓存缺少有效的原始下载核验记录。'
            }
            $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($manifestHash -ne $cachedReceipt.manifest_sha256) { throw '工具缓存清单摘要发生变化。' }
            $cachedManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json
            $actualManifest = @(Get-ToolchainManifest)
            if ((ConvertTo-Json -InputObject @($cachedManifest.files) -Depth 4 -Compress) -ne
                (ConvertTo-Json -InputObject $actualManifest -Depth 4 -Compress)) {
                throw '工具缓存文件与首次准备时的摘要清单不一致。'
            }
            $receipt.compiler = Get-VerifiedCompiler
            $receipt.download = $cachedReceipt.download
            $receipt.setup_process = $cachedReceipt.setup_process
            $receipt.manifest_sha256 = $manifestHash
            $receipt.reused = $true
            Write-Host '已核验并复用项目内 Inno Setup 7.1.0 工具缓存。'
        } catch {
            $receipt.cache_rejection = [ordered]@{reason = $_.Exception.Message; archived_path = $null}
            $receipt.cache_rejection.archived_path = Move-ToolCacheAside
            Write-Host "旧工具缓存校验失败，已保留至 $($receipt.cache_rejection.archived_path)，正在重新准备。"
        }
    }

    if (-not $receipt.reused) {
        $downloadPath = Join-Path $downloadDirectory $toolchain.filename
        if (Test-Path -LiteralPath $downloadPath) {
            try {
                $receipt.download = Get-VerifiedSignedFile -Path $downloadPath -ExpectedBytes $toolchain.bytes -ExpectedSha256 $toolchain.sha256
                Write-Host '已核验并复用官方工具下载缓存。'
            } catch {
                $rejectedDownload = $downloadPath + '.rejected-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
                $receipt.download_attempts += [ordered]@{source = $downloadPath; status = 'cache_rejected'; error = $_.Exception.Message; archived_path = $rejectedDownload}
                Move-Item -LiteralPath $downloadPath -Destination $rejectedDownload
            }
        }
        if ($null -eq $receipt.download) {
            foreach ($url in $toolchain.download_urls) {
                $partialPath = $downloadPath + '.' + [Guid]::NewGuid().ToString('N') + '.partial'
                $attempt = [ordered]@{source = $url; partial_path = $partialPath; status = 'downloading'; error = $null}
                $receipt.download_attempts += $attempt
                Write-ToolchainJson $receiptPath $receipt
                try {
                    if ([Uri]::new($url).Scheme -ne 'https') { throw '工具下载仅允许 HTTPS 官方来源。' }
                    Write-Host "正在下载固定版本 Inno Setup：$url"
                    Invoke-WebRequest -Uri $url -OutFile $partialPath -TimeoutSec 180 -MaximumRedirection 10
                    $verifiedDownload = Get-VerifiedSignedFile -Path $partialPath -ExpectedBytes $toolchain.bytes -ExpectedSha256 $toolchain.sha256
                    Move-Item -LiteralPath $partialPath -Destination $downloadPath
                    $verifiedDownload.path = $downloadPath
                    $verifiedDownload | Add-Member -NotePropertyName source_url -NotePropertyValue $url
                    $receipt.download = $verifiedDownload
                    $attempt.status = 'verified'
                    break
                } catch {
                    $attempt.status = 'failed'
                    $attempt.error = $_.Exception.Message
                    Write-Host "该来源下载或校验失败：$($_.Exception.Message)"
                }
            }
            if ($null -eq $receipt.download) { throw '所有官方工具来源均未通过下载和签名校验，已保留失败证据。' }
        }

        # portable 模式禁用卸载注册和文件关联；强制当前用户、静默执行，不要求管理员。
        $setupLogPath = Join-Path $evidenceDirectory 'portable-setup.log'
        $setupStdoutPath = Join-Path $evidenceDirectory 'portable-setup-stdout.log'
        $setupStderrPath = Join-Path $evidenceDirectory 'portable-setup-stderr.log'
        $setupArguments = @('/PORTABLE=1', '/CURRENTUSER', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', ('/DIR="' + $toolDirectory + '"'), ('/LOG="' + $setupLogPath + '"'))
        $receipt.setup_process = [ordered]@{
            path = $downloadPath
            arguments = $setupArguments
            status = 'starting'
            process_id = $null
            exit_code = $null
            log = $setupLogPath
        }
        Write-ToolchainJson $receiptPath $receipt
        Write-Host '正在项目缓存中准备 Inno Setup 便携工具……'
        $setupProcess = Start-Process -FilePath $downloadPath -ArgumentList $setupArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $setupStdoutPath -RedirectStandardError $setupStderrPath
        try {
            $receipt.setup_process.process_id = $setupProcess.Id
            $receipt.setup_process.status = 'running'
            Write-ToolchainJson $receiptPath $receipt
            $setupProcess.WaitForExit()
            $receipt.setup_process.exit_code = $setupProcess.ExitCode
            $receipt.setup_process.status = 'exited'
            Write-ToolchainJson $receiptPath $receipt
            if ($setupProcess.ExitCode -ne 0) { throw "官方便携工具准备失败，退出码 $($setupProcess.ExitCode)；请查看 $setupLogPath" }
        } finally {
            $setupProcess.Dispose()
        }
        if (-not (Test-Path -LiteralPath $setupLogPath -PathType Leaf)) { throw '官方便携工具未生成安装日志，无法核对本次执行。' }
        $receipt.compiler = Get-VerifiedCompiler
        $manifest = [ordered]@{version = $toolchain.version; files = @(Get-ToolchainManifest)}
        Write-ToolchainJson $manifestPath $manifest
        $receipt.manifest_sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $receipt.status = 'ready'
        Write-ToolchainJson $cachedReceiptPath $receipt
    }

    Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $evidenceDirectory $manifestName)
    $receipt.status = 'ready'
    $receipt.completed_at_utc = [DateTime]::UtcNow.ToString('o')
    Write-ToolchainJson $receiptPath $receipt
    Write-Host "Inno Setup 7.1.0 工具已就绪；证据：$receiptPath"
} catch {
    $receipt.status = 'failed'
    $receipt.error = $_.Exception.Message
    $receipt.completed_at_utc = [DateTime]::UtcNow.ToString('o')
    Write-ToolchainJson $receiptPath $receipt
    throw "Windows 安装包工具准备失败：$($receipt.error)；证据：$receiptPath"
} finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}

[pscustomobject][ordered]@{
    status = 'ready'
    compiler_path = $receipt.compiler.path
    version = '7.1.0'
    compiler_sha256 = $receipt.compiler.sha256
    tool_directory = $toolDirectory
    receipt_path = $receiptPath
}
