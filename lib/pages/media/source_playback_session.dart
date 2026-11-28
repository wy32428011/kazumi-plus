import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/download/download_target.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/media/source_player_collect_button.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/pages/player/player_presentation_context.dart';
import 'package:kazumi/pages/video/video_fullscreen_controller.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/candidate_probe_orchestrator.dart';
import 'package:kazumi/services/media/failover_controller.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/media_resume_session.dart';
import 'package:kazumi/services/media/playback_stall_monitor.dart';
import 'package:kazumi/services/media/source_fanout_service.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/platform/display_mode_service.dart';
import 'package:kazumi/services/player/hls_proxy_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/media.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:mobx/mobx.dart' hide Listenable;

class _FailoverUndoSnapshot {
  const _FailoverUndoSnapshot({
    required this.candidateRefKey,
    required this.roadIndex,
    required this.episodeIndex,
    required this.positionMs,
  });

  final String candidateRefKey;
  final int roadIndex;
  final int episodeIndex;
  final int positionMs;
}

/// 影视保留真实来源会话，同时承载跨源热切、实测遥测上报、全频道公开弹幕与单 mpv Make-Before-Break 四阶容灾。
class SourcePlaybackSession extends PlayerPresentationContext
    with ChangeNotifier
    implements PlayerDanmakuFeatures, PlayerSourceSwitchingFeatures {
  SourcePlaybackSession({
    required this.context,
    required this.controls,
    required MediaCatalogService catalog,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
    CandidateProbeOrchestrator? probeOrchestrator,
    PlaybackStallMonitor? stallMonitor,
    FailoverController? failoverController,
    SourceFanOutService? fanOutService,
  }) : _catalog = catalog,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance,
       _prober = probeOrchestrator ?? CandidateProbeOrchestrator.instance,
       _stallMonitor = stallMonitor ?? PlaybackStallMonitor(),
       _failover =
           failoverController ??
           FailoverController(
             scoringEngine: scoringEngine,
             probeOrchestrator: probeOrchestrator,
             healthRepository: healthRepository,
           ),
       _fanOut =
           fanOutService ??
           SourceFanOutService(
             catalog: catalog,
             healthRepository: healthRepository,
             scoringEngine: scoringEngine,
           ) {
    controls.canInteract = () => canInteract;
    controls.onBeforeSeek = () {
      _stallMonitor.markSeek();
      _danmaku.clearAndInvalidateScheduledDanmakus();
    };
    controls.onBeforePlayingChanged = (playing) {
      if (playing) {
        _danmaku.resumeCanvas();
      } else {
        _danmaku.pauseCanvas();
      }
    };
    controls.onSpeedChanged = updateDanmakuSpeed;
    controls.playback.playerSpeed = GStorage.getSetting(
      SettingsKeys.defaultPlaySpeed,
    );
    _autoFailoverEnabled = _readSettingOrDefault(
      SettingsKeys.autoFailoverEnabled,
      true,
    );
    _strategy = SourceRecommendationStrategy.parse(
      _readSettingOrDefault(
        SettingsKeys.sourceRecommendationStrategy,
        'balanced',
      ),
    );

    _activeMedia = context.media;
    _activePlaylist = context.playlist;

    final seedCluster =
        context.workCluster ??
        _fanOut.seedClusterFromSummary(
          context.media,
          playlist: context.playlist,
          strategy: _strategy,
        );
    _cluster = seedCluster;
    _selectedDubVariant = seedCluster.dubVariant;

    final initialCandidates = <MediaCandidate>[
      if (context.candidates.isNotEmpty)
        ...context.candidates
      else
        ...seedCluster.candidates,
    ];
    if (!initialCandidates.any((c) => c.refKey == context.media.ref.key)) {
      initialCandidates.insert(
        0,
        MediaCandidate(
          summary: context.media,
          playlist: context.playlist,
        ),
      );
    }
    _candidates = _applyPinnedAndRank(initialCandidates);
    _activeCandidateRefKey = context.media.ref.key;

    if (_activePlaylist.roads.isNotEmpty) {
      _roadIndex = context.roadIndex.clamp(
        0,
        _activePlaylist.roads.length - 1,
      );
      final episodes = _activePlaylist.roads[_roadIndex].episodes;
      if (episodes.isNotEmpty) {
        _episodeIndex = context.episodeIndex.clamp(0, episodes.length - 1);
      }
    }
    _rebuildRoadList();
  }

  final PlaybackContext context;
  @override
  final PlayerControlsController controls;
  final MediaCatalogService _catalog;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;
  final CandidateProbeOrchestrator _prober;
  final PlaybackStallMonitor _stallMonitor;
  final FailoverController _failover;
  final SourceFanOutService _fanOut;
  final _library = SourceMediaLibrary.instance;
  final _resolver = WebViewVideoSourceService();
  final _switches = AsyncSerialQueue();
  final _danmakuSessions = AsyncSessionOwner();
  late final PlayerDanmakuController _danmaku = PlayerDanmakuController(
    isLocalPlayback: () => false,
  );
  final _pip = Observable(false);

  late MediaSummary _activeMedia;
  late SourcePlaylist _activePlaylist;
  late WorkCluster _cluster;
  late List<MediaCandidate> _candidates;
  late String _activeCandidateRefKey;
  late AudioDubVariant _selectedDubVariant;
  late bool _autoFailoverEnabled;
  late SourceRecommendationStrategy _strategy;

  List<Road> _roadList = const [];
  Timer? _loadTimeout;
  StreamSubscription<bool>? _completedSubscription;
  MediaResumeSession? _resumeSession;
  CancelToken? _fanOutCancel;
  Future<void>? _closeFuture;
  DateTime _lastSave = DateTime.now();

  int _generation = 0;
  int _readyGeneration = -1;
  int _roadIndex = 0;
  int _episodeIndex = 0;
  int _pendingResumeTargetMs = 0;
  String _currentCdnGroup = '';
  String _loadedDanmakuEpisodeKey = '';
  bool _loading = true;
  bool _ready = false;
  bool _resumePending = false;
  bool _backgroundSuspended = false;
  bool _manualSwitchInProgress = false;
  bool _failoverInProgress = false;
  bool _isDiscoveringSources = false;
  bool _exiting = false;
  bool _disposed = false;
  bool _reportedPlayback = false;
  bool _hasStarted = false;
  String? _error;
  FailoverBannerState? _failoverBanner;
  _FailoverUndoSnapshot? _undoSnapshot;
  Timer? _bannerAutoHideTimer;

  static T _readSettingOrDefault<T>(SettingKey<T> key, T fallback) {
    try {
      return GStorage.getSetting(key);
    } catch (_) {
      return fallback;
    }
  }

  MediaSummary get media => _activeMedia;
  SourcePlaylist get playlist => _activePlaylist;
  WorkCluster get workCluster => _cluster;

  PlaybackRoad? get _road =>
      _roadIndex >= 0 && _roadIndex < _activePlaylist.roads.length
      ? _activePlaylist.roads[_roadIndex]
      : null;

  PlayableEpisode? get _episode {
    final episodes = _road?.episodes;
    return episodes != null &&
            _episodeIndex >= 0 &&
            _episodeIndex < episodes.length
        ? episodes[_episodeIndex]
        : null;
  }

  MediaCandidate get _activeCandidate {
    for (final c in _candidates) {
      if (c.refKey == _activeCandidateRefKey) return c;
    }
    return MediaCandidate(
      summary: _activeMedia,
      playlist: _activePlaylist,
      cdnGroup: _currentCdnGroup,
    );
  }

  String get _pinPrefKey => 'pin:${_cluster.clusterKey}';

  String? get _pinnedRuleId {
    try {
      return _library.preference(_pinPrefKey);
    } catch (_) {
      return null;
    }
  }

  void _rebuildRoadList() {
    _roadList = [
      for (final road in _activePlaylist.roads)
        Road(
          name: road.name,
          data: [for (final episode in road.episodes) episode.url],
          identifier: [for (final episode in road.episodes) episode.title],
        ),
    ];
  }

  @override
  AnimePlayerFeatures? get animeFeatures => null;
  @override
  PlayerDanmakuFeatures get danmakuFeatures => this;
  @override
  PlayerDanmakuController get danmaku => _danmaku;
  @override
  String get danmakuHistoryKey =>
      'danmakuSearchHistory_source_${_activeMedia.ref.key}';
  @override
  String get initialDanmakuKeyword =>
      DanmakuApi.buildSearchCandidates([_activeMedia.title]).firstOrNull ??
      _activeMedia.title.trim();
  @override
  MediaKind get danmakuMediaKind => _activeMedia.ref.kind;
  @override
  void updateDanmakuSpeed() =>
      _danmaku.updateDanmakuSpeed(controls.playback.playerSpeed);
  @override
  void cancelAutomaticDanmakuLoad() => _danmakuSessions.cancel();
  @override
  PlayerSourceSwitchingFeatures? get sourceSwitchingFeatures => this;
  @override
  MediaKind? get mediaKind => _activeMedia.ref.kind;
  @override
  String get title => _activeMedia.title;
  @override
  String get src => _episode?.url ?? _activeMedia.detailSource;
  @override
  List<Road> get roadList => _roadList;

  /// 下载复用当前活跃来源规则的解析与请求头；来源已禁用或删除时返回 null。
  DownloadTarget? get downloadTarget {
    final provider = _catalog.providerById(_activeMedia.ref.ruleId);
    if (provider == null) return null;
    final season = _activePlaylist.season;
    return DownloadTarget(
      recordId: DownloadTarget.sourceRecordId(
        _activeMedia.ref,
        seasonId: season?.id ?? '',
      ),
      title: season == null || season.name.isEmpty
          ? _activeMedia.title
          : '${_activeMedia.title} ${season.name}',
      coverUrl: _activeMedia.posterUrl,
      pluginName: provider.plugin.name,
      roads: _roadList,
      playingRoad: _roadIndex,
      playingEpisode: _episodeIndex + 1,
    );
  }

  @override
  VideoEpisodeSelection get selectedEpisode =>
      VideoEpisodeSelection(episode: _episodeIndex + 1, road: _roadIndex);
  @override
  VideoEpisodeSelection? get playingEpisode => _ready ? selectedEpisode : null;
  @override
  final fullscreen = VideoFullscreenController(
    applyFullscreen: DisplayModeService.applyVideoFullscreen,
  );
  @override
  bool get isPip => _pip.value;
  @override
  set isPip(bool value) {
    if (value == _pip.value) return;
    runInAction(() => _pip.value = value);
    _notify();
  }

  @override
  bool get loading => _loading;
  @override
  String? get errorMessage => _error;
  @override
  bool get resumePending => _resumePending;
  bool get exiting => _exiting;

  /// 测试可见：当前待确认恢复目标（毫秒）。
  @visibleForTesting
  int get pendingResumeTargetMs => _pendingResumeTargetMs;

  @override
  bool get canInteract =>
      !_disposed &&
      !_exiting &&
      _ready &&
      !_loading &&
      !_resumePending &&
      _error == null &&
      _readyGeneration == _generation;
  @override
  String get mediaId =>
      'source:${_activeMedia.ref.key}:${_road?.id ?? ''}:${_episode?.key ?? ''}';
  @override
  String get sourceName => _activeMedia.sourceName;
  @override
  String? get artworkUrl =>
      _activeMedia.posterUrl.isEmpty ? null : _activeMedia.posterUrl;

  // === PlayerSourceSwitchingFeatures ===

  @override
  Listenable get sourceChanges => this;
  @override
  String get currentSourceLabel => _activeMedia.sourceName;
  @override
  String get currentCdnGroup => _currentCdnGroup;
  @override
  bool get autoFailoverEnabled => _autoFailoverEnabled;
  @override
  SourceRecommendationStrategy get recommendationStrategy => _strategy;
  @override
  AudioDubVariant get selectedDubVariant => _selectedDubVariant;
  @override
  bool get isSwitchingSource => _manualSwitchInProgress || _failoverInProgress;
  @override
  bool get isDiscoveringSources => _isDiscoveringSources;
  @override
  FailoverBannerState? get failoverBanner => _failoverBanner;

  @override
  List<AudioDubVariant> get availableDubVariants {
    final set = <AudioDubVariant>{
      _cluster.dubVariant,
      for (final sib in _cluster.siblingDubClusters) sib.dubVariant,
      for (final c in _candidates) c.richMeta.dubVariant,
    };
    return set.toList(growable: false);
  }

  @override
  List<PlayerSourceOption> get sourceOptions {
    final dubPool = _candidatesForDub(_selectedDubVariant);
    final activeCdn = _currentCdnGroup;
    return [
      for (final c in dubPool)
        PlayerSourceOption(
          id: c.refKey,
          ruleId: c.ruleId,
          sourceName: c.sourceName.isNotEmpty ? c.sourceName : c.ruleId,
          isCurrent: c.refKey == _activeCandidateRefKey,
          isPinned: c.isPinned,
          probeStatus: c.probeStatus,
          ttfbMs: c.ttfbMs,
          cdnGroup: c.cdnGroup,
          isSameCdnAsCurrent:
              activeCdn.isNotEmpty &&
              c.cdnGroup.isNotEmpty &&
              c.cdnGroup == activeCdn &&
              c.refKey != _activeCandidateRefKey,
          verifiedProfile:
              c.streamProfile ??
              _health
                  .bestAvailableHealthFor(c.ruleId, _activeMedia.ref.kind)
                  ?.lastVerifiedProfile,
          score: c.score,
          dubVariant: c.richMeta.dubVariant,
          episodeSummary: c.summary.statusText,
          errorReason: c.lastError,
          isLazyWebview: c.isLazyWebview,
          canOpenManualCaptcha:
              c.probeStatus == CandidateProbeStatus.captchaRequired &&
              _catalog.providerById(c.ruleId)?.plugin.antiCrawlerConfig.enabled ==
                  true,
        ),
    ];
  }

  List<MediaCandidate> _candidatesForDub(AudioDubVariant dub) {
    final matching = _candidates
        .where((c) => c.richMeta.dubVariant == dub)
        .toList();
    if (matching.isNotEmpty) return matching;
    for (final sib in _cluster.siblingDubClusters) {
      if (sib.dubVariant == dub) {
        return _applyPinnedAndRank(sib.candidates);
      }
    }
    return _candidates;
  }

  @override
  Future<void> setAutoFailoverEnabled(bool enabled) async {
    if (_autoFailoverEnabled == enabled) return;
    _autoFailoverEnabled = enabled;
    try {
      await GStorage.putSetting<bool>(
        SettingsKeys.autoFailoverEnabled,
        enabled,
      );
    } catch (_) {}
    _notify();
  }

  @override
  Future<void> setRecommendationStrategy(
    SourceRecommendationStrategy strategy,
  ) async {
    if (_strategy == strategy) return;
    _strategy = strategy;
    try {
      await GStorage.putSetting<String>(
        SettingsKeys.sourceRecommendationStrategy,
        strategy.name,
      );
    } catch (_) {}
    _candidates = _applyPinnedAndRank(_candidates);
    _notify();
  }

  @override
  void selectDubVariant(AudioDubVariant variant) {
    if (_selectedDubVariant == variant) return;
    _selectedDubVariant = variant;
    for (final sib in _cluster.siblingDubClusters) {
      if (sib.dubVariant == variant) {
        for (final c in sib.candidates) {
          if (!_candidates.any((e) => e.refKey == c.refKey)) {
            _candidates = [..._candidates, c];
          }
        }
      }
    }
    _candidates = _applyPinnedAndRank(_candidates);
    _notify();
  }

  @override
  Future<void> togglePinSource(String optionId) async {
    final target = _candidates.where((c) => c.refKey == optionId).firstOrNull;
    if (target == null) return;
    final currentPin = _pinnedRuleId;
    final nextPin = currentPin == target.ruleId ? '' : target.ruleId;
    try {
      await _library.setPreference(_pinPrefKey, nextPin);
    } catch (_) {}
    _candidates = _applyPinnedAndRank(_candidates);
    _notify();
  }

  @override
  Future<void> openCaptchaVerification(
    BuildContext context,
    String optionId,
  ) async {
    final target = _candidates.where((c) => c.refKey == optionId).firstOrNull;
    if (target == null) return;
    final provider = _catalog.providerById(target.ruleId);
    if (provider == null) return;
    final channel = provider.plugin.catalog?.channels[_activeMedia.ref.kind.name];
    final op = channel?.search ?? channel?.discover;
    if (op == null) return;

    final verified = await verifyMediaCaptcha(
      context,
      MediaCaptchaRequest(
        plugin: provider.plugin,
        operation: op,
        variables: {'keyword': _activeMedia.title, 'page': 1},
        label: '${provider.plugin.name} 人工验证',
      ),
    );
    if (verified && !_disposed) {
      _health.clearCaptchaCooldown(
        SourceHealthRepository.pluginIdentityKey(provider.plugin),
      );
      _candidates = _applyPinnedAndRank(
        _candidates
            .map(
              (c) => c.refKey == optionId
                  ? c.copyWith(
                      probeStatus: CandidateProbeStatus.idle,
                      lastError: '',
                    )
                  : c,
            )
            .toList(),
      );
      _notify();
    }
  }

  @override
  Future<void> refreshSources() async {
    if (_disposed || _exiting || _isDiscoveringSources) return;
    _isDiscoveringSources = true;
    _notify();
    _fanOutCancel?.cancel('refresh');
    final cancelToken = CancelToken();
    _fanOutCancel = cancelToken;
    try {
      final enriched = await _fanOut.enrichWorkCluster(
        seedCluster: _cluster,
        strategy: _strategy,
        cancelToken: cancelToken,
        onUpdate: _mergeClusterUpdate,
      );
      if (!_disposed && !cancelToken.isCancelled) {
        _mergeClusterUpdate(enriched);
      }
    } finally {
      if (!_disposed) {
        _isDiscoveringSources = false;
        _notify();
      }
    }
  }

  void _mergeClusterUpdate(WorkCluster updated) {
    if (_disposed || _exiting) return;
    _cluster = updated;
    final mergedByRef = <String, MediaCandidate>{
      for (final c in _candidates) c.refKey: c,
    };
    for (final c in updated.candidates) {
      final prev = mergedByRef[c.refKey];
      if (prev == null) {
        mergedByRef[c.refKey] = c;
      } else {
        mergedByRef[c.refKey] = prev.copyWith(
          detail: prev.detail ?? c.detail,
          playlist: prev.playlist ?? c.playlist,
          richMeta: c.richMeta.hasValidDoubanId ? c.richMeta : prev.richMeta,
        );
      }
    }
    _candidates = _applyPinnedAndRank(mergedByRef.values.toList());
    _notify();
  }

  @override
  void dismissFailoverBanner() {
    _bannerAutoHideTimer?.cancel();
    _failoverBanner = null;
    _notify();
  }

  @override
  Future<void> undoLastFailover() async {
    final snap = _undoSnapshot;
    if (snap == null || _disposed || _exiting) return;
    _undoSnapshot = null;
    dismissFailoverBanner();
    _failover.clearCandidateFailure(snap.candidateRefKey);
    await _switchToCandidateRef(
      snap.candidateRefKey,
      overrideResumeMs: snap.positionMs,
      preferredRoadIndex: snap.roadIndex,
      preferredEpisodeIndex: snap.episodeIndex,
      isManual: true,
    );
  }

  @override
  Future<void> switchToSource(String optionId) async {
    if (_disposed || _exiting) return;
    if (optionId == _activeCandidateRefKey && _error == null) return;
    _failover.clearCandidateFailure(optionId);
    dismissFailoverBanner();
    await _switchToCandidateRef(optionId, isManual: true);
  }

  List<MediaCandidate> _applyPinnedAndRank(List<MediaCandidate> items) {
    final pinned = _pinnedRuleId ?? '';
    final updated = [
      for (final c in items)
        c.copyWith(isPinned: pinned.isNotEmpty && c.ruleId == pinned),
    ];
    return _scoring.rankCandidates(
      updated,
      kind: _activeMedia.ref.kind,
      strategy: _strategy,
      penalizedCdnGroups: _failover.penalizedCdnGroups,
      activeCdnGroup: _currentCdnGroup,
    );
  }

  bool _isCurrent(int generation) =>
      !_disposed && !_exiting && generation == _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() async {
    if (_hasStarted || _exiting || _disposed) return;
    _hasStarted = true;
    // 后台按需补全其余健康源，确保玩家随时可在抽屉中热切或播中自动容灾。
    if (_candidates.length <= 1) {
      unawaited(refreshSources());
    }
    if (_activePlaylist.roads.isEmpty ||
        _activePlaylist.roads.every((road) => road.episodes.isEmpty)) {
      _loading = false;
      _error = '来源没有提供可播放的内容。';
      _notify();
      return;
    }
    final road = context.roadIndex.clamp(0, _activePlaylist.roads.length - 1);
    final episodes = _activePlaylist.roads[road].episodes;
    if (episodes.isEmpty) {
      _roadIndex = road;
      _loading = false;
      _error = '所选线路没有剧集，请切换其他线路。';
      _notify();
      return;
    }
    await _switchEpisode(
      road,
      context.episodeIndex.clamp(0, episodes.length - 1),
      explicitResumeMs: context.initialResumeMs,
    );
  }

  /// 展示组件沿用一基集号，只有此入口转换到影视内部的零基索引。
  @override
  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) {
    _failover.resetForNewEpisode();
    dismissFailoverBanner();
    return _switchEpisode(
      currentRoad,
      episode - 1,
      explicitResumeMs: offset > 0 ? offset * 1000 : null,
    );
  }

  @override
  Future<void> retry({bool fromBeginning = false}) {
    _failover.clearCandidateFailure(_activeCandidateRefKey);
    return _switchEpisode(_roadIndex, _episodeIndex, resume: !fromBeginning);
  }

  /// 提取当前安全恢复位置（毫秒）：若仍在 `_resumePending`，绝不读取 `0ms`，必须沿用 `_pendingResumeTargetMs`！
  int _captureSafeResumeMs() {
    if (_resumePending && _pendingResumeTargetMs > 0) {
      return _pendingResumeTargetMs;
    }
    if (_ready) {
      final posMs = controls.playback.playerPosition.inMilliseconds;
      if (posMs > 0) return posMs;
    }
    if (_pendingResumeTargetMs > 0) return _pendingResumeTargetMs;
    return 0;
  }

  Future<void> _switchToCandidateRef(
    String targetRefKey, {
    int? overrideResumeMs,
    int? preferredRoadIndex,
    int? preferredEpisodeIndex,
    HlsPreFetchedSeed? preFetchedSeed,
    required bool isManual,
    FailoverBannerState? bannerOnSuccess,
  }) async {
    final targetCandidate = _candidates
        .where((c) => c.refKey == targetRefKey)
        .firstOrNull;
    if (targetCandidate == null) return;

    final provider = _catalog.providerById(targetCandidate.ruleId);
    if (provider == null) {
      KazumiLogger().w('SourcePlaybackSession: 目标片源已禁用 ${targetCandidate.ruleId}');
      return;
    }

    final preservedResumeMs = overrideResumeMs ?? _captureSafeResumeMs();
    final previousEpisode = _episode;
    final previousEpisodeIndex = _episodeIndex;

    if (isManual) {
      _manualSwitchInProgress = true;
      _notify();
    }

    try {
      final targetPlaylist =
          targetCandidate.playlist ??
          await provider.queryPlaylist(
            targetCandidate.summary,
            season: _activePlaylist.season,
          );
      if (_disposed || _exiting) return;
      if (targetPlaylist.roads.isEmpty ||
          targetPlaylist.roads.every((r) => r.episodes.isEmpty)) {
        throw StateError('${targetCandidate.sourceName} 暂无可播线路');
      }

      // 精确集号对齐优先，其次按索引回退。
      var nextRoad = (preferredRoadIndex ?? 0).clamp(
        0,
        targetPlaylist.roads.length - 1,
      );
      var nextEpisode = 0;

      if (preferredEpisodeIndex != null &&
          preferredEpisodeIndex >= 0 &&
          preferredEpisodeIndex < targetPlaylist.roads[nextRoad].episodes.length) {
        nextEpisode = preferredEpisodeIndex;
      } else {
        final match = _alignEpisodeInPlaylist(
          targetPlaylist,
          targetNumber: previousEpisode?.number,
          fallbackIndex: previousEpisodeIndex,
        );
        nextRoad = match.$1;
        nextEpisode = match.$2;
      }

      // 更新本地缓存的 playlist 与活跃来源上下文。
      _candidates = _candidates
          .map(
            (c) => c.refKey == targetRefKey
                ? c.copyWith(playlist: targetPlaylist)
                : c,
          )
          .toList();
      _activeCandidateRefKey = targetRefKey;
      _activeMedia = targetCandidate.summary;
      _activePlaylist = targetPlaylist;
      _currentCdnGroup = targetCandidate.cdnGroup;
      _rebuildRoadList();

      if (bannerOnSuccess != null) {
        _showFailoverBanner(bannerOnSuccess);
      }

      await _switchEpisode(
        nextRoad,
        nextEpisode,
        resume: true,
        explicitResumeMs: preservedResumeMs,
        isCrossSourceSwitch: true,
        preFetchedSeed: preFetchedSeed,
      );
    } catch (error) {
      KazumiLogger().w('SourcePlaybackSession: 切换片源失败', error: error);
      _candidates = _applyPinnedAndRank(
        _candidates
            .map(
              (c) => c.refKey == targetRefKey
                  ? c.copyWith(
                      probeStatus: CandidateProbeStatus.failed,
                      lastError: '$error',
                    )
                  : c,
            )
            .toList(),
      );
      _notify();
    } finally {
      if (isManual && !_disposed) {
        _manualSwitchInProgress = false;
        _notify();
      }
    }
  }

  static (int roadIndex, int episodeIndex) _alignEpisodeInPlaylist(
    SourcePlaylist playlist, {
    int? targetNumber,
    required int fallbackIndex,
  }) {
    if (targetNumber != null) {
      for (var r = 0; r < playlist.roads.length; r++) {
        final eps = playlist.roads[r].episodes;
        for (var e = 0; e < eps.length; e++) {
          if (eps[e].number == targetNumber) {
            return (r, e);
          }
        }
      }
    }
    for (var r = 0; r < playlist.roads.length; r++) {
      final eps = playlist.roads[r].episodes;
      if (eps.isNotEmpty) {
        return (r, fallbackIndex.clamp(0, eps.length - 1));
      }
    }
    return (0, 0);
  }

  Future<void> _switchEpisode(
    int roadIndex,
    int episodeIndex, {
    bool resume = true,
    int? explicitResumeMs,
    bool isCrossSourceSwitch = false,
    HlsPreFetchedSeed? preFetchedSeed,
  }) async {
    if (_disposed ||
        _exiting ||
        roadIndex < 0 ||
        roadIndex >= _activePlaylist.roads.length) {
      return;
    }
    final episodes = _activePlaylist.roads[roadIndex].episodes;
    if (episodeIndex < 0 || episodeIndex >= episodes.length) return;

    final generation = ++_generation;
    _readyGeneration = -1;
    _resumeSession?.cancel();
    _loadTimeout?.cancel();
    _resolver.cancel();
    _stallMonitor.reset();
    _notify();

    await _switches.run(() async {
      if (!_isCurrent(generation)) return;
      // 切源/切集前仅在未处于 _resumePending 时保存进度，严禁覆盖旧记录为 0ms。
      if (!_resumePending) {
        await saveProgress();
      }
      await _completedSubscription?.cancel();
      _completedSubscription = null;
      _ready = false;
      final speed = controls.playback.playerSpeed;
      await controls.stop();
      if (!_isCurrent(generation)) return;

      _roadIndex = roadIndex;
      _episodeIndex = episodeIndex;
      final episode = _episode!;
      final danmakuEpisodeNum = _resolveDanmakuEpisodeNumber(episode);
      final episodeKey = _activeMedia.ref.kind == MediaKind.movie
          ? 'movie'
          : 'tv:$danmakuEpisodeNum';
      final keepCurrentDanmaku = isCrossSourceSwitch &&
          episodeKey == _loadedDanmakuEpisodeKey &&
          _danmaku.danDanmakus.isNotEmpty;
      if (!keepCurrentDanmaku) {
        _loadedDanmakuEpisodeKey = '';
        _danmakuSessions.cancel();
        _danmaku.clearAndInvalidateScheduledDanmakus();
        _danmaku.finishDanmakuLoad(disableDanmaku: true);
      } else {
        _danmaku.clearAndInvalidateScheduledDanmakus();
      }
      _loading = true;
      _error = null;
      _reportedPlayback = false;
      _notify();

      try {
        final provider = _catalog.providerById(_activeMedia.ref.ruleId);
        if (provider == null) {
          throw StateError('原来源已禁用或删除，请切换推荐片源或返回规则管理恢复来源。');
        }
        final plugin = provider.plugin;

        var offsetMs = 0;
        if (explicitResumeMs != null && explicitResumeMs > 0) {
          offsetMs = explicitResumeMs;
        } else if (resume && _readSettingOrDefault(SettingsKeys.playResume, true)) {
          final progress = _library.progressFor(
            _activeMedia.ref,
            _road!.id,
            episode,
          );
          if (progress != null &&
              (progress.durationMs <= 0 ||
                  progress.positionMs < progress.durationMs - 5000)) {
            offsetMs = progress.positionMs;
          }
        }
        final offset = offsetMs ~/ 1000;
        _pendingResumeTargetMs = offsetMs;

        // Android 续播或跨源切源均需等待输出重建后回读确认，确认前锁死 saveProgress()。
        _resumePending =
            (Platform.isAndroid && offset > 0) ||
            (isCrossSourceSwitch && offset > 0);
        final resumeSession = _resumePending ? MediaResumeSession() : null;
        _resumeSession = resumeSession;

        final path = Uri.parse(episode.url).path.toLowerCase();
        var url = episode.url;
        var format = VideoSourceFormat.auto;
        var isWebviewSource = false;

        if (path.endsWith('.m3u8')) {
          format = VideoSourceFormat.hls;
        } else if (!RegExp(
          r'\.(mp4|mkv|webm|mov|avi|m4v|ts)$',
        ).hasMatch(path)) {
          isWebviewSource = true;
          final resolved = await _resolver.resolve(
            episode.url,
            useLegacyParser: plugin.useLegacyParser,
            offset: offset,
            timeout: const Duration(seconds: 30),
          );
          url = resolved.url;
          format = resolved.format;
        }
        if (!_isCurrent(generation)) return;

        final referer = plugin.referer.isEmpty
            ? plugin.baseUrl
            : plugin.referer;
        final headers = <String, String>{
          'User-Agent': plugin.userAgent.isEmpty
              ? getRandomUA()
              : plugin.userAgent,
          'Referer': referer,
        };

        // 若无现成 seed 且是 HLS，执行轻量探针校验并生成 HlsPreFetchedSeed 零拷贝移交（若当前源失活则触发容灾）。
        var activeSeed = preFetchedSeed;
        final isHls =
            format == VideoSourceFormat.hls ||
            Uri.tryParse(url)?.path.toLowerCase().endsWith('.m3u8') == true;
        if (activeSeed == null && isHls && !isWebviewSource) {
          final probeRes = await _prober.probeSingle(
            CandidateProbeTarget(
              id: _activeCandidateRefKey,
              pluginIdentityKey: SourceHealthRepository.pluginIdentityKey(
                plugin,
              ),
              sourceName: plugin.name,
              kind: _activeMedia.ref.kind,
              streamUrl: url,
              headers: headers,
              isHls: true,
            ),
            isCancelled: () => !_isCurrent(generation),
          );
          if (!_isCurrent(generation)) return;
          if (probeRes.reachable) {
            activeSeed = probeRes.preFetchedSeed;
            if (probeRes.resolvedCdnGroup.isNotEmpty) {
              _currentCdnGroup = probeRes.resolvedCdnGroup;
            }
            _updateCandidateTelemetry(
              _activeCandidateRefKey,
              status: CandidateProbeStatus.ready,
              ttfbMs: probeRes.ttfbMs,
              throughputKbps: probeRes.throughputKbps,
              cdnGroup: probeRes.resolvedCdnGroup,
              masterProfile: probeRes.masterProfile,
            );
          } else {
            _updateCandidateTelemetry(
              _activeCandidateRefKey,
              status: probeRes.failureKind == SourceFailureKind.captchaRequired
                  ? CandidateProbeStatus.captchaRequired
                  : CandidateProbeStatus.failed,
              cdnGroup: probeRes.resolvedCdnGroup,
              error: probeRes.errorMessage,
            );
            if (_autoFailoverEnabled && _hasAlternativeCandidates()) {
              unawaited(
                _triggerAutoFailover(
                  StallTriggerReason.startupBlackScreen,
                  generation,
                ),
              );
              return;
            }
            throw StateError(
              probeRes.errorMessage.isNotEmpty
                  ? probeRes.errorMessage
                  : '片源探活失败',
            );
          }
        }

        _stallMonitor.markLoadStarted(isWebviewSource: isWebviewSource);

        _loadTimeout = Timer(const Duration(seconds: 45), () {
          if (controls.debug.playerWidth == 0 && _isCurrent(generation)) {
            if (_autoFailoverEnabled && _hasAlternativeCandidates()) {
              unawaited(
                _triggerAutoFailover(
                  StallTriggerReason.startupBlackScreen,
                  generation,
                ),
              );
            } else {
              _failPlayback('媒体加载超时，请重试或更换片源。', generation);
            }
          }
        });

        final initialized = await controls.initialize(
          PlayerMediaInitParams(
            videoUrl: url,
            offset: _resumePending ? 0 : offset,
            isLocalPlayback: false,
            httpHeaders: headers,
            adBlockerEnabled: plugin.adBlocker,
            referer: referer,
            videoSourceFormat: format,
            coverUrl: artworkUrl,
            playbackSpeed: speed,
            hlsPreFetchedSeed: activeSeed,
            failoverAware: _autoFailoverEnabled,
            onCdnGroupResolved: (cdn) {
              if (!_isCurrent(generation)) return;
              _currentCdnGroup = cdn;
              _updateCandidateTelemetry(
                _activeCandidateRefKey,
                cdnGroup: cdn,
              );
            },
            onPrioritySegmentFailure: (failure) {
              if (!_isCurrent(generation) || !_autoFailoverEnabled) return;
              final trigger = _stallMonitor.reportProxyPrioritySegmentFailure(
                sample: _buildHealthSample(),
              );
              if (trigger != null) {
                unawaited(_triggerAutoFailover(trigger, generation));
              }
            },
          ),
          canInstall: () => _isCurrent(generation),
          honorPlatformDecoderFallback: true,
          onPlaybackError: (message) {
            if (!_isCurrent(generation)) return;
            if (_autoFailoverEnabled && _hasAlternativeCandidates()) {
              unawaited(
                _triggerAutoFailover(
                  StallTriggerReason.startupBlackScreen,
                  generation,
                ),
              );
            } else {
              _failPlayback(message, generation);
            }
          },
        );
        if (!_isCurrent(generation)) return;
        final player = controls.playback.mediaPlayer;
        if (!initialized || player == null) {
          throw StateError('播放器初始化失败，请重试或更换片源。');
        }

        _ready = true;
        _readyGeneration = generation;
        _completedSubscription = player.stream.completed.listen((completed) {
          if (!completed || !_isCurrent(generation) || _resumePending) return;
          unawaited(saveProgress());
          // 铁律：仅电视剧允许自动连播下一集，电影播完绝不自动跳下一版本或片源！
          if (_readSettingOrDefault(SettingsKeys.autoPlayNext, true) &&
              _activeMedia.ref.kind == MediaKind.tv &&
              _episodeIndex + 1 < _road!.episodes.length) {
            unawaited(_switchEpisode(_roadIndex, _episodeIndex + 1));
          }
        });
        _loading = false;
        _lastSave = DateTime.now();
        _notify();

        if (!keepCurrentDanmaku) {
          unawaited(
            _loadPlaybackDanmaku(
              episode: episode,
              episodeNumber: danmakuEpisodeNum,
              episodeKey: episodeKey,
              generation: generation,
            ),
          );
        }

        if (resumeSession != null) {
          unawaited(
            _restoreProgress(
              resumeSession,
              player,
              offsetMs,
              generation,
              isCrossSourceSwitch: isCrossSourceSwitch,
            ),
          );
        }
      } catch (error, stackTrace) {
        if (!_isCurrent(generation)) return;
        KazumiLogger().e(
          'PlusPlayback: 初始化失败',
          error: error,
          stackTrace: stackTrace,
        );
        if (_autoFailoverEnabled && _hasAlternativeCandidates()) {
          unawaited(
            _triggerAutoFailover(
              StallTriggerReason.startupBlackScreen,
              generation,
            ),
          );
          return;
        }
        _loading = false;
        _error = '播放失败：$error';
        _loadTimeout?.cancel();
        _notify();
      }
    });
  }

  bool _hasAlternativeCandidates() {
    final current = _activeCandidate;
    return _candidates.any(
      (c) =>
          c.refKey != current.refKey &&
          c.isAutoEligible &&
          c.richMeta.dubVariant == current.richMeta.dubVariant &&
          !_failover.failedCandidateKeys.contains(c.refKey),
    );
  }

  Future<void> _triggerAutoFailover(
    StallTriggerReason reason,
    int generation,
  ) async {
    if (_failoverInProgress || !_isCurrent(generation) || !_autoFailoverEnabled) {
      return;
    }
    _failoverInProgress = true;
    _notify();

    final fromCandidate = _activeCandidate;
    final fromRoadIndex = _roadIndex;
    final fromEpisodeIndex = _episodeIndex;
    final preservedPositionMs = _captureSafeResumeMs();

    try {
      final decision = await _failover.resolveNext(
        kind: _activeMedia.ref.kind,
        currentCandidate: fromCandidate,
        allCandidates: _candidates,
        triggerReason: reason,
        strategy: _strategy,
        currentPlayableTracks: controls.quality.tracks,
        currentSelectedTrackId: controls.quality.selectedId,
        isConstrainedNetwork: controls.playback.cachePolicy.isConstrained,
        isCancelled: () => !_isCurrent(generation),
        targetBuilder: _buildProbeTargetForCandidate,
      );
      if (!_isCurrent(generation)) return;

      switch (decision.kind) {
        case FailoverDecisionKind.stepDownQuality:
          final track = decision.lowerTrack;
          if (track != null) {
            await controls.quality.select(track);
            _stallMonitor.clearTrigger();
            _showFailoverBanner(
              FailoverBannerState(
                fromSourceName: fromCandidate.sourceName,
                toSourceName: '${track.w ?? 0}×${track.h ?? 0}',
                reasonText: decision.reasonText,
                tier: 1,
                canUndo: false,
                createdAt: DateTime.now(),
              ),
            );
          }
          break;

        case FailoverDecisionKind.switchCandidate:
          final next = decision.candidate;
          if (next == null) break;
          _undoSnapshot = _FailoverUndoSnapshot(
            candidateRefKey: fromCandidate.refKey,
            roadIndex: fromRoadIndex,
            episodeIndex: fromEpisodeIndex,
            positionMs: preservedPositionMs,
          );
          _candidates = _applyPinnedAndRank(
            _candidates
                .map((c) => c.refKey == next.refKey ? next : c)
                .toList(),
          );
          await _switchToCandidateRef(
            next.refKey,
            overrideResumeMs: preservedPositionMs,
            preFetchedSeed: decision.probeResult?.preFetchedSeed,
            isManual: false,
            bannerOnSuccess: FailoverBannerState(
              fromSourceName: fromCandidate.sourceName,
              toSourceName: next.sourceName,
              reasonText: decision.reasonText,
              tier: decision.tier,
              canUndo: true,
              createdAt: DateTime.now(),
            ),
          );
          break;

        case FailoverDecisionKind.localOffline:
          _failPlayback('检测到当前网络连接异常，请检查网络后重试。', generation);
          break;

        case FailoverDecisionKind.exhausted:
          if (reason == StallTriggerReason.startupBlackScreen || !_ready) {
            _failPlayback(
              '当前所有可用片源均无法播放，可打开片源抽屉手动检查或重试。',
              generation,
            );
          }
          break;
      }
    } finally {
      if (!_disposed) {
        _failoverInProgress = false;
        _notify();
      }
    }
  }

  Future<CandidateProbeTarget?> _buildProbeTargetForCandidate(
    MediaCandidate candidate,
  ) async {
    final provider = _catalog.providerById(candidate.ruleId);
    if (provider == null) return null;
    try {
      final playlist =
          candidate.playlist ??
          await provider.queryPlaylist(
            candidate.summary,
            season: _activePlaylist.season,
          );
      if (playlist.roads.isEmpty) return null;
      final match = _alignEpisodeInPlaylist(
        playlist,
        targetNumber: _episode?.number,
        fallbackIndex: _episodeIndex,
      );
      final ep = playlist.roads[match.$1].episodes[match.$2];
      final plugin = provider.plugin;
      final referer = plugin.referer.isEmpty ? plugin.baseUrl : plugin.referer;
      // 缓存已拿到的 playlist，后续切换零二次请求。
      _candidates = _candidates
          .map(
            (c) => c.refKey == candidate.refKey
                ? c.copyWith(playlist: playlist)
                : c,
          )
          .toList();
      return CandidateProbeTarget(
        id: candidate.refKey,
        pluginIdentityKey: SourceHealthRepository.pluginIdentityKey(plugin),
        sourceName: plugin.name,
        kind: _activeMedia.ref.kind,
        streamUrl: ep.url,
        headers: {
          'User-Agent': plugin.userAgent.isEmpty
              ? getRandomUA()
              : plugin.userAgent,
          'Referer': referer,
        },
        isLazyWebview: candidate.isLazyWebview,
      );
    } catch (_) {
      return null;
    }
  }

  void _showFailoverBanner(FailoverBannerState banner) {
    _failoverBanner = banner;
    _bannerAutoHideTimer?.cancel();
    _bannerAutoHideTimer = Timer(const Duration(seconds: 7), () {
      if (!_disposed && identical(_failoverBanner, banner)) {
        _failoverBanner = null;
        _notify();
      }
    });
    _notify();
  }

  void _updateCandidateTelemetry(
    String refKey, {
    CandidateProbeStatus? status,
    int? ttfbMs,
    int? throughputKbps,
    String? cdnGroup,
    VerifiedStreamProfile? masterProfile,
    VerifiedStreamProfile? mpvProfile,
    String? error,
  }) {
    _candidates = _applyPinnedAndRank(
      _candidates.map((c) {
        if (c.refKey != refKey) return c;
        return c.copyWith(
          probeStatus: status ?? c.probeStatus,
          ttfbMs: ttfbMs ?? c.ttfbMs,
          throughputKbps: throughputKbps ?? c.throughputKbps,
          cdnGroup: (cdnGroup != null && cdnGroup.isNotEmpty)
              ? cdnGroup
              : c.cdnGroup,
          streamProfile: mpvProfile ?? masterProfile ?? c.streamProfile,
          lastError: error ?? c.lastError,
        );
      }).toList(),
    );
    _notify();
  }

  PlaybackHealthSample _buildHealthSample() => PlaybackHealthSample(
    playing: controls.playback.playerPlaying,
    loading: _loading || controls.playback.loading,
    resumePending: _resumePending,
    completed: controls.playback.playerCompleted,
    backgroundSuspended: _backgroundSuspended,
    seeking: controls.seeking.hasActiveInteractiveSeek,
    qualitySwitching: controls.quality.switching,
    manualSwitchInProgress: _manualSwitchInProgress || _failoverInProgress,
    buffering: controls.playback.playerBuffering,
    position: controls.playback.playerPosition,
    buffer: controls.playback.playerBuffer,
    playerWidth: controls.debug.playerWidth,
    isConstrainedNetwork: controls.playback.cachePolicy.isConstrained,
  );

  Future<void> saveProgress() async {
    if (_readSettingOrDefault(SettingsKeys.privateMode, false) ||
        _resumePending ||
        !_ready ||
        _road == null ||
        _episode == null) {
      return;
    }
    final position = controls.playback.playerPosition;
    final duration = controls.playback.playerDuration;
    if (duration <= Duration.zero && position <= Duration.zero) return;
    try {
      await _library.recordProgress(
        media: _activeMedia,
        road: _road!,
        episode: _episode!,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        season: _activePlaylist.season,
      );
    } catch (error) {
      KazumiLogger().e('PlusPlayback: 保存进度失败', error: error);
    }
  }

  Future<void> _restoreProgress(
    MediaResumeSession session,
    Player player,
    int targetMs,
    int generation, {
    bool isCrossSourceSwitch = false,
  }) async {
    try {
      await session.restore(
        player: player,
        video: controls.playback.videoController!,
        position: Duration(milliseconds: targetMs),
        tolerance: isCrossSourceSwitch
            ? const Duration(seconds: 8)
            : const Duration(seconds: 3),
        isCurrent: () =>
            _isCurrent(generation) && controls.playback.isCurrentPlayer(player),
      );
      if (!_isCurrent(generation)) return;
      _resumePending = false;
      _pendingResumeTargetMs = 0;
      _notify();
      KazumiLogger().i(
        'PlusPlayback: resume confirmed media=${_activeMedia.ref.key} '
        'episode=${_episode!.key} '
        'position=${controls.playback.playerPosition.inMilliseconds}',
        forceLog: true,
      );
      await saveProgress();
    } catch (error) {
      if (!_isCurrent(generation) || session.isCancelled) return;
      _failPlayback('恢复观看进度失败，旧进度已保留。可重试或从头播放。', generation);
    }
  }

  void _failPlayback(String message, int generation) {
    if (!_isCurrent(generation)) return;
    ++_generation;
    _readyGeneration = -1;
    _resumeSession?.cancel();
    _loadTimeout?.cancel();
    _stallMonitor.reset();
    _ready = false;
    _loading = false;
    _error = message;
    _notify();
    unawaited(_switches.run(controls.stop));
  }

  @override
  void onPlaybackTick() {
    if (_disposed || _exiting) return;

    // 评估卡顿与起播黑屏超时（满足严苛布防门控时触发自动容灾）。
    if (_autoFailoverEnabled && !_failoverInProgress) {
      final trigger = _stallMonitor.sample(_buildHealthSample());
      if (trigger != null && _hasAlternativeCandidates()) {
        unawaited(_triggerAutoFailover(trigger, _generation));
        return;
      }
    }

    if (!_ready) return;
    final position = controls.playback.playerPosition;
    if (!_resumePending &&
        !_reportedPlayback &&
        controls.debug.playerWidth > 0 &&
        position.inSeconds >= 2) {
      _reportedPlayback = true;
      _loadTimeout?.cancel();
      final decodedWidth = controls.debug.playerWidth;
      final decodedHeight = controls.debug.playerHeight;
      final profile = VerifiedStreamProfile(
        width: decodedWidth,
        height: decodedHeight,
        provenance: StreamProfileProvenance.mpvTrackList,
        verifiedAt: DateTime.now(),
      );
      final provider = _catalog.providerById(_activeMedia.ref.ruleId);
      final identityKey = provider != null
          ? SourceHealthRepository.pluginIdentityKey(provider.plugin)
          : _activeMedia.ref.ruleId;
      _health.recordSuccess(
        pluginIdentityKey: identityKey,
        kind: _activeMedia.ref.kind,
        cdnGroup: _currentCdnGroup,
        verifiedProfile: profile,
      );
      _updateCandidateTelemetry(
        _activeCandidateRefKey,
        status: CandidateProbeStatus.ready,
        mpvProfile: profile,
      );
      KazumiLogger().i(
        'PlusPlayback: decoded media=${_activeMedia.ref.key} episode=${_episode!.key} '
        'size=${decodedWidth}x$decodedHeight '
        'position=${position.inMilliseconds}',
        forceLog: true,
      );
    }

    final now = DateTime.now();
    if (now.difference(_lastSave) >= const Duration(seconds: 5)) {
      _lastSave = now;
      unawaited(saveProgress());
    }
  }

  @override
  Future<void> onBackground() async {
    _backgroundSuspended = true;
    await saveProgress();
  }

  @override
  Future<void> onForeground() async {
    _backgroundSuspended = false;
  }

  @override
  Widget buildCollectionButton(
    BuildContext context,
    PlayerPanelHold Function() acquirePlayerPanelHold,
  ) => SourcePlayerCollectButton(
    media: _activeMedia,
    acquirePlayerPanelHold: acquirePlayerPanelHold,
  );

  int _resolveDanmakuEpisodeNumber(PlayableEpisode episode) {
    if (_activeMedia.ref.kind == MediaKind.movie) {
      return 1;
    }
    if (episode.number != null && episode.number! > 0) {
      return episode.number!;
    }
    final parsed = extractEpisodeNumber(episode.title);
    if (parsed > 0) {
      return parsed;
    }
    return _episodeIndex + 1;
  }

  Future<void> _loadPlaybackDanmaku({
    required PlayableEpisode episode,
    required int episodeNumber,
    required String episodeKey,
    required int generation,
  }) async {
    final danmakuSession = _danmakuSessions.begin();
    _danmaku.beginDanmakuLoad();
    try {
      final titles = <String>[
        if (_activeMedia.title.trim().isNotEmpty) _activeMedia.title.trim(),
        if (_cluster.primaryTitle.trim().isNotEmpty)
          _cluster.primaryTitle.trim(),
        for (final alias in _cluster.aliases)
          if (alias.trim().isNotEmpty) alias.trim(),
      ];
      final result = await _danmaku.fetchMediaDanmaku(
        titles: titles,
        episodeNumber: episodeNumber,
        mediaKind: _activeMedia.ref.kind,
      );
      if (!_isCurrent(generation) || danmakuSession.isStale) {
        return;
      }
      if (result.hasDanmakus) {
        final enableDanmaku = _readSettingOrDefault(
          SettingsKeys.danmakuEnabledByDefault,
          true,
        );
        _loadedDanmakuEpisodeKey = episodeKey;
        _danmaku.applyDanmakuLoad(result, enableDanmaku: enableDanmaku);
        KazumiLogger().i(
          'PlusDanmaku: loaded ${result.danmakus.length} danmakus '
          'for ${_activeMedia.title} (${episode.title})',
        );
      } else {
        _danmaku.applyUnavailableDanmakuLoad(result);
      }
    } catch (error) {
      if (_isCurrent(generation) && danmakuSession.isActive) {
        _danmaku.finishDanmakuLoad(disableDanmaku: true);
      }
      KazumiLogger().w('PlusDanmaku: failed to load danmaku', error: error);
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _exiting = true;
    ++_generation;
    _readyGeneration = -1;
    _resumeSession?.cancel();
    _danmakuSessions.cancel();
    _danmaku.clearAndInvalidateScheduledDanmakus();
    _fanOutCancel?.cancel('close');
    _resolver.cancel();
    _loadTimeout?.cancel();
    _bannerAutoHideTimer?.cancel();
    _stallMonitor.reset();
    _notify();
    await saveProgress();
    await _health.flushNow();
    try {
      await _completedSubscription?.cancel();
      _completedSubscription = null;
      await _switches.run(controls.stop);
    } catch (error) {
      KazumiLogger().w('影视播放器停止失败，继续释放页面资源', error: error);
    }
    _ready = false;
    try {
      await fullscreen.close();
    } catch (error) {
      KazumiLogger().w('影视播放器全屏状态释放失败', error: error);
    }
    try {
      await _resolver.dispose();
    } catch (error) {
      KazumiLogger().w('影视来源解析器释放失败', error: error);
    } finally {
      controls.beginShutdown();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
