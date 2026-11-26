import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/pages/player/player_presentation_context.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_fullscreen_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/failover_controller.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/playback_stall_monitor.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/source_traffic_guard.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/utils/media.dart';

class _AnimeFailoverUndoSnapshot {
  const _AnimeFailoverUndoSnapshot({
    required this.candidateId,
    required this.episode,
    required this.road,
    required this.offsetSeconds,
  });

  final String candidateId;
  final int episode;
  final int road;
  final int offsetSeconds;
}

/// 动漫原有业务通过适配器保留，同时接入统一播中热切源、实测健康遥测与自动容灾契约；
/// 严格守卫 BangumiItem 主身份、弹幕时间轴与 `/kazumiPlusSync` WebDAV 同步，绝不写入影视四表。
class AnimePlayerPresentation extends PlayerPresentationContext
    with ChangeNotifier
    implements AnimePlayerFeatures, PlayerSourceSwitchingFeatures {
  AnimePlayerPresentation({
    required this.controller,
    required this.video,
    required Future<void> Function(int episode, {int currentRoad, int offset})
    changeEpisode,
    PluginsController? pluginsController,
    SourceTrafficGuard? trafficGuard,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
    PlaybackStallMonitor? stallMonitor,
  }) : _changeEpisode = changeEpisode,
       _pluginsController = pluginsController,
       _trafficGuard = trafficGuard ?? SourceTrafficGuard.instance,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance,
       _stallMonitor = stallMonitor ?? PlaybackStallMonitor() {
    controls.canInteract = () => canInteract;
    controls.onBeforeSeek = _stallMonitor.markSeek;
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
  }

  @override
  final PlayerController controller;
  @override
  final VideoPageController video;
  final Future<void> Function(int episode, {int currentRoad, int offset})
  _changeEpisode;
  final PluginsController? _pluginsController;
  final SourceTrafficGuard _trafficGuard;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;
  final PlaybackStallMonitor _stallMonitor;

  VideoEpisodeSelection? _completedSelection;
  final List<AnimeSourceCandidate> _candidates = [];
  final Map<String, String> _sessionErrors = {};
  final Set<String> _penalizedCdnGroups = {};

  bool _candidatesSynced = false;
  bool _autoFailoverEnabled = true;
  SourceRecommendationStrategy _strategy =
      SourceRecommendationStrategy.balanced;
  bool _isSwitchingSource = false;
  bool _isDiscoveringSources = false;
  bool _backgroundSuspended = false;
  bool _reportedMpvResolution = false;
  bool _disposed = false;
  String? _pinnedPluginKey;
  String _lastObservedSrc = '';
  VideoEpisodeSelection? _lastObservedSelection;
  FailoverBannerState? _failoverBanner;
  _AnimeFailoverUndoSnapshot? _undoSnapshot;
  Timer? _bannerAutoHideTimer;
  CancelToken? _discoverCancelToken;
  RuleCancelToken? _discoverRuleCancelToken;

  static T _readSettingOrDefault<T>(SettingKey<T> key, T fallback) {
    try {
      return GStorage.getSetting(key);
    } catch (_) {
      return fallback;
    }
  }

  PluginsController? get _resolvedPluginsController {
    if (_pluginsController != null) return _pluginsController;
    try {
      return inject<PluginsController>();
    } catch (_) {
      return null;
    }
  }

  String get _searchKeyword {
    final cn = video.bangumiItem.nameCn.trim();
    if (cn.isNotEmpty) return cn;
    final raw = video.bangumiItem.name.trim();
    if (raw.isNotEmpty) return raw;
    return video.title.trim();
  }

  String get _pinSettingKey => 'anime_pin_${video.bangumiItem.id}';

  String? get _effectivePinnedPluginKey {
    if (_pinnedPluginKey != null) {
      return _pinnedPluginKey!.isEmpty ? null : _pinnedPluginKey;
    }
    try {
      final stored = GStorage.getStringListSettingByName(_pinSettingKey);
      if (stored.isNotEmpty && stored.first.isNotEmpty) {
        _pinnedPluginKey = stored.first;
        return stored.first;
      }
    } catch (_) {}
    return null;
  }

  String get _activeCandidateId => video.isOfflineMode
      ? ''
      : '${SourceHealthRepository.pluginIdentityKey(video.currentPlugin)}|${video.src}';

  /// 从 [VideoPageController] 同步初始活跃源与来自 `SourceSheet` 的同作品候选。
  void syncCandidatesFromVideo() {
    if (video.isOfflineMode || _disposed) return;
    _candidatesSynced = true;
    final current = AnimeSourceCandidate(
      plugin: video.currentPlugin,
      title: video.title,
      src: video.src,
      roads: List<Road>.of(video.roadList),
    );
    _upsertCandidate(current, replaceRoads: true);
    for (final alt in video.alternateSources) {
      _upsertCandidate(alt);
    }
    _stallMonitor.markLoadStarted(
      isWebviewSource: !video.currentPlugin.useNativePlayer,
    );
    _reportedMpvResolution = false;
    _lastObservedSrc = video.src;
    _lastObservedSelection = video.selectedEpisode;
  }

  void _ensureCandidatesSynced() {
    if (!_candidatesSynced && !video.isOfflineMode) {
      syncCandidatesFromVideo();
    }
  }

  void _upsertCandidate(
    AnimeSourceCandidate candidate, {
    bool replaceRoads = false,
  }) {
    final idx = _candidates.indexWhere((c) => c.id == candidate.id);
    if (idx < 0) {
      _candidates.add(candidate);
      return;
    }
    if (replaceRoads ||
        (_candidates[idx].roads.isEmpty && candidate.roads.isNotEmpty)) {
      _candidates[idx] = candidate;
    }
  }

  @override
  PlayerControlsController get controls => controller.controls;
  @override
  AnimePlayerFeatures get animeFeatures => this;
  @override
  PlayerSourceSwitchingFeatures? get sourceSwitchingFeatures =>
      video.isOfflineMode ? null : this;
  @override
  MediaKind? get mediaKind => MediaKind.anime;
  @override
  String get title => video.title;
  @override
  String get src => video.src;
  @override
  List<Road> get roadList => video.roadList;
  @override
  VideoEpisodeSelection get selectedEpisode => video.selectedEpisode;
  @override
  VideoEpisodeSelection? get playingEpisode => video.playingEpisode;
  @override
  VideoFullscreenController get fullscreen => video.fullscreen;
  @override
  bool get isPip => video.isPip;
  @override
  set isPip(bool value) => video.isPip = value;
  @override
  bool get loading => video.loading;
  @override
  String? get errorMessage => video.errorMessage;
  @override
  bool get canInteract =>
      !loading &&
      errorMessage == null &&
      !controls.playback.loading &&
      controls.playback.mediaPlayer != null;
  @override
  String get mediaId =>
      '${video.bangumiItem.id}_${playbackEpisode.road}_${playbackEpisode.episode}';
  @override
  String get sourceName =>
      video.isOfflineMode ? video.offlinePluginName : video.currentPlugin.name;
  @override
  String? get artworkUrl => video.bangumiItem.images['large'];
  @override
  String episodeTitle(VideoEpisodeSelection selection) =>
      video.resolveEpisode(selection)?.displayTitle ??
      super.episodeTitle(selection);

  @override
  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) {
    _reportedMpvResolution = false;
    if (!video.isOfflineMode) {
      _stallMonitor.markLoadStarted(
        isWebviewSource: !video.currentPlugin.useNativePlayer,
      );
    }
    return _changeEpisode(episode, currentRoad: currentRoad, offset: offset);
  }

  @override
  Future<void> retry({bool fromBeginning = false}) => changeEpisode(
    selectedEpisode.episode,
    currentRoad: selectedEpisode.road,
    offset: fromBeginning ? 0 : video.historyOffset,
  );

  @override
  Widget buildCollectionButton(
    BuildContext context,
    PlayerPanelHold Function() acquirePlayerPanelHold,
  ) => PlayerPanelHoldCollectButton(
    acquirePlayerPanelHold: acquirePlayerPanelHold,
    bangumiItem: video.bangumiItem,
  );

  // === PlayerSourceSwitchingFeatures ===

  @override
  Listenable get sourceChanges => this;

  @override
  String get currentSourceLabel => sourceName;

  @override
  String get currentCdnGroup => video.currentCdnGroup;

  @override
  bool get autoFailoverEnabled => _autoFailoverEnabled;

  @override
  SourceRecommendationStrategy get recommendationStrategy => _strategy;

  @override
  AudioDubVariant get selectedDubVariant => AudioDubVariant.original;

  @override
  List<AudioDubVariant> get availableDubVariants => const [
    AudioDubVariant.original,
  ];

  @override
  bool get isSwitchingSource => _isSwitchingSource;

  @override
  bool get isDiscoveringSources => _isDiscoveringSources;

  @override
  FailoverBannerState? get failoverBanner => _failoverBanner;

  @override
  List<PlayerSourceOption> get sourceOptions {
    if (video.isOfflineMode) return const [];
    _ensureCandidatesSynced();
    final now = DateTime.now();
    final activeId = _activeCandidateId;
    final activeCdn = video.currentCdnGroup;
    final pinnedKey = _effectivePinnedPluginKey;

    final options = <PlayerSourceOption>[];
    for (final candidate in _candidates) {
      final identityKey = candidate.pluginIdentityKey;
      final isCurrent = candidate.id == activeId;
      final isPinned = pinnedKey != null && pinnedKey == identityKey;
      final health = _health.bestAvailableHealthFor(
        identityKey,
        MediaKind.anime,
      );
      final sessionErr = _sessionErrors[candidate.id] ?? '';
      final inCaptcha = _health.isSourceInCaptchaCooldown(
        identityKey,
        MediaKind.anime,
        now: now,
      );
      final circuitOpen = health != null && health.isCircuitOpen(now);

      final CandidateProbeStatus status;
      if (isCurrent && sessionErr.isEmpty) {
        status = CandidateProbeStatus.ready;
      } else if (sessionErr.isNotEmpty) {
        status = CandidateProbeStatus.failed;
      } else if (inCaptcha) {
        status = CandidateProbeStatus.captchaRequired;
      } else if (circuitOpen) {
        status = CandidateProbeStatus.circuitOpen;
      } else if (candidate.roads.isNotEmpty) {
        status = CandidateProbeStatus.ready;
      } else {
        status = CandidateProbeStatus.idle;
      }

      var score = _scoring.scorePlugin(
        candidate.plugin,
        MediaKind.anime,
        strategy: _strategy,
        penalizedCdnGroups: _penalizedCdnGroups,
        now: now,
      );
      if (isPinned && score >= 0) {
        score += SourceScoringEngine.pinBonus;
      }

      final cdnGroup = isCurrent && activeCdn.isNotEmpty
          ? activeCdn
          : (health?.lastCdnGroup ?? '');
      final isSameCdn =
          activeCdn.isNotEmpty &&
          cdnGroup.isNotEmpty &&
          cdnGroup == activeCdn &&
          !isCurrent;

      final errorReason = sessionErr.isNotEmpty
          ? sessionErr
          : inCaptcha
          ? '需人工验证（冷却 30 分钟）'
          : circuitOpen
          ? '熔断冷却中'
          : '';

      options.add(
        PlayerSourceOption(
          id: candidate.id,
          ruleId: identityKey,
          sourceName: candidate.plugin.name,
          isCurrent: isCurrent,
          isPinned: isPinned,
          probeStatus: status,
          ttfbMs: health?.ewmaTtfbMs?.round(),
          cdnGroup: cdnGroup,
          isSameCdnAsCurrent: isSameCdn,
          verifiedProfile: health?.lastVerifiedProfile,
          score: score,
          episodeSummary: candidate.title != video.title ? candidate.title : '',
          errorReason: errorReason,
          isLazyWebview:
              candidate.plugin.searchMode != RuleMode.api &&
              !candidate.plugin.useNativePlayer,
          canOpenManualCaptcha:
              status == CandidateProbeStatus.captchaRequired &&
              candidate.plugin.antiCrawlerConfig.enabled,
        ),
      );
    }

    options.sort((a, b) {
      if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
      if (a.isHealthyOrActive != b.isHealthyOrActive) {
        return a.isHealthyOrActive ? -1 : 1;
      }
      final diff = b.score.compareTo(a.score);
      if (diff != 0) return diff;
      return a.sourceName.compareTo(b.sourceName);
    });
    return options;
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
    _notify();
  }

  @override
  void selectDubVariant(AudioDubVariant variant) {
    // 动漫按 BangumiItem 独立建条，不拆多配音分簇。
  }

  @override
  Future<void> togglePinSource(String optionId) async {
    _ensureCandidatesSynced();
    final target = _candidates.where((c) => c.id == optionId).firstOrNull;
    if (target == null) return;
    final key = target.pluginIdentityKey;
    final nextPin = _effectivePinnedPluginKey == key ? '' : key;
    _pinnedPluginKey = nextPin;
    try {
      await GStorage.putStringListSettingByName(
        _pinSettingKey,
        nextPin.isEmpty ? const [] : [nextPin],
      );
    } catch (_) {}
    _notify();
  }

  @override
  Future<void> switchToSource(String optionId) async {
    await _switchToCandidate(optionId, isManual: true);
  }

  Future<bool> _switchToCandidate(
    String optionId, {
    required bool isManual,
    FailoverBannerState? bannerOnSuccess,
  }) async {
    if (video.isOfflineMode || _disposed || _isSwitchingSource) return false;
    _ensureCandidatesSynced();
    if (optionId == _activeCandidateId) return true;
    final index = _candidates.indexWhere((c) => c.id == optionId);
    if (index < 0) return false;
    final target = _candidates[index];

    _isSwitchingSource = true;
    _notify();

    try {
      var roads = target.roads;
      if (roads.isEmpty) {
        final cancelToken = RuleCancelToken();
        final sw = Stopwatch()..start();
        roads = await _trafficGuard.run<List<Road>>(
          url: target.plugin.usesApiSearch
              ? target.plugin.baseUrl
              : target.src,
          query: {'plugin': target.pluginIdentityKey, 'src': target.src},
          deduplicate: true,
          action: (_) => target.plugin.queryChapterRoads(
            target.src,
            cancelToken: cancelToken,
          ),
        );
        sw.stop();
        if (_disposed) return false;
        if (roads.isEmpty) {
          throw StateError('该来源暂无可用播放列表');
        }
        _candidates[index] = target.copyWith(roads: roads);
        _health.recordSuccess(
          pluginIdentityKey: target.pluginIdentityKey,
          kind: MediaKind.anime,
          ttfbMs: sw.elapsedMilliseconds,
        );
      }

      final currentRef = video.resolveEpisode(playbackEpisode);
      final (alignedRoad, alignedEpisode) = _alignAnimeEpisode(
        roads,
        targetSortNumber: currentRef?.sortNumber,
        fallbackEpisode: playbackEpisode.episode,
      );
      final preservedOffset = controls.playback.playerPosition.inSeconds
          .clamp(0, 86400);

      _sessionErrors.remove(optionId);
      _reportedMpvResolution = false;
      _stallMonitor.markLoadStarted(
        isWebviewSource: !target.plugin.useNativePlayer,
      );

      await video.switchSource(
        plugin: target.plugin,
        title: target.title,
        src: target.src,
        roads: roads,
        episode: alignedEpisode,
        currentRoad: alignedRoad,
        offset: preservedOffset,
        playerController: controller,
      );

      if (_disposed) return false;
      _lastObservedSrc = video.src;
      _lastObservedSelection = video.selectedEpisode;
      if (bannerOnSuccess != null) {
        _showFailoverBanner(bannerOnSuccess);
      }
      _notify();
      return video.errorMessage == null;
    } catch (error) {
      KazumiLogger().w('AnimePlayerPresentation: 切源失败', error: error);
      final failureKind = error is CaptchaRequiredException
          ? SourceFailureKind.captchaRequired
          : SourceFailureKind.emptyPlaylist;
      _health.recordFailure(
        pluginIdentityKey: target.pluginIdentityKey,
        kind: MediaKind.anime,
        failureKind: failureKind,
        message: '$error',
      );
      _sessionErrors[optionId] = error is CaptchaRequiredException
          ? '需人工验证（冷却 30 分钟）'
          : '加载播放列表失败';
      if (isManual) {
        KazumiDialog.showToast(message: '切换至 ${target.plugin.name} 失败，请尝试其他片源');
      }
      _notify();
      return false;
    } finally {
      if (!_disposed) {
        _isSwitchingSource = false;
        _notify();
      }
    }
  }

  /// 对齐跨动漫插件的目标集数：优先按解析出的正片集号匹配，否则按 1-based 序号钳位回退。
  static (int roadIndex, int episode) _alignAnimeEpisode(
    List<Road> roads, {
    int? targetSortNumber,
    required int fallbackEpisode,
  }) {
    if (targetSortNumber != null && targetSortNumber > 0) {
      for (var r = 0; r < roads.length; r++) {
        final identifiers = roads[r].identifier;
        for (var i = 0; i < identifiers.length; i++) {
          if (extractEpisodeNumber(identifiers[i]) == targetSortNumber) {
            return (r, i + 1);
          }
        }
      }
    }
    for (var r = 0; r < roads.length; r++) {
      if (roads[r].data.isNotEmpty) {
        return (r, fallbackEpisode.clamp(1, roads[r].data.length));
      }
    }
    return (0, 1);
  }

  @override
  Future<void> openCaptchaVerification(
    BuildContext context,
    String optionId,
  ) async {
    _ensureCandidatesSynced();
    final target = _candidates.where((c) => c.id == optionId).firstOrNull;
    if (target == null) return;
    final verified = await verifyPluginSearchCaptcha(
      context,
      plugin: target.plugin,
      keyword: _searchKeyword,
    );
    if (verified && !_disposed) {
      _health.clearCaptchaCooldown(
        target.pluginIdentityKey,
        kind: MediaKind.anime,
      );
      _sessionErrors.remove(optionId);
      _notify();
    }
  }

  @override
  Future<void> refreshSources() async {
    if (video.isOfflineMode || _disposed || _isDiscoveringSources) return;
    _ensureCandidatesSynced();
    final pluginsController = _resolvedPluginsController;
    final keyword = _searchKeyword;
    if (pluginsController == null || keyword.isEmpty) return;

    _discoverCancelToken?.cancel('refresh');
    _discoverRuleCancelToken?.cancel();
    final guardToken = CancelToken();
    final ruleToken = RuleCancelToken();
    _discoverCancelToken = guardToken;
    _discoverRuleCancelToken = ruleToken;

    _isDiscoveringSources = true;
    _notify();

    try {
      final now = DateTime.now();
      final animePlugins = pluginsController.pluginList
          .where((p) => p.enabled && p.supportedMediaTypes.contains('anime'))
          .toList()
        ..sort((a, b) {
          final sb = _scoring.scorePlugin(b, MediaKind.anime, now: now);
          final sa = _scoring.scorePlugin(a, MediaKind.anime, now: now);
          return sb.compareTo(sa);
        });

      final targetNorm = MediaTextNormalizer.normalizeTitleForMatching(keyword);
      await Future.wait(
        animePlugins.map((plugin) async {
          if (_disposed || guardToken.isCancelled) return;
          final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
          if (_health.isSourceInCaptchaCooldown(
            identityKey,
            MediaKind.anime,
          )) {
            return;
          }
          final health = _health.healthFor(identityKey, MediaKind.anime);
          if (health != null && health.isCircuitOpen(DateTime.now())) {
            return;
          }

          final targetUrl = plugin.usesApiSearch
              ? plugin.baseUrl
              : (plugin.searchURL.isNotEmpty
                    ? plugin.searchURL
                    : plugin.baseUrl);
          final sw = Stopwatch()..start();
          try {
            final resp = await _trafficGuard.run(
              url: targetUrl,
              query: {'keyword': keyword, 'plugin': identityKey},
              cancelToken: guardToken,
              deduplicate: true,
              action: (_) => plugin.queryBangumi(
                keyword,
                shouldRethrow: true,
                cancelToken: ruleToken,
              ),
            );
            sw.stop();
            if (_disposed || guardToken.isCancelled || resp.data.isEmpty) {
              return;
            }
            _health.recordSuccess(
              pluginIdentityKey: identityKey,
              kind: MediaKind.anime,
              ttfbMs: sw.elapsedMilliseconds,
            );
            var best = resp.data.first;
            for (final item in resp.data) {
              final norm = MediaTextNormalizer.normalizeTitleForMatching(
                item.name,
              );
              if (norm == targetNorm) {
                best = item;
                break;
              }
              if (targetNorm.isNotEmpty &&
                  (norm.contains(targetNorm) || targetNorm.contains(norm))) {
                best = item;
              }
            }
            _upsertCandidate(
              AnimeSourceCandidate(
                plugin: plugin,
                title: best.name,
                src: best.src,
              ),
            );
            _notify();
          } on CaptchaRequiredException {
            sw.stop();
            _health.recordFailure(
              pluginIdentityKey: identityKey,
              kind: MediaKind.anime,
              failureKind: SourceFailureKind.captchaRequired,
              message: '动漫片源发现触发站点验证',
            );
          } catch (_) {
            sw.stop();
          }
        }),
      );
    } finally {
      if (!_disposed) {
        _isDiscoveringSources = false;
        _notify();
      }
    }
  }

  void _showFailoverBanner(FailoverBannerState banner) {
    _bannerAutoHideTimer?.cancel();
    _failoverBanner = banner;
    _bannerAutoHideTimer = Timer(const Duration(seconds: 7), () {
      if (!_disposed && _failoverBanner == banner) {
        _failoverBanner = null;
        _notify();
      }
    });
    _notify();
  }

  @override
  void dismissFailoverBanner() {
    _bannerAutoHideTimer?.cancel();
    if (_failoverBanner == null) return;
    _failoverBanner = null;
    _notify();
  }

  @override
  Future<void> undoLastFailover() async {
    final undo = _undoSnapshot;
    if (undo == null || _disposed) return;
    _undoSnapshot = null;
    dismissFailoverBanner();
    final switched = await _switchToCandidate(
      undo.candidateId,
      isManual: true,
    );
    if (switched && !_disposed) {
      KazumiDialog.showToast(message: '已切回原片源');
    }
  }

  Future<void> _triggerAutoFailover(StallTriggerReason reason) async {
    if (video.isOfflineMode ||
        _disposed ||
        _isSwitchingSource ||
        !_autoFailoverEnabled) {
      return;
    }
    _ensureCandidatesSynced();
    final currentPlugin = video.currentPlugin;
    final currentIdentity = SourceHealthRepository.pluginIdentityKey(
      currentPlugin,
    );
    final currentCdn = video.currentCdnGroup;
    _health.recordStall(
      pluginIdentityKey: currentIdentity,
      kind: MediaKind.anime,
      cdnGroup: currentCdn,
      reason: reason.name,
    );
    if (currentCdn.isNotEmpty) {
      _penalizedCdnGroups.add(currentCdn);
    }

    // 优先挑选异 CDN 健康候选，其次剩余未熔断同 CDN 候选。
    final allOptions = sourceOptions
        .where((opt) => !opt.isCurrent && opt.isHealthyOrActive)
        .toList();
    if (allOptions.isEmpty) return;

    final crossCdn = allOptions.where((opt) => !opt.isSameCdnAsCurrent).toList();
    final orderedTargets = [
      ...crossCdn,
      ...allOptions.where((opt) => opt.isSameCdnAsCurrent),
    ];

    final previousId = _activeCandidateId;
    final previousName = currentPlugin.name;
    final previousEp = playbackEpisode;
    final previousOffset = controls.playback.playerPosition.inSeconds;

    for (final target in orderedTargets) {
      if (_disposed) return;
      final switched = await _switchToCandidate(
        target.id,
        isManual: false,
        bannerOnSuccess: FailoverBannerState(
          fromSourceName: previousName,
          toSourceName: target.sourceName,
          reasonText: reason == StallTriggerReason.startupBlackScreen
              ? '起播超时'
              : '播放卡顿',
          tier: 2,
          canUndo: true,
          createdAt: DateTime.now(),
        ),
      );
      if (switched) {
        _undoSnapshot = _AnimeFailoverUndoSnapshot(
          candidateId: previousId,
          episode: previousEp.episode,
          road: previousEp.road,
          offsetSeconds: previousOffset,
        );
        return;
      }
    }
  }

  @override
  void onPlaybackTick() {
    final playback = controls.playback;
    final identity = video.currentHistoryIdentity;
    if (playback.playerPlaying &&
        !loading &&
        identity != null &&
        identity.canRecord) {
      video.historyController.updateHistory(
        identity,
        playback.playerPosition,
        duration: playback.playerDuration,
      );
    }

    // 跟踪实测解码分辨率与播中卡顿自愈（仅在线动漫会话）。
    if (!video.isOfflineMode && !_disposed) {
      if (_lastObservedSrc != video.src ||
          _lastObservedSelection != video.selectedEpisode) {
        _lastObservedSrc = video.src;
        _lastObservedSelection = video.selectedEpisode;
        _reportedMpvResolution = false;
        _stallMonitor.markLoadStarted(
          isWebviewSource: !video.currentPlugin.useNativePlayer,
        );
      }

      final width = controls.debug.playerWidth;
      final height = controls.debug.playerHeight;
      if (!_reportedMpvResolution &&
          !loading &&
          errorMessage == null &&
          width > 0 &&
          height > 0) {
        _reportedMpvResolution = true;
        _health.recordSuccess(
          pluginIdentityKey: SourceHealthRepository.pluginIdentityKey(
            video.currentPlugin,
          ),
          kind: MediaKind.anime,
          cdnGroup: video.currentCdnGroup,
          verifiedProfile: VerifiedStreamProfile(
            width: width,
            height: height,
            provenance: StreamProfileProvenance.mpvTrackList,
            verifiedAt: DateTime.now(),
          ),
        );
        _notify();
      }

      if (_autoFailoverEnabled && !_isSwitchingSource && errorMessage == null) {
        final trigger = _stallMonitor.sample(
          PlaybackHealthSample(
            playing: playback.playerPlaying,
            loading: loading || playback.loading,
            resumePending: false,
            completed: playback.completed,
            backgroundSuspended: _backgroundSuspended,
            seeking: controls.seeking.hasActiveInteractiveSeek,
            qualitySwitching: controls.quality.switching,
            manualSwitchInProgress: _isSwitchingSource,
            buffering: playback.playerBuffering,
            position: playback.playerPosition,
            buffer: playback.buffer,
            playerWidth: width,
            isConstrainedNetwork: MeteredNetworkService.isMetered,
          ),
        );
        if (trigger != null) {
          unawaited(_triggerAutoFailover(trigger));
        }
      }
    }

    final selection = playbackEpisode;
    if (!playback.completed) _completedSelection = null;
    if (playback.completed &&
        canInteract &&
        playingEpisode != null &&
        _completedSelection != selection &&
        selection.road >= 0 &&
        selection.road < roadList.length) {
      _completedSelection = selection;
      if (playback.resumedNearEnd) {
        unawaited(playback.restartFromBeginning());
      } else if (GStorage.getSetting(SettingsKeys.autoPlayNext) &&
          selection.episode < roadList[selection.road].data.length) {
        final next = VideoEpisodeSelection(
          episode: selection.episode + 1,
          road: selection.road,
        );
        KazumiDialog.showToast(message: '正在加载${episodeTitle(next)}');
        unawaited(changeEpisode(next.episode, currentRoad: next.road));
      }
    }
    controller.setSyncPlayCurrentPosition();
  }

  @override
  Future<void> onBackground() async {
    _backgroundSuspended = true;
  }

  @override
  Future<void> onForeground() async {
    _backgroundSuspended = false;
  }

  @override
  Future<void> onFullscreenChanged() async {
    if (GStorage.getSetting(SettingsKeys.webDavEnable) &&
        GStorage.getSetting(SettingsKeys.webDavEnableHistory)) {
      try {
        await WebDav().syncHistory();
      } catch (error) {
        KazumiLogger().w('WebDav: auto history sync failed', error: error);
      }
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _bannerAutoHideTimer?.cancel();
    _discoverCancelToken?.cancel('disposed');
    _discoverRuleCancelToken?.cancel();
    _stallMonitor.reset();
    super.dispose();
  }
}
