# Kazumi Plus 多平台实施记录

## 首期范围与状态

2026-10-12 确认同仓复用业务核心，新增 macOS、iOS/iPadOS、Android TV/Google TV/安卓盒子。Apple 使用云构建；macOS 为 ad-hoc 自用 Universal DMG；iOS 只交付未签名 ARM64 IPA。电视使用规则仓库与网址导入，不包含扫码配对。

| 平台 | 下限与架构 | 应用身份 | 当前状态 |
| --- | --- | --- | --- |
| macOS | macOS 12，arm64 + x86_64 | app.kazumiplus.client | Universal DMG构建、全部原生切片、实际挂载/签名/云启动通过；真实Mac播放待验 |
| iOS/iPadOS | iOS 15，arm64 | app.kazumiplus.client | 未签名IPA构建、完整原生包体及本地回读通过；未安装到真机 |
| 安卓电视/盒子 | API 24，arm64-v8a + armeabi-v7a | app.kazumiplus.client.tv | 最终 60096ad9 Release 的影视、规则与冷启动限定核验通过；真实电视与 WebView 缺失未验 |

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

在 Mac 上挂载 DMG 并把 `Kazumi Plus.app` 复制到应用程序目录。系统对未公证应用的首次打开处理随 macOS 版本变化，按 [Apple 官方打开说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac) 操作。最终DMG已实际只读挂载和校验，但这段安装说明及云端启动不算作真实Mac播放验收。

iOS IPA 必须含 `Payload/Kazumi Plus.app`，为 ARM64 真机目标且应用无 provisioning profile。未签名 IPA 不作为安装或播放证明；本轮不进行个人签名、TestFlight、商店提交或真机侧载。

## 验证与交付

仅进行必要静态检查、Release 构建、产物回读及操作核验，不新增全量测试套件。电视计划逐项核验三频道、搜索、详情、线路/选集、播放控制、收藏、冷续播、导入失败、网络中断、WebView 不可用；通过项以实际摘要为准，真实电视硬解、音画同步与长时间播放单列。

新产物关联源码提交、工具版本、日志和 SHA256；统一清单最后按实际交付文件重算。旧 Windows/Android 包不冒充新源码构建。既有来源 HLS 插播 PTS 断点继续作为来源边界记录。

