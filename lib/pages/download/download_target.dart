import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/video/video_controller.dart';

/// 下载选集面板所需的最小信息，让番剧与影视播放页共用同一套下载流程。
class DownloadTarget {
  const DownloadTarget({
    required this.recordId,
    required this.title,
    required this.coverUrl,
    required this.pluginName,
    required this.roads,
    required this.playingRoad,
    required this.playingEpisode,
  });

  /// 番剧使用 Bangumi ID（正数）；影视使用 [sourceRecordId] 生成的负数，避免两者冲突。
  final int recordId;
  final String title;
  final String coverUrl;
  final String pluginName;
  final List<Road> roads;
  final int playingRoad;
  final int playingEpisode;

  factory DownloadTarget.anime(VideoPageController controller) {
    final item = controller.bangumiItem;
    final playback = controller.playbackEpisode;
    return DownloadTarget(
      recordId: item.id,
      title: item.nameCn.isNotEmpty ? item.nameCn : item.name,
      coverUrl: item.images['large'] ?? '',
      pluginName: controller.currentPlugin.name,
      roads: controller.roadList,
      playingRoad: playback.road,
      playingEpisode: playback.episode,
    );
  }

  /// 影视作品没有 Bangumi ID，由来源、类型、作品与季稳定派生记录 ID。
  static int sourceRecordId(MediaRef ref, {String seasonId = ''}) {
    // FNV-1a 32 位：跨启动稳定，不能用 String.hashCode（不保证跨进程一致）。
    var hash = 0x811c9dc5;
    for (final unit in '${ref.key}|$seasonId'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return -(hash == 0 ? 1 : hash);
  }

  /// 负数记录 ID 表示非 Bangumi 作品，不能用于弹弹Play 或 Bangumi 查询。
  static bool isBangumiRecord(int recordId) => recordId > 0;
}
