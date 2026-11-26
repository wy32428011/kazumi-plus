import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/api_rule_engine.dart';
import 'package:kazumi/services/plugin/catalog_rule_strategy.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:kazumi/utils/http_headers.dart';

export 'package:kazumi/services/plugin/rule_engine_models.dart'
    show
        CaptchaRequiredException,
        NoResultException,
        SearchErrorException,
        ChapterErrorException;

String pluginNameKey(String name) => name.toLowerCase();

/// 新规则按稳定编号识别，原有动漫规则继续按名称兼容。
String pluginIdentityKey(Plugin plugin) => plugin.ruleId.isNotEmpty
    ? 'id:${plugin.ruleId}'
    : 'name:${pluginNameKey(plugin.name)}';

class Plugin {
  static final RuleEngine _ruleEngine = RuleEngine();

  String api;
  String type;
  String name;
  String version;
  String ruleId;
  int plusSchemaVersion;
  List<String> supportedMediaTypes;
  bool enabled;
  CatalogRuleConfig? catalog;
  bool muliSources;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useWebview;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useNativePlayer;
  bool usePost;
  bool useLegacyParser;
  bool adBlocker;
  String userAgent;
  String baseUrl;
  String searchURL;
  String searchList;
  String searchName;
  String searchResult;
  String chapterRoads;
  String chapterRoadName;
  String chapterResult;
  String referer;
  String searchMode;
  String chapterMode;
  ApiSearchConfig searchApiConfig;
  ApiChapterConfig chapterApiConfig;
  AntiCrawlerConfig antiCrawlerConfig;

  Plugin({
    required this.api,
    required this.type,
    required this.name,
    required this.version,
    required this.muliSources,
    required this.useWebview,
    required this.useNativePlayer,
    required this.usePost,
    required this.useLegacyParser,
    required this.adBlocker,
    required this.userAgent,
    required this.baseUrl,
    required this.searchURL,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    this.chapterRoadName = '',
    required this.chapterResult,
    required this.referer,
    this.searchMode = RuleMode.xpath,
    this.chapterMode = RuleMode.xpath,
    ApiSearchConfig? searchApiConfig,
    ApiChapterConfig? chapterApiConfig,
    AntiCrawlerConfig? antiCrawlerConfig,
    this.ruleId = '',
    this.plusSchemaVersion = 0,
    List<String>? supportedMediaTypes,
    this.enabled = true,
    this.catalog,
  })  : searchApiConfig = searchApiConfig ?? ApiSearchConfig(),
        chapterApiConfig = chapterApiConfig ?? ApiChapterConfig(),
       supportedMediaTypes = supportedMediaTypes ?? [type],
        antiCrawlerConfig = antiCrawlerConfig ?? AntiCrawlerConfig.empty();

  factory Plugin.fromJson(Map<String, dynamic> json) {
    return Plugin(
      api: json['api']?.toString() ?? '1',
      type: json['type'] as String? ?? 'anime',
      name: json['name'] as String? ?? '',
      version: json['version']?.toString() ?? '',
      ruleId: json['ruleId'] as String? ?? '',
      plusSchemaVersion: (json['plusSchemaVersion'] as num?)?.toInt() ?? 0,
      supportedMediaTypes: (json['supportedMediaTypes'] as List?)
          ?.map((value) => value.toString())
          .toList(),
      enabled: json['enabled'] as bool? ?? true,
      catalog: json['catalog'] is Map
          ? CatalogRuleConfig.fromJson(
              Map<String, dynamic>.from(json['catalog']),
            )
          : null,
      muliSources: json['muliSources'] as bool? ?? true,
      useWebview: json['useWebview'] as bool? ?? true,
      useNativePlayer: json['useNativePlayer'] as bool? ?? true,
      usePost: json['usePost'] ?? false,
      useLegacyParser: json['useLegacyParser'] ?? false,
      adBlocker: json['adBlocker'] ?? false,
      userAgent: json['userAgent'] as String? ?? '',
      baseUrl: json['baseURL'] as String? ?? '',
      searchURL: json['searchURL'] as String? ?? '',
      searchList: json['searchList'] as String? ?? '',
      searchName: json['searchName'] as String? ?? '',
      searchResult: json['searchResult'] as String? ?? '',
      chapterRoads: json['chapterRoads'] as String? ?? '',
      chapterRoadName: json['chapterRoadName'] as String? ?? '',
      chapterResult: json['chapterResult'] as String? ?? '',
      referer: json['referer'] ?? '',
      searchMode: RuleMode.normalize(json['searchMode']),
      chapterMode: RuleMode.normalize(json['chapterMode']),
      searchApiConfig: json['searchApiConfig'] is Map
          ? ApiSearchConfig.fromJson(
              Map<String, dynamic>.from(json['searchApiConfig']),
            )
          : ApiSearchConfig(),
      chapterApiConfig: json['chapterApiConfig'] is Map
          ? ApiChapterConfig.fromJson(
              Map<String, dynamic>.from(json['chapterApiConfig']),
            )
          : ApiChapterConfig(),
      antiCrawlerConfig: json['antiCrawlerConfig'] != null
          ? AntiCrawlerConfig.fromJson(
              Map<String, dynamic>.from(json['antiCrawlerConfig']),
            )
          : AntiCrawlerConfig.empty(),
    );
  }

