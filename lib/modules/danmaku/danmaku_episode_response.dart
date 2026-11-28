class DanmakuEpisode {
  int episodeId;
  String episodeTitle;

  /// `dandan` 的 [episodeId] 是弹弹剧集编号；`custom` 为兼容源剧集编号；`bilibili` 时是视频 cid。
  String catalog;

  DanmakuEpisode({
    required this.episodeId,
    required this.episodeTitle,
    this.catalog = 'dandan',
  });

  factory DanmakuEpisode.fromJson(
    Map<String, dynamic> json, {
    String catalog = 'dandan',
  }) {
    final rawEpisodeId = json['episodeId'];
    return DanmakuEpisode(
      episodeId: rawEpisodeId is num
          ? rawEpisodeId.toInt()
          : int.parse('${rawEpisodeId ?? ''}'),
      episodeTitle: '${json['episodeTitle'] ?? ''}',
      catalog: catalog,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'episodeId': episodeId,
      'episodeTitle': episodeTitle,
    };
  }
}

class DanmakuEpisodeResponse {
  int bangumiId;
  List<DanmakuEpisode> episodes;
  int errorCode;
  bool success;
  String errorMessage;

  DanmakuEpisodeResponse({
    required this.bangumiId,
    required this.episodes,
    required this.errorCode,
    required this.success,
    required this.errorMessage,
  });

  factory DanmakuEpisodeResponse.fromJson(
    Map<String, dynamic> json, {
    String catalog = 'dandan',
  }) {
    final bangumi = json['bangumi'];
    final episodeList = <DanmakuEpisode>[];
    var bangumiId = 0;

    if (bangumi is Map) {
      final rawAnimeId = bangumi['animeId'];
      if (rawAnimeId is num) {
        bangumiId = rawAnimeId.toInt();
      } else if (rawAnimeId != null) {
        bangumiId = int.tryParse('$rawAnimeId') ?? 0;
      }
      final rawEpisodes = bangumi['episodes'];
      if (rawEpisodes is List) {
        for (final item in rawEpisodes) {
          if (item is! Map) continue;
          try {
            episodeList.add(
              DanmakuEpisode.fromJson(
                Map<String, dynamic>.from(item),
                catalog: catalog,
              ),
            );
          } catch (_) {
            // 忽略单条损坏的分集记录。
          }
        }
      }
    }

    final rawErrorCode = json['errorCode'];
    return DanmakuEpisodeResponse(
      bangumiId: bangumiId,
      episodes: episodeList,
      errorCode: rawErrorCode is num ? rawErrorCode.toInt() : 0,
      success: json['success'] is bool ? json['success'] as bool : true,
      errorMessage: '${json['errorMessage'] ?? ''}',
    );
  }

  factory DanmakuEpisodeResponse.fromTemplate() {
    return DanmakuEpisodeResponse(
      bangumiId: 0,
      episodes: [],
      errorCode: 0,
      success: false,
      errorMessage: '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'bangumi': episodes.map((episode) => episode.toJson()).toList(),
      'errorCode': errorCode,
      'success': success,
      'errorMessage': errorMessage,
    };
  }
}
