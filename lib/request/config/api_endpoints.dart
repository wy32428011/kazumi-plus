import 'package:flutter/services.dart' show appBuildName;

class ApiEndpoints {
  /// 当前版本
  static const String version = appBuildName ?? '0.0.0';

  /// 规则API级别。9 支持搜索来源模板 sourceTemplate。
  static const int apiLevel = 9;

  /// 项目主页
  static const String projectUrl = "https://kazumi.app/";

  /// Github 项目主页
  static const String sourceUrl = "https://github.com/Predidit/Kazumi";

  /// 图标作者
  static const String iconUrl = "https://www.pixiv.net/users/66219277";

  /// 规则仓库
  static const String pluginShop =
      'https://raw.githubusercontent.com/Predidit/KazumiRules/main/';

  /// 规则仓库镜像
  static const String pluginShopMirror =
      'https://raw.gitcode.com/gh_mirrors/ka/KazumiRules/raw/main/';

  /// Kazumi Plus 独立版默认发布更新源（与上游 Predidit/Kazumi 隔离）。
  static const String defaultPlusUpdateUrl =
      'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest';

  /// 在线升级
  ///
  /// 默认指向 Kazumi Plus 独立发布仓库；发布者或分支构建可通过
  /// `--dart-define=KAZUMI_PLUS_UPDATE_URL=...` 覆盖为自定义独立渠道，
  /// 或传入空字符串显式关闭应用内更新检测。
  static const String latestApp = String.fromEnvironment(
    'KAZUMI_PLUS_UPDATE_URL',
    defaultValue: defaultPlusUpdateUrl,
  );

  /// 经合法性与上游隔离校验后的实际更新接口地址；非法或指向原版时返回空串。
  static String get effectiveLatestApp => resolveUpdateUrl(latestApp);

  /// 是否已配置有效的独立版更新渠道。
  static bool get isUpdateConfigured => effectiveLatestApp.isNotEmpty;

  /// 更新日志 / 发布页面地址；优先从独立更新地址推导，避免跳转到原版发布页。
  static String get releasePageUrl {
    final derived = deriveReleasePageUrl(effectiveLatestApp);
    if (derived.isNotEmpty) {
      return derived;
    }
    return '$sourceUrl/releases';
  }

  /// Bangumi 镜像测试后端
  static const String bangumiMirrorDomain = 'https://api.kazumi.fyi';

  /// Kazumi 镜像后端应用更新
  static String get latestAppMirror => effectiveLatestApp;

