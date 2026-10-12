import 'dart:convert';

/// 内容类型与来源编号分别保存，避免影视编号与 Bangumi 编号冲突。
enum MediaKind {
  anime('动漫'),
  tv('电视剧'),
  movie('电影');

  const MediaKind(this.label);
  final String label;

  static MediaKind parse(Object? value) =>
      values.firstWhere((kind) => kind.name == value, orElse: () => anime);
}

/// 作品身份不依赖标题、规则显示名称或临时播放地址。
class MediaRef {
  const MediaRef.bangumi(this.id)
    : provider = 'bangumi',
      ruleId = '',
      kind = MediaKind.anime;

  const MediaRef.source({
    required this.ruleId,
    required this.kind,
    required this.id,
  }) : provider = 'rule';

  final String provider;
  final String ruleId;
  final MediaKind kind;
  final String id;

  bool get isAnime => provider == 'bangumi';
  String get key => jsonEncode([provider, ruleId, kind.name, id]);

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'ruleId': ruleId,
    'kind': kind.name,
    'id': id,
  };

  factory MediaRef.fromJson(Map<String, dynamic> json) {
    final id = json['id'].toString();
    if (json['provider'] == 'bangumi') return MediaRef.bangumi(id);
    return MediaRef.source(
      ruleId: json['ruleId'] as String,
      kind: MediaKind.parse(json['kind']),
      id: id,
    );
  }

  @override
  bool operator ==(Object other) => other is MediaRef && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class MediaCategory {
  const MediaCategory({
    required this.id,
    required this.name,
    required this.kind,
  });
  final String id;
  final String name;
  final MediaKind kind;
}

/// 收藏和历史保存摘要快照，来源暂时不可用时仍可展示作品。
class MediaSummary {
  const MediaSummary({
    required this.ref,
    required this.title,
    required this.detailSource,
    this.sourceName = '',
    this.posterUrl = '',
    this.year = '',
    this.region = '',
    this.statusText = '',
    this.ratingText = '',
  });

  final MediaRef ref;
  final String title;
  final String detailSource;
  final String sourceName;
  final String posterUrl;
  final String year;
  final String region;
  final String statusText;
  final String ratingText;

  Map<String, dynamic> toJson() => {
    'ref': ref.toJson(),
    'title': title,
    'detailSource': detailSource,
    'sourceName': sourceName,
    'posterUrl': posterUrl,
    'year': year,
    'region': region,
    'statusText': statusText,
    'ratingText': ratingText,
  };

  factory MediaSummary.fromJson(Map<String, dynamic> json) => MediaSummary(
    ref: MediaRef.fromJson(Map<String, dynamic>.from(json['ref'] as Map)),
    title: json['title'] as String,
    detailSource: json['detailSource'] as String,
    sourceName: json['sourceName'] as String? ?? '',
    posterUrl: json['posterUrl'] as String? ?? '',
    year: json['year'] as String? ?? '',
    region: json['region'] as String? ?? '',
    statusText: json['statusText'] as String? ?? '',
    ratingText: json['ratingText'] as String? ?? '',
  );
}

class MediaSeason {
  const MediaSeason({
    required this.id,
    required this.name,
    this.number,
    this.detailSource,
  });
  final String id;
  final String name;
  final int? number;
  final String? detailSource;
}

class MediaDetail {
  const MediaDetail({
    required this.summary,
    this.description = '',
    this.aliases = const [],
    this.genres = const [],
    this.castText = '',
    this.seasons = const [],
  });
  final MediaSummary summary;
  final String description;
  final List<String> aliases;
  final List<String> genres;
  final String castText;
  final List<MediaSeason> seasons;
}

class MediaPage {
  const MediaPage({
    required this.items,
    required this.page,
    required this.hasMore,
  });
  final List<MediaSummary> items;
  final int page;
  final bool hasMore;
}

/// 播放项使用来源稳定标识；显示序号不充当进度主键。
class PlayableEpisode {
  const PlayableEpisode({
    required this.id,
    required this.title,
    required this.url,
    this.number,
    this.seasonId,
  });
  final String id;
  final String title;
  final String url;
  final int? number;
  final String? seasonId;

  String get key => jsonEncode([seasonId, id]);
}

class PlaybackRoad {
  const PlaybackRoad({
    required this.id,
    required this.name,
    required this.episodes,
  });
  final String id;
  final String name;
  final List<PlayableEpisode> episodes;
}

class SourcePlaylist {
  const SourcePlaylist({required this.roads, this.season});
  final List<PlaybackRoad> roads;
  final MediaSeason? season;
}

class PlaybackContext {
  const PlaybackContext({
    required this.media,
    required this.playlist,
    this.roadIndex = 0,
    this.episodeIndex = 0,
  });
  final MediaSummary media;
  final SourcePlaylist playlist;
  final int roadIndex;
  final int episodeIndex;
}
