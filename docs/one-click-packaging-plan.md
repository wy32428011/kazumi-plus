# 一键打包需求与执行计划

日期：2026-10-13。

## 已确定需求

- 在 Windows 项目根目录交付可双击的 `一键打包.exe`，启动即执行，无需输入打包命令。
- 默认串行构建 Windows x64 Release、Android 手机 ARM64 Release、Android TV ARMv7/ARM64 Release；支持参数单独选择目标。
- 复用 `scripts/build_plus.ps1` 的 Flutter 3.47.7、源码稳定性、签名、包名与 ABI 校验，保留手机及电视已有签名身份。
- 双击入口打包当前工作区，显式传入 `-AllowDirty` 并在日志与清单保留实际状态；需要干净提交时可使用严格参数。
- 构建后自动生成完整 Windows ZIP、手机 APK、电视 APK、SHA256 校验和及构建清单。每次运行使用新的批次目录，历史安装包保持可追溯。
- Windows ZIP 包含完整运行目录及 LICENSE，排除 PDB；安卓每个目标完成后立即复制，避免共享构建目录被下一目标刷新。
- 控制台显示阶段、日志、错误及最终路径，成功时打开产物目录，结束时保留窗口供阅读；脚本调用可关闭这些交互。
- 构建期间互斥，重复启动明确提示；失败退出非零，不将旧产物或部分完成的批次显示为成功。
- 项目路径根据程序所在位置解析，不硬编码盘符。Windows 自带 PowerShell 5.1 不满足要求，入口自动定位 PowerShell 7.2+。
- macOS/iOS 沿用现有 Apple 云构建，本入口范围为上述三种本地目标。

## 分工与执行顺序

1. 主代理实现自动构建、打包、产物回读及失败处理，并增加明确绑定本次运行的构建证据目录。
2. 子代理实现轻量 Windows 可执行入口及其生成脚本，使用系统 .NET Framework 编译器，避免新安装依赖。
3. 子代理独立审查调用参数、源码来源、签名、路径与失败传播；更新 README 使用说明。
4. 完成源码后冻结修改，生成 EXE，从该入口实际运行全部三个目标，逐文件回读 ZIP/APK 和 SHA256，记录真实完成情况。

## 验证与交付标准

遵循用户要求，不新增或运行自动化测试套件。以脚本语法检查、入口编译、真实 Release 构建、原有签名/包名/ABI 校验、归档逐文件摘要回读、最终批次清单回读及交叉审查证明可用。构建与打包完成不改变既有设备播放验收边界。

检查任务所属残留进程，按已知归属清理；本次不启动 Node.js 或 Chrome。其他会话的 Codex 服务、浏览器及构建进程不归本任务回收。交付前更新 README 和实际执行记录。

## 实际完成记录

2026-10-13 已完成入口、自动打包流程、README 使用说明及独立交叉审查。

