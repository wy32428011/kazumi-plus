import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/source_health_repository.dart';

/// 动漫播中热切源与容灾使用的备选片源条目（仅携带插件与条目引用，不改变 BangumiItem 主身份）。
class AnimeSourceCandidate {
  const AnimeSourceCandidate({
    required this.plugin,
    required this.title,
    required this.src,
    this.roads = const [],
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;

  String get pluginIdentityKey =>
      SourceHealthRepository.pluginIdentityKey(plugin);

  String get id => '$pluginIdentityKey|$src';

  AnimeSourceCandidate copyWith({
    Plugin? plugin,
    String? title,
    String? src,
    List<Road>? roads,
  }) {
    return AnimeSourceCandidate(
      plugin: plugin ?? this.plugin,
      title: title ?? this.title,
      src: src ?? this.src,
      roads: roads ?? this.roads,
    );
  }
}

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    this.alternateSources = const [],
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;

  /// 同作品在其他动漫插件中的匹配结果，用于播放器内一键切源与播中容灾。
  final List<AnimeSourceCandidate> alternateSources;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}

