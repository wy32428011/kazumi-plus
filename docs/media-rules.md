# Kazumi Plus 影视资料规则

影视规则使用 `plusSchemaVersion: 1`，原有 `api`、搜索和选集配置继续兼容。完整配置见 `assets/plugins/baofeng.json`、`subo.json`、`modu.json`、`guangsu.json`。

## 身份与类型

- `ruleId`：来源稳定编号；改名、升级或换域名时保留。编辑器不允许修改已保存编号。
- `supportedMediaTypes`：支持的内容类型，可包括 `anime`、`tv`、`movie`。
- `enabled`：是否启用。覆盖导入或升级保留用户禁用状态；删除的预置源不会在下次启动自动重装。
- `catalog.channels.tv/movie`：按频道配置资料能力。

每个频道声明 `categoryIds` 白名单、`defaultCategoryId`，以及 `categories`、`discover`、`search`、`detail` 操作。未知分类不自动进入频道；站点评分和当前可用集数按来源实际返回展示。

## 操作配置

每个操作包含 `mode: api|xpath`、`request`、`listPath`、`fields`。请求复用现有 GET/POST、headers/query、JSON/form body 和 Cookie 机制，变量支持 `@keyword`、`@source`、`@categoryId`、`@page`、`@seasonId`、`@mediaType`、`@sort`。

资料条目字段要求 `title`、`source`、`categoryId`；分类要求 `id`、`name`。可选资料字段为 `id`、`poster`、`year`、`region`、`status`、`rating`、`description`、`aliases`、`genres`、`cast`。无站内编号时采用完整详情入口后备身份，保留查询参数；不要使用临时媒体 URL 或作品名称充当作品 ID。

API 字段可写 JSONPath 字符串；XPath 字段可写路径，或 `{ "path": "//a", "attribute": "href" }`。不声明属性时读取文本。API 保持现有受限 JSONPath 能力，不执行脚本。

分页从1开始，配置 `totalPagesPath` 或 `hasMorePath`；XPath 可使用 `nextPagePath`。三者只配置一种。单页来源不配置分页。过滤后空页仍遵循来源总页数；重复页面应通过界面诊断停止自动翻页。

分季资料可在详情中配置 `seasonsPath`；启用后 `seasonFields.id/name/source` 必填，`number` 可选。每季 `source` 必须返回独立章节入口（URL 或站内编号），作为现有章节请求的 `@source`；响应缺少入口时明确报错，绝不回退原作品列表。没有源端季结构时不推断第1季；每季独立详情的站点不按名称自动合并。

## 预置暴风规则

接口为 `https://bfzyapi.com/api.php/provide/vod/`。分类读取 `class`，资料读取 `list`，分页读取 `pagecount`。电影仅使用21–28，电视剧仅使用31–38；默认电影26、电视剧31。

详情用站内 `vod_id` 作为 `@source`；线路来自 `vod_play_from`，分集串来自 `vod_play_url`。沿用原分隔字符串选集机制。单项电影显示正片，电视剧仅识别明确集号；无法明确识别的标题不会从首个数字猜集号。

在规则编辑器的「资料」页配置类型和资料操作，并通过资料预览核验分类、分页、搜索、详情及播放列表。预览解析成功不代表媒体实际可播放；实际音画需要进入播放器核验。

## 新增预置来源（2026-10-12）

| 稳定编号 | 接口 | 电影白名单 / 默认 | 电视剧白名单 / 默认 |
| --- | --- | --- | --- |
| `kazumi-plus.subo` | `https://subocj.com/api.php/provide/vod/from/subm3u8/` | 6–13 / 10 | 14–18、20、21 / 14 |
| `kazumi-plus.modu` | `https://www.mdzyapi.com/api.php/provide/vod/` | 5、10–25 / 15 | 26–33 / 26 |
| `kazumi-plus.guangsu` | `https://api.guangsuapi.com/api.php/provide/vod/from/gsm3u8/` | 6–12、20、24 / 10 | 13–16、21–23 / 13 |

## 扩展预置来源及画质核验（2026-11-11 修订）

以下来源支持 `anime`、`tv`、`movie`。来源名称、目录顺序及清单中的分辨率声明均不构成全站画质保证；预置显示名不再附加“4K”“蓝光高码”等未经逐片证实的标签。已经安装的用户规则不会被强制覆盖。

本轮实际分片核验：豪华与新浪的《街头霸王2026》样本为 1920×1080，猫眼《无所不能》为 800×448；魔都样本的子清单连接失败。未验证到可用 4K 样本，不能宣称全站 4K、蓝光或无水印。详见 [画质与播放核验记录](playback-quality-2026-11-11.md)。

