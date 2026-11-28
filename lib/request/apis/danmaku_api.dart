import 'package:kazumi/modules/danmaku/danmaku_ch_convert.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/request/apis/bilibili_danmaku_api.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

class DanmakuCatalog {
  static const dandan = 'dandan';
  static const custom = 'custom';
  static const bilibili = BilibiliDanmakuApi.catalog;

  DanmakuCatalog._();
}

class DanmakuApi {
  static final DanmakuClient _client = DanmakuClient.instance;

  /// 校验并归一化自定义弹弹Play v2 兼容服务地址（允许带 token 路径，不接受非 http/https）。
  static String normalizeCustomBaseUrl(String raw) {
    var trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return '';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    if (trimmed.toLowerCase().endsWith('/api/v2')) {
      trimmed = trimmed.substring(0, trimmed.length - '/api/v2'.length);
    }
    return trimmed;
  }

  static String get customApiBaseUrl {
    try {
      return normalizeCustomBaseUrl(
        GStorage.getSetting<String>(SettingsKeys.danmakuCustomApiUrl),
      );
    } catch (_) {
      return '';
    }
  }

  static bool get customApiConfigured => customApiBaseUrl.isNotEmpty;

  static Future<int> getDanDanBangumiIDByBgmBangumiID(int bgmBangumiID) async {
    final path = ApiEndpoints.formatUrl(
      ApiEndpoints.dandanAPIInfoByBgmBangumiId,
      [bgmBangumiID],
    );
    final endPoint = ApiEndpoints.dandanAPIDomain + path;
    final jsonData = await _client.get(endPoint);
    return DanmakuEpisodeResponse.fromJson(jsonData).bangumiId;
  }

  static Future<DanmakuEpisodeResponse> getDanDanEpisodesByDanDanBangumiID(
    int bangumiID, {
    List<DanmakuEpisode> fallback = const [],
  }) async {
    final path = ApiEndpoints.dandanAPIInfo + bangumiID.toString();
    final endPoint = ApiEndpoints.dandanAPIDomain + path;
    try {
      final jsonData = await _client.get(endPoint);
      final parsed = DanmakuEpisodeResponse.fromJson(
        Map<String, dynamic>.from(jsonData as Map),
        catalog: DanmakuCatalog.dandan,
      );
      if (parsed.episodes.isNotEmpty || fallback.isEmpty) {
        return parsed;
      }
    } catch (_) {
      if (fallback.isEmpty) rethrow;
    }
    return DanmakuEpisodeResponse(
      bangumiId: bangumiID,
      episodes: fallback,
      errorCode: 0,
      success: true,
      errorMessage: '',
    );
  }

  static Future<DanmakuSearchResponse> searchCustomAnimes(String title) async {
    final baseUrl = customApiBaseUrl;
    final keyword = normalizeSearchKeyword(title);
    if (baseUrl.isEmpty || keyword.isEmpty) {
      return const DanmakuSearchResponse(animes: [], hasMore: false);
    }
    final endPoint = '$baseUrl${ApiEndpoints.dandanAPISearchEpisodes}';
    for (final query in [
      {'anime': keyword, 'v2': 'true'},
      {'anime': keyword},
    ]) {
      try {
        final response = await DioFactory.apiDio.get<dynamic>(
          endPoint,
          queryParameters: query,
        );
        if (response.data is Map) {
          final parsed = DanmakuSearchResponse.fromJson(
            Map<String, dynamic>.from(response.data as Map),
            catalog: DanmakuCatalog.custom,
          );
          if (parsed.animes.isNotEmpty) return parsed;
        }
      } catch (error) {
        KazumiLogger().w('Danmaku: custom search failed', error: error);
      }
    }
    return const DanmakuSearchResponse(animes: [], hasMore: false);
  }

  static Future<List<DanmakuEpisode>> getCustomEpisodes(
    int animeId, {
    List<DanmakuEpisode> fallback = const [],
  }) async {
    final baseUrl = customApiBaseUrl;
    if (baseUrl.isEmpty) return fallback;
    final endPoint = '$baseUrl${ApiEndpoints.dandanAPIInfo}$animeId';
    try {
      final response = await DioFactory.apiDio.get<dynamic>(endPoint);
      if (response.data is Map) {
        final parsed = DanmakuEpisodeResponse.fromJson(
          Map<String, dynamic>.from(response.data as Map),
          catalog: DanmakuCatalog.custom,
        );
        if (parsed.episodes.isNotEmpty) return parsed.episodes;
      }
    } catch (error) {
      KazumiLogger().w('Danmaku: custom episodes failed', error: error);
      if (fallback.isEmpty) rethrow;
    }
    return fallback;
  }

