---
name: find-media-source
description: Discover, probe, verify, and onboard new Kazumi Plus media/video sources (MacCMS/VOD API or XPath) following plusSchemaVersion 1. Use when asked to find new movie/TV/anime sources, replace broken sources, inspect source APIs or HLS streams, verify real video resolution, or author assets/plugins/*.json rules.
metadata:
  project: kazumi-plus
---

# 寻找、核验与接入片源（Kazumi Plus）

本技能指导如何在 Kazumi Plus 中寻找可用影视/动漫片源、按项目协议实测验证并安全接入，避免引入假可用、断链、无法搜索或夸大画质的来源。

## 何时使用

- 用户要求寻找新的电影、电视剧或动漫片源 / 采集站接口
- 现有预置片源失效、换域名或分类变动，需要排查或替换
- 需要核验某个候选接口的分类、分页、搜索、详情、HLS 链路或实际分辨率
- 需要编写或更新 `assets/plugins/<slug>.json` 并注册到预置列表

## 工作流程

### 1. 核对现状与查重

1. 先阅读 `docs/media-rules.md` 与 `lib/plugins/plugins_controller.dart` 中的内置 `kazumi-plus.*` 清单，确认已有来源与分类规范。
2. 参考 `docs/media-sources-2026-10-12.md` 中的排除记录，避免重复排查已知无搜索或全站 403/404 的站点（除非用户明确要求复测）。
3. 明确本次目标：
   - 覆盖频道：`anime`、`tv`、`movie` 中的哪些频道
   - 接入方式：随包预置（`assets/plugins/` + `PluginsController`）还是导出独立 JSON 给用户手动导入

### 2. 筛选候选来源

- 优先选择公开的 MacCMS / 苹果 CMS 标准 JSON 采集接口（典型路径 `/api.php/provide/vod/` 或指定 M3U8 线路 `/api.php/provide/vod/from/<flag>/`），支持直接返回 HLS（`.m3u8`）播放地址，**不引入第三方外部解析服务器**。
- **合规与安全红线**：
  - 严禁绕过验证码、Cloudflare / 反爬质询、付费/登录鉴权墙，严禁禁用 TLS 证书校验。
  - 遇到 403/404、TLS 失败、防盗链拦截或“暂不支持搜索”时，如实记录并淘汰，不做规避尝试。

### 3. 真实链路低频核验

发起批量外部网络请求前，先确认目标范围；对每个来源**串行请求，单次请求间至少保留 1 秒间隔**。原始响应与分片证据只写入 `.tools/`（不纳入 Git）。

逐项核对以下链路：

1. **分类接口（`ac=list`）**：读取真实 `class` 数组，按频道人工核对并建立 `categoryIds` 白名单与 `defaultCategoryId`。
   - 严禁照搬其他站点的分类编号。
   - 过滤掉综艺、体育、资讯、短剧等非目标频道分类（电影频道按源站实际可包含动画电影、纪录片）。
2. **目录与分页（`ac=videolist&t=<categoryId>&pg=1` / `pg=2`）**：确认第 1 页有频道内作品，且第 2 页非空、不与第 1 页作品列表重复。
3. **搜索接口（`ac=videolist&wd=<title>&pg=1`）**：使用目录中抽样作品的精确标题搜索，确认返回结果包含同一 `vod_id`。
4. **详情与选集（`ac=videolist&ids=<vod_id>`）**：确认详情返回一致的 `vod_id` 与白名单内 `type_id`，`vod_play_from` / `vod_play_url` 可用现有分隔串解析出有效线路与 `.m3u8` 地址。
5. **HLS 媒体链**：携带与应用一致的 `User-Agent` 和 `Referer`（`baseURL/`）检查主清单、子清单、AES-128 密钥（如存在须为 16 字节）及首分片（仅读 1024 字节，拒绝返回 HTML/JSON 错误页的假 200 响应）。
6. **画质核验（按需）**：若需标注实际清晰度，必须用 `ffprobe` 检查实际拉取的分片分辨率与码率；**禁止把站名或 M3U8 清单声明当作实际画质，禁止为规则名附加“4K”“蓝光”“无水印”等未经逐片证实的标签**。

### 4. 编写规则 JSON（`plusSchemaVersion: 1`）

以 `assets/plugins/subo.json` 或 `assets/plugins/haohua.json` 为模板，严格遵守 `docs/media-rules.md`：

- `ruleId`：使用稳定唯一编号（预置源格式 `kazumi-plus.<slug>`），后续改名或换域名保持不变。
- `name`：简洁中性的来源名，不附带画质宣传词。
- `supportedMediaTypes`：仅声明已核验通过的频道（`anime`、`tv`、`movie`）。
- 资料必填字段：`title`、`source`（优先 `vod_id`，无站内编号时用完整详情 URL 含查询参数，**禁止用作品标题或临时媒体 URL**）、`categoryId`。
- 分页配置：`totalPagesPath`、`hasMorePath`、`nextPagePath` 三者只配其一；单页源不配分页。
- 缺失数据不补造：无源端季结构时不推断“第 1 季”，缺失评分/年份时不填默认值。

### 5. 项目内建脚本与测试验收

将规则保存至 `assets/plugins/<slug>.json`。若需作为随包预置源，同步在 `lib/plugins/plugins_controller.dart` 注册 `ruleId -> assetPath`（沿用 `plus_seed_v1.json` 增量机制，不覆盖用户已有规则及禁用/删除状态）。

使用项目隔离 SDK 运行核验（PowerShell）：

```powershell
# 1. 使用应用真实解析器核验接口与 HLS 链路
& '.\.tools\flutter\bin\cache\dart-sdk\bin\dart.exe' run scripts\inspect_media_sources.dart .tools/media-sources-live <slug>

# 2. 静态分析
& '.\.tools\flutter\bin\flutter.bat' analyze --no-pub --no-fatal-infos --fatal-warnings

# 3. 规则引擎单元测试
& '.\.tools\flutter\bin\flutter.bat' test test/rule_engine_test.dart
```

### 6. 文档更新与结果汇报

1. 若已接入预置源，更新 `docs/media-rules.md` 中的来源表（稳定编号、名称、接口、画质核验状态、各频道白名单/默认分类）。
2. 在最终汇报中**分项说明已验证与未验证的边界**：
   - API 分类 / 分页 / 搜索 / 详情解析是否通过
   - HLS 主/子清单、密钥与首分片读取是否通过
   - 是否已做 `ffprobe` 分片分辨率抽样
   - 是否已在应用播放器内完成实际音画、拖动与续播验收（脚本通过**不等同于**播放器实播通过）
   - 被淘汰的候选来源及具体失败原因