  /// 判断更新地址是否指向原版 Predidit/Kazumi 渠道。
  static bool isUpstreamKazumiUpdateUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (host == 'api.github.com' &&
        RegExp(r'^/repos/predidit/kazumi(/|$)').hasMatch(path)) {
      return true;
    }
    if ((host == 'github.com' || host == 'www.github.com') &&
        RegExp(r'^/predidit/kazumi(/|$)').hasMatch(path)) {
      return true;
    }
    return false;
  }

  /// 校验并归一化更新检测地址，拒绝非 http(s) 地址及上游原版渠道。
  static String resolveUpdateUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasAuthority) return '';
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    if (isUpstreamKazumiUpdateUrl(trimmed)) return '';
    return trimmed;
  }

  /// 将 GitHub Releases API 地址转换为对应的网页发布页地址。
  static String deriveReleasePageUrl(String updateUrl) {
    final normalized = resolveUpdateUrl(updateUrl);
    if (normalized.isEmpty) return '';
    final uri = Uri.parse(normalized);
    if (uri.host.toLowerCase() == 'api.github.com') {
      final match = RegExp(
        r'^/repos/([^/]+)/([^/]+)/releases(?:/.*)?$',
        caseSensitive: false,
      ).firstMatch(uri.path);
      if (match != null) {
        return 'https://github.com/${match.group(1)}/${match.group(2)}/releases';
      }
    }
    return normalized;
  }

  /// 弹弹官网
  static const String dandanIndex = 'https://www.dandanplay.com/';

  /// Bangumi 官网
  static const String bangumiIndex = 'https://bangumi.tv/';

  /// bangumi API
  static const String bangumiAPIDomain = 'https://api.bgm.tv';

  /// Bangumi 鉴权 API
  static const String bangumiAuthAPIMirrorDomain = 'https://api.bgmapi.com';

  /// Telegram 群组
  static const String telegramGroup = 'https://t.me/kazumi_app';

  /// 番剧信息
  static const String bangumiInfoByID = '/v0/subjects/{0}';

  /// 条目关联信息
  static const String bangumiRelationsByID = '/v0/subjects/{0}/subjects';

  /// 条目搜索
  static const String bangumiRankSearch =
      '/v0/search/subjects?limit={0}&offset={1}';

  /// 从条目ID获取角色信息
  static const String bangumiCharacterByID = '/v0/subjects/{0}/characters';

  /// 从条目ID获取工作人员信息
  static const String bangumiStaffByID = '/v0/subjects/{0}/persons';

  /// 从条目ID获取剧集ID
  static const String bangumiEpisodeByID = '/v0/episodes';

  /// 返回当前 Access Token 对应的用户信息
  static const String bangumiUsernameByToken = '/v0/me';

  /// 新增或修改用户单个条目收藏
  static const String bangumiSetCollection = '/v0/users/-/collections/{0}';

  /// 获取用户全部收藏（不限类型）。用户名，分页参数1(limit)，分页参数2(offset)
  static const String bangumiGetAllCollections =
      '/v0/users/{0}/collections?subject_type=2&limit={1}&offset={2}';

  /// Bangumi Next API Domain
  static const String bangumiAPINextDomain = 'https://next.bgm.tv';

  static const bangumiPublicApiHosts = {'api.bgm.tv', 'next.bgm.tv'};

  /// 每日放送
  static const String bangumiCalendar = '/p1/calendar';

  /// 番剧趋势
  static const String bangumiTrendsNext = '/p1/trending/subjects';

  /// Kazumi Bangumi 镜像缓存榜单
  static const String bangumiMirrorPopularSubjects =
      '/kazumi/v1/popular/subjects';

  /// Kazumi Bangumi 镜像季节时间表
  static const String bangumiMirrorSeasonCalendar =
      '/kazumi/v1/calendar/season';

  /// 番剧信息
  static const String bangumiInfoByIDNext = '/p1/subjects/{0}';

  /// 番剧评论
  static const String bangumiCommentsByIDNext =
      '/p1/subjects/{0}/comments?limit={1}&offset={2}';

  /// 番剧剧集评论
  static const String bangumiEpisodeCommentsByIDNext =
      '/p1/episodes/{0}/comments';

  /// 番剧角色信息
  static const String bangumiCharacterInfoByCharacterIDNext =
      '/p1/characters/{0}';

  /// 番剧角色评论
  static const String bangumiCharacterCommentsByIDNext =
      '/p1/characters/{0}/comments';

  /// DanDanPlay API Domain
  static const String dandanAPIDomain = 'https://api.dandanplay.net';

  /// 获取弹幕
  static const String dandanAPIComment = "/api/v2/comment/";

  /// 检索弹弹番剧元数据
  static const String dandanAPISearchEpisodes = "/api/v2/search/episodes";

  /// 获取弹弹番剧元数据
  static const String dandanAPIInfo = "/api/v2/bangumi/";

  /// 获取弹弹番剧元数据（通过BGM番剧ID）
  static const String dandanAPIInfoByBgmBangumiId = "/api/v2/bangumi/bgmtv/{0}";

  /// 图片识别番剧
  static const String traceApi = 'https://api.trace.moe/search';

  static String formatUrl(String url, List<dynamic> params) {
    for (int i = 0; i < params.length; i++) {
      url = url.replaceAll('{$i}', params[i].toString());
    }
    return url;
  }
}
