# AGENTS.md

本文件是 **Kazumi Plus** 的共享项目说明，适用于所有 AI 编程助手与协作者。Claude Code 专属约定见 [CLAUDE.md](CLAUDE.md)。

## 项目概览

Kazumi Plus（`0.1.0+1`）是基于 [Predidit/Kazumi](https://github.com/Predidit/Kazumi)（基线 `4960f9c04246eb52e1f36728f0f5c60ae6fa54dc`）的独立 Flutter 多平台客户端，提供 **动漫**、**电视剧**、**电影** 三个频道，覆盖 Windows、Android 手机、Android TV、macOS 与 iOS/iPadOS。

- **动漫**：保留 Bangumi 目录/搜索/详情、原有 XPath/API 规则、弹幕、SyncPlay、下载与 WebDAV 同步。
- **电视剧 / 电影**：由影视规则（`plusSchemaVersion: 1`）同时提供分类、目录、搜索、详情、线路与播放入口；共用原动漫播放器界面，独立维护本地片单、历史、续播与下载。

## 技术栈与目录结构

- **框架与版本**：Flutter `3.47.7`（`pubspec.yaml` 锁定）、Dart `>=3.10.0 <4.0.0`。
- **DI 与路由**：`flutter_modular`
  - [lib/app_module.dart](lib/app_module.dart)：根模块，组合 `coreModule` 与 `indexModule`。
  - [lib/core_module.dart](lib/core_module.dart)：全应用生命周期单例（Repository、Service、跨功能 Controller）。**页面或局部状态不要放进 `coreModule`**，应放在路由 `provide` 或带路径模块中。
  - [lib/pages/index_module.dart](lib/pages/index_module.dart)：路由树与 `/tab` 作用域（`PopularController`、`TimelineController` 随 shell 释放）。
- **状态管理**：`mobx` + `flutter_mobx` + `mobx_codegen`（生成 `*.g.dart`）。
- **本地存储**：`hive_ce` + `hive_ce_flutter`（注册表 [lib/hive_registrar.g.dart](lib/hive_registrar.g.dart)，协调层 [lib/services/storage/](lib/services/storage/)）。
- **播放与网络**：`media_kit` / `media_kit_video`（锁定 Predidit fork）、`dio` + `cookie_jar` + `ech_http`（本地补丁位于 [third_party/ech_http/](third_party/ech_http/)）、`xpath_selector`、`json_path`。
- **关键目录**：
  - `lib/pages/player/`：统一播放器层（`PlayerControlsController`、`PlayerPresentationContext`、`PlayerItem` 等）与动漫包装层 `PlayerController`。
  - `lib/pages/media/`：电视剧/电影频道浏览、详情、搜索与来源播放页。
  - `lib/pages/video/`、`lib/pages/popular/`、`lib/pages/download/`：动漫播放、推荐、离线下载等页面。
  - `lib/plugins/`：规则模型（`api_rule_config.dart`、`catalog_rule_config.dart`、`anti_crawler_config.dart`）与 `PluginsController`。
  - `lib/services/media/`：影视目录服务、恢复会话与本地媒体库。
  - `lib/television/`：Android TV 焦点管理与遥控器播放控制。
  - `assets/plugins/`：12 个随包预置 JSON 规则。
  - `scripts/`：构建、一键打包、Windows 安装包、Apple 构建与影视源核验脚本。
  - `test/`：27 个单元/逻辑测试文件。

## 工具链与常用命令

本地隔离 Flutter SDK 位于 `.tools/flutter`（不纳入 Git）。以下命令均在仓库根目录使用 **PowerShell 7.2+** 执行；若改用系统 Flutter，请替换可执行路径。

```powershell
# 静态分析（与项目验收口径一致）
& '.\.tools\flutter\bin\flutter.bat' analyze --no-fatal-infos --fatal-warnings

# 运行单元测试
& '.\.tools\flutter\bin\flutter.bat' test

# 运行单个测试文件
& '.\.tools\flutter\bin\flutter.bat' test test/rule_engine_test.dart

# MobX / Hive 代码生成
& '.\.tools\flutter\bin\dart.bat' run build_runner build --delete-conflicting-outputs

# 单目标构建（默认要求干净 Git 提交；开发构建显式传 -AllowDirty）
& '.\scripts\build_plus.ps1' -Target WindowsRelease
& '.\scripts\build_plus.ps1' -Target AndroidRelease
& '.\scripts\build_plus.ps1' -Target AndroidDebug
& '.\scripts\build_plus.ps1' -Target AndroidTvRelease

# 一键打包（支持 All / Windows / WindowsInstaller / Android / AndroidTv）
& '.\scripts\package_plus.ps1' -Target All -AllowDirty

# 真实影视来源抽样核验（串行请求，1 秒间隔，输出写入指定目录）
& '.\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe' run scripts\inspect_media_sources.dart .tools/media-sources-live subo modu guangsu
```

- **Apple 云构建**：通过 [.github/workflows/plus-build.yaml](.github/workflows/plus-build.yaml)（`workflow_dispatch`）执行；禁止针对上游 `Predidit/Kazumi` 运行。
- **分析器排除项**：见 [analysis_options.yaml](analysis_options.yaml)（排除 `**/*.g.dart`、`lib/bbcode/generated/**`、各原生平台目录与 `build/**`）。

## 核心设计不变量与约束

### 1. 应用与数据隔离
- Android 包名为 `app.kazumiplus.client`，Windows 可执行文件为 `kazumi_plus.exe`，可与原版 Kazumi 并存。
- 使用独立数据目录，**不扫描也不搬移原版 Kazumi 数据**。
- 动漫 WebDAV 根目录为 `/kazumiPlusSync`。影视本地表（`plus_source_collections_v1`、`plus_source_histories_v1`、`plus_source_progress_v1`、`plus_media_preferences_v1`）仅保存在本机，不进入 Bangumi 或动漫 WebDAV 同步。
- 不使用原版更新渠道；独立更新地址通过编译参数 `KAZUMI_PLUS_UPDATE_URL` 注入。

### 2. 影视规则与身份模型
- 完整协议见 [docs/media-rules.md](docs/media-rules.md)。
- `ruleId` 是来源稳定编号，改名/升级/换域名时保持不变，规则编辑器不允许修改已保存的 `ruleId`。
- 影视作品数据库主键必须是**完整来源身份的 SHA256**（防止长 URL 超出 Hive 主键限制）；**禁止使用作品标题或临时媒体 URL 充当作品 ID**。
- 预置源升级按 `plugins/v2/plus_seed_v1.json` 增量安装：保留已有同编号规则与用户禁用状态；用户删除的预置源不在下次启动自动重装；记录损坏时必须明确报错并停止预置安装。
- 缺少源端季结构时不自动推断“第 1 季”，不按名称合并独立详情；单页或未知分类按白名单过滤，评分等缺失字段不补造。
- 不得为预置源名称附加未经逐片证实的“4K”“蓝光”“无水印”等画质标签。

### 3. 统一播放器与多端交互
- 动漫、电视剧、电影共用 `PlayerControlsController`、`PlayerPresentationContext`、`PlayerItem` 通用播放界面；原 `PlayerController` 作为动漫包装层保留弹幕与 SyncPlay 副作用。
- 影视播放使用 `MediaRef` 与来源稳定播放项 ID，**不构造伪造 Bangumi 条目**。
- 影视无数据支持的入口（弹幕、评论、一起看）必须在全部布局、更多菜单、快捷键、TV 遥控器操作、Android 原生 PiP 与 macOS 菜单中按能力隐藏。
- Android 恢复进度须在视频输出初始化后定位并回读实际位置，确认前不覆盖旧记录；切集/返回可取消；电影不自动切换版本。
- Android TV 改动须维护独立焦点范围与遥控器返回/重试焦点交接（参见 `lib/television/` 与 [docs/unified-player-implementation.md](docs/unified-player-implementation.md)）。

### 4. 依赖与原生构建补丁
- [pubspec.yaml](pubspec.yaml) 通过 `dependency_overrides.ech_http` 指向 [third_party/ech_http](third_party/ech_http)，用于修复 `ech_http 0.2.1` 在 MSVC 下触发 C2026 的问题。
- **不得修改全局 Pub 缓存，不得改动 `src/cacert.pem` 原始字节或禁用证书验证**；升级上游包前先确认说明文档 [third_party/ech_http/KAZUMI_PLUS_PATCH.md](third_party/ech_http/KAZUMI_PLUS_PATCH.md)。

### 5. 验证与交付纪律
- 静态分析、单元测试、源站抽样、构建成功、模拟器运行、真机音画验收各自独立记录，**不得互相替代**。
- 修改代码后，至少对改动范围运行 `flutter analyze --no-pub --no-fatal-infos --fatal-warnings` 和相关 `flutter test`，如实报告未验证项。

## 权威参考文档

- [docs/media-rules.md](docs/media-rules.md) — 影视资料规则协议与预置源清单
- [docs/unified-player-implementation.md](docs/unified-player-implementation.md) — 三类内容统一播放器架构与验收边界
- [docs/multi-platform-implementation.md](docs/multi-platform-implementation.md) — 多平台构建与运行限制
- [docs/kazumi-plus-implementation.md](docs/kazumi-plus-implementation.md) — 首版实施与数据边界记录
- [third_party/ech_http/KAZUMI_PLUS_PATCH.md](third_party/ech_http/KAZUMI_PLUS_PATCH.md) — `ech_http` Windows 补丁来源与校验
