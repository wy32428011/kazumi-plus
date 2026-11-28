// ignore_for_file: library_private_types_in_public_api

import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_target.dart';
import 'package:kazumi/request/apis/bilibili_danmaku_api.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/utils/danmaku.dart';

part 'player_danmaku_controller.g.dart';

class PlayerDanmakuController extends _PlayerDanmakuController
    with _$PlayerDanmakuController {
  PlayerDanmakuController({
    required super.isLocalPlayback,
    super.downloadController,
  });
}

enum DanmakuLoadStatus {
  success,
  empty,
  failed,
}

class DanmakuLoadResult {
  const DanmakuLoadResult({
    required this.danmakus,
    required this.bangumiID,
    required this.status,
  });

  factory DanmakuLoadResult.success({
    required List<DanmakuEntry> danmakus,
    required int bangumiID,
  }) {
    return DanmakuLoadResult(
      danmakus: danmakus,
      bangumiID: bangumiID,
      status: danmakus.isEmpty
          ? DanmakuLoadStatus.empty
          : DanmakuLoadStatus.success,
    );
  }

  factory DanmakuLoadResult.failed({
    required int bangumiID,
  }) {
    return DanmakuLoadResult(
      danmakus: const [],
      bangumiID: bangumiID,
      status: DanmakuLoadStatus.failed,
    );
  }

  final List<DanmakuEntry> danmakus;
  final int bangumiID;
  final DanmakuLoadStatus status;

  bool get hasDanmakus => status == DanmakuLoadStatus.success;

  bool get isFailed => status == DanmakuLoadStatus.failed;
}

class DanmakuTimeline {
  static int? resolveSourceSecond(
    Duration playbackPosition,
    double timelineOffsetSeconds,
  ) {
    final sourceMilliseconds = playbackPosition.inMilliseconds -
        (timelineOffsetSeconds * 1000).round();
    if (sourceMilliseconds < 0) {
      return null;
    }
    return Duration(milliseconds: sourceMilliseconds).inSeconds;
  }

  static int staggerDelayMilliseconds({
    required int index,
    required int total,
  }) {
    if (total <= 0) {
      return 0;
    }
    return index * 1000 ~/ total;
  }
}

abstract class _PlayerDanmakuController with Store {
  _PlayerDanmakuController({
    required this.isLocalPlayback,
    this.downloadController,
  });

  final bool Function() isLocalPlayback;
  final DownloadController? downloadController;

  canvas.DanmakuController? _canvasController;

  canvas.DanmakuController get canvasController => _canvasController!;

  set canvasController(canvas.DanmakuController controller) {
    _canvasController = controller;
  }

  bool get hasCanvasController => _canvasController != null;

  bool get isCanvasRunning => _canvasController?.running ?? false;

  void attachCanvasController(canvas.DanmakuController controller) {
    _canvasController = controller;
  }

  void clearCanvas() {
    _canvasController?.clear();
  }

  void pauseCanvas() {
    _canvasController?.pause();
  }

  void resumeCanvas() {
    _canvasController?.resume();
  }

  final Map<int, List<DanmakuEntry>> danDanmakus = {};
  @observable
  bool danmakuOn = false;
  @observable
  bool danmakuLoading = false;

  int bangumiID = 0;
  int _scheduledDanmakuGeneration = 0;

  int get scheduledDanmakuGeneration => _scheduledDanmakuGeneration;

  double get timelineOffsetSeconds {
    try {
      return GStorage.getSetting(SettingsKeys.danmakuTimeOffset);
    } catch (_) {
      return 0.0;
    }
  }

  int? resolveDanmakuSecond(Duration playbackPosition) {
    return DanmakuTimeline.resolveSourceSecond(
      playbackPosition,
      timelineOffsetSeconds,
    );
  }

  List<DanmakuEntry> danmakusForPlaybackPosition(Duration playbackPosition) {
    final danmakuSecond = resolveDanmakuSecond(playbackPosition);
    if (danmakuSecond == null) {
      return const [];
    }
    return danDanmakus[danmakuSecond] ?? const [];
  }

  @action
  void setDanmakuEnabled(bool value) {
    danmakuOn = value;
  }

  void clearAndInvalidateScheduledDanmakus() {
    _scheduledDanmakuGeneration++;
    _canvasController?.clear();
  }

  // Apply fetched data only after VideoPageController validates the session.
  Future<DanmakuLoadResult> fetchDanmaku(
    int bangumiId,
    String pluginName,
    int episode, {
    List<String> fallbackTitles = const [],
  }) async {
    if (isLocalPlayback()) {
      return await _fetchCachedDanmaku(
        bangumiId,
        pluginName,
        episode,
        fallbackTitles: fallbackTitles,
      );
    }
    return await _fetchDanDanmakuByBgmBangumiID(
      bangumiId,
      episode,
      fallbackTitles: fallbackTitles,
    );
  }

