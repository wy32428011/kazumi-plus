/// Response of `/api/v2/search/episodes`.
///
/// Entries carry no cover, rating or air date, unlike `/api/v2/search/anime`.
class DanmakuSearchAnime {
  final int animeId;
  final String animeTitle;
  final String typeDescription;

  /// `dandan` 走弹弹分集接口；`bilibili` 的 [animeId] 是 season_id。
  final String catalog;

  const DanmakuSearchAnime({
    required this.animeId,
    required this.animeTitle,
    required this.typeDescription,
    this.catalog = 'dandan',
  });

  factory DanmakuSearchAnime.fromJson(Map<String, dynamic> json) {
    final animeId = json['animeId'];
    return DanmakuSearchAnime(
      animeId: animeId is num ? animeId.toInt() : animeId as int,
      animeTitle: '${json['animeTitle'] ?? ''}',
      typeDescription: json['typeDescription'] ?? '',
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

  factory DanmakuSearchResponse.fromJson(Map<String, dynamic> json) {
    final raw = json['animes'];
    final animes = <DanmakuSearchAnime>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          animes.add(
            DanmakuSearchAnime.fromJson(Map<String, dynamic>.from(item)),
          );
        } catch (_) {
          // 缺字段的条目不能让整次搜索失败。
        }
      }
    }
    return DanmakuSearchResponse(
      animes: animes,
      hasMore: json['hasMore'] ?? false,
    );
  }
}