- 根目录 `一键打包.exe` 已生成，大小 9,728 字节；启动器源码为 `scripts/packager/Launcher.cs`，再生成命令为 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/build_packager.ps1`。
- 入口可显示中文帮助；不支持的目标返回 2；严格模式对当前未提交工作区返回 1；已有任务运行时第二个入口返回 1，不启动第二次构建。
- 交叉审查修正单目标数组折叠导致 StrictMode 下 `.Count` 失败的问题，目标列表显式保持数组。
- 实际重复生成修正 Windows PowerShell 5.1 将 `File.Replace` 的空备份参数绑定成空字符串的问题，改用本次唯一备份文件；连续两次生成均退出 0，生成临时目录无文件残留。
- 从 EXE 执行 `--no-pause --no-open`，默认全部三目标仍自动构建；2026-10-13 20:55:28 开始，21:00:05 完成，退出码 0，耗时约 4 分 37 秒。
- 成功批次为 `dist/packages/20261013-205528-289-7a81c1ef-fd94cbb4/`，对应 `.partial` 目录已转为正式批次；运行记录为 `.tools/logs/package-20261013-205528-289-7a81c1ef-fd94cbb4/result.json`。
- 三目标均绑定提交 `7a81c1ef619859e460f725b6225749d0660630db` 及实际未提交源码，`source_dirty=true`，共同源码摘要 `44fda517c0d5ad8a07414d0aa112148450b097a74b27be550134d7b876c07023`。

| 本次文件 | 字节数 | 产物核验 |
| --- | ---: | --- |
| `Kazumi-Plus-0.1.0-windows-x64.zip` | 40,602,646 | 66 个 ZIP 条目逐文件长度、SHA256 与本次构建证据一致 |
| `Kazumi-Plus-0.1.0-android-arm64.apk` | 30,598,533 | `app.kazumiplus.client` / versionCode 12 / ARM64；原固定手机调试证书 |
| `Kazumi-Plus-0.1.0-android-tv-arm.apk` | 50,681,226 | `app.kazumiplus.client.tv` / versionCode 1 / ARM64+ARMv7；原固定电视发布证书 |

安装包及两份来源清单的 `SHA256SUMS.txt` 共 5 项均已独立回读一致，详细摘要保存在批次 `build-manifest.json` 和校验文件中。构建日志中的现有 NuGet/CMake、Gradle/AGP/Kotlin 版本提示未阻断实际构建，没有为处理提示升级工具链或跳过校验。

本次只证明打包程序及所选目标的构建、签名/架构检查、归档和摘要回读。未执行新一轮设备播放验收，未新增或运行自动化测试套件。产物来源按运行时源码快照记录，本文和 README 的验收补记不改变已生成产物的来源。

## Flutter 版本 JSON 附加提示修复计划

2026-10-13 用户运行批次 `20261013-210426-754-7a81c1ef-03d71fb0` 失败。原始版本文件第 1–15 行为完整 JSON，第 16 行开始追加 `The Flutter CLI developer tool` 遥测说明，脚本直接解析整个文件导致 `Additional text encountered after finished reading JSON content: T`。

修复要求：保留原始工具输出与退出码；使用完整 JSON 解析器读取第一个版本对象，生成纯版本 JSON 供后续校验；仍严格检查 Flutter 3.47.7，不通过截断固定行数或正则猜测 JSON 边界，也不修改全局遥测设置。解析失败时应明确显示原始日志位置。

执行顺序：子代理确认 SDK 的真实输出行为并实现版本读取修复；主代理用实际失败记录回读版本对象，独立审查后从 EXE 重新完成三个目标的真实构建及产物回读；最终更新 README 与本记录。旧失败批次继续保留为诊断证据。

### 修复验收结果

- SDK `packages/flutter_tools/lib/src/base/process.dart` 的退出钩子通过 `printStatus` 将首次遥测提示写入 stdout，单独分离 stderr 无法解决。本次保留完整输出，以 `scripts/flutter_version_json.ps1` 的 `JsonTextReader`/`JObject.Load` 读取完整首个对象；关闭自动日期转换以保留版本日期原文。
- 主代理与子代理均回读真实失败文件，成功获得版本 3.47.7、正确 SDK 路径及原样的 `engineCommitDate`；原始数据仍含提示，转换结果不含提示且通过严格 JSON 解析。独立交叉审查通过，脚本语法检查通过。
- 现有 EXE 执行全部三目标，2026-10-13 21:25:47 开始、21:27:23 完成，退出码 0，耗时约 1 分 37 秒。成功批次为 `dist/packages/20261013-212547-014-7a81c1ef-4a51e8f0/`，运行记录为 `.tools/logs/package-20261013-212547-014-7a81c1ef-4a51e8f0/result.json`。
- 三目标均生成原始版本输出 `flutter-version-output.log` 及纯版本数据 `flutter-version.json`；纯 JSON 都解析为 Flutter 3.47.7。
- Windows ZIP 的 66 个文件逐条回读通过；手机、电视保留原签名与架构检查，APK 复制后摘要一致。最终 SHA256 清单的 3 个安装包及 2 个来源清单共 5 项独立回读全部一致，正式批次无 `.partial` 后缀。
- 本批次来源摘要为 `b58528afaa0558a8e8e710a98f88e1aa61b5fe816cc75cc67a9eb77d89003955`，保持 `source_dirty=true`。修复验收后的文档补记不改变已生成产物的来源。

本轮未修改全局遥测配置，未重新生成签名，未新增或运行自动化测试套件。旧失败批次及原始错误文件保留用于追溯。

## 桌面启动依赖读取错误排查计划

2026-10-13 批次 `20261013-214238-460-7a81c1ef-1b5f21a7` 在 Windows 编译阶段退出 1，最早错误为 Pub 缓存文件读取失败，随后产生大量连锁编译错误。检查时 241 个依赖根目录在 PowerShell 和项目 Dart SDK 中均可读取，不能直接归因为依赖已删除。失败还导致 Windows、Linux、macOS 的 5 个生成插件注册文件被清空。

本次执行顺序：保留依赖配置及生成文件的失败现场；比较桌面控制台与后台调用的实际 SDK 路径行为；针对已证实的根因修复入口或构建准备阶段；由 Flutter 恢复插件注册并核对变化；从一键 EXE 完成三目标构建与产物回读；最后记录结果。不逐条修改依赖失败引起的业务代码错误，也不取消源码一致性检查。

独立桌面控制台复查批次 `20261013-215335-028-7a81c1ef-dbc7cfb5`：Windows 编译本身成功，Flutter 同时将 5 个被清空的生成文件恢复为首次失败前的准确内容；随后原打包流程因过早冻结源码而拒绝。首次调用期间依赖暂时不可读的外部触发没有再次复现，不能把错误文本中的 `/C:/` 直接认定为 Windows 路径转换错误。

已确定的修复规格：新增依赖准备阶段，显式执行锁定版本的 `flutter pub get`（优先离线，必要时联网），保留 SDK 版本原始日志；准备前备份生成文件并记录全部源码摘要；只允许 Windows/Linux 的 `.cc`、`.h`、`.cmake` 注册文件和 macOS 的 Swift 注册文件这 7 项生成内容变化，其他源码与锁文件变化拒绝继续；使用同一 SDK 的 Dart 标准库实际读取所有包的元数据及可用入口文件；确认插件元数据有效后冻结全部源码；每个平台编译前再次核对依赖。所有准备证据随包保存，正式构建期的完整来源校验保持有效。

### 原生库缓存的进一步发现与修复

批次 `20261013-221315-213-7a81c1ef-e6542b7c` 虽通过编译和普通文件摘要检查，独立回读却发现 Windows ZIP 只有 64 个条目，缺少 `libmpv-2.dll` 与 `media_kit_event_loop.dll`，原生资产清单也仅包含 ech_http。因此该批次已改标为 `invalid_missing_windows_runtime`，保存在带 `.invalid` 后缀的目录，原始结果已另存审计副本，不作为合格交付包。

已定位到 `.dart_tool/flutter_build/0df61be6a8ee9854d4a891415dff099a/build_hooks.stamp` 及 `build_hooks_result.json` 仍是 21:43:40 的残缺记录。此前依赖不可读时，Flutter 没有发现 media_kit 的 hook，却记录了只含 ech_http 的成功缓存；恢复依赖文件不会使这份缺少依赖项的缓存失效。SDK 又按残缺清单重新复制原生库，导致播放器 DLL 丢失。media_kit 的原始 libmpv 下载缓存及摘要核对正常，可以由现有 hook 重建，无需复制旧安装包文件。

新增修复：依赖可读后，只归档 `.dart_tool/flutter_build` 各配置的 `build_hooks.stamp` 和相关诊断 JSON/依赖记录，强制重新发现原生 hook；保留 hooks_runner 的有效下载和编译缓存。Windows 发布校验同时要求三个原生资产 ID 与对应 DLL 实体、非空尺寸相符，阻止仅靠编译退出状态或目录存在判定成功。

### 最终验收

2026-10-13 22:32:23 从现有 `一键打包.exe` 以独立桌面控制台启动，参数 `--no-pause --no-open` 仅关闭结束后的等待与文件夹弹出。监督进程持有实际 EXE 句柄，确认 22:35:13 退出码为 **0**。运行用户为同一普通 Windows 用户，未提升管理员权限。

合格批次：`dist/packages/20261013-223223-974-7a81c1ef-168ada6c/`。运行状态为 `packaged_and_verified` / `phase=complete`，记录位于 `.tools/logs/package-20261013-223223-974-7a81c1ef-168ada6c/result.json`。

- 依赖准备离线完成，`pubspec.lock` 与准备前摘要一致；源文件准备阶段无非预期变化。
- 已归档 7 项原生发现阶段缓存标记。原有 Windows 残缺记录停留在 21:43:40；重新构建后的完整 `build_hooks_result.json` 更新时间为 22:34:04，并包含 media_kit 与 ech_http。
- Windows、Android 手机、Android TV 的目标开始前均实际读回 241 个包元数据和 452 个项目直接导入，失败数 0。8 个合法没有 Dart 目录的资源/原生插件按可选目录处理，实际必需的导入仍强制可读。
- 三个目标的日志编译错误数为 0，APK 签名与架构校验通过。各目标共用源码摘要 `d6e990c63f15e34bcc253a9579a8a4ab6bb684c6777fc3b56f8b6fdd77816e58`，`source_dirty=true`。
- Windows ZIP 66 个条目逐文件摘要通过；直接打开 ZIP 回读确认 `libmpv-2.dll`（38,723,584 字节）、`media_kit_event_loop.dll`（104,448 字节）、`ech_http.dll`（2,106,880 字节）均存在，对应三个 `windows_x64` 原生资产绑定完全匹配。
- libmpv 随包摘要 `361e3a306707454a24e7d3558b2eb7a9ccc23a4f5ed396fe7e77f0a44908eda5` 与经核验的原始 hook 下载缓存一致；事件循环 DLL 由 hook 重新生成，没有从旧安装包补文件。
- 最终三个安装包与两份来源清单的 SHA256 共 5 项独立回读一致。先前缺库批次保留于 `.invalid` 目录且明确标为无效。

| 最终产物 | 字节数 | SHA256 |
| --- | ---: | --- |
| `Kazumi-Plus-0.1.0-windows-x64.zip` | 40,602,647 | `eb97116d30691ac8204790cce98bca9b2e4e7c2c5e52fd977d49ae9935e76279` |
| `Kazumi-Plus-0.1.0-android-arm64.apk` | 30,598,533 | `fcd4a4e22ace3e79d7c8dc8f9ec35dc434ec3409ee4569694396b7c74dbb8563` |
| `Kazumi-Plus-0.1.0-android-tv-arm.apk` | 50,681,226 | `e2164a3ff96a6055502852a97886a49c885d013b1633f0b28b541c84188547a0` |

本次没有新增或运行自动化测试套件，验收采用实际 SDK 读取、真实三端构建、签名/架构检查、ZIP 内容及摘要回读。原始那次依赖访问异常的瞬时触发未能再次复现；其留下的注册文件异常、冻结顺序错误和残缺原生库缓存已经确认并修复，入口增加了对应的前置检查和拒绝不完整产物的检查。本批未重复设备播放验收，后补文档记录不改变产物来源。