  /// 为电视剧 / 电影等非 Bangumi 会话按标题和集号拉取公开弹幕。
  Future<DanmakuLoadResult> fetchMediaDanmaku({
    required List<String> titles,
    required int episodeNumber,
    required MediaKind mediaKind,
  }) async {
    try {
      final list = await DanmakuApi.fetchDanmakuByTitles(
        titles,
        episodeNumber,
        mediaKind: mediaKind,
      );
      return DanmakuLoadResult.success(danmakus: list, bangumiID: 0);
    } catch (e) {
      KazumiLogger().w(
        'PlayerDanmakuController: failed to fetch media danmaku',
        error: e,
      );
      return DanmakuLoadResult.failed(bangumiID: 0);
    }
  }

  @action
  void beginDanmakuLoad() {
    danDanmakus.clear();
    danmakuLoading = true;
  }

  @action
  void applyDanmakuLoad(
    DanmakuLoadResult result, {
    required bool enableDanmaku,
  }) {
    bangumiID = result.bangumiID;
    addDanmakus(result.danmakus);
    danmakuOn = enableDanmaku;
    danmakuLoading = false;
  }

  @action
  void applyUnavailableDanmakuLoad(DanmakuLoadResult result) {
    bangumiID = result.bangumiID;
    danDanmakus.clear();
    danmakuOn = false;
    danmakuLoading = false;
  }

  @action
  void finishDanmakuLoad({bool disableDanmaku = false}) {
    if (disableDanmaku) {
      danDanmakus.clear();
      danmakuOn = false;
    }
    danmakuLoading = false;
  }

