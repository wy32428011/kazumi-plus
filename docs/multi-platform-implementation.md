# Kazumi Plus 多平台实施记录

## 首期范围与状态

2026-10-12 确认同仓复用业务核心，新增 macOS、iOS/iPadOS、Android TV/Google TV/安卓盒子。Apple 使用云构建；macOS 为 ad-hoc 自用 Universal DMG；iOS 只交付未签名 ARM64 IPA。电视使用规则仓库与网址导入，不包含扫码配对。

| 平台 | 下限与架构 | 应用身份 | 当前状态 |
| --- | --- | --- | --- |
| macOS | macOS 12，arm64 + x86_64 | app.kazumiplus.client | 工程与检查脚本已实现，待个人仓库云构建 |
| iOS/iPadOS | iOS 15，arm64 | app.kazumiplus.client | 工程与 unsigned IPA 脚本已实现，待个人仓库云构建 |
| 安卓电视/盒子 | API 24，arm64-v8a + armeabi-v7a | app.kazumiplus.client.tv | 界面和构建配置已实现、静态检查通过，待构建及遥控器核验 |

工程已存在、静态检查通过、构建通过、实际播放通过分别记录。没有设备的真机项目保留待验收。

## 实现约定

- 设备形态由 `PlatformEnvironmentService` 单独识别；电视 flavor、编译标记和 Android 系统能力参与判断。`MediaKind.tv` 仅代表电视剧内容。
- 规则、媒体身份、收藏和历史沿用现有模型与存储格式。电视使用独立包名和 Android 沙盒。
- 电视使用侧边导航、可见焦点、滚动跟随和返回焦点恢复。进度控件获焦时左右调整 10 秒；媒体键控制播放；返回先收浮层再退页面。
- 网址导入复用 `PluginImportParser`，用户确认预览后才写库；下载失败、无效内容不保存。下载上限 2 MiB，接收超时 20 秒。
- WebView 能力探测失败不阻断 Android 启动。网页解析或验证码来源提示换源，API/HLS/MP4 直链沿用播放核心。
- 新增代码注释使用中文，保留手机与桌面原有交互。
- 影视电视播放器复用应用级 `AudioController`，以独立 owner 发布真实影视/集信息；旧页面不能更新或释放后续媒体会话。音频中断只恢复原有效会话，恢复期间系统暂停仍可生效。

## 电视 APK 与签名

在 PowerShell 7.2+ 中执行，默认要求干净提交；开发构建可显式加 `-AllowDirty`，证据会标记未提交状态。

```powershell
# x86_64 模拟器调试包与 ARMv7/ARM64 通用发布包。
& '.\scripts\build_plus.ps1' -Target AndroidTvDebug
& '.\scripts\build_plus.ps1' -Target AndroidTvRelease

# 手机原有入口保持有效，保留原 APK 文件名兼容别名。
& '.\scripts\build_plus.ps1' -Target AndroidRelease
```

电视原始发布包为 `build/app/outputs/flutter-apk/app-tv-release.apk`。TV Release 强制使用固定发布证书，公钥摘要记录在 `scripts/signing/tv-release-certificate.json`。私钥和密码保存在已忽略的 `.tools/signing/kazumi-plus-tv/` 并另有本地备份；换机或云端构建应恢复该身份，不能重新生成后覆盖既有版本。

Android 云任务为可选目标：手机需要 `KAZUMI_MOBILE_DEBUG_KEYSTORE_BASE64` 以延续既有调试签名；电视需要 `KAZUMI_TV_KEYSTORE_BASE64`、`KAZUMI_TV_KEYSTORE_PASSWORD`、`KAZUMI_TV_KEY_ALIAS`、`KAZUMI_TV_KEY_PASSWORD`。Apple 首期任务不需要这些 Android 签名 Secrets。

## Apple 云构建

工具固定为 Flutter 3.47.7、Xcode 26.3、CocoaPods 1.16.2、xcodeproj 1.27.0、CMake Python 分发 3.31.6、Ninja Python 分发 1.11.1.4。工具不符、冻结锁变化或正式构建修改源码时停止并保存日志。

首次 CocoaPods 锁来自真实 Mac 解析。`--bootstrap-pods` 归档锁及生成文件，返回 78 表示待冻结，不冒充成品；回读并提交真实生成文件后执行正式构建。

```bash
# 首次解析；提交回传的真实锁文件后再执行正式构建。
bash scripts/build_apple.sh macos --bootstrap-pods
bash scripts/build_apple.sh ios --bootstrap-pods

# 固定 Mac 工具链上的正式构建。
bash scripts/build_apple.sh macos
bash scripts/build_apple.sh ios
```

默认输出为 `dist/apple/macos`、`dist/apple/ios`，保存 `result.json`、日志、原生结构报告、SHA256 和安装包。重复运行需新的 `--output-dir`，保留旧证据。

macOS 要求全部随包 Mach-O 包含 arm64/x86_64，最低系统不高于 12；签名从内层库到外层应用执行。云端启动仅证明主机架构下进程与动态库可用，真实 Mac 播放及 Intel 真机另验。DMG 使用 ad-hoc 签名，未做 Developer ID 公证；安装文档按系统首次打开流程说明。

iOS IPA 必须含 `Payload/Kazumi Plus.app`，为 ARM64 真机目标且应用无 provisioning profile。未签名 IPA 不作为安装或播放证明；本轮不进行个人签名、TestFlight、商店提交或真机侧载。

## 验证与交付

仅进行必要静态检查、Release 构建、产物回读及操作核验，不新增全量测试套件。电视核验覆盖三频道、搜索、详情、线路/选集、播放控制、收藏、冷续播、导入失败、网络中断、WebView 不可用；真实电视硬解、音画同步与长时间播放单列。

新产物关联源码提交、工具版本、日志和 SHA256；统一清单最后按实际交付文件重算。旧 Windows/Android 包不冒充新源码构建。既有来源 HLS 插播 PTS 断点继续作为来源边界记录。

用户已授权创建个人 GitHub 仓库，首期仅上传 Actions Artifacts。当前仓库创建等待 GitHub 网页登录；本地代码和电视构建继续推进。

2026-10-13 静态核验：全仓 `flutter analyze --no-fatal-infos --fatal-warnings` 退出 0，0 error、0 warning，17 条原有 info。后续音频 owner/中断修正的两文件定向分析也为 No issues found。Apple plist/XML、图标尺寸、脚本语法及 actionlint 已通过；尚未将这些结果当作安装包或播放验收通过。
