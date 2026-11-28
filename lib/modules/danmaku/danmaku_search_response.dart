import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';

/// Response of `/api/v2/search/episodes`.
///
/// Entries carry no cover, rating or air date, unlike `/api/v2/search/anime`.
class DanmakuSearchAnime {
  final int animeId;
  final String animeTitle;
  final String typeDescription;

  /// `dandan` 走弹弹分集接口；`custom` 走自定义兼容接口；`bilibili` 的 [animeId] 是 season_id。
  final String catalog;

  /// 部分弹弹Play v2 兼容服务会直接在 search/episodes 响应中内联分集列表。
  final List<DanmakuEpisode> inlineEpisodes;

  const DanmakuSearchAnime({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
    this.catalog = 'dandan',
    this.inlineEpisodes = const [],
  });

  factory DanmakuSearchAnime.fromJson(
    Map<String, dynamic> json, {
    String catalog = 'dandan',
  }) {
    final rawAnimeId = json['animeId'];
    final rawEpisodes = json['episodes'];
    final inlineEpisodes = <DanmakuEpisode>[];
    if (rawEpisodes is List) {
      for (final item in rawEpisodes) {
        if (item is! Map) continue;
        try {
          inlineEpisodes.add(
            DanmakuEpisode.fromJson(
              Map<String, dynamic>.from(item),
              catalog: catalog,
            ),
          );
        } catch (_) {
          // 忽略单条损坏的内联分集。
        }
      }
    }
    return DanmakuSearchAnime(
      animeId: rawAnimeId is num
          ? rawAnimeId.toInt()
          : int.parse('${rawAnimeId ?? ''}'),
      animeTitle: '${json['animeTitle'] ?? ''}',
      typeDescription: '${json['typeDescription'] ?? ''}',
      catalog: catalog,
      inlineEpisodes: inlineEpisodes,
    );
  }
}

class DanmakuSearchResponse {
  final List<DanmakuSearchAnime> animes;

  /// Result set was truncated; the user should narrow the keyword.
  final bool hasMore;

  const DanmakuSearchResponse({
    required this.animes,
    required this.hasMore,
  });

  factory DanmakuSearchResponse.fromJson(
    Map<String, dynamic> json, {
    String catalog = 'dandan',
  }) {
    final raw = json['animes'];
    final animes = <DanmakuSearchAnime>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          animes.add(
            DanmakuSearchAnime.fromJson(
              Map<String, dynamic>.from(item),
              catalog: catalog,
            ),
          );
        } catch (_) {
          // 缺字段的条目不能让整次搜索失败。
        }
      }
    }
    return DanmakuSearchResponse(
      animes: animes,
      hasMore: json['hasMore'] == true,
    );
  }
}
