# Kazumi Plus 多平台实施记录

## 首期范围与状态

2026-10-12 确认同仓复用业务核心，新增 macOS、iOS/iPadOS、Android TV/Google TV/安卓盒子。Apple 使用云构建；macOS 为 ad-hoc 自用 Universal DMG；iOS 只交付未签名 ARM64 IPA。电视使用规则仓库与网址导入，不包含扫码配对。

| 平台 | 下限与架构 | 应用身份 | 当前状态 |
| --- | --- | --- | --- |
| macOS | macOS 12，arm64 + x86_64 | app.kazumiplus.client | 工程与检查脚本已实现，待个人仓库云构建 |
| iOS/iPadOS | iOS 15，arm64 | app.kazumiplus.client | 工程与 unsigned IPA 脚本已实现，待个人仓库云构建 |
| 安卓电视/盒子 | API 24，arm64-v8a + armeabi-v7a | app.kazumiplus.client.tv | Release 与双 ABI/专用签名后验通过；内容区 Left 回侧栏修复重建与最终运行核验继续记录 |

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

生成 DMG 后，在 Mac 上挂载并把 `Kazumi Plus.app` 复制到应用程序目录。系统对未公证应用的首次打开处理随 macOS 版本变化，按 [Apple 官方打开说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac) 操作。本任务当前尚未产生 DMG，不将这段安装说明算作 Mac 运行验收。

iOS IPA 必须含 `Payload/Kazumi Plus.app`，为 ARM64 真机目标且应用无 provisioning profile。未签名 IPA 不作为安装或播放证明；本轮不进行个人签名、TestFlight、商店提交或真机侧载。

## 验证与交付

仅进行必要静态检查、Release 构建、产物回读及操作核验，不新增全量测试套件。电视计划逐项核验三频道、搜索、详情、线路/选集、播放控制、收藏、冷续播、导入失败、网络中断、WebView 不可用；通过项以实际摘要为准，真实电视硬解、音画同步与长时间播放单列。

新产物关联源码提交、工具版本、日志和 SHA256；统一清单最后按实际交付文件重算。旧 Windows/Android 包不冒充新源码构建。既有来源 HLS 插播 PTS 断点继续作为来源边界记录。

用户已授权创建个人 GitHub 仓库，首期仅上传 Actions Artifacts。Chrome 的 GitHub 登录和双重验证尚未完成，验证会话过期后已回到登录页；个人仓库尚未创建、源码尚未推送。Apple bootstrap 与正式云构建均未执行，因此没有 DMG、IPA 或真实 CocoaPods 锁。本地工程与 workflow 审查通过不替代这些构建证据。

2026-10-13 静态核验：全仓 `flutter analyze --no-fatal-infos --fatal-warnings` 退出 0，0 error、0 warning，17 条原有 info。后续音频 owner/中断修正的两文件定向分析也为 No issues found。Apple plist/XML、图标尺寸、脚本语法及 actionlint 已通过；尚未将这些结果当作安装包或播放验收通过。

## 2026-10-13 本地交付与回读

本地首批制品固定到提交 `880f0541a1eaec64b18d7cc38896678cd649611c`，四目标来源清单摘要均为 `8b4064b723f1f170de13e14da6f67c8d2a05e481f5b7c8286e661c826d4ae863`，`source_dirty=false`。Windows 与手机保留该批来源；电视后续焦点修复制品另行记录，下面旧电视包只保留为构建候选。文档后续更新与制品源码提交分别记录。

本轮依据实际构建修正了 split APK 的 ABI/flavor 文件名顺序及 Kotlin 缓存排除；TV universal 原生依赖原先混入 x86_64 残片，已依据 Flutter 本次目标过滤，保留 split 模式原有逻辑。失败候选单独保留，没有交付为成功包。

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| `Kazumi-Plus-0.1.0-android-tv-arm.apk` | 50,669,478 | `63ac24e6e84780a2cce237d5aeb035b5cc57722e5cc37564d42ef77d6296a30b` |
| `Kazumi-Plus-0.1.0-multiplatform-20261013-android-arm64.apk` | 30,588,421 | `e56d4d63616dea29a9bf3735318a846015ddad157e825cbb5b037e19c689ccc5` |
| `Kazumi-Plus-0.1.0-multiplatform-20261013-windows-x64.zip` | 40,605,246 | `0b09702dfbd7a28555d5f02336ce8a57dc4c36447fd3db9617c2100560251ef0` |

Windows ZIP 的 65 个构建文件及 LICENSE 共 66/66 条目逐流验证通过。主 SHA256SUMS 对实际 9 个分发文件读回一致；旧包未改，旧 Windows ZIP 摘要已纠正，日期专用 sources 摘要 3/3 一致。构建来源、工具版本、签名指纹及日志路径见 `dist/multi-platform-build-20261013.json`。

Android 手机回归使用真实 ARM64 Release 包，设备实际 `base.apk` 摘要与分发包一致；运行环境为 API36 x86_64 模拟器及 `libndk_translation.so`，不称为 ARM 真机。保数据安装后和冷启动后的三条旧片单均保留；电视剧第1集从 28:52 冷续播，日志确认位置 1732000ms 与 1920×1080 解码，画面前进后正常退出保存 34:57。电影旧进度 15:32 保留，续播确认 932000ms 与 1920×1080，前进并保存 15:50。证据为 `.tools/logs/mobile-regression-20261013/summary.json` 与同目录截图/脱敏日志。开发设备此前安装 x64 Debug versionCode14，本次仅在该隔离模拟器使用保数据 `install -r -d` 安装 ARM64 Release versionCode12；没有卸载原数据，保留原手机发布版本策略。

Windows 回归从本批 ZIP 解压启动，EXE 摘要与制品一致。电视剧第2集旧 8:00 进度在首帧日志精确读回 480000ms、1920×1080，正常退出保存 16:46；电影正片实际 1920×1080 出画、总长 1:22:16，退出保存 1:26。通过应用内正常退出后启动新进程，原电视剧收藏与两条进度均再次读回；动漫目录可见，本轮未重复 Windows 动漫播放全套核验。证据为 `.tools/logs/windows-regression-20261013/summary.json` 与同目录截图/选摘日志，验收进程和窗口均已正常退出。

Windows 首次暴风国产剧目录出现一次 12 秒 receiveTimeout；保留原日志，同 API 独立采样 200，应用点击重试后目录及后续播放成功。没有据单次超时修改代理、DNS、来源或超时设置。该请求使用普通 pluginDio，不经过 Bangumi ECH 适配器；这次恢复不能保证后续源站可用性。

电视 Debug 已用遥控器完成首启、三频道入口、电视剧搜索/详情/收藏、播放暂停、进度 ±10 秒、1.25 倍速、线路/选集、媒体键、前后集与两次返回、卡片焦点恢复及冷启动流程。媒体键状态同时回读 Android media_session，影视样本实际 1920×1080 出画；最终 ARM Release 运行、电影/动漫及异常场景按电视验收摘要继续记录，未完成项不冒充通过。

最终遥控器核验发现嵌套 RouterOutlet 的内容焦点范围默认在方向边界停止，导致 Left 无法回到侧栏。修复仅为电视内容区添加专属方向策略：先沿用正常遍历，只有当前有效内容页的真实左边界才返回选中入口；排除弹层、被覆盖路由和文本编辑，保留播放器叶层快退处理。具体代码已独立静态交叉审查，运行通过项待新包读回后追加。
