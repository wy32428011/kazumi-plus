@AGENTS.md

# CLAUDE.md

本文件补充 Claude Code 在本仓库中的工作约定；项目架构、命令与通用不变量统一维护在 [AGENTS.md](AGENTS.md)，不在此重复。

## 工作方式

- **优先使用隔离 SDK**：系统 `PATH` 中通常没有全局 `flutter`/`dart`，运行分析、测试与代码生成时直接调用 `.tools/flutter/bin/flutter.bat` 与 `.tools/flutter/bin/dart.bat`。
- **勿手改生成文件**：`**/*.g.dart`、`lib/hive_registrar.g.dart`、`lib/bbcode/generated/**` 由工具生成。修改 MobX（`@observable`/`@action`/`@computed`）或 Hive 模型后，执行 `build_runner` 重新生成。
- **保护本地工具与产物目录**：`.tools/`（隔离 SDK、AVD、签名材料、验收日志）与 `dist/`（发行包）属于本地运行/交付产物，未经明确要求不要清理、修改或提交；严禁将 `.tools/signing/` 下的任何密钥或证书提交到 Git。
- **构建脚本注意工作区状态**：`scripts/build_plus.ps1` 与 `scripts/package_plus.ps1` 默认拒绝脏工作区；本地开发验证请显式传 `-AllowDirty`，切勿为绕过检查而擅自丢弃用户未提交改动。
- **外向操作先确认**：推送分支、触发 `.github/workflows/plus-build.yaml` 云构建、批量请求线上影视源（`scripts/inspect_media_sources.dart`）前先确认范围。

## 改动后检查清单

1. 运行静态分析：`& '.\.tools\flutter\bin\flutter.bat' analyze --no-pub --no-fatal-infos --fatal-warnings`（如改动影响依赖解析则去掉 `--no-pub`）。
2. 运行受影响的单元测试：`& '.\.tools\flutter\bin\flutter.bat' test <test_path>`；涉及公共模块（规则引擎、播放控制、存储）时尽量跑全量 `test/`。
3. 涉及播放器 UI、TV 焦点或规则字段变更时，对照 [docs/unified-player-implementation.md](docs/unified-player-implementation.md) 与 [docs/media-rules.md](docs/media-rules.md) 检查能力显隐、焦点交接与身份隔离是否被破坏。

## 技能（Skills）

### 内置技能（直接通过 `/<skill>` 使用）
- `/code-review`：提交前对当前 diff 做正确性与规则回归审查。
- `/simplify`：重构或清理复杂页面/控制器代码（如播放器与规则编辑器）。
- `/security-review`：审查网络请求、WebView 解析、规则导入与打包脚本改动。

### 项目已安装技能（`.agents/skills/`，已链接至 `.claude/skills/`）
- `find-media-source` — 项目专属：按 `plusSchemaVersion: 1` 寻找、低频实测核验（API/HLS/`ffprobe`）并接入新片源（[SKILL.md](.agents/skills/find-media-source/SKILL.md)）
- `flutter-apply-architecture-best-practices` — Flutter 分层与架构规范
- `flutter-build-responsive-layout` — 手机/桌面/TV 响应式布局适配
- `flutter-fix-layout-issues` — 溢出与布局约束排查
- `flutter-add-widget-test` — Widget 测试编写
- `dart-add-unit-test` — Dart 单元测试（适合规则引擎、解析器与仓库层）
- `dart-run-static-analysis` — Dart 静态分析与 lint 修复

### 可选补充安装
- `affaan-m/ecc@flutter-dart-code-review` — Flutter/Dart 专项代码审查（`npx skills add affaan-m/ecc --skill flutter-dart-code-review -a claude-code codex -y`）
