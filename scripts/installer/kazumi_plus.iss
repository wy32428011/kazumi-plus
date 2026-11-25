; 所有路径和版本均由本次一键打包流程提供，禁止隐式使用历史构建目录。
#ifndef BundleDir
  #error 缺少必填参数 BundleDir。
#endif
#ifndef AppVersion
  #error 缺少必填参数 AppVersion。
#endif
#ifndef OutputDir
  #error 缺少必填参数 OutputDir。
#endif
#ifndef OutputBaseFilename
  #error 缺少必填参数 OutputBaseFilename。
#endif
#ifndef AppIcon
  #error 缺少必填参数 AppIcon。
#endif
#ifndef LicenseFile
  #error 缺少必填参数 LicenseFile。
#endif

; 提前阻止入口文件、图标或许可证缺失的安装包编译。
#if !FileExists(BundleDir + "\kazumi_plus.exe")
  #error 安装载荷缺少 kazumi_plus.exe。
#endif
#if !FileExists(AppIcon)
  #error 安装图标文件不存在。
#endif
#if !FileExists(LicenseFile)
  #error 许可证文件不存在。
#endif
#if !FileExists(BundleDir + "\LICENSE")
  #error 安装载荷缺少随包 LICENSE。
#endif

[Setup]
; 固定安装身份，使后续版本沿用原安装目录及卸载项。
AppId=KazumiPlus.Windows.Desktop
AppName=Kazumi Plus
AppVersion={#AppVersion}
AppVerName=Kazumi Plus {#AppVersion}
AppPublisher=KazumiPlus
VersionInfoCompany=KazumiPlus
VersionInfoProductName=Kazumi Plus
VersionInfoVersion={#AppVersion}
; 每用户安装，无需管理员权限，不开放切换到所有用户安装。
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\Kazumi Plus
UsePreviousAppDir=yes
DefaultGroupName=Kazumi Plus
; 分组页保持可用，使用户选择及命令行 /GROUP 都能按预期生效。
DisableProgramGroupPage=no
UninstallDisplayIcon={app}\kazumi_plus.exe
; 使用原生 x64 安装器并限制系统版本，与项目构建目标保持一致。
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.19041
WizardStyle=modern dynamic
SetupIconFile={#AppIcon}
LicenseFile={#LicenseFile}
; 安装、升级和卸载要求用户正常退出应用，不自动关闭或重启应用。
AppMutex=kazumi.plus.win.mutex
SetupMutex=kazumi.plus.win.setup.mutex
CloseApplications=no
RestartApplications=no
; 输出仅落到本次批次目录，保留旧批次及其安装包。
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/normal
SolidCompression=yes

[Languages]
; 使用官方编译器附带的简体中文界面。
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
; 桌面快捷方式由用户选择，默认不勾选。
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: unchecked

[Files]
; 载荷由主流程核验，只排除调试符号，并保留完整文件层级及 LICENSE。
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; 开始菜单分组支持安装器的 /GROUP 参数，便于隔离验收。
Name: "{group}\Kazumi Plus"; Filename: "{app}\kazumi_plus.exe"; WorkingDir: "{app}"
Name: "{group}\卸载 Kazumi Plus"; Filename: "{uninstallexe}"; WorkingDir: "{app}"
Name: "{userdesktop}\Kazumi Plus"; Filename: "{app}\kazumi_plus.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; 交互安装完成后可启动应用，静默安装不自动启动。
Filename: "{app}\kazumi_plus.exe"; WorkingDir: "{app}"; Description: "启动 Kazumi Plus"; Flags: postinstall nowait skipifsilent

; 不定义删除用户数据的操作，规则、收藏和播放历史保留在原 AppData 目录。
