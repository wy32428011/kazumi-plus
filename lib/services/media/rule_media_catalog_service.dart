import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/catalog_rule_strategy.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/episode_url.dart';

/// 来源列表始终读取当前规则快照，删除或禁用后不会被旧缓存重新启用。
class RuleMediaCatalogService implements MediaCatalogService {
  RuleMediaCatalogService(
    this.pluginsController, {
    double Function(Plugin plugin, MediaKind kind)? scoreProvider,
    VodPayloadCache? payloadCache,
  }) : _scoreProvider = scoreProvider,
       _payloadCache = payloadCache ?? VodPayloadCache.instance;

  final PluginsController pluginsController;
  double Function(Plugin plugin, MediaKind kind)? _scoreProvider;
  final VodPayloadCache _payloadCache;

  /// 无本地实测历史时的冷启动回退顺序（优先独立 1080P/高清健康源，移出低清 maoyan 与假活 modu 置顶）。
  static const _coldStartFallbackOrder = [
    'kazumi-plus.iqiyi',
    'kazumi-plus.zy360',
    'kazumi-plus.hongniu',
    'kazumi-plus.4kav',
    'kazumi-plus.guangsu',
    'kazumi-plus.baofeng',
    'kazumi-plus.subo',
    'kazumi-plus.ikun',
    'kazumi-plus.jinying',
    'kazumi-plus.huya',
    'kazumi-plus.haohua',
    'kazumi-plus.xinlang',
    'kazumi-plus.maoyan',
    'kazumi-plus.modu',
  ];

  /// 允许 Phase 2 的实测评分引擎动态注入排序函数。
  void setScoreProvider(
    double Function(Plugin plugin, MediaKind kind)? provider,
  ) {
    _scoreProvider = provider;
  }

  @override
  List<MediaProvider> providersFor(MediaKind kind) {
    final providers = [
      for (final plugin in pluginsController.pluginList)
        if (_available(plugin) &&
            plugin.supportedMediaTypes.contains(kind.name) &&
            plugin.catalog!.channels.containsKey(kind.name))
          RuleMediaProvider(plugin, payloadCache: _payloadCache),
    ];
    final scorer = _scoreProvider;
    providers.sort((a, b) {
      if (scorer != null) {
        final diff = scorer(b.plugin, kind).compareTo(scorer(a.plugin, kind));
        if (diff != 0) return diff;
      }
      final indexA = _coldStartFallbackOrder.indexOf(a.ruleId);
      final indexB = _coldStartFallbackOrder.indexOf(b.ruleId);
      final rankA = indexA < 0 ? 100 : indexA;
      final rankB = indexB < 0 ? 100 : indexB;
      return rankA.compareTo(rankB);
    });
    return providers;
  }

  @override
  MediaProvider? providerById(String ruleId) {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.ruleId == ruleId && _available(plugin)) {
        return RuleMediaProvider(plugin, payloadCache: _payloadCache);
      }
    }
    return null;
  }

  bool _available(Plugin plugin) =>
      plugin.enabled &&
      plugin.ruleId.isNotEmpty &&
      plugin.plusSchemaVersion == 1 &&
      plugin.catalog != null &&
      !plugin.requiresNewerClient;
}

/// 一个规则同时提供资料与播放；底层持久化身份始终保留来源 MediaRef，
/// 并通过 [VodPayloadCache] 非破坏式复用 MacCMS `ac=videolist` 完整载荷。
class RuleMediaProvider implements MediaProvider {
  RuleMediaProvider(
    this.plugin, {
    RuleEngine? engine,
    VodPayloadCache? payloadCache,
  }) : _engine = engine ?? RuleEngine(),
       _payloadCache = payloadCache ?? VodPayloadCache.instance;

  @override
  final Plugin plugin;
  final RuleEngine _engine;
  final VodPayloadCache _payloadCache;
  static const _strategy = CatalogRuleStrategy();
  static const _apiStrategy = ApiRuleStrategy();
  bool _validated = false;

  @override
  String get ruleId => plugin.ruleId;

