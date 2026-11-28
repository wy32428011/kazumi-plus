import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/danmaku.dart';
import 'package:kazumi/utils/http_headers.dart';

/// 弹弹 Play 未配置凭证或拒绝请求时，用哔哩哔哩公开检索补上动漫、电视剧与电影弹幕。
class BilibiliDanmakuApi {
  static const catalog = 'bilibili';
  static final _random = Random();
  static String? _buvid;

  static Future<DanmakuSearchResponse> search(
    String title, {
    MediaKind? preferredKind,
  }) async {
    final keyword = title.trim();
    if (keyword.isEmpty) {
      return const DanmakuSearchResponse(animes: [], hasMore: false);
    }
    final searchTypes = switch (preferredKind) {
      MediaKind.movie || MediaKind.tv => const ['media_ft', 'media_bangumi'],
      _ => const ['media_bangumi', 'media_ft'],
    };
    final merged = <int, DanmakuSearchAnime>{};
    var hasMore = false;
    for (final type in searchTypes) {
      final payload = await _getJson(
        'https://api.bilibili.com/x/web-interface/search/type',
        queryParameters: {'search_type': type, 'keyword': keyword},
      );
      final data = payload?['data'];
      if (data is! Map) continue;
      final page = data['page'];
      final pages = data['numPages'];
      if (page is num && pages is num && pages > page) hasMore = true;
      final result = data['result'];
      if (result is! List) continue;
      for (final item in result) {
        if (item is! Map) continue;
        final seasonId = item['season_id'];
        final rawTitle = item['title'];
        if (seasonId is! num || rawTitle is! String) continue;
        final title = _plainText(rawTitle);
        if (title.isEmpty) continue;
        final id = seasonId.toInt();
        merged.putIfAbsent(
          id,
          () => DanmakuSearchAnime(
            animeId: id,
            animeTitle: title,
            typeDescription: _typeLabel(item),
            catalog: catalog,
          ),
        );
      }
    }
    return DanmakuSearchResponse(
      animes: merged.values.toList(),
      hasMore: hasMore,
    );
  }

  static Future<List<DanmakuEpisode>> episodes(int seasonId) async {
    final payload = await _getJson(
      'https://api.bilibili.com/pgc/view/web/season',
      queryParameters: {'season_id': seasonId},
    );
    final result = payload?['result'];
    if (result is! Map) return const [];
    final episodes = result['episodes'];
    if (episodes is! List) return const [];
    final parsed = <DanmakuEpisode>[];
    for (final item in episodes) {
      if (item is! Map) continue;
      final cid = item['cid'];
      if (cid is! num || cid <= 0) continue;
      parsed.add(
        DanmakuEpisode(
          episodeId: cid.toInt(),
          episodeTitle: _episodeTitle(item),
          catalog: catalog,
        ),
      );
    }
    return parsed;
  }

  static Future<List<DanmakuEntry>> comments(int cid) async {
    final response = await DioFactory.apiDio.get<dynamic>(
      'https://api.bilibili.com/x/v1/dm/list.so',
      queryParameters: {'oid': cid},
      options: Options(
        headers: _headers(referer: 'https://www.bilibili.com'),
        responseType: ResponseType.bytes,
      ),
    );
    final data = response.data;
    if (data is! List<int> || data.isEmpty) return const [];
    final xml = _decodeXml(data);
    return parseXml(xml);
  }

  /// 按候选标题与集号自动匹配作品并拉取弹幕，用于弹弹 Play 不可用时的兜底。
  static Future<List<DanmakuEntry>> fetchEpisodeComments(
    List<String> titles,
    int episodeNumber, {
    MediaKind? mediaKind,
  }) async {
    if (episodeNumber <= 0) return const [];
    final tried = <String>{};
    for (final rawTitle in titles) {
      final keyword = _stripEpisodeSuffix(rawTitle);
      if (keyword.isEmpty || !tried.add(keyword)) continue;
      final response = await search(keyword, preferredKind: mediaKind);
      final anime = selectBestAnime(
        response.animes,
        keyword,
        preferredKind: mediaKind,
      );
      if (anime == null) continue;
      final episodeList = await episodes(anime.animeId);
      final matched = matchEpisode(
        episodeList,
        episodeNumber,
        isMovie: mediaKind == MediaKind.movie,
      );
      if (matched == null) continue;
      final list = await comments(matched.episodeId);
      if (list.isNotEmpty) return list;
    }
    return const [];
  }

