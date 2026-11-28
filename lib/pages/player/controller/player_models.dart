import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/services/player/hls_proxy_service.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

/// 通用播放器只接收媒体参数，作品身份与观看记录由上层会话持有。
class PlayerMediaInitParams {
  const PlayerMediaInitParams({
    required this.videoUrl,
    required this.offset,
    required this.isLocalPlayback,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.referer,
    this.mediaKind = MediaKind.anime,
    this.videoSourceFormat = VideoSourceFormat.auto,
    this.coverUrl,
    this.playbackSpeed,
    this.hlsPreFetchedSeed,
    this.failoverAware = false,
    this.onPrioritySegmentFailure,
    this.onCdnGroupResolved,
  });

  final String videoUrl;
  final int offset;
  final bool isLocalPlayback;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final String referer;
  final MediaKind mediaKind;
  final VideoSourceFormat videoSourceFormat;
  final String? coverUrl;

  /// 影视切集可保留当前倍速；未指定时沿用播放器默认设置。
  final double? playbackSpeed;

  /// 探针预取的 HLS 清单种子（TTL ≤ 15s），零拷贝交给本地代理省去二次拉取。
  final HlsPreFetchedSeed? hlsPreFetchedSeed;

  /// 开启后本地 HLS 代理收紧优先分片超时（6s × 2）并在失败时上报触发容灾。
  final bool failoverAware;

  final void Function(HlsProxySegmentFailure failure)? onPrioritySegmentFailure;
  final void Function(String cdnGroup)? onCdnGroupResolved;
}

class PlaybackInitParams {
  final String videoUrl;
  final int offset;
  final bool isLocalPlayback;
  final VideoSourceFormat videoSourceFormat;
  final int bangumiId;
  final String pluginName;
  final int episode;
  final int danmakuEpisodeNumber;
  final String pageUrl;

  /// Parsed title number online, downloaded episode number offline.
  final int? sortNumber;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final String episodeTitle;
  final String referer;
  final int currentRoad;
  final String? coverUrl;
  final String? bangumiName;

  const PlaybackInitParams({
    required this.videoUrl,
    required this.offset,
    required this.isLocalPlayback,
    required this.bangumiId,
    required this.pluginName,
    required this.episode,
    required this.danmakuEpisodeNumber,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episodeTitle,
    required this.referer,
    required this.currentRoad,
    this.videoSourceFormat = VideoSourceFormat.auto,
    this.pageUrl = '',
    this.sortNumber,
    this.coverUrl,
    this.bangumiName,
  });
}

class SyncPlayChatMessage {
  final String username;
  final String message;
  final bool fromRemote;
  final DateTime time;

  SyncPlayChatMessage({
    required this.username,
    required this.message,
    this.fromRemote = true,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}
