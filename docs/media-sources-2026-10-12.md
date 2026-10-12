# 影视来源扩充记录

日期：2026-10-12。范围：为电影与电视剧增加经过实际核实的来源，保留原有暴风影视。

## 接入结果

新增速播、魔都、光速三个来源，电影和电视剧频道均从1个来源增加到4个。各站作品可能重合，不将来源数量或分类数量当作独立片库总量。

| 来源 | 稳定编号 | 电影分类 | 电视剧分类 | 接口证据 |
| --- | --- | ---: | ---: | --- |
| 速播影视 | `kazumi-plus.subo` | 8 | 7 | [站点采集帮助](https://suboziyuan.com/index.php/help/index.html)；[JSON接口](https://subocj.com/api.php/provide/vod/from/subm3u8/?ac=list) |
| 魔都影视 | `kazumi-plus.modu` | 17 | 8 | [站点公布接口](https://www.mdzyapi.com/)；[JSON接口](https://www.mdzyapi.com/api.php/provide/vod/?ac=list) |
| 光速影视 | `kazumi-plus.guangsu` | 9 | 7 | [来源站点](https://guangsuzy.com/)；[JSON接口](https://api.guangsuapi.com/api.php/provide/vod/from/gsm3u8/?ac=list) |

分类编号分别取自各站实际 `class` 返回，未照搬暴风分类。每个源均提供独立规则、资料分类、目录分页、搜索、详情和直接HLS选集。保持来源稳定编号与原作品编号，不按同名影片自动合并。

## 核验方法与证据

使用 `scripts/inspect_media_sources.dart` 读取实际随包JSON并调用应用现有 `CatalogRuleStrategy`、`ApiRuleStrategy` 完成：

1. 校验影视资料配置、API搜索配置和章节配置。
2. 读取站点分类，确认全部频道白名单存在；抽取目录第一页及第二页，确认页面不重复。
3. 用目录作品标题搜索并核对同一作品编号；回读详情的编号及频道分类。
4. 解析播放线路及选集，按应用使用的来源Referer访问HLS主清单、子清单和首媒体分片。
5. 加密HLS核对AES-128密钥为16字节；分片只读1024字节，拒绝返回HTML/JSON错误的媒体入口。

原始接口响应、HLS和汇总位于 `.tools/media-sources-20261012/final/`；可纳入版本管理的汇总见 [真实来源证据](media-sources-2026-10-12-evidence.json)。初始候选取证位于同级各来源目录。按用户要求不新增或运行自动化测试。

| 来源 | 电视剧样本 | 电影样本 | 已完成媒体核验 |
| --- | --- | --- | --- |
| 速播影视 | 美人余，编号161128，10集 | 魔法情缘，编号158822，1项 | HLS、16字节AES密钥、首分片1024字节 |
| 魔都影视 | 伟大的长征，编号90995，10集 | 奔跑吧紫溪，编号91146，1项 | 主/子HLS、首分片1024字节 |
| 光速影视 | 美人余，编号220639，10集 | 魔法情缘，编号218329，1项 | 主/子HLS、16字节AES密钥、首分片1024字节 |

以上为当时来源返回的当前可用集数，不代表整季总集数。仅覆盖媒体链可读取；本轮新增源未逐一进行播放器实际音画、暂停拖动和冷续播验收。

## 未默认加入的候选

| 来源 | 实际问题 | 处理 |
| --- | --- | --- |
| 索尼 | 分类、详情、媒体清单可访问；关键词搜索返回HTTP200纯文本“暂不支持搜索” | 不满足完整接入要求，移除候选规则 |
| 量子 | API可返回资料；伟大的长征、肖申克的救赎播放清单返回404，Referer未改善 | 不加入 |
| 无尽 | 部分资料接口可返回；媒体403，M3U8线路搜索遇到Cloudflare挑战 | 不加入 |
| 非凡 | HTTPS API请求发生TLS连接失败 | 不加入 |
| 高清1080 | 分类、目录和搜索可用；伟大的长征、肖申克的救赎及近期电影换身的HLS均403，站点/API Referer未改善 | 不加入 |

失败结论针对本次网络与抽查样本，未声称这些站点永久失效，也未绕过验证码、鉴权或TLS验证。

## 增量安装与交付

预置安装从单一首次标记改为逐编号增量记录，继续使用 `plus_seed_v1.json`。旧用户无需重置数据即可收到新增来源；同编号用户规则、禁用状态、删除决定和同名自定义规则均保留。规则保存失败不会提前记录已处理编号；安装记录通过同目录临时文件刷盘后替换。

源码与规则交叉审查已完成。静态检查0 error/0 warning，17条既有info；新增核验脚本及controller定向分析无问题。

- Windows最终Release构建成功，日志 `.tools/logs/build-WindowsRelease-20261012-231311.log`。
- Android arm64 Release构建成功，日志 `.tools/logs/build-AndroidRelease-20261012-231627.log`。本轮未安装到Android真机或进行新增来源音画验收。
- APK元数据回读为 `app.kazumiplus.client`、版本 `0.1.0`、`versionCode=12`、仅 `arm64-v8a`；签名核验通过，沿用现有Android Debug证书。
- 实际临时启动Windows最终Release，从旧 `plus_seed_v1.json`（仅暴风）增量生成四个编号，并回读本机规则库的暴风、速播、魔都、光速。逐字段JSON对比确认原暴风规则完全一致；随后关闭本次启动进程，保留来源与用户数据。
- 启动证据为 `.tools/media-sources-20261012/windows-startup-readback.json`；原规则及标记已备份在 `storage-before/`。本机路径为 `C:/Users/wangyun/AppData/Roaming/KazumiPlus/Kazumi Plus/plugins/v2/`。
- Windows ZIP的66个文件逐一读流成功；ZIP和APK均回读四个影视规则，Android规则SHA256与源码一致，APK内含8个arm64原生库。

交付文件使用日期后缀，旧交付包保持原文件名。额外提供只含三个新增源的JSON数组，旧版可在规则管理的「导入规则」粘贴完整内容。

| 交付物 | 字节 | SHA256 |
| --- | ---: | --- |
| `dist/Kazumi-Plus-0.1.0-sources-20261012-windows-x64.zip` | 40558553 | `76f287331dd6eb18771ac6a6b17248bdf346826c71b9bc191e6b3385b756d74a` |
| `dist/Kazumi-Plus-0.1.0-sources-20261012-android-arm64.apk` | 30551393 | `33bee5c3405ebb016d6db13e5e0436d730c4deab159530b196757954c14e7e2c` |
| `dist/Kazumi-Plus-extra-media-sources-20261012.json` | 23554 | `4c806ab3c1b6cdb3c6ec9131755cbf6480c5381486f402538842b0a53272e107` |

校验文件为 `dist/SHA256SUMS-sources-20261012.txt`。任务状态：来源规则接入、真实媒体链核验、本机增量安装及两端构建交付已完成；新增来源的播放器音画及Android真机运行仍未逐一核验。
