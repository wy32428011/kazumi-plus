import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/plugin/catalog_rule_strategy.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/episode_url.dart';

/// 来源列表始终读取当前规则快照，删除或禁用后不会被旧缓存重新启用。
class RuleMediaCatalogService implements MediaCatalogService {
  RuleMediaCatalogService(this.pluginsController);

  final PluginsController pluginsController;

  @override
  List<MediaProvider> providersFor(MediaKind kind) => [
    for (final plugin in pluginsController.pluginList)
      if (_available(plugin) &&
          plugin.supportedMediaTypes.contains(kind.name) &&
          plugin.catalog!.channels.containsKey(kind.name))
        RuleMediaProvider(plugin),
  ];

  @override
  MediaProvider? providerById(String ruleId) {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.ruleId == ruleId && _available(plugin)) {
        return RuleMediaProvider(plugin);
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

/// 一个规则同时提供资料与播放；身份始终保留来源，不按同名作品跨站合并。
class RuleMediaProvider implements MediaProvider {
  RuleMediaProvider(this.plugin, {RuleEngine? engine})
    : _engine = engine ?? RuleEngine();

  @override
  final Plugin plugin;
  final RuleEngine _engine;
  static const _strategy = CatalogRuleStrategy();
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
    for (final row in parsed.rows) {
      if (!channel.categoryIds.contains(_text(row['categoryId']))) continue;
      if (selectedCategoryId != null &&
          _text(row['categoryId']) != selectedCategoryId) {
        continue;
      }
      final item = _summary(row, operation, kind);
      if (item != null) items[item.ref.key] = item;
    }
    // 搜索页可能全部属于其它类型；仍沿用原站总页数，不能把过滤空页当末页。
    return MediaPage(
      items: items.values.toList(),
      page: page,
      hasMore: parsed.hasMore,
    );
  }

  MediaSummary? _summary(
    Map<String, Object?> row,
    CatalogOperation operation,
    MediaKind kind,
  ) {
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
    return MediaSummary(
      ref: MediaRef.source(ruleId: ruleId, kind: kind, id: id),
      title: title,
      detailSource: source,
      sourceName: plugin.name,
      posterUrl: _absoluteUrl(_text(row['poster'])),
      year: _plainText(row['year']),
      region: _plainText(row['region']),
      statusText: _plainText(row['status']),
      ratingText: _plainText(row['rating']),
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
    final parsed = await _execute(
      channel.detail,
      item.ref.kind,
      phase: '详情',
      source: item.detailSource,
      cancelToken: cancelToken,
    );
    for (final row in parsed.rows) {
      if (!channel.categoryIds.contains(_text(row['categoryId']))) continue;
      final summary = _summary(row, channel.detail, item.ref.kind);
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
      return MediaDetail(
        summary: summary,
        description: _plainText(row['description']),
        aliases: _strings(row['aliases']),
        genres: _strings(row['genres']),
        castText: _plainText(row['cast']),
        seasons: seasons,
      );
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
      throw CatalogErrorException(plugin.name, '分季播放列表',
          cause: '所选季缺少章节入口，请检查 seasonFields.source 配置与响应');
    }
    final source = season == null ? item.detailSource : season.detailSource!.trim();
    final roads = await plugin.queryChapterRoads(
      source,
      cancelToken: cancelToken,
    );
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
            ? road.identifier[index]
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
    if (result.isEmpty) throw ChapterErrorException(plugin.name);
    return SourcePlaylist(roads: result, season: season);
  }

  // 只接受明确集号，避免将 1080P 或 S02E03 中的首个数字识别为集号。
  int? _episodeNumber(String title) {
    final match = RegExp(
      r'^(?:第\s*)?(\d+)\s*(?:集|话|期)?$',
    ).firstMatch(title.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
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
      html.parseFragment(_text(value)).text?.trim() ?? '';
  List<String> _strings(Object? value) => value is List
      ? value.map(_plainText).where((item) => item.isNotEmpty).toList()
      : _plainText(value)
            .split(RegExp(r'[,，、/]'))
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList();
}
