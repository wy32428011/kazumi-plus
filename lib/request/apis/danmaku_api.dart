import 'package:kazumi/modules/danmaku/danmaku_ch_convert.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/request/apis/bilibili_danmaku_api.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

class DanmakuApi {
  static final DanmakuClient _client = DanmakuClient.instance;

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
    int bangumiID,
  ) async {
    final path = ApiEndpoints.dandanAPIInfo + bangumiID.toString();
    final endPoint = ApiEndpoints.dandanAPIDomain + path;
    final jsonData = await _client.get(endPoint);
    return DanmakuEpisodeResponse.fromJson(jsonData);
  }

  // v2 episode search avoids the anime search's 25-result cap.
  // Fetch full episode lists separately; search results can truncate them.
  static Future<DanmakuSearchResponse> searchAnimes(String title) async {
    final keyword = normalizeSearchKeyword(title);
    if (dandanCredentialsConfigured) {
      try {
        final endPoint =
            ApiEndpoints.dandanAPIDomain + ApiEndpoints.dandanAPISearchEpisodes;
        final jsonData = await _client.get(
          endPoint,
          queryParameters: {'anime': keyword, 'v2': 'true'},
        );
        final response = DanmakuSearchResponse.fromJson(
          Map<String, dynamic>.from(jsonData as Map),
        );
        if (response.animes.isNotEmpty) return response;
      } catch (error) {
        KazumiLogger().w(
          'Danmaku: dandan search failed, falling back',
          error: error,
        );
      }
    } else {
      KazumiLogger().w(
        'Danmaku: dandan credentials are missing, searching bilibili',
      );
    }
    return BilibiliDanmakuApi.search(keyword);
  }

  /// 去掉来源标题末尾的集数，避免把「第01集」送进作品检索。
  static String normalizeSearchKeyword(String title) {
    final trimmed = title.trim();
    final normalized = trimmed
        .replaceAll(RegExp(r'\s*第\s*\d+\s*[集话話期]\s*$'), '')
        .replaceAll(RegExp(r'\s*(?:EP|E)\s*\d+\s*$', caseSensitive: false), '')
        .trim();
    return normalized.isEmpty ? trimmed : normalized;
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
    final conversion = DanmakuChConvert.fromValue(
      GStorage.getSetting(SettingsKeys.danmakuChConvert),
    );
    KazumiLogger().i('Danmaku: final request URL $endPoint');
    final jsonData = await _client.get(
      endPoint,
      queryParameters: {
        'withRelated': 'true',
        'chConvert': conversion.value.toString(),
      },
    );
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
