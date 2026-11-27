#requires -Version 7.2
Set-StrictMode -Version Latest

$script:KazumiPlusDefaultUpdateUrl = 'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest'

function Test-UpstreamKazumiUpdateUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $false
    }
    try {
        $uri = [Uri]$Url.Trim()
    } catch {
        return $false
    }
    $hostName = $uri.Host.ToLowerInvariant()
    $pathName = $uri.AbsolutePath.ToLowerInvariant()
    if ($hostName -eq 'api.github.com' -and $pathName -match '^/repos/predidit/kazumi(/|$)') {
        return $true
    }
    if (($hostName -eq 'github.com' -or $hostName -eq 'www.github.com') -and $pathName -match '^/predidit/kazumi(/|$)') {
        return $true
    }
    return $false
}

function Get-GitHubRepoSlugFromRemoteUrl([string]$RemoteUrl) {
    if ([string]::IsNullOrWhiteSpace($RemoteUrl)) {
        return $null
    }
    $trimmed = $RemoteUrl.Trim()
    if ($trimmed -match '^(?:https?://(?:www\.)?github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    return $null
}

function Resolve-KazumiPlusUpdateUrl {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$ExplicitUpdateUrl = '',
        [string]$EnvironmentUpdateUrl = ''
    )

    $candidate = ''
    if (-not [string]::IsNullOrWhiteSpace($ExplicitUpdateUrl)) {
        $candidate = $ExplicitUpdateUrl.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($EnvironmentUpdateUrl)) {
        $candidate = $EnvironmentUpdateUrl.Trim()
    } elseif (-not [string]::IsNullOrWhiteSpace($env:KAZUMI_PLUS_UPDATE_URL)) {
        $candidate = $env:KAZUMI_PLUS_UPDATE_URL.Trim()
    } else {
        $remotes = @(& git -C $ProjectRoot remote 2>$null)
        if ($LASTEXITCODE -eq 0 -and $remotes.Count -gt 0) {
            $orderedRemotes = @()
            if ($remotes -contains 'plus') {
                $orderedRemotes += 'plus'
            }
            $orderedRemotes += @($remotes | Where-Object { $_ -ne 'plus' })
            foreach ($remoteName in $orderedRemotes) {
                $remoteUrl = (& git -C $ProjectRoot remote get-url $remoteName 2>$null)
                if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteUrl)) {
                    continue
                }
                $slug = Get-GitHubRepoSlugFromRemoteUrl ($remoteUrl | Select-Object -First 1)
                if ([string]::IsNullOrWhiteSpace($slug)) {
                    continue
                }
                if ($slug.Equals('Predidit/Kazumi', [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                $candidate = "https://api.github.com/repos/$slug/releases/latest"
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            $candidate = $script:KazumiPlusDefaultUpdateUrl
        }
    }

    if ($candidate -notmatch '^https?://') {
        throw "KAZUMI_PLUS_UPDATE_URL 必须是有效的 http/https 地址：$candidate"
    }
    if (Test-UpstreamKazumiUpdateUrl $candidate) {
        throw "禁止将 Kazumi Plus 更新地址指向原版上游仓库 Predidit/Kazumi：$candidate"
    }
    return $candidate
}
