#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$privateRoot = Join-Path $projectRoot '.tools/signing/kazumi-plus-tv'
$keystorePath = Join-Path $privateRoot 'release.p12'
$propertiesPath = Join-Path $privateRoot 'signing.properties'
$publicPath = Join-Path $projectRoot 'scripts/signing/tv-release-certificate.json'
$keyAlias = 'kazumi-plus-tv'
$utf8 = [Text.UTF8Encoding]::new($false)
$keytool = (Get-Command keytool -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

# 私钥仅允许落在已被 Git 忽略的位置，拒绝因规则缺失而意外进入仓库。
& git -C $projectRoot check-ignore --quiet -- '.tools/signing/kazumi-plus-tv/release.p12'
if ($LASTEXITCODE -ne 0) { throw '签名目录未被 Git 忽略，拒绝创建私钥。' }
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null

# 在写入密码或私钥前收紧目录权限，子文件继承当前用户、SYSTEM 和管理员权限。
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    # 只更新 DACL，不请求修改所有者或审计规则所需的系统特权。
    & icacls $privateRoot '/inheritance:r' '/grant:r' ('*' + $owner.Value + ':(OI)(CI)F') '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法限制签名目录访问权限。' }
    $acl = Get-Acl -LiteralPath $privateRoot
    $allowedSids = @($owner.Value, 'S-1-5-18', 'S-1-5-32-544')
    $unexpectedAccess = @($acl.Access | Where-Object {
        $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowedSids
    })
    if (-not $acl.AreAccessRulesProtected -or $unexpectedAccess.Count -gt 0) { throw '签名目录权限未收紧到预期主体。' }
} else {
    & chmod 700 $privateRoot
    if ($LASTEXITCODE -ne 0) { throw '无法限制签名目录权限。' }
}

$hasKey = Test-Path -LiteralPath $keystorePath
$hasProperties = Test-Path -LiteralPath $propertiesPath
if ($hasKey -ne $hasProperties) { throw '发现不完整签名配置；请恢复备份，脚本不会替换既有发布密钥。' }
$password = $null
if ($hasKey) {
    $privateValues = @{}
    foreach ($line in Get-Content -LiteralPath $propertiesPath) {
        $delimiter = $line.IndexOf('=')
        if ($delimiter -gt 0) { $privateValues[$line.Substring(0, $delimiter)] = $line.Substring($delimiter + 1) }
    }
    $password = $privateValues['storePassword']
    if ([string]::IsNullOrWhiteSpace($password)) { throw '既有签名配置缺少密码，拒绝生成替代密钥。' }
} else {
    $randomBytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($randomBytes)
    $password = [Convert]::ToBase64String($randomBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [Array]::Clear($randomBytes, 0, $randomBytes.Length)
}

# 密码通过进程环境交给 keytool，不进入命令参数或工具日志。
$passwordVariable = 'KAZUMI_TV_SIGNING_INIT_PASSWORD'
$previousPassword = [Environment]::GetEnvironmentVariable($passwordVariable, 'Process')
try {
    [Environment]::SetEnvironmentVariable($passwordVariable, $password, 'Process')
    if (-not $hasKey) {
        & $keytool -genkeypair -noprompt -keystore $keystorePath -storetype PKCS12 -alias $keyAlias -keyalg RSA -keysize 4096 -validity 10000 -dname 'CN=Kazumi Plus TV, O=Kazumi Plus' "-storepass:env" $passwordVariable "-keypass:env" $passwordVariable 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'TV 专用发布密钥创建失败。' }
    }
    $certificatePath = Join-Path $privateRoot 'release-certificate.der'
    & $keytool -exportcert -keystore $keystorePath -storetype PKCS12 -alias $keyAlias "-storepass:env" $passwordVariable -file $certificatePath 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw '无法验证 TV 签名证书；请检查或恢复已有签名配置。' }
    $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($certificatePath)
    try {
        $fingerprint = $certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256).ToLowerInvariant()
        if (Test-Path -LiteralPath $publicPath) {
            $expected = Get-Content -LiteralPath $publicPath -Raw | ConvertFrom-Json
            if ($expected.certificateSha256 -ne $fingerprint) { throw '私钥与已提交的 TV 公钥指纹不一致，拒绝更换发布身份。' }
        }
        $publicInformation = [ordered]@{
            schemaVersion = 1
            applicationId = 'app.kazumiplus.client.tv'
            keyAlias = $keyAlias
            storeType = 'PKCS12'
            certificateSha256 = $fingerprint
            subject = $certificate.Subject
            notBeforeUtc = $certificate.NotBefore.ToUniversalTime().ToString('o')
            notAfterUtc = $certificate.NotAfter.ToUniversalTime().ToString('o')
        }
        [IO.File]::WriteAllText($publicPath, ($publicInformation | ConvertTo-Json) + "`n", $utf8)
    } finally { $certificate.Dispose() }

    $propertyLines = @(
        'storeFile=' + $keystorePath.Replace('\', '/')
        'storePassword=' + $password
        'keyAlias=' + $keyAlias
        'keyPassword=' + $password
        'storeType=PKCS12'
    ) -join "`n"
    [IO.File]::WriteAllText($propertiesPath, $propertyLines + "`n", $utf8)
    $ciSecrets = [ordered]@{
        KAZUMI_TV_KEYSTORE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($keystorePath))
        KAZUMI_TV_KEYSTORE_PASSWORD = $password
        KAZUMI_TV_KEY_ALIAS = $keyAlias
        KAZUMI_TV_KEY_PASSWORD = $password
    }
    [IO.File]::WriteAllText((Join-Path $privateRoot 'ci-secrets.json'), ($ciSecrets | ConvertTo-Json) + "`n", $utf8)

    # 备份保留在同一受限目录下；不会将私钥、密码或 base64 输出到终端。
    $backupRoot = Join-Path $privateRoot ('backups/' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    foreach ($fileName in @('release.p12', 'signing.properties', 'release-certificate.der', 'ci-secrets.json')) {
        Copy-Item -LiteralPath (Join-Path $privateRoot $fileName) -Destination (Join-Path $backupRoot $fileName)
    }
    if ((Get-FileHash -LiteralPath $keystorePath -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $backupRoot 'release.p12') -Algorithm SHA256).Hash) {
        throw '签名备份校验失败。'
    }
    Write-Output "TV 专用签名已验证；公钥 SHA256：$fingerprint"
    Write-Output "私有配置和备份位于受限且被 Git 忽略的目录：$privateRoot"
    Write-Output "公钥记录：$publicPath"
} finally {
    [Environment]::SetEnvironmentVariable($passwordVariable, $previousPassword, 'Process')
    $password = $null
}
