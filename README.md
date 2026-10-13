# Kazumi Plus

基于 [Predidit/Kazumi](https://github.com/Predidit/Kazumi) 的独立 Flutter 客户端，提供动漫、电视剧、电影三个频道。开发基线为 `4960f9c04246eb52e1f36728f0f5c60ae6fa54dc`，当前版本为 `0.1.0+1`。

![Kazumi Plus](assets/images/logo/logo_rounded.png)

## 首版功能

| 能力 | 动漫 | 电视剧 / 电影 |
| --- | --- | --- |
| 资料 | 原有 Bangumi 目录、搜索与详情 | 当前影视规则提供分类、海报、简介、演职员等资料 |
| 来源 | 兼容原有 XPath/API 规则 | 预置暴风、速播、魔都、光速影视，支持导入、编辑、启停和更新 |
| 浏览与搜索 | 保留原有体验 | 独立频道、分类分页、按来源分组搜索 |
| 播放 | 原有播放器与附属能力 | 复用原播放内核，支持线路、选集、暂停、拖动、倍速、全屏 |
| 片单与历史 | 保留原数据模型和动漫同步 | 本地独立保存，跨频道统一筛选与续播 |
| 下载 / 云同步 / 一起看 / 自动弹幕 | 原有能力 | 后续版本范围 |

电视剧只使用来源实际提供的季结构；缺少季信息时显示来源剧集。当前可用集数不代表整季完结总集数。电影使用正片或来源版本，评分等缺失字段不补造。

Windows、Android 手机版与安卓电视版已完成本地构建和限定运行核验。个人[私有源码仓库](https://github.com/wy32428011/kazumi-plus)已创建并推送，macOS Universal DMG 与 iOS/iPadOS 未签名 IPA 已完成真实云构建、产物检查和本地文件回读；当前结果与验收边界见 [多平台实施记录](docs/multi-platform-implementation.md)。

## 使用与数据隔离

推荐页顶部切换动漫、电视剧、电影；影视频道选择来源和分类，从卡片或搜索进入详情，再选择线路和播放项。片单和历史支持全部、动漫、电视剧、电影筛选。

- Android 包名为 `app.kazumiplus.client`，Windows 程序为 `kazumi_plus.exe`，可以与原版并存。
- 独立版使用新数据目录，不扫描或搬移原版库。原规则仍可导入；原版完整数据迁移工具暂未提供。
- 动漫 WebDAV 根目录为 `/kazumiPlusSync`。影视片单与进度仅保存在本机，不进入 Bangumi 或动漫 WebDAV 同步。
- 影视规则删除或停用后，片单和历史保留摘要快照；重新启用相同规则编号可恢复关联。
- Android 影视默认自动解码遵循播放器的平台兼容判断；模拟器使用软件解码，真机保留硬解能力。恢复进度在视频输出初始化后定位并核对实际位置，确认前不覆盖原记录。
- 新增随包影视来源在首次运行该版本时按来源编号增量安装；保留已有规则及禁用状态，用户删除已提供的来源后不会在下次启动自动重装。来源可能失效，界面提供重试和规则管理入口。
- 应用不使用原版安装包更新渠道。发布者可通过 `KAZUMI_PLUS_UPDATE_URL` 编译参数配置独立更新地址；缺省使用独立版发布包更新。

影视规则协议与完整示例见 [规则说明](docs/media-rules.md) 和 [暴风预置规则](assets/plugins/baofeng.json)。2026-10-12 新增来源与可用性证据见 [来源扩充记录](docs/media-sources-2026-10-12.md)。

### 2026-10-12 影视来源扩充

电影和电视剧来源从1个增加到4个。原暴风影视保留，新增以下来源，两个频道均支持分类、分页、搜索、详情和选集：

| 来源 | 电影分类数 | 电视剧分类数 | 随包规则 |
| --- | ---: | ---: | --- |
| 速播影视 | 8 | 7 | [subo.json](assets/plugins/subo.json) |
| 魔都影视 | 17 | 8 | [modu.json](assets/plugins/modu.json) |
| 光速影视 | 9 | 7 | [guangsu.json](assets/plugins/guangsu.json) |

启动新版后，在电视剧或电影频道的来源选择处切换。当前来源偏好会保留；可以在影视搜索页选择全部来源搜索。旧版也可进入规则管理的「导入规则」，粘贴 `dist/Kazumi-Plus-extra-media-sources-20261012.json` 文件的完整 JSON 数组，一次导入三个新增来源。

本次通过真实请求和应用现有解析器核对分类、目录两页、搜索、详情、选集、HLS主/子清单、加密密钥及首分片；未新增或运行自动化测试。源站内容可能重合，分类数不等于独立影片数。新来源尚未逐一进行播放器音画验收，单次媒体链抽样成功也不保证全部历史影片或后续网络状态。

新增来源包使用日期后缀，保留此前交付包：`dist/Kazumi-Plus-0.1.0-sources-20261012-windows-x64.zip`、`dist/Kazumi-Plus-0.1.0-sources-20261012-android-arm64.apk`。本次校验值见 `dist/SHA256SUMS-sources-20261012.txt`，构建和启动回读状态见来源扩充记录。

需要重新核实源站时，可从项目根目录执行以下命令。该脚本读取随包规则，并调用应用正在使用的资料及选集解析器；每个来源的API请求串行且保留1秒间隔。

```powershell
& '.\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe' run scripts\inspect_media_sources.dart .tools/media-sources-live subo modu guangsu
```

失败会返回非零退出码；原始响应、媒体清单和摘要写入指定目录。仅做抽样检查，不下载完整影片。

## 构建

环境要求与 `pubspec.yaml` 一致：Flutter `3.47.7`、Dart `>=3.10.0 <4.0.0`。Windows 需要 Visual Studio C++ 桌面组件；Android 使用 SDK36、NDK `28.2.13676358` 及兼容 JDK。

本任务的 SDK 安装在 `.tools/flutter`，该目录不纳入 Git。使用已安装 Flutter 时将下面的路径替换成相应命令。

```powershell
& '.\.tools\flutter\bin\flutter.bat' analyze --no-fatal-infos --fatal-warnings
& '.\scripts\build_plus.ps1' -Target WindowsRelease
& '.\scripts\build_plus.ps1' -Target AndroidRelease
# 专属模拟器的 x86_64 调试构建：
& '.\scripts\build_plus.ps1' -Target AndroidDebug
```

构建脚本需要 PowerShell 7.2+，默认要求干净源码提交，记录提交及逐文件摘要；开发构建可显式传 `-AllowDirty` 并保留 dirty 标记。脚本仅在当前进程启用 Git 长路径，并为 Windows 上的 Android 构建传入 `kotlin.incremental=false`，避免跨盘增量缓存错误。保留 Flutter 的依赖检查和平台注册器刷新，确保 debug/release 切换正确排除开发专用插件。指定其他 SDK 时使用 `-FlutterRoot` 参数。

原版 `ech_http 0.2.1` 的 CA 字符串触发 MSVC C2026。项目通过本地 `dependency_overrides` 引用保留完整 CA 字节的最小补丁，未修改全局 Pub 缓存。来源、哈希和修复说明见 [ech_http 补丁记录](third_party/ech_http/KAZUMI_PLUS_PATCH.md)。Windows runner 显式使用 UTF-8 编译中文注释，保留编译警告检查。

独立图标来自项目内几何标识，可使用 `scripts/generate_plus_icons.ps1` 重新生成。

### Windows 便携包与 Android APK

`build_plus.ps1` 负责构建，压缩和复制产物需要另行执行。Windows 构建结果在 `build/windows/x64/runner/Release`，必须保留整个目录里的 DLL 和 `data`，不能只分发 `kazumi_plus.exe`。

```powershell
Set-Location 'F:\kazumi-plus'
& 'F:\kazumi-plus\scripts\build_plus.ps1' -Target WindowsRelease
New-Item -ItemType Directory -Path 'F:\kazumi-plus\dist' -Force | Out-Null
$packageBatch = 'manual-' + (git rev-parse --short HEAD).Trim()
$windowsZip = "F:\kazumi-plus\dist\Kazumi-Plus-0.1.0-$packageBatch-windows-x64.zip"
if (Test-Path -LiteralPath $windowsZip) { throw '该批次已经存在，请保留旧包并使用新的批次名称。' }
Copy-Item -LiteralPath 'F:\kazumi-plus\LICENSE' -Destination 'F:\kazumi-plus\build\windows\x64\runner\Release\LICENSE' -Force
Compress-Archive -Path 'F:\kazumi-plus\build\windows\x64\runner\Release\*' -DestinationPath $windowsZip

& 'F:\kazumi-plus\scripts\build_plus.ps1' -Target AndroidRelease
$mobileApk = "F:\kazumi-plus\dist\Kazumi-Plus-0.1.0-$packageBatch-android-arm64.apk"
if (Test-Path -LiteralPath $mobileApk) { throw '该批次已经存在，请保留旧包并使用新的批次名称。' }
Copy-Item -LiteralPath 'F:\kazumi-plus\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk' -Destination $mobileApk
```

以上路径对应本次工作目录，换目录时一起调整。脚本缺省使用 `.tools/flutter`，也可用 `-FlutterRoot` 指定 SDK。重建前退出从对应 Release 目录运行的程序，避免文件占用。

Windows 用户完整解压 ZIP 后运行 `kazumi_plus.exe`。分发到其他电脑时还需处理 Visual C++ 运行库依赖，参见 [Flutter Windows 部署文档](https://docs.flutter.dev/platform-integration/windows/building)。Android 手机版 Release 延续原调试证书；正式手机发行需要另配发布签名，参见 [Flutter Android 签名文档](https://docs.flutter.dev/deployment/android#sign-the-app)。电视 Release 已固定独立发布证书，后续升级应保持该签名身份。

## 实施与验证记录

### macOS、iOS 与安卓电视版

本轮已交付 macOS 12 起的 Universal DMG、iOS 15 起的未签名 ARM64 IPA，以及 API 24 起的 Android TV/Google TV/安卓盒子版本。苹果端已接入个人私有仓库，真实 CocoaPods 和 SwiftPM 锁已回读并冻结。Mac 包的全部29个原生文件均为双架构，实际只读挂载后的结构与签名检查通过，ARM64云主机启动25秒无致命错误；iOS包的29个原生文件、Payload结构及未签名状态通过检查。本轮不包含真实Mac播放或iPhone/iPad安装。

电视版使用独立 `app.kazumiplus.client.tv` 包名和遥控器界面，三类内容复用现有资料、规则、收藏与播放内核。新增“从网址导入”支持下载预览后确认保存；电视提供内置规则、规则仓库与网址导入。缺少系统 WebView 时仍能启动，网页解析来源显示原因并允许换源。

Windows、手机包绑定源码提交 `880f0541a1eaec64b18d7cc38896678cd649611c`；最终电视包包含侧栏焦点及规则搜索确认输入修复，单独绑定 `60096ad9447899a38154c9076bfcf971b7dd1e5d`。各自串行构建、签名/包名/架构及干净源码清单后验均退出 0；电视发布包仅含 ARM64、ARMv7，两组播放原生库齐全。后续 Apple 与文档提交不会改变既有包的来源。

| 平台 | 当前分发文件 | 验证结果 |
| --- | --- | --- |
| Android TV / Google TV / 安卓盒子 | [电视 ARM APK](dist/Kazumi-Plus-0.1.0-tv-20261013-60096ad9-android-arm.apk) | 最终包哈希、保数据升级、动漫/影视实播、媒体暂停、规则搜索/清空、导入失败保规则及电影冷启动回读通过；来源 PTS 与真机边界见下文 |
| Android 手机 | [手机 ARM64 APK](dist/Kazumi-Plus-0.1.0-multiplatform-20261013-android-arm64.apk) | 实际 ARM64 Release 包在 x64 模拟器转换环境中完成旧片单保留、电视剧/电影续播与保存；真机待验 |
| Windows x64 | [Windows 便携 ZIP](dist/Kazumi-Plus-0.1.0-multiplatform-20261013-windows-x64.zip) | ZIP 66/66 文件摘要核对通过；解压包的影视播放、旧收藏及退出重启进度回读通过 |
| macOS 12+ | [Universal DMG](dist/Kazumi-Plus-0.1.0-apple-20261013-cfd5a774-macos-universal.dmg) | ARM64+Intel全部原生文件、实际只读挂载、ad-hoc签名和云端启动通过；真实Mac播放待验 |
| iOS / iPadOS 15+ | [ARM64 未签名 IPA](dist/Kazumi-Plus-0.1.0-apple-20261013-dbc5e522-ios-arm64-unsigned.ipa) | Release构建、29个原生文件、包体及应用未签名状态通过；未安装到真机 |

表中的安装包位于本地 `dist/`，该目录不随源码推送。Apple 云制品及证据通过个人仓库的 [Actions 构建页](https://github.com/wy32428011/kazumi-plus/actions/workflows/plus-build.yaml) 交付；首次仅使用私有 Artifacts，配置保留14天。本地副本不受云端保留期影响。

macOS 成品来源为 `cfd5a774ef5c14b94149cd24d017ab266233e032`，iOS 成品来源为 `dbc5e5227e55ec0714aba1493567a13bf0e26769`。两端按真实构建提交分别记录，后续文档提交不改变安装包来源。Apple签名、架构、最低系统、启动及挂载结果见 [Apple构建清单](dist/apple-build-20261013.json)。

本轮统一文件、实际运行状态与源码快照见 [交付摘要](dist/delivery-20261013.json)。源码ZIP由最终文档提交执行 `git archive`，只含已跟踪源码；构建工具缓存和本地签名私钥不包含在快照中。总校验清单按实际分发文件重新计算，保留旧包的来源和摘要。

在 Mac 上挂载 DMG，将 `Kazumi Plus.app` 拖到「应用程序」。该包使用 ad-hoc 签名，未做 Developer ID 公证；首次打开按 [Apple 官方说明](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac) 处理。iOS IPA 为未签名设备版构建，当前不能直接安装；本轮不提供签名、侧载或商店发布流程。

Windows、手机及首批文件的实际校验值见 [SHA256SUMS.txt](dist/SHA256SUMS.txt)，本批来源见 [平台构建清单](dist/multi-platform-build-20261013.json)。最终电视另有 [构建清单](dist/tv-build-20261013-60096ad9.json) 和 [专用校验和](dist/SHA256SUMS-tv-20261013-60096ad9.txt)。构建清单是构建时快照，实际运行结论单独保存在对应验收摘要中。旧包全部保留；旧 Windows ZIP 的过时校验值已按实际文件纠正。详细命令、固定工具链、产物检查和运行边界见 [多平台实施记录](docs/multi-platform-implementation.md)。

首版历史任务状态与环境证据见 [实施记录](docs/kazumi-plus-implementation.md)。2026-10-12 的 Windows 验收曾由用户中止；2026-10-13 按多平台方案另行验证本批新 ZIP，已完成电视剧/电影出画、续播和重启持久化。各次验收按对应包与源码区分。构建通过、HLS 清单可达、实际画面和音频实测分别记录；按照本次需求未新增或运行全套自动化测试。

首版旧包 `dist/Kazumi-Plus-0.1.0-windows-x64.zip`、`dist/Kazumi-Plus-0.1.0-android-arm64.apk` 及前次 `dist/Kazumi-Plus-0.1.0-android-tv-arm.apk` 保留供历史对照；本轮使用上表带日期与来源标识的新包。手机版 Release 延续原调试证书，电视 Release 使用专用发布证书；ARM 真机运行尚未验证。

已知来源边界：暴风某些剧集的插播使用独立 PTS 时间轴，插播期间退出可能保存偏低的进度。已确认首集约300.68秒断点样本；初始化续播定位与这个来源断点分别记录。现有来源广告过滤开关可配置，但该断点的修复尚未计为通过，未把候选过滤设置默认写入预置规则。

## 来源、许可证与致谢

本项目保留上游 GPL-3.0 许可证，见 [LICENSE](LICENSE)。上游原始说明可查阅 [固定基线 README](https://github.com/Predidit/Kazumi/blob/4960f9c04246eb52e1f36728f0f5c60ae6fa54dc/README.md)。

感谢 Kazumi 及其贡献者，以及 Bangumi、media-kit、XPathSelector、Hive、弹弹play、Anime4K、SyncPlay、trace.moe 等上游依赖和服务。字体仍使用 Mi Sans，相关权利归原作者。Kazumi Plus 使用本项目生成的几何图标；上游授权插画的权利仍归其作者，不随 GPL 代码授权转移。

本程序不新增遥测或服务器端资料聚合服务。作品资料和媒体由当前选择的来源提供。