  static Future<List<DanmakuEntry>> getCustomComments(int episodeId) async {
    final baseUrl = customApiBaseUrl;
    if (baseUrl.isEmpty) return const [];
    final endPoint = '$baseUrl${ApiEndpoints.dandanAPIComment}$episodeId';
    KazumiLogger().i('Danmaku: custom comment URL $endPoint');
    final response = await DioFactory.apiDio.get<dynamic>(
      endPoint,
      queryParameters: {
        'withRelated': 'true',
        'chConvert': _chConvertValue(),
      },
    );
    return _parseDanDanComments(response.data);
  }

  /// 并发聚合自定义弹幕源、弹弹Play 与 B站公开弹幕，用于手动搜索与多源切换。
  static Future<DanmakuSearchResponse> searchAnimes(
    String title, {
    MediaKind? preferredKind,
  }) async {
    final keyword = normalizeSearchKeyword(title);
    if (keyword.isEmpty) {
      return const DanmakuSearchResponse(animes: [], hasMore: false);
    }

    final customFuture = customApiConfigured
        ? searchCustomAnimes(keyword).catchError((Object error) {
            KazumiLogger().w('Danmaku: custom search error', error: error);
            return const DanmakuSearchResponse(animes: [], hasMore: false);
          })
        : Future.value(
            const DanmakuSearchResponse(animes: [], hasMore: false),
          );

    final dandanFuture = dandanCredentialsConfigured
        ? _searchOfficialDandan(keyword).catchError((Object error) {
            KazumiLogger().w('Danmaku: dandan search error', error: error);
            return const DanmakuSearchResponse(animes: [], hasMore: false);
          })
        : Future.value(
            const DanmakuSearchResponse(animes: [], hasMore: false),
          );

    final bilibiliFuture = BilibiliDanmakuApi.search(
      keyword,
      preferredKind: preferredKind,
    ).catchError((Object error) {
      KazumiLogger().w('Danmaku: bilibili search error', error: error);
      return const DanmakuSearchResponse(animes: [], hasMore: false);
    });

    final results = await Future.wait([
      customFuture,
      dandanFuture,
      bilibiliFuture,
    ]);
    final merged = <DanmakuSearchAnime>[];
    var hasMore = false;
    for (final result in results) {
      merged.addAll(result.animes);
      if (result.hasMore) hasMore = true;
    }
    return DanmakuSearchResponse(animes: merged, hasMore: hasMore);
  }

  static Future<DanmakuSearchResponse> _searchOfficialDandan(
    String keyword,
  ) async {
    final endPoint =
        ApiEndpoints.dandanAPIDomain + ApiEndpoints.dandanAPISearchEpisodes;
    final jsonData = await _client.get(
      endPoint,
      queryParameters: {'anime': keyword, 'v2': 'true'},
    );
    return DanmakuSearchResponse.fromJson(
      Map<String, dynamic>.from(jsonData as Map),
      catalog: DanmakuCatalog.dandan,
    );
  }

  /// 按作品标题与集号依次尝试：自定义源 → 弹弹Play（已配置凭证）→ B站公开弹幕。
  static Future<List<DanmakuEntry>> fetchDanmakuByTitles(
    List<String> titles,
    int episodeNumber, {
    MediaKind? mediaKind,
  }) async {
    if (episodeNumber <= 0) return const [];
    final candidates = buildSearchCandidates(titles);
    if (candidates.isEmpty) return const [];
    final isMovie = mediaKind == MediaKind.movie;

    if (customApiConfigured) {
      for (final keyword in candidates) {
        try {
          final searchRes = await searchCustomAnimes(keyword);
          final anime = BilibiliDanmakuApi.selectBestAnime(
            searchRes.animes,
            keyword,
            preferredKind: mediaKind,
          );
          if (anime == null) continue;
          final episodes = await getCustomEpisodes(
            anime.animeId,
            fallback: anime.inlineEpisodes,
          );
          final matched = BilibiliDanmakuApi.matchEpisode(
            episodes,
            episodeNumber,
            isMovie: isMovie,
          );
          if (matched == null) continue;
          final entries = await getCustomComments(matched.episodeId);
          if (entries.isNotEmpty) return entries;
        } catch (error) {
          KazumiLogger().w('Danmaku: custom auto-match failed', error: error);
        }
      }
    }

    if (dandanCredentialsConfigured) {
      for (final keyword in candidates) {
        try {
          final searchRes = await _searchOfficialDandan(keyword);
          final anime = BilibiliDanmakuApi.selectBestAnime(
            searchRes.animes,
            keyword,
            preferredKind: mediaKind,
          );
          if (anime == null) continue;
          final episodeResp = await getDanDanEpisodesByDanDanBangumiID(
            anime.animeId,
            fallback: anime.inlineEpisodes,
          );
          final matched = BilibiliDanmakuApi.matchEpisode(
            episodeResp.episodes,
            episodeNumber,
            isMovie: isMovie,
          );
          if (matched == null) continue;
          final entries = await getDanDanmakuByEpisodeID(matched.episodeId);
          if (entries.isNotEmpty) return entries;
        } catch (error) {
          KazumiLogger().w('Danmaku: dandan auto-match failed', error: error);
        }
      }
    }

    return BilibiliDanmakuApi.fetchEpisodeComments(
      candidates,
      episodeNumber,
      mediaKind: mediaKind,
    );
  }

