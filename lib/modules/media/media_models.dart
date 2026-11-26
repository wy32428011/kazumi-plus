import 'dart:convert';
import 'package:kazumi/modules/media/work_cluster_models.dart';

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

/// 影视（电视剧、电影）支持的排序方式。
enum MediaSort {
  latest('最新更新'),
  rating('评分最高'),
  yearDesc('年份最新'),
  yearAsc('年份最早'),
  title('片名排序');

  const MediaSort(this.label);
  final String label;

  static MediaSort parse(Object? value) =>
      values.firstWhere((sort) => sort.name == value, orElse: () => latest);
}

extension MediaSortListExtension on List<MediaSummary> {
  /// 对影视列表按指定的排序方式排序；[MediaSort.latest] 保持源站原始更新顺序。
  List<MediaSummary> sortedBy(MediaSort sort) {
    if (sort == MediaSort.latest) return this;
    final copy = List<MediaSummary>.of(this);
    switch (sort) {
      case MediaSort.latest:
        return copy;
      case MediaSort.rating:
        copy.sort((a, b) {
          final rawA = double.tryParse(
            a.ratingText.replaceAll(RegExp(r'[^\d.]'), ''),
          );
          final rawB = double.tryParse(
            b.ratingText.replaceAll(RegExp(r'[^\d.]'), ''),
          );
          final scoreA = (rawA != null && rawA > 0 && rawA <= 10.0)
              ? rawA
              : 0.0;
          final scoreB = (rawB != null && rawB > 0 && rawB <= 10.0)
              ? rawB
              : 0.0;
          if (scoreA > 0 && scoreB > 0 && scoreA != scoreB) {
            return scoreB.compareTo(scoreA);
          }
          if (scoreA > 0 && scoreB <= 0) return -1;
          if (scoreB > 0 && scoreA <= 0) return 1;
          return a.title.compareTo(b.title);
        });
        return copy;
      case MediaSort.yearDesc:
        copy.sort((a, b) {
          final yearA =
              int.tryParse(
                RegExp(r'\d{4}').firstMatch(a.year)?.group(0) ?? '',
              ) ??
              0;
          final yearB =
              int.tryParse(
                RegExp(r'\d{4}').firstMatch(b.year)?.group(0) ?? '',
              ) ??
              0;
          if (yearA > 0 && yearB > 0 && yearA != yearB) {
            return yearB.compareTo(yearA);
          }
          if (yearA > 0 && yearB <= 0) return -1;
          if (yearB > 0 && yearA <= 0) return 1;
          return a.title.compareTo(b.title);
        });
        return copy;
      case MediaSort.yearAsc:
        copy.sort((a, b) {
          final yearA =
              int.tryParse(
                RegExp(r'\d{4}').firstMatch(a.year)?.group(0) ?? '',
              ) ??
              0;
          final yearB =
              int.tryParse(
                RegExp(r'\d{4}').firstMatch(b.year)?.group(0) ?? '',
              ) ??
              0;
          if (yearA > 0 && yearB > 0 && yearA != yearB) {
            return yearA.compareTo(yearB);
          }
          if (yearA > 0 && yearB <= 0) return -1;
          if (yearB > 0 && yearA <= 0) return 1;
          return a.title.compareTo(b.title);
        });
        return copy;
      case MediaSort.title:
        copy.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        return copy;
    }
  }
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
    this.workCluster,
    this.candidates = const [],
    this.initialResumeMs,
  });
  final MediaSummary media;
  final SourcePlaylist playlist;
  final int roadIndex;
  final int episodeIndex;
  final WorkCluster? workCluster;
  final List<MediaCandidate> candidates;

  /// 若从停用源无损续播或跨源切入，显式传入待恢复位置（毫秒）。
  final int? initialResumeMs;
}