  factory Plugin.fromTemplate() {
    return Plugin(
      api: ApiEndpoints.apiLevel.toString(),
      type: 'anime',
      name: '',
      version: '',
      muliSources: true,
      useWebview: true,
      useNativePlayer: true,
      usePost: false,
      useLegacyParser: false,
      adBlocker: false,
      userAgent: '',
      baseUrl: '',
      searchURL: '',
      searchList: '',
      searchName: '',
      searchResult: '',
      chapterRoads: '',
      chapterResult: '',
      referer: '',
      searchMode: RuleMode.xpath,
      chapterMode: RuleMode.xpath,
      searchApiConfig: ApiSearchConfig(),
      chapterApiConfig: ApiChapterConfig(),
      antiCrawlerConfig: AntiCrawlerConfig.empty(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'api': api,
      'type': type,
      'name': name,
      'version': version,
      if (ruleId.isNotEmpty) 'ruleId': ruleId,
      if (plusSchemaVersion > 0) 'plusSchemaVersion': plusSchemaVersion,
      if (catalog != null ||
          supportedMediaTypes.length != 1 ||
          supportedMediaTypes.first != type)
        'supportedMediaTypes': supportedMediaTypes,
      if (!enabled) 'enabled': false,
      if (catalog != null) 'catalog': catalog!.toJson(),
      'muliSources': muliSources,
      'useWebview': useWebview,
      'useNativePlayer': useNativePlayer,
      'usePost': usePost,
      'useLegacyParser': useLegacyParser,
      'adBlocker': adBlocker,
      'userAgent': userAgent,
      'baseURL': baseUrl,
      'searchURL': searchURL,
      'searchList': searchList,
      'searchName': searchName,
      'searchResult': searchResult,
      'chapterRoads': chapterRoads,
      if (chapterRoadName.isNotEmpty) 'chapterRoadName': chapterRoadName,
      'chapterResult': chapterResult,
      'referer': referer,
      'searchMode': searchMode,
      'chapterMode': chapterMode,
      // Persisting re-serializes the whole plugin list, so a configured API
      // rule must survive even while the mode points at XPath.
      if (searchMode == RuleMode.api || searchApiConfig.request.url.isNotEmpty)
        'searchApiConfig': searchApiConfig.toJson(),
      if (chapterMode == RuleMode.api ||
          chapterApiConfig.request.url.isNotEmpty)
        'chapterApiConfig': chapterApiConfig.toJson(),
      'antiCrawlerConfig': antiCrawlerConfig.toJson(),
    };
  }

  bool get usesApiSearch => searchMode == RuleMode.api;

  bool get requiresNewerClient => int.parse(api) > ApiEndpoints.apiLevel || plusSchemaVersion > 1;

  /// 为资料请求暴露不可变快照，沿用同一 Cookie 与取消机制。
  RuleExecutionConfig get executionConfig => _executionConfig;

  /// 导入与编辑共用校验，旧动漫规则没有资料块时保持原有行为。
  void validateCatalog() {
    if (supportedMediaTypes.isEmpty ||
        supportedMediaTypes.any(
          (value) => !const ['anime', 'tv', 'movie'].contains(value),
        )) {
      throw const FormatException('支持类型必须是 anime、tv 或 movie');
    }
    if (catalog == null) return;
    if (ruleId.trim().isEmpty || plusSchemaVersion != 1) {
      throw const FormatException('影视资料规则需要稳定 ruleId 和 plusSchemaVersion: 1');
    }
    if (catalog!.channels.keys.any(
      (key) => !supportedMediaTypes.contains(key),
    )) {
      throw const FormatException('资料频道必须包含在 supportedMediaTypes 中');
    }
    const CatalogRuleStrategy().validate(catalog!);
  }

  RuleExecutionConfig get _executionConfig => RuleExecutionConfig(
        pluginName: name,
        baseUrl: baseUrl,
        userAgent: userAgent,
        usePost: usePost,
        searchMode: searchMode,
        chapterMode: chapterMode,
        searchUrl: searchURL,
        searchList: searchList,
        searchName: searchName,
        searchResult: searchResult,
        chapterRoads: chapterRoads,
        chapterRoadName: chapterRoadName,
        chapterResult: chapterResult,
        searchApiConfig: searchApiConfig,
        chapterApiConfig: chapterApiConfig,
        antiCrawlerConfig: antiCrawlerConfig,
      );

  Future<RuleSearchTrace> traceSearch(
    String keyword, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.search(
      _executionConfig,
      keyword,
      cancelToken: cancelToken,
    );
  }

  Future<RuleChapterTrace> traceChapters(
    String source, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.queryChapters(
      _executionConfig,
      source,
      cancelToken: cancelToken,
    );
  }

  /// Parses HTML harvested from the captcha webview as a search result;
  /// returns null when not applicable, letting callers fall back to
  /// [queryBangumi].
  PluginSearchResponse? parseHarvestedSearch(String html) {
    return _ruleEngine.tryParseHarvestedSearch(_executionConfig, html);
  }

  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async {
    try {
      return (await traceSearch(keyword, cancelToken: cancelToken)).response;
    } on CaptchaRequiredException {
      rethrow;
    } on NoResultException {
      rethrow;
    } on SearchErrorException {
      if (shouldRethrow) rethrow;
      return PluginSearchResponse(pluginName: name, data: <SearchItem>[]);
    }
  }

  Future<List<Road>> queryChapterRoads(
    String source, {
    RuleCancelToken? cancelToken,
  }) async {
    return (await traceChapters(source, cancelToken: cancelToken)).roads;
  }

  String buildFullUrl(String urlItem) {
    return normalizeEpisodeUrl(baseUrl, urlItem);
  }

  /// Headers used when resolving or downloading the final media resource.
  ///
  /// 规则未单独填写 referer 时用来源站点，与播放器打开直链的方式一致，
  /// 避免分片请求被防盗链拒绝。
  Map<String, String> buildHttpHeaders() {
    final refererValue = referer.isNotEmpty ? referer : baseUrl;
    return {
      'user-agent': userAgent.isEmpty ? getRandomUA() : userAgent,
      if (refererValue.isNotEmpty) 'referer': refererValue,
    };
  }
}