  Future<DanmakuLoadResult> _fetchCachedDanmaku(
    int bangumiId,
    String pluginName,
    int episode, {
    List<String> fallbackTitles = const [],
  }) async {
    final downloader = downloadController;
    if (downloader == null) {
      return await _fetchDanDanmakuByBgmBangumiID(
        bangumiId,
        episode,
        fallbackTitles: fallbackTitles,
      );
    }
    KazumiLogger().i(
        'PlayerController: attempting to load cached danmaku for episode $episode');
    var nextBangumiID = bangumiID;
    try {
      final cachedDanmakus = await downloader.getCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
      );

      if (cachedDanmakus != null && cachedDanmakus.isNotEmpty) {
        KazumiLogger().i(
            'PlayerController: loaded ${cachedDanmakus.length} cached danmakus');
        return DanmakuLoadResult.success(
          danmakus: cachedDanmakus,
          bangumiID: nextBangumiID,
        );
      } else {
        // 影视缓存使用负数记录 ID，查弹弹Play 会匹配到无关番剧的弹幕。
        if (!DownloadTarget.isBangumiRecord(bangumiId)) {
          return DanmakuLoadResult.success(
            danmakus: const [],
            bangumiID: nextBangumiID,
          );
        }
        KazumiLogger()
            .i('PlayerController: no cached danmaku, attempting online fetch');
        final onlineResult = await _fetchDanDanmakuByBgmBangumiID(
          bangumiId,
          episode,
          fallbackTitles: fallbackTitles,
        );
        if (onlineResult.hasDanmakus) {
          KazumiLogger().i(
              'PlayerController: fetched ${onlineResult.danmakus.length} danmakus online');
          _saveDanmakuToCache(
            downloader,
            bangumiId,
            pluginName,
            episode,
            onlineResult.danmakus,
            onlineResult.bangumiID,
          );
        }
        return onlineResult;
      }
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to load cached danmaku', error: e);
      return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
    }
  }

  void _saveDanmakuToCache(
      DownloadController downloadController,
      int bangumiId,
      String pluginName,
      int episode,
      List<DanmakuEntry> danmakus,
      int danDanID) {
    try {
      downloadController.updateCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
        danmakus,
        danDanID,
      );
      KazumiLogger()
          .i('PlayerController: saved ${danmakus.length} danmakus to cache');
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to save danmaku to cache', error: e);
    }
  }

  Future<DanmakuLoadResult> _fetchDanDanmakuByBgmBangumiID(
    int bgmBangumiID,
    int episode, {
    List<String> fallbackTitles = const [],
  }) async {
    KazumiLogger().i(
        'PlayerController: attempting to get danmaku [BgmBangumiID] $bgmBangumiID');
    var nextBangumiID = bangumiID;
    var dandanFailed = false;

    if (DanmakuApi.customApiConfigured && fallbackTitles.isNotEmpty) {
      try {
        final candidates = DanmakuApi.buildSearchCandidates(fallbackTitles);
        for (final keyword in candidates) {
          final searchRes = await DanmakuApi.searchCustomAnimes(keyword);
          final anime = BilibiliDanmakuApi.selectBestAnime(
            searchRes.animes,
            keyword,
            preferredKind: MediaKind.anime,
          );
          if (anime == null) continue;
          final episodes = await DanmakuApi.getCustomEpisodes(
            anime.animeId,
            fallback: anime.inlineEpisodes,
          );
          final matched = BilibiliDanmakuApi.matchEpisode(episodes, episode);
          if (matched == null) continue;
          final entries = await DanmakuApi.getCustomComments(matched.episodeId);
          if (entries.isNotEmpty) {
            return DanmakuLoadResult.success(
              danmakus: entries,
              bangumiID: nextBangumiID,
            );
          }
        }
      } catch (e) {
        KazumiLogger().w(
          'PlayerController: custom danmaku lookup failed',
          error: e,
        );
      }
    }

    if (dandanCredentialsConfigured) {
      try {
        nextBangumiID =
            await DanmakuApi.getDanDanBangumiIDByBgmBangumiID(bgmBangumiID);
        if (nextBangumiID != 0) {
          final res = await DanmakuApi.getDanDanmaku(nextBangumiID, episode);
          if (res.isNotEmpty) {
            return DanmakuLoadResult.success(
              danmakus: res,
              bangumiID: nextBangumiID,
            );
          }
        }
      } catch (e) {
        dandanFailed = true;
        KazumiLogger().w(
            'PlayerController: failed to get danmaku [BgmBangumiID] $bgmBangumiID',
            error: e);
      }
    } else {
      KazumiLogger().i(
        'PlayerController: dandan credentials missing, falling back to bilibili danmaku',
      );
    }

    if (fallbackTitles.isNotEmpty) {
      try {
        final fallback = await BilibiliDanmakuApi.fetchEpisodeComments(
          DanmakuApi.buildSearchCandidates(fallbackTitles),
          episode,
          mediaKind: MediaKind.anime,
        );
        return DanmakuLoadResult.success(
          danmakus: fallback,
          bangumiID: nextBangumiID,
        );
      } catch (e) {
        KazumiLogger().w(
          'PlayerController: bilibili fallback danmaku failed',
          error: e,
        );
        return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
      }
    }

    if (dandanFailed) {
      return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
    }
    return DanmakuLoadResult.success(
      danmakus: const [],
      bangumiID: nextBangumiID,
    );
  }

  @action
  Future<bool> getDanDanmakuByEpisodeID(int episodeID) async {
    KazumiLogger().i('PlayerController: attempting to get danmaku $episodeID');
    danmakuLoading = true;
    try {
      danDanmakus.clear();
      var res = await DanmakuApi.getDanDanmakuByEpisodeID(episodeID);
      addDanmakus(res);
      return res.isNotEmpty;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to get danmaku', error: e);
      rethrow;
    } finally {
      danmakuLoading = false;
    }
  }

  /// 用外部弹幕替换当前列表。不新增 MobX action，避免改生成文件。
  Future<bool> replaceDanmakus(List<DanmakuEntry> entries) async {
    runInAction(() {
      danmakuLoading = true;
      danDanmakus.clear();
    });
    try {
      addDanmakus(entries);
      return entries.isNotEmpty;
    } finally {
      runInAction(() => danmakuLoading = false);
    }
  }

  void addDanmakus(List<DanmakuEntry> danmakus) {
    var danmakuDeduplicationEnable = false;
    try {
      danmakuDeduplicationEnable =
          GStorage.getSetting(SettingsKeys.danmakuDeduplication);
    } catch (_) {}

    final List<DanmakuEntry> listToAdd = danmakuDeduplicationEnable
        ? mergeDuplicateDanmakus(danmakus, timeWindowSeconds: 5)
        : danmakus;

    for (final element in listToAdd) {
      final danmakuSecond = element.time.toInt();
      (danDanmakus[danmakuSecond] ??= <DanmakuEntry>[]).add(element);
    }
  }

  void updateDanmakuSpeed(double playerSpeed) {
    final controller = _canvasController;
    if (controller == null) return;

    var baseDuration = 8.0;
    var followSpeed = true;
    try {
      baseDuration = GStorage.getSetting(SettingsKeys.danmakuDuration);
      followSpeed = GStorage.getSetting(SettingsKeys.danmakuFollowSpeed);
    } catch (_) {}

    final duration = followSpeed ? (baseDuration / playerSpeed) : baseDuration;
    controller
        .updateOption(controller.option.copyWith(duration: duration));
  }
}
