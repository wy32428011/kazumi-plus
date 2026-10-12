#requires -Version 7.0
[CmdletBinding()]
param([string]$KeystorePath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.android/debug.keystore'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$privateRoot = Join-Path $projectRoot '.tools/signing/kazumi-plus-tv/mobile-debug'
$publicPath = Join-Path $projectRoot 'scripts/signing/mobile-debug-certificate.json'
if (-not (Test-Path -LiteralPath $KeystorePath -PathType Leaf)) { throw '找不到既有 mobile debug.keystore；不会生成替代证书。' }
if (-not (Test-Path -LiteralPath (Join-Path $projectRoot '.tools/signing/kazumi-plus-tv/signing.properties'))) {
    throw '请先运行 initialize_tv_signing.ps1，建立受限签名目录。'
}
& git -C $projectRoot check-ignore --quiet -- '.tools/signing/kazumi-plus-tv/mobile-debug/ci-secrets.json'
if ($LASTEXITCODE -ne 0) { throw '私有导出目录未被 Git 忽略。' }
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
$keytool = (Get-Command keytool -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$variable = 'KAZUMI_MOBILE_DEBUG_EXPORT_PASSWORD'
$previousValue = [Environment]::GetEnvironmentVariable($variable, 'Process')
try {
    # 使用 Android 调试签名的既有约定，仅导出原文件，不改写或重新生成密钥。
    [Environment]::SetEnvironmentVariable($variable, 'android', 'Process')
    $certificatePath = Join-Path $privateRoot 'debug-certificate.der'
    & $keytool -exportcert -keystore $KeystorePath -alias androiddebugkey '-storepass:env' $variable -file $certificatePath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法读取既有 mobile 调试证书，停止导出。' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
    try {
        $fingerprint = $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        if (Test-Path -LiteralPath $publicPath) {
            $expected = Get-Content -LiteralPath $publicPath -Raw | ConvertFrom-Json
            if ($expected.certificateSha256 -ne $fingerprint) { throw 'mobile 调试证书已变化，拒绝替换固定指纹。' }
        }
        $publicInformation = [ordered]@{schemaVersion = 1; applicationId = 'app.kazumiplus.client'; certificateSha256 = $fingerprint; subject = $certificate.Subject}
        [IO.File]::WriteAllText($publicPath, ($publicInformation | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
    } finally { $certificate.Dispose() }
    Copy-Item -LiteralPath $KeystorePath -Destination (Join-Path $privateRoot 'debug.keystore') -Force
    $privateExport = @{KAZUMI_MOBILE_DEBUG_KEYSTORE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($KeystorePath))}
    [IO.File]::WriteAllText((Join-Path $privateRoot 'ci-secrets.json'), ($privateExport | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output "原 mobile 调试证书已备份；公钥 SHA256：$fingerprint"
    Write-Output "供仓库 Secrets 使用的私有导出文件保存在：$privateRoot"
} finally { [Environment]::SetEnvironmentVariable($variable, $previousValue, 'Process') }
