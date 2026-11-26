import 'package:flutter/widgets.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_fullscreen_controller.dart';
import 'package:kazumi/services/media/failover_controller.dart';

/// 展示层统一使用一基集数、零基线路；来源内部索引只在适配边界转换。
class VideoEpisodeSelection {
  const VideoEpisodeSelection({required this.episode, required this.road});
  final int episode;
  final int road;
  @override
  bool operator ==(Object other) =>
      other is VideoEpisodeSelection &&
      other.episode == episode &&
      other.road == road;
  @override
  int get hashCode => Object.hash(episode, road);
  @override
  String toString() => 'VideoEpisodeSelection(episode: $episode, road: $road)';
}

/// 仅真实动漫会话提供此能力，影视不会创建占位弹幕或 Bangumi 对象。
abstract interface class AnimePlayerFeatures {
  PlayerController get controller;
  VideoPageController get video;
}

/// 统一「片源与清晰度」抽屉中的单条片源候选视图模型（影视与动漫共用）。
class PlayerSourceOption {
  const PlayerSourceOption({
    required this.id,
    required this.ruleId,
    required this.sourceName,
    required this.isCurrent,
    this.isPinned = false,
    this.probeStatus = CandidateProbeStatus.idle,
    this.ttfbMs,
    this.cdnGroup = '',
    this.isSameCdnAsCurrent = false,
    this.verifiedProfile,
    this.score = 0.0,
    this.dubVariant = AudioDubVariant.original,
    this.episodeSummary = '',
    this.errorReason = '',
    this.isLazyWebview = false,
    this.canOpenManualCaptcha = false,
  });

  final String id;
  final String ruleId;
  final String sourceName;
  final bool isCurrent;
  final bool isPinned;
  final CandidateProbeStatus probeStatus;
  final int? ttfbMs;
  final String cdnGroup;
  final bool isSameCdnAsCurrent;

  /// 仅当 `verifiedProfile.isUiVerified == true` 时 UI 才展示实测画质徽章。
  final VerifiedStreamProfile? verifiedProfile;
  final double score;
  final AudioDubVariant dubVariant;
  final String episodeSummary;
  final String errorReason;
  final bool isLazyWebview;
  final bool canOpenManualCaptcha;

  bool get isHealthyOrActive =>
      isCurrent ||
      probeStatus == CandidateProbeStatus.idle ||
      probeStatus == CandidateProbeStatus.probing ||
      probeStatus == CandidateProbeStatus.ready ||
      probeStatus == CandidateProbeStatus.degraded;
}

/// 影视与动漫共享的播中热切源、自动容灾与策略控制契约。
abstract interface class PlayerSourceSwitchingFeatures {
  Listenable get sourceChanges;
  String get currentSourceLabel;
  String get currentCdnGroup;
  bool get autoFailoverEnabled;
  SourceRecommendationStrategy get recommendationStrategy;
  AudioDubVariant get selectedDubVariant;
  List<AudioDubVariant> get availableDubVariants;
  List<PlayerSourceOption> get sourceOptions;
  bool get isSwitchingSource;
  bool get isDiscoveringSources;
  FailoverBannerState? get failoverBanner;

  Future<void> setAutoFailoverEnabled(bool enabled);
  Future<void> setRecommendationStrategy(SourceRecommendationStrategy strategy);
  void selectDubVariant(AudioDubVariant variant);
  Future<void> switchToSource(String optionId);
  Future<void> togglePinSource(String optionId);
  Future<void> openCaptchaVerification(BuildContext context, String optionId);
  Future<void> refreshSources();
  void dismissFailoverBanner();
  Future<void> undoLastFailover();
}

/// 播放画面只读取展示契约，作品身份、恢复与历史始终归具体会话所有。
abstract class PlayerPresentationContext {
  PlayerControlsController get controls;
  AnimePlayerFeatures? get animeFeatures;
  PlayerSourceSwitchingFeatures? get sourceSwitchingFeatures => null;
  MediaKind? get mediaKind => null;
  bool get isMovie => mediaKind == MediaKind.movie;
  String get title;
  String get src;
  List<Road> get roadList;
  VideoEpisodeSelection get selectedEpisode;
  VideoEpisodeSelection? get playingEpisode;
  VideoEpisodeSelection get playbackEpisode =>
      playingEpisode ?? selectedEpisode;
  VideoFullscreenController get fullscreen;
  bool get isFullscreen => fullscreen.isFullscreen;
  bool get isPip;
  set isPip(bool value);
  bool get loading;
  String? get errorMessage;
  bool get resumePending => false;
  bool get canInteract;
  String get mediaId;
  String get sourceName;
  String? get artworkUrl;
  String episodeTitle(VideoEpisodeSelection selection) {
    if (selection.road < 0 || selection.road >= roadList.length) return '';
    final labels = roadList[selection.road].identifier;
    final index = selection.episode - 1;
    return index >= 0 && index < labels.length
        ? labels[index]
        : '第 ${selection.episode} 集';
  }

  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  });
  Future<void> retry({bool fromBeginning = false});

  /// 共用播放器的唯一状态时钟调用此钩子，避免历史与连播重复执行。
  void onPlaybackTick();
  Future<void> onFullscreenChanged() async {}
  Future<void> onBackground() async {}
  Future<void> onForeground() async {}
  Widget buildCollectionButton(
    BuildContext context,
    PlayerPanelHold Function() acquirePlayerPanelHold,
  );
}