  @override
  List<MediaKind> get supportedKinds => MediaKind.values
      .where(
        (kind) =>
            plugin.supportedMediaTypes.contains(kind.name) &&
            plugin.catalog?.channels.containsKey(kind.name) == true,
      )
      .toList();

  CatalogChannel _channel(MediaKind kind) {
    // 预览或磁盘手工修改也走同一校验，将缺字段展示为明确的来源错误。
    if (!_validated) {
      plugin.validateCatalog();
      _validated = true;
    }
    final channel = plugin.catalog?.channels[kind.name];
    if (channel == null || !supportedKinds.contains(kind)) {
      throw UnsupportedError('${plugin.name} 未配置${kind.label}资料');
    }
    return channel;
  }

  Future<CatalogParseResult> _execute(
    CatalogOperation operation,
    MediaKind kind, {
    required String phase,
    String source = '',
    String categoryId = '',
    String keyword = '',
    String seasonId = '',
    String sort = '',
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    if (page < 1) throw const FormatException('页码必须从 1 开始');
    final raw = await _engine.requestCatalog(
      plugin.executionConfig,
      operation,
      {
        'source': source,
        'categoryId': categoryId,
        'keyword': keyword,
        'seasonId': seasonId,
        'sort': sort,
        'page': page,
        'mediaType': kind.name,
      },
      phase: phase,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCancelled == true) {
      throw cancelToken!.cancelError ?? StateError('请求已取消');
    }
    try {
      return _strategy.parse(raw, operation, page);
    } catch (error) {
      throw CatalogErrorException(plugin.name, '$phase解析', cause: error);
    }
  }

  @override
  Future<List<MediaCategory>> queryCategories(
    MediaKind kind, {
    CancelToken? cancelToken,
  }) async {
    final channel = _channel(kind);
    final parsed = await _execute(
      channel.categories,
      kind,
      phase: '分类',
      cancelToken: cancelToken,
    );
    final categories = <String, MediaCategory>{};
    for (final row in parsed.rows) {
      final id = _text(row['id']);
      final name = _plainText(row['name']);
      if (channel.categoryIds.contains(id) && name.isNotEmpty) {
        categories[id] = MediaCategory(id: id, name: name, kind: kind);
      }
    }
    // 默认分类排在前面，界面不需要了解各站的分类编号。
    return [
      if (categories.containsKey(channel.defaultCategoryId))
        categories[channel.defaultCategoryId]!,
      ...categories.values.where(
        (item) => item.id != channel.defaultCategoryId,
      ),
    ];
  }

  @override
  Future<MediaPage> queryDiscover(
    MediaKind kind, {
    String? categoryId,
    MediaSort? sort,
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    final channel = _channel(kind);
    final selected = categoryId ?? channel.defaultCategoryId;
    if (!channel.categoryIds.contains(selected)) {
      throw const FormatException('分类不属于当前频道');
    }
    final parsed = await _execute(
      channel.discover,
      kind,
      phase: '目录',
      categoryId: selected,
      sort: sort?.name ?? '',
      page: page,
      cancelToken: cancelToken,
    );
    return _page(
      parsed,
      channel.discover,
      kind,
      channel,
      page,
      selectedCategoryId: selected,
    );
  }

  @override
  Future<MediaPage> searchMedia(
    MediaKind kind,
    String keyword, {
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    final channel = _channel(kind);
    if (keyword.trim().isEmpty) {
      return MediaPage(items: const [], page: page, hasMore: false);
    }
    final parsed = await _execute(
      channel.search,
      kind,
      phase: '搜索',
      keyword: keyword.trim(),
      page: page,
      categoryId: channel.defaultCategoryId,
      cancelToken: cancelToken,
    );
    return _page(parsed, channel.search, kind, channel, page);
  }

  MediaPage _page(
    CatalogParseResult parsed,
    CatalogOperation operation,
    MediaKind kind,
    CatalogChannel channel,
    int page, {
    String? selectedCategoryId,
  }) {
    final items = <String, MediaSummary>{};
    for (var i = 0; i < parsed.rows.length; i++) {
      final row = parsed.rows[i];
      if (!channel.categoryIds.contains(_text(row['categoryId']))) continue;
      if (selectedCategoryId != null &&
          _text(row['categoryId']) != selectedCategoryId) {
        continue;
      }
      final rawNode = i < parsed.rawNodes.length ? parsed.rawNodes[i] : null;
      final rawMap = rawNode is Map
          ? Map<String, Object?>.from(rawNode)
          : null;
      final item = _summary(row, operation, kind, rawMap: rawMap);
      if (item == null) continue;
      items[item.ref.key] = item;
      _cacheRowPayload(
        item: item,
        row: row,
        rawMap: rawMap,
        operation: operation,
        channel: channel,
      );
    }
    // 搜索页可能全部属于其它类型；仍沿用原站总页数，不能把过滤空页当末页。
    return MediaPage(
      items: items.values.toList(),
      page: page,
      hasMore: parsed.hasMore,
    );
  }

  void _cacheRowPayload({
    required MediaSummary item,
    required Map<String, Object?> row,
    required Map<String, Object?>? rawMap,
    required CatalogOperation operation,
    required CatalogChannel channel,
  }) {
    final richMeta = _extractRichMeta(
      summary: item,
      row: row,
      rawMap: rawMap,
      hasExplicitSeasons: channel.detail.seasonsPath.isNotEmpty,
    );
    MediaDetail? detail;
    SourcePlaylist? playlist;

    // 仅对无显式分季的 MacCMS API 完整载荷预生成 detail 与 playlist，实现 3→1 复用。
    if (operation.mode == RuleMode.api &&
        rawMap != null &&
        channel.detail.mode == RuleMode.api &&
        channel.detail.seasonsPath.isEmpty &&
        _looksLikeFullMacCmsVodNode(rawMap)) {
      detail = MediaDetail(
        summary: item,
        description: richMeta.description.isNotEmpty
            ? richMeta.description
            : _plainText(row['description']),
        aliases: richMeta.aliases,
        genres: richMeta.genres,
        castText: richMeta.actors.join(' / '),
      );
      playlist = _tryParseMacCmsPlaylist(item, rawMap);
    }

    _payloadCache.put(
      CachedVodPayload(
        ref: item.ref,
        summary: item,
        richMeta: richMeta,
        detail: detail,
        playlist: playlist,
        cachedAt: DateTime.now(),
      ),
    );
  }

  bool _looksLikeFullMacCmsVodNode(Map<String, Object?> rawMap) {
    final hasPlayUrl =
        rawMap['vod_play_url']?.toString().trim().isNotEmpty == true;
    final hasDetailFields =
        rawMap.containsKey('vod_content') ||
        rawMap.containsKey('vod_actor') ||
        rawMap.containsKey('vod_director');
    return hasPlayUrl || hasDetailFields;
  }

  SourcePlaylist? _tryParseMacCmsPlaylist(
    MediaSummary item,
    Map<String, Object?> rawMap,
  ) {
    final playUrl = rawMap['vod_play_url']?.toString().trim() ?? '';
    if (playUrl.isEmpty) return null;
    if (plugin.chapterMode != RuleMode.api ||
        plugin.chapterApiConfig.format != ApiChapterFormat.delimited) {
      return null;
    }
    try {
      final syntheticRaw = jsonEncode({
        'list': [rawMap],
      });
      final parsed = _apiStrategy.parseChapters(
        syntheticRaw,
        plugin.chapterApiConfig,
        source: item.detailSource,
        baseUrl: plugin.baseUrl,
      );
      if (parsed.roads.isEmpty) return null;
      return _buildPlaylistFromRoads(item, parsed.roads);
    } catch (_) {
      return null;
    }
  }

  RichMediaMeta _extractRichMeta({
    required MediaSummary summary,
    required Map<String, Object?> row,
    required Map<String, Object?>? rawMap,
    required bool hasExplicitSeasons,
  }) {
    final doubanId = MediaTextNormalizer.cleanDoubanId(
      rawMap?['vod_douban_id'],
    );
    final doubanScore = MediaTextNormalizer.parseHonestScoreValue(
      rawMap?['vod_douban_score'],
    );
    final directors = MediaTextNormalizer.splitMultiValue(
      rawMap?['vod_director'],
    );
    final aliases = MediaTextNormalizer.splitMultiValue(
      rawMap?['vod_sub'] ?? row['aliases'],
    );
    final actors = MediaTextNormalizer.splitMultiValue(
      rawMap?['vod_actor'] ?? row['cast'],
    );
    final genres = MediaTextNormalizer.splitMultiValue(
      rawMap?['vod_class'] ?? row['genres'],
    );
    final description = MediaTextNormalizer.decodeHtmlRecursive(
      rawMap?['vod_content'] ?? row['description'],
    );
    final updatedAtText = MediaTextNormalizer.decodeHtmlRecursive(
      rawMap?['vod_time'],
    );
    final language = MediaTextNormalizer.decodeHtmlRecursive(
      rawMap?['vod_lang'],
    );
    final playFrom = MediaTextNormalizer.decodeHtmlRecursive(
      rawMap?['vod_play_from'],
    );
    final playUrl = _text(rawMap?['vod_play_url']);
    final dubVariant = MediaTextNormalizer.detectDubVariant(
      title: summary.title,
      statusText: summary.statusText,
      region: summary.region,
      playFrom: playFrom,
    );
    final seasonToken = MediaTextNormalizer.extractExplicitSeasonToken(
      summary.title,
    );
    final completion = MediaTextNormalizer.parseCompletionAndCount(
      summary.statusText,
    );
    final isCamOrTs = MediaTextNormalizer.detectCamOrTs(
      summary.title,
      statusText: summary.statusText,
    );

    return RichMediaMeta(
      doubanId: doubanId,
      doubanScore: doubanScore,
      directors: directors,
      aliases: aliases,
      actors: actors,
      genres: genres,
      description: description,
      updatedAtText: updatedAtText,
      language: language,
      playFrom: playFrom,
      playUrl: playUrl,
      hasExplicitSeasons: hasExplicitSeasons,
      dubVariant: dubVariant,
      seasonToken: seasonToken,
      isCompleted: completion.isCompleted,
      reportedEpisodeCount: completion.episodeCount,
      isCamOrTs: isCamOrTs,
    );
  }

  MediaSummary? _summary(
    Map<String, Object?> row,
    CatalogOperation operation,
    MediaKind kind, {
    Map<String, Object?>? rawMap,
  }) {
    final title = _plainText(row['title']);
    var source = _text(row['source']);
    if (title.isEmpty || source.isEmpty) return null;
    if (operation.mode == RuleMode.xpath) {
      source = _absoluteUrl(source);
      if (source.isEmpty) return null;
    }
    final rawId = _text(row['id']);
    // 无站内编号时保留完整查询参数，仅移除 URL 片段，不以标题猜测身份。
    final id = rawId.isNotEmpty ? rawId : source.split('#').first;

    final ratingPath = operation.fields['rating']?.path.trim() ?? '';
    final isMacCmsVodScore =
        operation.mode == RuleMode.api &&
        (ratingPath == r'$.vod_score' || ratingPath.endsWith('.vod_score'));
    final honestRating = MediaTextNormalizer.parseHonestRating(
      doubanScore: rawMap?['vod_douban_score'],
      rawRating: row['rating'],
      isMacCmsVodScore: isMacCmsVodScore,
    );

    return MediaSummary(
      ref: MediaRef.source(ruleId: ruleId, kind: kind, id: id),
      title: title,
      detailSource: source,
      sourceName: plugin.name,
      posterUrl: _absoluteUrl(_text(row['poster'])),
      year: MediaTextNormalizer.cleanYear(row['year']),
      region: _plainText(row['region']),
      statusText: _plainText(row['status']),
      ratingText: honestRating,
    );
  }

  void _checkItem(MediaSummary item) {
    if (item.ref.provider != 'rule' || item.ref.ruleId != ruleId) {
      throw const FormatException('作品来源与当前规则不一致');
    }
  }

  @override
  Future<MediaDetail> queryDetail(
    MediaSummary item, {
    CancelToken? cancelToken,
  }) async {
    _checkItem(item);
    final channel = _channel(item.ref.kind);
    if (channel.detail.mode == RuleMode.api &&
        channel.detail.seasonsPath.isEmpty) {
      final cached = _payloadCache.get(item.ref);
      if (cached?.detail != null) {
        return cached!.detail!;
      }
    }

    final parsed = await _execute(
      channel.detail,
      item.ref.kind,
      phase: '详情',
      source: item.detailSource,
      cancelToken: cancelToken,
    );
    for (var i = 0; i < parsed.rows.length; i++) {
      final row = parsed.rows[i];
      if (!channel.categoryIds.contains(_text(row['categoryId']))) continue;
      final normalizedRow = channel.detail.mode == RuleMode.xpath
          ? _normalizeDetailSourceAlias(row, item.detailSource)
          : row;
      final rawNode = i < parsed.rawNodes.length ? parsed.rawNodes[i] : null;
      final rawMap = rawNode is Map
          ? Map<String, Object?>.from(rawNode)
          : null;
      final summary = _summary(
        normalizedRow,
        channel.detail,
        item.ref.kind,
        rawMap: rawMap,
      );
      if (summary == null || summary.ref != item.ref) continue;
      final seasons = <MediaSeason>[];
      final seen = <String>{};
      for (final season in parsed.seasons) {
        final id = _text(season['id']);
        final name = _plainText(season['name']);
        if (id.isEmpty || name.isEmpty || !seen.add(id)) continue;
        var source = _text(season['source']);
        if (source.isNotEmpty && channel.detail.mode == RuleMode.xpath) {
          source = _absoluteUrl(source);
        }
        seasons.add(
          MediaSeason(
            id: id,
            name: name,
            number: int.tryParse(_text(season['number'])),
            detailSource: source.isEmpty ? null : source,
          ),
        );
      }
      final detail = MediaDetail(
        summary: summary,
        description: _plainText(row['description']),
        aliases: _strings(row['aliases']),
        genres: _strings(row['genres']),
        castText: _plainText(row['cast']),
        seasons: seasons,
      );

      // 冷启动从历史/收藏直达详情页时，同样顺带缓存 MacCMS 播放列表与富元数据，省去二次请求。
      if (channel.detail.mode == RuleMode.api &&
          rawMap != null &&
          channel.detail.seasonsPath.isEmpty) {
        final richMeta = _extractRichMeta(
          summary: summary,
          row: normalizedRow,
          rawMap: rawMap,
          hasExplicitSeasons: seasons.isNotEmpty,
        );
        final playlist = _tryParseMacCmsPlaylist(summary, rawMap);
        _payloadCache.put(
          CachedVodPayload(
            ref: summary.ref,
            summary: summary,
            richMeta: richMeta,
            detail: detail,
            playlist: playlist,
            cachedAt: DateTime.now(),
          ),
        );
      }
      return detail;
    }
    throw CatalogErrorException(plugin.name, '详情', cause: '没有匹配作品编号和频道分类的条目');
  }

  @override
  Future<SourcePlaylist> queryPlaylist(
    MediaSummary item, {
    MediaSeason? season,
    CancelToken? cancelToken,
  }) async {
    _checkItem(item);
    _channel(item.ref.kind);
    // 季缺少独立章节入口时拒绝播放，不能把原作品列表误标成其它季。
    if (season != null && (season.detailSource?.trim().isEmpty ?? true)) {
      throw CatalogErrorException(
        plugin.name,
        '分季播放列表',
        cause: '所选季缺少章节入口，请检查 seasonFields.source 配置与响应',
      );
    }

    // 仅当无显式分季时允许命中缓存；含 season != null 严格绕过原作品缓存按季独立请求。
    if (season == null) {
      final cached = _payloadCache.get(item.ref);
      if (cached?.playlist != null && cached!.playlist!.roads.isNotEmpty) {
        return cached.playlist!;
      }
    }

    final source = season == null
        ? item.detailSource
        : season.detailSource!.trim();
    final roads = await plugin.queryChapterRoads(
      source,
      cancelToken: cancelToken,
    );
    final playlist = _buildPlaylistFromRoads(item, roads, season: season);
    if (playlist.roads.isEmpty) throw ChapterErrorException(plugin.name);
    return playlist;
  }

  SourcePlaylist _buildPlaylistFromRoads(
    MediaSummary item,
    List<Road> roads, {
    MediaSeason? season,
  }) {
    final result = <PlaybackRoad>[];
    final seenRoads = <String>{};
    for (var roadIndex = 0; roadIndex < roads.length; roadIndex++) {
      final road = roads[roadIndex];
      final episodes = <PlayableEpisode>[];
      final numbers = road.identifier.map(_episodeNumber).toList();
      for (var index = 0; index < road.data.length; index++) {
        final url = _absoluteUrl(road.data[index]);
        if (url.isEmpty) continue;
        final originalTitle = index < road.identifier.length
            ? _plainText(road.identifier[index])
            : '';
        final number = index < numbers.length ? numbers[index] : null;
        final isFeature =
            item.ref.kind == MediaKind.movie && road.data.length == 1;
        final uniqueNumber =
            number != null &&
            numbers.where((candidate) => candidate == number).length == 1;
        episodes.add(
          PlayableEpisode(
            id: isFeature
                ? 'feature'
                : uniqueNumber
                ? 'episode:$number'
                : url,
            title: isFeature
                ? '正片'
                : originalTitle.isNotEmpty
                ? originalTitle
                : '播放项 ${index + 1}',
            url: url,
            number: isFeature ? null : number,
            seasonId: season?.id,
          ),
        );
      }
      if (episodes.isNotEmpty) {
        final uniqueName =
            road.name.trim().isNotEmpty &&
            !RegExp(r'^播放线路\d+$').hasMatch(road.name) &&
            roads.where((candidate) => candidate.name == road.name).length == 1;
        // 唯一源站线路名不受重排影响；缺少名称或重名时使用入口集合指纹。
        final urls = episodes.map((episode) => episode.url).toList()..sort();
        final stableId = uniqueName
            ? 'name:${road.name}'
            : 'entries:${sha256.convert(utf8.encode(jsonEncode(urls)))}';
        if (!seenRoads.add(stableId)) continue;
        result.add(
          PlaybackRoad(id: stableId, name: road.name, episodes: episodes),
        );
      }
    }
    return SourcePlaylist(roads: result, season: season);
  }

  // 只接受明确集号，避免将 1080P 或 S02E03 中的首个数字识别为集号。
  int? _episodeNumber(String title) =>
      MediaTextNormalizer.parseEpisodeNumber(title);

  Map<String, Object?> _normalizeDetailSourceAlias(
    Map<String, Object?> row,
    String expectedDetailSource,
  ) {
    final parsedSource = _absoluteUrl(_text(row['source']));
    if (parsedSource.isEmpty || parsedSource == expectedDetailSource) {
      return row;
    }
    final parsedUri = Uri.tryParse(parsedSource);
    final expectedUri = Uri.tryParse(expectedDetailSource);
    if (parsedUri == null || expectedUri == null) return row;
    final parsedHost = parsedUri.host.toLowerCase();
    final expectedHost = expectedUri.host.toLowerCase();
    final sameWwwAlias =
        parsedHost == expectedHost ||
        'www.$parsedHost' == expectedHost ||
        parsedHost == 'www.$expectedHost';
    String trimSlash(String path) =>
        path.endsWith('/') && path.length > 1
            ? path.substring(0, path.length - 1)
            : path;
    if (sameWwwAlias &&
        parsedUri.scheme == expectedUri.scheme &&
        parsedUri.port == expectedUri.port &&
        trimSlash(parsedUri.path) == trimSlash(expectedUri.path) &&
        parsedUri.query == expectedUri.query) {
      return {...row, 'source': expectedDetailSource};
    }
    return row;
  }

  String _absoluteUrl(String value) {
    if (value.isEmpty) return '';
    final normalized = normalizeEpisodeUrl(plugin.baseUrl, value);
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !const ['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      return '';
    }
    return normalized;
  }

  String _text(Object? value) => value?.toString().trim() ?? '';
  String _plainText(Object? value) =>
      MediaTextNormalizer.decodeHtmlRecursive(value);
  List<String> _strings(Object? value) =>
      MediaTextNormalizer.splitMultiValue(value);
}