| 稳定编号 | 名称 | 接口 | 画质规格 | 动漫白名单 / 默认 | 电影白名单 / 默认 | 电视剧白名单 / 默认 |
| --- | --- | --- | --- | --- | --- | --- |
| `kazumi-plus.maoyan` | 猫眼影视 | `https://api.maoyanapi.top/api.php/provide/vod/from/mym3u8/` | 抽样 800×448 | 4、29、38–40 / 40 | 6–12、20–29、45、54 / 6 | 13–16、30–33 / 13 |
| `kazumi-plus.modu` | 魔都影视 | `https://www.mdzyapi.com/api.php/provide/vod/` | 清单声明 1080P，分片未证实 | 1–5 / 2 | 5、10–25 / 15 | 26–33 / 26 |
| `kazumi-plus.haohua` | 豪华影视 | `https://hhzyapi.com/api.php/provide/vod/from/hhm3u8/` | 抽样 1920×1080 | 17、23–26 / 25 | 9–16、23、34–37 / 9 | 3–7、20、28 / 20 |
| `kazumi-plus.xinlang` | 新浪影视 | `https://api.xinlangapi.com/xinlangapi.php/provide/vod/from/xlm3u8/` | 抽样 1920×1080 | 3、17、38–40 / 39 | 5–12、17、41–44 / 6 | 13–16、18、20、21 / 13 |
| `kazumi-plus.huya` | 虎牙影视 | `https://www.huyaapi.com/api.php/provide/vod/from/hym3u8/` | 本轮未核验 | 17、23–26 / 25 | 9–16、23 / 9 | 3–7、20、28 / 20 |
| `kazumi-plus.jinying` | 金鹰影视 | `https://jyzyapi.com/provide/vod/from/jinyingm3u8/` | 本轮未核验 | 17、23–26 / 25 | 9–16、23 / 9 | 3–7、20、28 / 20 |
| `kazumi-plus.ikun` | ikun影视 | `https://ikunzyapi.com/api.php/provide/vod/from/ikm3u8/` | 本轮未核验 | 4、22、35–37 / 37 | 6–22 / 6 | 23–30 / 23 |
| `kazumi-plus.guangsu` | 光速影视 | `https://api.guangsuapi.com/api.php/provide/vod/from/gsm3u8/` | 本轮未核验 | 4、20、41–43 / 42 | 6–12、20、24 / 10 | 13–16、21–23 / 13 |
| `kazumi-plus.subo` | 速播影视 | `https://subocj.com/api.php/provide/vod/from/subm3u8/` | 本轮未核验 | 3、13、24–26 / 25 | 6–13 / 10 | 14–18、20、21 / 14 |
| `kazumi-plus.baofeng` | 暴风影视 | `https://bfzyapi.com/api.php/provide/vod/` | 本轮未核验 | 39–44、50 / 41 | 21–28 / 26 | 31–38 / 31 |
| `kazumi-plus.hongniu` | 红牛影视 | `https://www.hongniuzy2.com/api.php/provide/vod/from/hnm3u8/` | 抽样 1920×1080（剧）、1920×800（影）、1280×720（漫） | 20、36–38 / 37 | 5–11、19、20 / 5 | 12–18 / 12 |
| `kazumi-plus.iqiyi` | 爱奇艺影视 | `https://iqiyizyapi.com/api.php/provide/vod/` | 抽样 1920×1080（影/剧/漫） | 1–5 / 2 | 5、10–24 / 10 | 26–33 / 26 |
| `kazumi-plus.zy360` | 360影视 | `https://360zy.com/api.php/provide/vod/` | 抽样 1920×1080（影/剧/漫） | 29、38–40 / 40 | 6–12、20–27、29、45 / 6 | 13–16、30–33 / 13 |
| `kazumi-plus.4kav` | 4K-AV | `https://www.4k-av.com/movie/`（XPath） | 抽样 3840×1608 HEVC 10-bit HDR 60fps（部分老片为 1080P） | 未启用 | `/movie/` / `/movie/` | 未启用 |

新增规则沿用 `class/list/pagecount`、`vod_id` 及 `vod_play_from/vod_play_url` 分隔字符串。速播和光速指定源站的 M3U8 线路接口，魔都实测返回 `modum3u8`；不引入额外解析服务器。电影分类按源站实际返回包含动画电影、纪录片等电影内容；综艺、体育及其他未列出的分类不会混入频道。

`PluginsController` 的内置清单明确关联稳定编号与资源路径，所有 JSON 由 `assets/plugins/` 打包。`plugins/v2/plus_seed_v1.json` 的 `ruleIds` 累计记录已经提供过的来源：升级仅安装尚未处理的编号，已有同编号规则保持用户版本及启停状态；已处理但被用户删除的来源不会重装。同名自定义规则只使新预置显示名追加 Plus 后缀。记录损坏时明确报错并停止预置安装，不把损坏记录当作首次启动。

真实来源核验脚本为 `scripts/inspect_media_sources.dart`，复用 `CatalogRuleStrategy` 和 `ApiRuleStrategy`。核实证据及排除来源见 [来源扩充记录](media-sources-2026-10-12.md)。