  /// 清理影视/动漫来源标题中的集数、清晰度、配音与括号年份后缀，生成按精准度排序的检索词列表。
  static List<String> buildSearchCandidates(List<String> rawTitles) {
    final result = <String>[];
    final seen = <String>{};

    void addCandidate(String value) {
      final clean = value.trim();
      if (clean.isNotEmpty && seen.add(clean)) {
        result.add(clean);
      }
    }

    for (final raw in rawTitles) {
      final base = normalizeSearchKeyword(raw);
      if (base.isEmpty) continue;
      addCandidate(base);

      final withoutSeason = base
          .replaceAll(RegExp(r'\s*第[一二三四五六七八九十\d]+[季部]\s*$'), '')
          .replaceAll(
            RegExp(r'\s*(?:Season|S)\s*\d+\s*$', caseSensitive: false),
            '',
          )
          .trim();
      if (withoutSeason.isNotEmpty && withoutSeason != base) {
        addCandidate(withoutSeason);
      }
    }

    return result;
  }

  /// 去掉来源标题末尾的集数、清晰度、配音及年份等修饰后缀，避免影响弹幕库检索。
  static String normalizeSearchKeyword(String title) {
    var normalized = title.trim();
    if (normalized.isEmpty) return '';

    final noiseTagPattern = RegExp(
      r'(?:[\(\[（【][^()\[\]（）【】]*(?:19|20)\d{2}[^()\[\]（）【】]*[\)\]）】]|'
      r'[\(\[（【]\s*(?:HD|BD|4K|1080P|720P|国语|粤语|中字|双字|英语|日语|蓝光|TC|抢先版|全集)\s*[\)\]）】]|'
      r'\s+(?:HD|BD|4K|1080P|720P|国语版?|粤语版?|中字|双字|蓝光|TC|抢先版|全集|未删减版?|导演剪辑版?))$',
      caseSensitive: false,
    );

    String previous;
    do {
      previous = normalized;
      normalized = normalized
          .replaceAll(RegExp(r'\s*第\s*\d+\s*[集话話期]\s*$'), '')
          .replaceAll(
            RegExp(r'\s*(?:EP|E)\s*\d+\s*$', caseSensitive: false),
            '',
          )
          .replaceAll(noiseTagPattern, '')
          .trim();
    } while (normalized != previous && normalized.isNotEmpty);

    return normalized.isEmpty ? title.trim() : normalized;
  }

  static Future<List<DanmakuEntry>> getDanDanmaku(
    int bangumiID,
    int episode,
  ) async {
    if (bangumiID == 0) {
      return [];
    }
    // Automatic matching relies on an undocumented episode ID convention.
    return _getComments('$bangumiID${episode.toString().padLeft(4, '0')}');
  }

  static Future<List<DanmakuEntry>> getDanDanmakuByEpisodeID(int episodeID) =>
      _getComments(episodeID.toString());

  static Future<List<DanmakuEntry>> _getComments(String episodeID) async {
    final endPoint =
        '${ApiEndpoints.dandanAPIDomain}${ApiEndpoints.dandanAPIComment}$episodeID';
    KazumiLogger().i('Danmaku: final request URL $endPoint');
    final jsonData = await _client.get(
      endPoint,
      queryParameters: {
        'withRelated': 'true',
        'chConvert': _chConvertValue(),
      },
    );
    return _parseDanDanComments(jsonData);
  }

  static String _chConvertValue() {
    try {
      return DanmakuChConvert.fromValue(
        GStorage.getSetting(SettingsKeys.danmakuChConvert),
      ).value.toString();
    } catch (_) {
      return DanmakuChConvert.none.value.toString();
    }
  }

  static List<DanmakuEntry> _parseDanDanComments(dynamic jsonData) {
    if (jsonData is! Map) return const [];
    final rawComments = jsonData['comments'];
    if (rawComments is! List) return const [];
    final entries = <DanmakuEntry>[];
    for (final comment in rawComments) {
      if (comment is! Map) continue;
      try {
        entries.add(DanmakuEntry.fromJson(Map<String, dynamic>.from(comment)));
      } catch (_) {
        // 单条弹幕字段不完整时保留其余结果。
      }
    }
    return entries;
  }
}