  static DanmakuSearchAnime? selectBestAnime(
    List<DanmakuSearchAnime> animes,
    String keyword, {
    MediaKind? preferredKind,
  }) {
    if (animes.isEmpty) return null;
    final normalizedKeyword = _normalizeTitle(keyword);
    if (normalizedKeyword.isEmpty) return animes.first;

    DanmakuSearchAnime? best;
    var bestScore = -1;
    for (final anime in animes) {
      final normalizedTitle = _normalizeTitle(anime.animeTitle);
      if (normalizedTitle.isEmpty) continue;
      final exact = normalizedTitle == normalizedKeyword;
      var score = 0;
      if (exact) {
        score += 120;
      } else if (normalizedTitle.contains(normalizedKeyword) ||
          normalizedKeyword.contains(normalizedTitle)) {
        // 拒绝明显衍生/二创/解说标题误匹配（例如搜「甄嬛传」命中「甄嬛传规则怪谈」）。
        if (_isDerivativeNoiseTitle(anime.animeTitle, keyword)) {
          continue;
        }
        if (normalizedTitle.length > normalizedKeyword.length * 2 + 4 &&
            !_hasReasonableSubtitleOrSeason(normalizedTitle, normalizedKeyword)) {
          continue;
        }
        score += 60;
      } else {
        continue;
      }
      if (!_isVariantTitle(anime.animeTitle)) {
        score += 20;
      }
      score += _typeAffinityScore(anime.typeDescription, preferredKind);
      final lengthPenalty =
          (normalizedTitle.length - normalizedKeyword.length).abs().clamp(0, 20);
      score -= lengthPenalty;
      if (score > bestScore) {
        bestScore = score;
        best = anime;
      }
    }
    return best;
  }

  static DanmakuEpisode? matchEpisode(
    List<DanmakuEpisode> episodes,
    int episodeNumber, {
    bool isMovie = false,
  }) {
    if (episodes.isEmpty || episodeNumber <= 0) return null;

    final featureEpisodes =
        episodes.where((ep) => !_isPreviewOrExtraTitle(ep.episodeTitle)).toList();

    if (isMovie) {
      for (final ep in featureEpisodes) {
        if (ep.episodeTitle.contains('正片')) {
          return ep;
        }
      }
      if (featureEpisodes.isNotEmpty) {
        return featureEpisodes.first;
      }
      return episodes.first;
    }

    final exactPrefix = RegExp(
      r'^第\s*0*' + episodeNumber.toString() + r'\s*[集话話期](?:\s|$)',
    );
    final exactEp = RegExp(
      r'^(?:EP|E)\s*0*' + episodeNumber.toString() + r'(?:\s|$)',
      caseSensitive: false,
    );
    final exactNumber = RegExp(r'^0*' + episodeNumber.toString() + r'$');

    for (final episode in featureEpisodes) {
      final title = episode.episodeTitle.trim();
      if (exactPrefix.hasMatch(title) ||
          exactEp.hasMatch(title) ||
          exactNumber.hasMatch(title)) {
        return episode;
      }
    }

    final index = episodeNumber - 1;
    if (index >= 0 && index < featureEpisodes.length) {
      return featureEpisodes[index];
    }
    if (index >= 0 && index < episodes.length) {
      return episodes[index];
    }
    return null;
  }

  static int _typeAffinityScore(
    String typeDescription,
    MediaKind? preferredKind,
  ) {
    if (typeDescription.isEmpty) return 0;
    return switch (preferredKind) {
      MediaKind.movie => typeDescription.contains('电影') ? 15 : 0,
      MediaKind.tv => (typeDescription.contains('电视剧') ||
              typeDescription.contains('剧集') ||
              typeDescription.contains('综艺') ||
              typeDescription.contains('纪录片'))
          ? 15
          : 0,
      _ => (typeDescription.contains('番剧') || typeDescription.contains('国创'))
          ? 15
          : 0,
    };
  }