用户已授权创建个人 GitHub 仓库，首期仅上传 Actions Artifacts。用户完成登录后，已创建 [wy32428011/kazumi-plus 私有仓库](https://github.com/wy32428011/kazumi-plus)，以独立 `plus` remote 推送 `main`，原上游 `origin` 保留。真实 bootstrap、正式构建和产物交付已完成，历次运行与最终结果见下文；编译成功和失败候选分别记录，不混为合格安装包。

2026-10-13 静态核验：全仓 `flutter analyze --no-fatal-infos --fatal-warnings` 退出 0，0 error、0 warning，17 条原有 info。后续音频 owner/中断修正的两文件定向分析也为 No issues found。Apple plist/XML、图标尺寸、脚本语法及 actionlint 已通过；尚未将这些结果当作安装包或播放验收通过。

## 2026-10-13 本地交付与回读

本地首批制品固定到提交 `880f0541a1eaec64b18d7cc38896678cd649611c`，四目标来源清单摘要均为 `8b4064b723f1f170de13e14da6f67c8d2a05e481f5b7c8286e661c826d4ae863`，`source_dirty=false`。Windows 与手机保留该批来源；电视后续焦点修复制品另行记录，下面旧电视包只保留为构建候选。文档后续更新与制品源码提交分别记录。

本轮依据实际构建修正了 split APK 的 ABI/flavor 文件名顺序及 Kotlin 缓存排除；TV universal 原生依赖原先混入 x86_64 残片，已依据 Flutter 本次目标过滤，保留 split 模式原有逻辑。失败候选单独保留，没有交付为成功包。

| 文件 | 字节数 | SHA256 |
| --- | ---: | --- |
| `Kazumi-Plus-0.1.0-android-tv-arm.apk` | 50,669,478 | `63ac24e6e84780a2cce237d5aeb035b5cc57722e5cc37564d42ef77d6296a30b` |
| `Kazumi-Plus-0.1.0-multiplatform-20261013-android-arm64.apk` | 30,588,421 | `e56d4d63616dea29a9bf3735318a846015ddad157e825cbb5b037e19c689ccc5` |
| `Kazumi-Plus-0.1.0-multiplatform-20261013-windows-x64.zip` | 40,605,246 | `0b09702dfbd7a28555d5f02336ce8a57dc4c36447fd3db9617c2100560251ef0` |

Windows ZIP 的 65 个构建文件及 LICENSE 共 66/66 条目逐流验证通过。本地首批主 SHA256SUMS 对当时 9 个分发文件读回一致；旧包未改，旧 Windows ZIP 摘要已纠正，日期专用 sources 摘要 3/3 一致。构建来源、工具版本、签名指纹及日志路径见 `dist/multi-platform-build-20261013.json`。后续电视包和源码快照完成后，主清单按实际文件重新汇总。

Android 手机回归使用真实 ARM64 Release 包，设备实际 `base.apk` 摘要与分发包一致；运行环境为 API36 x86_64 模拟器及 `libndk_translation.so`，不称为 ARM 真机。保数据安装后和冷启动后的三条旧片单均保留；电视剧第1集从 28:52 冷续播，日志确认位置 1732000ms 与 1920×1080 解码，画面前进后正常退出保存 34:57。电影旧进度 15:32 保留，续播确认 932000ms 与 1920×1080，前进并保存 15:50。证据为 `.tools/logs/mobile-regression-20261013/summary.json` 与同目录截图/脱敏日志。开发设备此前安装 x64 Debug versionCode14，本次仅在该隔离模拟器使用保数据 `install -r -d` 安装 ARM64 Release versionCode12；没有卸载原数据，保留原手机发布版本策略。

Windows 回归从本批 ZIP 解压启动，EXE 摘要与制品一致。电视剧第2集旧 8:00 进度在首帧日志精确读回 480000ms、1920×1080，正常退出保存 16:46；电影正片实际 1920×1080 出画、总长 1:22:16，退出保存 1:26。通过应用内正常退出后启动新进程，原电视剧收藏与两条进度均再次读回；动漫目录可见，本轮未重复 Windows 动漫播放全套核验。证据为 `.tools/logs/windows-regression-20261013/summary.json` 与同目录截图/选摘日志，验收进程和窗口均已正常退出。

Windows 首次暴风国产剧目录出现一次 12 秒 receiveTimeout；保留原日志，同 API 独立采样 200，应用点击重试后目录及后续播放成功。没有据单次超时修改代理、DNS、来源或超时设置。该请求使用普通 pluginDio，不经过 Bangumi ECH 适配器；这次恢复不能保证后续源站可用性。

电视 Debug 已用遥控器完成首启、三频道入口、电视剧搜索/详情/收藏、播放暂停、进度 ±10 秒、1.25 倍速、线路/选集、媒体键、前后集与两次返回、卡片焦点恢复及冷启动流程。媒体键状态同时回读 Android media_session，影视样本实际 1920×1080 出画；最终 ARM Release 运行、电影/动漫及异常场景按电视验收摘要继续记录，未完成项不冒充通过。

最终遥控器核验发现嵌套 RouterOutlet 的内容焦点范围默认在方向边界停止，导致 Left 无法回到侧栏。修复仅为电视内容区添加专属方向策略：先沿用正常遍历，只有当前有效内容页的真实左边界才返回选中入口；排除弹层、被覆盖路由和文本编辑，保留播放器叶层快退处理。具体代码已独立静态交叉审查，运行通过项待新包读回后追加。

新电视制品单独固定到 `b05996934ee48a00e5350a97732d1a77081e3f46`；TV Debug、TV Release 均退出 0，干净来源清单内容摘要为 `84dc1bcab8817542dd5f92a804d30179e65dd9d7d4526d71fe11e33abb61adf2`。正式新包 `dist/Kazumi-Plus-0.1.0-tv-20261013-b0599693-android-arm.apk` 为 50,673,438 字节，SHA256 `7715a5291d780eda1e96fd280a00976cbbfe8e977e6a2daef23f537046ae5de4`；包名 `app.kazumiplus.client.tv`，versionCode 1，仅 ARM64/ARMv7，各有 libapp/libflutter/libech_http/libmpv 四个主要原生库。专用签名身份保持不变；独立清单为 `dist/tv-build-20261013-b0599693.json`、`dist/tv-source-manifest-20261013-b0599693.json` 与 `dist/SHA256SUMS-tv-20261013-b0599693.txt`，3/3 摘要读回一致。最终运行证据另记，不把构建清单的 pending 状态算作运行通过。

b0599693 的真实 ARM64 Release 已在 API36 x64/NDK 转换环境安装，实际 base.apk 摘要一致且无 DEBUGGABLE。遥控器首启、电视剧 1920×1080 实播、系统 media_session 暂停与精确 +10 秒/继续播放、收藏和冷续播通过；退出保存 0:59，冷启详情保留该值，再播起点 59000ms 并实际推进。片单及“我的”内容区 Left 回侧栏通过，动漫详情与来源查询可访问。证据为 `.tools/logs/tv-release-acceptance-20261013-b0599693/`；完整结论以最终摘要为准。

后续规则页核验观察到原生搜索框一获焦就进入 IME，方向键用于编辑，增加到达上方规则动作的困难。仅电视规则搜索改用媒体搜索已有的 `TvSearchBox`：先方向聚焦按钮、确认后输入、提交返回搜索按钮，独立清除动作恢复全列表；手机/桌面保留即时 TextField 过滤。具体差异独立静态审查通过，不将旧入口断言为必然不可达。该修复的新 TV Release 来源与运行结果待构建后另记，播放与存储核心没有修改。

## 最终电视包与分阶段运行证据

最终电视发行包固定到 `60096ad9447899a38154c9076bfcf971b7dd1e5d`，文件 `dist/Kazumi-Plus-0.1.0-tv-20261013-60096ad9-android-arm.apk` 为 50,681,226 字节，SHA256 `e2164a3ff96a6055502852a97886a49c885d013b1633f0b28b541c84188547a0`。真实设备 `base.apk` 摘要一致，ARM64、非 DEBUGGABLE；包名、API24 下限、versionCode1、ARM64/ARMv7 两组原生库及固定发布证书均回读通过。来源清单内容摘要 `51df638f28dcff4ebf8c1bf8184b6ee2561df5195ce25bd6acc76dc1d339e1a9`，构建后工作区干净。

运行环境为官方 Android TV API36 x86_64 模拟器，通过 NDK 转换运行真实 ARM64 Release；不是物理电视硬解验收。最终包保数据升级后，原《蒸蒸日上》在看片单、电视剧历史 1 条与电影历史 1 条保留。初始化续播日志确认电视剧 90000ms、电影正片 496000ms，均为 1920×1080。电影真实画面推进至 16:52，系统媒体暂停后保存 24:45；正常退出播放器再强停应用冷启动，“我的”再次读回两条历史与电影 24:45。

电视剧续播初始化后又出现已知来源广告低 PTS：恢复确认 1:30 后，实际暂停位置为 19463ms，退出保存 0:19。该来源断点仍未修复，不能把初始化成功写成整段播放进度稳定；本轮没有据此修改预置过滤规则或掩盖保存值。电影样本未观察到同类下降。播放控制、音频输出质量、来源时间轴和存储持久化分别记录。

最终包规则仓库遥控器经过搜索按钮不会自动进入 IME，确认后打开输入弹窗；`DM84` 查询过滤为单一结果，独立清除恢复 16 条仓库规则。添加规则中的网址入口可达；无效网址失败显示安全中文原因，确认导入禁用，取消后原 6 条规则保留。规则管理同类过滤与清空在上一阶段 `2d0084ce` 已核验；各阶段分别保存证据，不合并成同一来源包。

`2d0084ce` 阶段通过模拟器 60000ms 网络延迟实际触发目录超时；恢复 0ms 后，原刷新入口重试成功。这证明模拟延迟超时恢复，不是物理断网实测。唯一 WebView 提供者停用尝试被 Android 系统自动恢复，缺失条件没有成立；恢复原 default 状态后回读，WebView 缺失场景仍为未验。

证据分别为 `.tools/logs/tv-release-acceptance-20261013-b0599693/summary.json`、`.tools/logs/tv-release-acceptance-20261013-2d0084ce/summary.json` 及 `.tools/logs/tv-release-acceptance-20261013-60096ad9/`。b059 Release 的遥控器首启、精确 +10000ms 和冷续播结果保留；倍速与切集来自更早 Debug 阶段的 `.tools/logs/tv-acceptance-5346/`，不冒称发行包新验收。最终包只声称实际重新核验的范围；缺少 WebView 的真实设备、物理电视硬解、音画同步与跨来源长时间稳定性未验证。

最终包另行补充动漫实播：遥控器进入《FX战士久留美》详情，选择7sefun第01集后实际出画，截图为5:58/23:45；后续另一清晰画面为12:22，媒体暂停键127使系统会话变为PAUSED，读回742992ms及该作品/集数/来源元数据。只核验这一实际来源样本，没有把来源搜索结果或其它来源可达当作实播。原600阶段摘要保留当时边界，后续补充记录使用同目录 `anime-supplement.json` 与 `anime-*.png`，不改写旧阶段结果。

任务专属电视 AVD 在核实名称 `KazumiPlus_TV_API36` 后已关闭并保留用户数据；手机版回归 AVD 与 Windows 验收窗口也已结束。构建快照内的 runtime pending 保留原值，后续实际运行状态由独立摘要说明。

## Apple 云运行与真实冻结记录

首轮 [run 38321481344](https://github.com/wy32428011/kazumi-plus/actions/runs/38321481344) 固定到 `60096ad9`，实际检查发现已安装 xcodeproj1.27.0 仍被 Ruby 默认激活的 1.28.1 覆盖。`39529380` 为本次 runner 的 Ruby 子进程增加明确激活约束，版本检查、直接 pod 及 Flutter 派生 pod 共用固定环境，并回读实际 gem 版本和目录；没有降低工具门槛。

第二轮 [bootstrap 38325841491](https://github.com/wy32428011/kazumi-plus/actions/runs/38325841491) 固定到 `395293809d0ac7ea246415684568f059196b3fec`，Mac/iOS job 均 success。结果明确为 `dependency_locks_generated_pending_freeze` / 退出78；只生成真实锁，不产生成品。两个 Artifact ZIP 摘要与服务端 digest 一致。回读 macOS Pod 锁 `4295ab8e2f025032939994c21ab25845b618ff244656455ec77825bbdf2f22f7`、iOS Pod 锁 `8c65b3d0f269693e4d5cb438f3ab3a4358b80f4f730a713182b64053b14cb559` 和项目工作区 SwiftPM 锁 `da9cca960dd7d3cf2d66f3bda1bc564131ef8059193b4ee46d86204be88cdf4c`，tracked 源码迁移为0、pubspec.lock不变；三份锁原样纳入 `5aa76cf409d67eaa6c59a1f799dc8964f8fcbdae`。

第三轮 [正式构建 38334552951](https://github.com/wy32428011/kazumi-plus/actions/runs/38334552951) 的 Mac/iOS Flutter 编译均退出0，随后按门槛阻断。iOS 新生成应用工作区同内容 SwiftPM 锁，需要将真实生成文件补入冻结；Mac 实际检查发现三个原生资产库的两种架构最低系统13，违反约定的12。正在依据实际日志处理并重建；失败候选和日志保留，不作为合格 DMG/IPA 交付。

第四轮 [正式构建 38343896839](https://github.com/wy32428011/kazumi-plus/actions/runs/38343896839) 固定到 `dbc5e5227e55ec0714aba1493567a13bf0e26769`。iOS 已完全通过并下载真实未签名 IPA：26,780,945 字节，SHA256 `a52ec8fc59384028c68abe8ea6f46baea9c968311729851f27577ce837842256`，本地解包的29个Mach-O路径/切片/摘要与云报告一致，最低系统15，应用无签名和 provisioning profile，构建后源码仍干净。该 IPA 保留这一实际来源，不随 Mac 后续修复改写提交。

Mac 最低系统适配仅在当前 job 的私有固定 SDK 副本执行：严格验证 Flutter revision 和原文件 SHA256 `197de2e6aabb6ec2098659927d90a862139257ff01037a5e6ec34412a63fb57c`，将原生资产默认13改为12，并验证修改后 SHA256 `129b422ba6569208313d34de25c5e3023a3cd31aef203d94ff381ffdb7cb87be`。清除副本旧工具快照后真正重建，结果记录 `modified_sdk=true`、源码补丁、新快照摘要和临时副本清理；不改共享缓存或成品 Mach-O 标记。第四轮 Mac 的双架构、全部切片最低12、ad-hoc签名、启动、DMG创建和hdiutil校验已通过。

第四轮 Mac 上传阶段耗时22分钟后因 Node 堆耗尽失败，没有可下载的 Mac Artifact。打包暂存目录的 `Applications -> /Applications` 快捷链接导致跟随符号链接的上传工具扫描宿主应用。现将该快捷链接限定在 `hdiutil create/verify` 的 try/finally 作用域，完成或失败即从上传暂存目录移除；已封装 DMG 内仍含安装快捷链接。仅重跑 Mac 正式目标，iOS 合格包和所有旧证据保留，Mac 成品等待成功上传后的读回。

## 最终 Apple 成品交付

第五轮 `38350132165` 已证明上传修复生效：537个文件约14秒完成，源码 `535ffa7e`。该轮DMG未执行实际挂载读回，作为中间成功候选保留；最终包追加真实只读挂载门禁后采用第六轮结果。

最终 [macOS run 38354548818](https://github.com/wy32428011/kazumi-plus/actions/runs/38354548818) 为 success，源码 `cfd5a774ef5c14b94149cd24d017ab266233e032`、`source_dirty=false`，构建后源码状态为空。云Artifact ZIP摘要 `7366d5096b3786107f3f2cf2192beccb4bf94aba20bac8e93e05500e96c6d727` 与服务端digest一致。实际DMG包含29个原生Mach-O文件，每个均有arm64+x86_64且最低系统不超过12；上传内部链接展开后的85条本地原生路径也逐项核对，两端记录与原始29个文件的字节/切片一致。

DMG在云端实际 `hdiutil attach -readonly -nobrowse` 挂载到本任务临时目录，确认卷确为只读，读取卷内 `Kazumi Plus.app` 的完整结构和全部原生文件，报告与打包前完全一致；挂载应用 `codesign --verify --deep --strict` 通过。最后实际卸载磁盘并清理空挂载点，`read_only`、`binaries_equal_staged_app`、`signature_verified`、`detached`、`mountpoint_cleaned` 均为true。ARM64云主程序观察25.017秒，无提前退出或致命加载标记，随后由脚本结束；Intel实机、macOS12实机UI及播放未验证。

| 本地成品 | 字节数 | SHA256 | 实际来源 |
| --- | ---: | --- | --- |
| `Kazumi-Plus-0.1.0-apple-20261013-cfd5a774-macos-universal.dmg` | 59,637,188 | `44742e7ff0a23cdadd1bef33859006e9534d3a44c5cb998ef3d3103af99e8e8c` | macOS `cfd5a774` / run38354548818 |
| `Kazumi-Plus-0.1.0-apple-20261013-dbc5e522-ios-arm64-unsigned.ipa` | 26,780,945 | `a52ec8fc59384028c68abe8ea6f46baea9c968311729851f27577ce837842256` | iOS `dbc5e522` / run38343896839 |

两个成品均复制到本地 `dist/` 并再次核对实际SHA。`dist/apple-build-20261013.json` 分平台记录真实提交、run/job/artifact、ZIP digest、源码清单、签名、启动、挂载及私有SDK适配信息。完整小证据在 `dist/apple-evidence-20261013/{ios,macos}/`，独立校验在 `dist/SHA256SUMS-apple-20261013.txt`。Mac源码清单内容摘要为 `63ea61951ff14c3b94b52634c3e98ae7d13e1e8c7018888add982640f2aa97f3`；iOS为 `2e188f791d6df84eed32aaba43b1313afda7bbe0809e5f4e41bb5cc3f7481c53`，不冒称两包来自同一个源码提交。

DMG为ad-hoc签名且未公证；IPA应用未签名、无provisioning profile，其内原生框架可能带ad-hoc签名。iOS仅完成构建交付，不包含安装、启动或播放。Apple首期产物交付完成，实机验证边界仍保留。Windows/手机 `880f`、电视 `60096ad9` 的既有运行证据不被Apple脚本后续提交替换。
