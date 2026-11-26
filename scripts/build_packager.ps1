#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$WindowsInstaller
)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $PSScriptRoot 'packager\Launcher.cs'
$outputFileName = if ($WindowsInstaller) { '一键打包Windows安装包.exe' } else { '一键打包.exe' }
$outputPath = Join-Path $projectDirectory $outputFileName
$iconPath = Join-Path $projectDirectory 'windows\runner\resources\app_icon.ico'
$temporaryDirectory = Join-Path $projectDirectory '.tools\packager-build'
$temporaryPath = Join-Path $temporaryDirectory ('launcher-{0}.exe' -f [Guid]::NewGuid().ToString('N'))
$backupPath = Join-Path $temporaryDirectory ('launcher-backup-{0}.exe' -f [Guid]::NewGuid().ToString('N'))
$replacementCompleted = $false

try {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "找不到启动器源码：$sourcePath"
    }

    # 使用系统自带编译器，入口运行与生成均不需要安装额外的 .NET SDK。
    $windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
    $compilerPath = Join-Path $windowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        $compilerPath = Join-Path $windowsDirectory 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compilerPath -PathType Leaf)) {
        throw '未找到系统 .NET Framework C# 编译器。请检查 Windows 的 .NET Framework 组件。'
    }

    New-Item -ItemType Directory -Path $temporaryDirectory -Force | Out-Null
    Write-Host ('正在生成 {0}……' -f $outputFileName)
    $compilerArguments = @('/nologo', '/target:exe', '/platform:anycpu', '/optimize+', '/codepage:65001', "/out:$temporaryPath")
    if ($WindowsInstaller) {
        # 两个入口共用源码，仅通过编译条件区分默认目标和界面说明。
        $compilerArguments += '/define:WINDOWS_INSTALLER'
    }
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        $compilerArguments += "/win32icon:$iconPath"
    }
    $compilerArguments += $sourcePath
    & $compilerPath @compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
        throw "启动器编译失败，退出码：$LASTEXITCODE"
    }

    # 先完整编译再原子替换；正在运行或被占用时保留原文件并明确报错。
    if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
        $runningLaunchers = @(Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($outputPath)) -ErrorAction SilentlyContinue)
        foreach ($runningLauncher in $runningLaunchers) {
            if ([string]::Equals($runningLauncher.Path, $outputPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "一键打包程序正在运行（进程 $($runningLauncher.Id)），请关闭该程序后重新生成。原文件已保留。"
            }
        }
        try {
            # PowerShell 5.1 会把字符串参数的 $null 绑定为空字符串，改用明确的唯一备份路径。
            [System.IO.File]::Replace($temporaryPath, $outputPath, $backupPath)
            $replacementCompleted = $true
        }
        catch {
            throw "无法替换 $outputPath。请关闭正在运行的一键打包程序或释放文件占用后重试。原文件已保留。原因：$($_.Exception.Message)"
        }
    }
    else {
        [System.IO.File]::Move($temporaryPath, $outputPath)
    }

    Write-Host "已生成：$outputPath"
    if ($WindowsInstaller) {
        Write-Host '双击该程序，即可构建并生成 Windows 安装包。'
    }
    else {
        Write-Host '双击该程序，即可按默认目标串行构建并打包。'
    }
}
catch {
    Write-Error "生成一键打包程序失败：$($_.Exception.Message)"
    exit 1
}
finally {
    # 只回收本次生成的临时文件，不影响其他构建任务。
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
    if ($replacementCompleted -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}