  static bool _isDerivativeNoiseTitle(String title, String keyword) {
    const noiseMarkers = [
      '规则怪谈',
      '一口气',
      '解说',
      '速看',
      '剪辑',
      '二创',
      '反应',
      'reaction',
      '鬼畜',
      '盘点',
      '吐槽',
    ];
    final lowerTitle = title.toLowerCase();
    final lowerKeyword = keyword.toLowerCase();
    for (final marker in noiseMarkers) {
      if (lowerTitle.contains(marker) && !lowerKeyword.contains(marker)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasReasonableSubtitleOrSeason(
    String normalizedTitle,
    String normalizedKeyword,
  ) {
    return normalizedTitle.startsWith(normalizedKeyword) &&
        normalizedTitle.length <= normalizedKeyword.length + 12;
  }

  static bool _isPreviewOrExtraTitle(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();
    return lower.contains('预告') ||
        lower.contains('花絮') ||
        lower.contains('彩蛋') ||
        lower.contains('抢先') ||
        RegExp(r'\bpv\b|pv\d', caseSensitive: false).hasMatch(trimmed);
  }

  static String _stripEpisodeSuffix(String title) {
    final trimmed = title.trim();
    final normalized = trimmed
        .replaceAll(RegExp(r'\s*第\s*\d+\s*[集话話期]\s*$'), '')
        .replaceAll(RegExp(r'\s*(?:EP|E)\s*\d+\s*$', caseSensitive: false), '')
        .trim();
    return normalized.isEmpty ? trimmed : normalized;
  }

  static String _normalizeTitle(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_:：·・,，.。!！?？\(\)（）\[\]【】「」『』]'), '');
  }

  static bool _isVariantTitle(String title) {
    const markers = ['中配', '粤配', '配音', '精编', '总集篇', '预告', 'PV', 'pv'];
    return markers.any(title.contains);
  }

  static Future<Map<String, dynamic>?> _getJson(
    String url, {
    required Map<String, dynamic> queryParameters,
  }) async {
    try {
      final response = await DioFactory.apiDio.get<dynamic>(
        url,
        queryParameters: queryParameters,
        options: Options(
          headers: _headers(referer: 'https://search.bilibili.com'),
          responseType: ResponseType.json,
        ),
      );
      final data = response.data;
      if (data is Map && data['code'] == 0) {
        return Map<String, dynamic>.from(data);
      }
      KazumiLogger().w(
        'Danmaku: bilibili search returned ${data is Map ? data['code'] : data.runtimeType}',
      );
    } catch (error) {
      KazumiLogger().w('Danmaku: bilibili request failed', error: error);
    }
    return null;
  }

  static Map<String, dynamic> _headers({required String referer}) {
    _buvid ??= '${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}'
        '${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
    return {
      'user-agent': getRandomUA(),
      'referer': referer,
      'cookie': 'buvid3=${_buvid}infoc',
    };
  }

  static String _decodeXml(List<int> bytes) {
    try {
      return utf8.decode(ZLibDecoder(raw: true).convert(bytes));
    } catch (_) {
      try {
        return utf8.decode(zlib.decode(bytes));
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  static List<DanmakuEntry> parseXml(String xml) {
    final expression = RegExp(r'<d p="([^"]*)">([^<]*)</d>');
    final entries = <DanmakuEntry>[];
    for (final match in expression.allMatches(xml)) {
      final parts = match.group(1)!.split(',');
      if (parts.length < 4) continue;
      final time = double.tryParse(parts[0]);
      final mode = int.tryParse(parts[1]);
      final color = int.tryParse(parts[3]);
      final message = _plainText(match.group(2)!).trim();
      if (time == null || mode == null || color == null || message.isEmpty) {
        continue;
      }
      entries.add(
        DanmakuEntry(
          time: time,
          message: message,
          type: mode == 4 || mode == 5 ? mode : 1,
          color: generateDanmakuColor(color),
          source: 'BiliBili',
        ),
      );
    }
    return entries;
  }

  static String _episodeTitle(Map item) {
    final index = '${item['title'] ?? ''}'.trim();
    final longTitle = '${item['long_title'] ?? ''}'.trim();
    final badge = '${item['badge'] ?? ''}'.trim();
    String baseTitle;
    if (index.isEmpty) {
      baseTitle = longTitle.isEmpty ? '正片' : longTitle;
    } else if (RegExp(r'^\d+$').hasMatch(index)) {
      baseTitle = longTitle.isEmpty ? '第$index集' : '第$index集 $longTitle';
    } else {
      baseTitle = longTitle.isEmpty ? index : '$index $longTitle';
    }
    if ((badge.contains('预告') || badge.contains('花絮')) &&
        !baseTitle.contains(badge)) {
      return '$baseTitle ($badge)';
    }
    return baseTitle;
  }

  static String _typeLabel(Map item) {
    final typeName = item['season_type_name'];
    if (typeName is String && typeName.trim().isNotEmpty) return typeName.trim();
    final styles = item['styles'];
    return styles is String ? styles.trim() : '';
  }

  static String _plainText(String value) {
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }
}
