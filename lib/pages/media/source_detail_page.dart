import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';
import 'package:kazumi/pages/download/download_target.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_fanout_service.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

/// 银盐放映室零选源影视详情页。
///
/// 核心原则：
/// - 优先消费 `initialCluster` 与 `VodPayloadCache`（实现 MacCMS 3→1 零冗余请求）；
/// - 后台静默调用 [SourceFanOutService.enrichWorkCluster] 补齐其余健康备选源；
/// - 停用源历史/片单自动无损寻找替代源并带入 `initialResumeMs` 一键续播；
/// - 电影单版本自动隐藏多余选集栏；超 50 集电视剧自动分组选集；
/// - 缺少源端季结构时绝不自动推断「第 1 季」，画质徽章严格消费 `mpv` 实播解码结果。
class SourceDetailPage extends StatefulWidget {
  const SourceDetailPage({
    super.key,
    required this.media,
    this.initialCluster,
  });

  final MediaSummary media;
  final WorkCluster? initialCluster;

  @override
  State<SourceDetailPage> createState() => _SourceDetailPageState();
}

class _SourceDetailPageState extends State<SourceDetailPage> {
  static const int _episodePageSize = 50;

  final _catalog = inject<MediaCatalogService>();
  final _downloadController = inject<DownloadController>();
  final _library = SourceMediaLibrary.instance;
  final _health = SourceHealthRepository.instance;
  final _scoring = SourceScoringEngine.instance;
  final _payloadCache = VodPayloadCache.instance;
  late final SourceFanOutService _fanOut;

  late WorkCluster _cluster;
  late MediaSummary _activeMedia;
  MediaDetail? _detail;
  SourcePlaylist? _playlist;
  MediaSeason? _season;

  int _roadIndex = 0;
  int _episodeSegment = 0;
  bool _reverseEpisodes = false;
  int _generation = 0;
  CancelToken? _cancel;
  CancelToken? _enrichCancel;
  String? _error;
  bool _loading = true;
  bool _enriching = false;
  bool _saving = false;
  bool _switchedFromDisabledSource = false;

  SourceRecommendationStrategy get _strategy =>
      SourceRecommendationStrategy.parse(
        GStorage.getSetting(SettingsKeys.sourceRecommendationStrategy),
      );

  MediaSummary get _displayMedia => _detail?.summary ?? _activeMedia;
  MediaProvider? get _activeProvider =>
      _catalog.providerById(_activeMedia.ref.ruleId);

  MediaCandidate? get _activeCandidate {
    for (final c in _cluster.candidates) {
      if (c.refKey == _activeMedia.ref.key) return c;
    }
    return _cluster.candidates.isNotEmpty ? _cluster.candidates.first : null;
  }

  @override
  void initState() {
    super.initState();
    _fanOut = SourceFanOutService(catalog: _catalog);
    final seed =
        widget.initialCluster ??
        _fanOut.seedClusterFromSummary(widget.media, strategy: _strategy);
    _cluster = _applyPinAndRank(seed);
    _activeMedia = _pickInitialMedia(_cluster, widget.media);

    // 若已命中 VodPayloadCache，先立即填充内存快照，实现零等待首帧
    final cached = _payloadCache.get(_activeMedia.ref);
    if (cached != null) {
      _detail = cached.detail;
      if (cached.playlist != null && cached.playlist!.roads.isNotEmpty) {
        _playlist = cached.playlist;
        _loading = false;
      }
    }

    unawaited(_loadActiveDetail());
    unawaited(_enrichInBackground());
  }

  MediaSummary _pickInitialMedia(WorkCluster cluster, MediaSummary fallback) {
    final pinnedRuleId = _library.pinnedRuleIdForGroup(cluster.clusterKey);
    if (pinnedRuleId != null && pinnedRuleId.isNotEmpty) {
      for (final c in cluster.candidates) {
        if (c.ruleId == pinnedRuleId && _catalog.providerById(c.ruleId) != null) {
          return c.summary;
        }
      }
    }
    // 若 fallback 来源可用，优先在初始簇内选择综合得分最高的可用源
    for (final c in cluster.candidates) {
      if (_catalog.providerById(c.ruleId) != null) {
        return c.summary;
      }
    }
    return fallback;
  }

  WorkCluster _applyPinAndRank(WorkCluster cluster) {
    final pinnedRuleId = _library.pinnedRuleIdForGroup(cluster.clusterKey);
    final updated = [
      for (final c in cluster.candidates)
        c.copyWith(isPinned: pinnedRuleId != null && c.ruleId == pinnedRuleId),
    ];
    final ranked = _scoring.rankCandidates(
      updated,
      kind: cluster.kind,
      strategy: _strategy,
    );
    return cluster.copyWith(candidates: ranked);
  }

  Future<void> _enrichInBackground() async {
    _enrichCancel?.cancel();
    final token = _enrichCancel = CancelToken();
    if (mounted) setState(() => _enriching = true);
    try {
      final enriched = await _fanOut.enrichWorkCluster(
        seedCluster: _cluster,
        strategy: _strategy,
        cancelToken: token,
        onUpdate: (partial) {
          if (!mounted || token.isCancelled) return;
          _applyEnrichedCluster(partial);
        },
      );
      if (!mounted || token.isCancelled) return;
      _applyEnrichedCluster(enriched);
      unawaited(
        _library.linkWorkCluster(_cluster, activeRefKey: _activeMedia.ref.key),
      );
    } catch (_) {
      // 后台补源失败不影响当前源主链路
    } finally {
      if (mounted && !token.isCancelled) {
        setState(() => _enriching = false);
      }
    }
  }

  void _applyEnrichedCluster(WorkCluster updated) {
    final ranked = _applyPinAndRank(updated);
    final currentProviderMissing = _activeProvider == null;
    MediaSummary? replacement;
    if (currentProviderMissing) {
      for (final c in ranked.candidates) {
        if (_catalog.providerById(c.ruleId) != null) {
          replacement = c.summary;
          break;
        }
      }
    }

    setState(() {
      _cluster = ranked;
      if (replacement != null) {
        _activeMedia = replacement;
        _switchedFromDisabledSource = true;
      }
    });

    if (replacement != null) {
      unawaited(_loadActiveDetail());
    }
  }

  Future<void> _loadActiveDetail({bool forceRefresh = false}) async {
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;

    final provider = _activeProvider;
    if (provider == null) {
      setState(() {
        _loading = false;
        _error = '原保存片源已停用或移除。正在自动搜索可用替代片源，原有片单与观看进度已完整保留。';
      });
      return;
    }

    // 检查是否已在 VodPayloadCache 中有完整详情+播放列表（MacCMS 3→1 零额外请求）
    if (!forceRefresh) {
      final cached = _payloadCache.get(_activeMedia.ref);
      if (cached?.detail != null &&
          cached?.playlist != null &&
          cached!.playlist!.roads.isNotEmpty) {
        final detail = cached.detail!;
        final history = _library.latestHistoryForCluster(_cluster);
        MediaSeason? season;
        for (final item in detail.seasons) {
          if (item.id == (_season?.id ?? history?.seasonId)) season = item;
        }
        season ??= detail.seasons.isEmpty ? null : detail.seasons.first;
        if (mounted && generation == _generation) {
          setState(() {
            _detail = detail;
            _season = season;
            _error = null;
            _loading = false;
          });
          _setPlaylist(cached.playlist!);
        }
        return;
      }
    }

    setState(() {
      _loading = true;
      _error = null;
      if (forceRefresh) _playlist = null;
    });

    try {
      final detail = await provider.queryDetail(
        _activeMedia,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      final history = _library.latestHistoryForCluster(_cluster);
      MediaSeason? season;
      for (final item in detail.seasons) {
        if (item.id == (_season?.id ?? history?.seasonId)) season = item;
      }
      season ??= detail.seasons.isEmpty ? null : detail.seasons.first;
      setState(() {
        _detail = detail;
        _season = season;
      });
      final playlist = await provider.queryPlaylist(
        detail.summary,
        season: season,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      _setPlaylist(playlist);
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      // 当前优选源失败时，若簇内还有其他健康备选源，自动尝试切到下一个备选源
      final fallback = _nextAvailableAlternative(_activeMedia.ref.key);
      if (fallback != null && !forceRefresh) {
        setState(() {
          _activeMedia = fallback.summary;
          _detail = fallback.detail;
          _playlist = fallback.playlist;
        });
        unawaited(_loadActiveDetail());
        return;
      }
      setState(() => _error = '无法获取当前片源资料或播放列表，可尝试切换其他片源或重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  MediaCandidate? _nextAvailableAlternative(String excludeRefKey) {
    for (final c in _cluster.candidates) {
      if (c.refKey == excludeRefKey) continue;
      if (_catalog.providerById(c.ruleId) == null) continue;
      if (!c.isAutoEligible) continue;
      return c;
    }
    return null;
  }

  void _setPlaylist(SourcePlaylist playlist) {
    final directHistory = _library.historyFor(_activeMedia.ref);
    final road = directHistory == null
        ? -1
        : playlist.roads.indexWhere((item) => item.id == directHistory.roadId);
    setState(() {
      _playlist = SourcePlaylist(
        roads: playlist.roads,
        season: playlist.season ?? _season,
      );
      _roadIndex = road < 0 ? 0 : road;
      _episodeSegment = 0;
    });
  }

  Future<void> _selectSeason(MediaSeason season) async {
    if (_season?.id == season.id) return;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;
    setState(() {
      _season = season;
      _loading = true;
      _playlist = null;
      _error = null;
    });
    try {
      final provider = _activeProvider;
      if (provider == null) throw StateError('来源不可用');
      final playlist = await provider.queryPlaylist(
        _displayMedia,
        season: season,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      _setPlaylist(playlist);
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      setState(() => _error = '本季播放列表暂时不可用，请重试或切换其他片源。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _switchCandidate(
    MediaCandidate candidate, {
    bool pin = false,
  }) async {
    if (_catalog.providerById(candidate.ruleId) == null) {
      KazumiDialog.showToast(message: '${candidate.sourceName} 当前已停用');
      return;
    }
    if (pin) {
      await _library.linkWorkCluster(
        _cluster,
        activeRefKey: candidate.refKey,
        pinnedRuleId: candidate.ruleId,
        updatePinned: true,
      );
    }
    setState(() {
      _cluster = _applyPinAndRank(_cluster);
      _activeMedia = candidate.summary;
      _detail = candidate.detail;
      _playlist = candidate.playlist;
      _season = null;
      _roadIndex = 0;
      _episodeSegment = 0;
      _switchedFromDisabledSource = false;
    });
    unawaited(_loadActiveDetail());
  }

  Future<void> _switchDubCluster(WorkCluster sibling) async {
    final allSiblings = [
      _cluster.copyWith(siblingDubClusters: const []),
      ..._cluster.siblingDubClusters.where(
        (s) => s.clusterKey != sibling.clusterKey,
      ),
    ];
    final next = _applyPinAndRank(
      sibling.copyWith(siblingDubClusters: allSiblings),
    );
    setState(() {
      _cluster = next;
      _activeMedia = _pickInitialMedia(next, next.toPrimarySummary());
      _detail = null;
      _playlist = null;
      _season = null;
      _roadIndex = 0;
      _episodeSegment = 0;
    });
    unawaited(_loadActiveDetail());
  }

  /// 在当前活跃片源的播放列表中寻找最匹配历史记录的 `(roadIndex, episodeIndex, initialResumeMs)`。
  (int, int, int?)? _resolveResumeTarget(SourceHistory? history) {
    final playlist = _playlist;
    if (playlist == null || history == null || playlist.roads.isEmpty) {
      return null;
    }

    // 1. 若同来源，严格按稳定 roadId + episodeId 精准定位
    if (history.media.ref == _activeMedia.ref) {
      if (history.seasonId != null &&
          history.seasonId != (_season?.id ?? playlist.season?.id)) {
        return null;
      }
      for (var r = 0; r < playlist.roads.length; r++) {
        final road = playlist.roads[r];
        if (road.id != history.roadId) continue;
        final ep = road.episodes.indexWhere((e) => e.id == history.episodeId);
        if (ep >= 0) return (r, ep, null);
      }
    }

    // 2. 跨源无损续播（例如原源已停用，自动切到健康替代源）：按电影首项或集数标题数字匹配，并显式带入 initialResumeMs
    final firstRoadIdx = playlist.roads.indexWhere(
      (r) => r.episodes.isNotEmpty,
    );
    if (firstRoadIdx < 0) return null;
    final episodes = playlist.roads[firstRoadIdx].episodes;
    if (_displayMedia.ref.kind == MediaKind.movie) {
      return (firstRoadIdx, 0, history.positionMs);
    }

    final targetNum = _extractEpisodeNumber(history.episodeTitle);
    if (targetNum != null) {
      for (var i = 0; i < episodes.length; i++) {
        final epNum = episodes[i].number ?? _extractEpisodeNumber(episodes[i].title);
        if (epNum == targetNum) {
          return (firstRoadIdx, i, history.positionMs);
        }
      }
    }
    return (firstRoadIdx, 0, history.positionMs);
  }

  int? _extractEpisodeNumber(String title) {
    final m = RegExp(r'\d+').firstMatch(title);
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  Future<void> _play(
    int roadIndex,
    int episodeIndex, {
    int? initialResumeMs,
  }) async {
    final playlist = _playlist;
    if (playlist == null || _activeProvider == null) {
      KazumiDialog.showToast(message: '当前片源暂不可用，请切换其他片源后再播放。');
      return;
    }
    unawaited(
      _library.linkWorkCluster(_cluster, activeRefKey: _activeMedia.ref.key),
    );
    await context.pushNamed(
      '/media/play',
      arguments: PlaybackContext(
        media: _displayMedia,
        playlist: playlist,
        roadIndex: roadIndex,
        episodeIndex: episodeIndex,
        workCluster: _cluster,
        candidates: _cluster.candidates,
        initialResumeMs: initialResumeMs,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _setCollection(CollectType status) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (status == CollectType.none) {
        final refs = <MediaRef>{
          _displayMedia.ref,
          for (final c in _cluster.candidates) c.summary.ref,
        };
        await _library.removeCollectionCluster(refs);
      } else {
        await _library.setCollection(_displayMedia, status: status.value);
        await _library.linkWorkCluster(
          _cluster,
          activeRefKey: _displayMedia.ref.key,
        );
      }
    } catch (_) {
      KazumiDialog.showToast(message: '保存片单失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openSourcePickerSheet() async {
    await showAdaptiveBottomSheet<void>(
      context: context,
      builder: (sheetCtx) {
        final tokens = KazumiThemeTokens.of(sheetCtx);
        final pinnedRuleId = _library.pinnedRuleIdForGroup(_cluster.clusterKey);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选择片源（共 ${_cluster.candidates.length} 源）',
                        style: Theme.of(sheetCtx).textTheme.titleMedium
                            ?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    if (_enriching)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.accent,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '补源中',
                            style: TextStyle(
                              color: tokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '已按实测分辨率、响应速度与稳定性自动排序；播放中遇卡顿将自动无缝切换跨 CDN 备源。',
                  style: TextStyle(color: tokens.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _cluster.candidates.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final candidate = _cluster.candidates[index];
                      final isActive =
                          candidate.refKey == _activeMedia.ref.key;
                      final isPinned = pinnedRuleId == candidate.ruleId;
                      final enabled =
                          _catalog.providerById(candidate.ruleId) != null;
                      final badge =
                          candidate.streamProfile?.uiBadgeText ?? '';
                      final metrics = <String>[
                        if (badge.isNotEmpty) '实测 $badge',
                        if (candidate.ttfbMs != null && candidate.ttfbMs! > 0)
                          '${candidate.ttfbMs}ms',
                        if (candidate.cdnGroup.isNotEmpty) candidate.cdnGroup,
                        if (candidate.summary.statusText.isNotEmpty)
                          candidate.summary.statusText,
                        if (!enabled) '规则已停用',
                      ];

                      return TvFocusFrame(
                        radius: 10,
                        child: Material(
                          color: isActive ? tokens.accentSoft : tokens.surface2,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: isActive
                                  ? tokens.accent.withValues(alpha: 0.7)
                                  : tokens.hairline,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: ListTile(
                            enabled: enabled,
                            dense: true,
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    candidate.sourceName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isActive
                                          ? tokens.accent
                                          : tokens.textPrimary,
                                      fontWeight: isActive
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (index == 0) ...[
                                  const SizedBox(width: 6),
                                  _MiniTag(
                                    text: '优选',
                                    color: tokens.accent,
                                    background: tokens.accentSoft,
                                  ),
                                ],
                                if (isPinned) ...[
                                  const SizedBox(width: 6),
                                  _MiniTag(
                                    text: '已固定',
                                    color: tokens.healthy,
                                    background: tokens.healthy.withValues(
                                      alpha: 0.16,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: metrics.isNotEmpty
                                ? Text(
                                    metrics.join('  '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: tokens.textSecondary,
                                      fontSize: 12,
                                    ),
                                  )
                                : null,
                            trailing: enabled
                                ? IconButton(
                                    tooltip: isPinned ? '已固定此片源' : '设为本片默认片源',
                                    icon: Icon(
                                      isPinned
                                          ? Icons.push_pin_rounded
                                          : Icons.push_pin_outlined,
                                      size: 18,
                                      color: isPinned
                                          ? tokens.accent
                                          : tokens.textMuted,
                                    ),
                                    onPressed: () {
                                      Navigator.of(sheetCtx).pop();
                                      unawaited(
                                        _switchCandidate(candidate, pin: true),
                                      );
                                    },
                                  )
                                : null,
                            onTap: enabled
                                ? () {
                                    Navigator.of(sheetCtx).pop();
                                    unawaited(_switchCandidate(candidate));
                                  }
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  DownloadTarget? _downloadTarget() {
    final playlist = _playlist;
    final provider = _activeProvider;
    if (playlist == null || provider == null) return null;
    final season = playlist.season ?? _season;
    return DownloadTarget(
      recordId: DownloadTarget.sourceRecordId(
        _displayMedia.ref,
        seasonId: season?.id ?? '',
      ),
      title: season == null || season.name.isEmpty
          ? _displayMedia.title
          : '${_displayMedia.title} ${season.name}',
      coverUrl: _displayMedia.posterUrl,
      pluginName: provider.plugin.name,
      roads: [
        for (final road in playlist.roads)
          Road(
            name: road.name,
            data: [for (final episode in road.episodes) episode.url],
            identifier: [for (final episode in road.episodes) episode.title],
          ),
      ],
      playingRoad: _roadIndex,
      playingEpisode: 1,
    );
  }

  Map<String, DownloadEpisode> _downloadsFor(DownloadTarget target) {
    final record = _downloadController.getRecordSnapshot(
      '${target.pluginName}_${target.recordId}',
    );
    if (record == null) return const {};
    return {
      for (final episode in record.episodes.values)
        if (episode.episodePageUrl.isNotEmpty) episode.episodePageUrl: episode,
    };
  }

  String _duration(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    if (value.inHours > 0) {
      return '${value.inHours}:${(value.inMinutes % 60).toString().padLeft(2, '0')}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _enrichCancel?.cancel();
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final isTv = PlatformEnvironmentService.isTelevision;
    final horizontalPad = isTv ? 32.0 : 20.0;

    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: SysAppBar(
        title: Text(
          _displayMedia.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '刷新资料',
            onPressed: _loading
                ? null
                : () => _loadActiveDetail(forceRefresh: true),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([_library, _health]),
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 36),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1080),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeroHeader(context, tokens),
                    if (_switchedFromDisabledSource) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.surface1,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.swap_horiz_rounded,
                              size: 18,
                              color: tokens.accent,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '原保存来源已停用，已自动匹配健康替代源「${_activeMedia.sourceName}」，点击即可按原进度续播。',
                                style: TextStyle(
                                  color: tokens.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_loading)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          backgroundColor: Colors.transparent,
                          color: tokens.accent,
                        ),
                      ),
                    if (_error != null)
                      MediaMessage(
                        message: _error!,
                        onRetry: () => _loadActiveDetail(forceRefresh: true),
                      ),
                    if (_cluster.siblingDubClusters.isNotEmpty) ...[
                      _buildDubVariantRow(context, tokens),
                      const SizedBox(height: 18),
                    ],
                    if (_detail != null && _detail!.seasons.isNotEmpty) ...[
                      _buildSeasonSelector(context, tokens),
                      const SizedBox(height: 18),
                    ],
                    if (_playlist != null)
                      Observer(
                        builder: (context) {
                          final target = _downloadTarget();
                          final downloads = target == null
                              ? const <String, DownloadEpisode>{}
                              : _downloadsFor(target);
                          return _buildPlaybackSection(
                            context,
                            tokens,
                            target,
                            downloads,
                          );
                        },
                      ),
                    if (_detail != null) ...[
                      const SizedBox(height: 24),
                      _buildInfoCards(context, tokens),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroHeader(BuildContext context, KazumiThemeTokens tokens) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final collection = _library.collectionForCluster(_cluster);
    final collected = collection != null;
    final collectionStatus = collection != null
        ? CollectType.fromValue(collection.status)
        : CollectType.none;
    final history = _library.latestHistoryForCluster(_cluster);
    final resume = _resolveResumeTarget(history);
    final firstPlayableRoad =
        _playlist?.roads.indexWhere((road) => road.episodes.isNotEmpty) ?? -1;
    final canPlay = resume != null || firstPlayableRoad >= 0;

    final activeCand = _activeCandidate;
    final verifiedBadge = activeCand?.streamProfile?.uiBadgeText ?? '';
    final rating = _cluster.ratingText.isNotEmpty
        ? _cluster.ratingText
        : _displayMedia.ratingText;
    final genres = _detail?.genres.isNotEmpty == true
        ? _detail!.genres
        : _cluster.genres;

    final primaryLabel = resume != null && history != null
        ? '继续观看 · ${history.episodeTitle} (${_duration(history.positionMs)})'
        : _displayMedia.ref.kind == MediaKind.movie
        ? '智能播放'
        : '智能播放 · 第 1 集';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: compact ? 108 : 164,
          height: compact ? 160 : 242,
          decoration: BoxDecoration(
            color: tokens.surface1,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tokens.hairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: NetworkImgLayer(
            src: _displayMedia.posterUrl.isNotEmpty
                ? _displayMedia.posterUrl
                : _cluster.posterUrl,
            width: compact ? 108 : 164,
            height: compact ? 160 : 242,
            borderRadius: BorderRadius.zero,
          ),
        ),
        SizedBox(width: compact ? 14 : 22),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _displayMedia.title,
                style:
                    (compact
                            ? Theme.of(context).textTheme.titleLarge
                            : Theme.of(context).textTheme.headlineSmall)
                        ?.copyWith(
                          color: tokens.textPrimary,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (rating.isNotEmpty)
                    _MiniTag(
                      text: '评分 $rating',
                      color: tokens.accent,
                      background: tokens.accentSoft,
                    ),
                  if (_displayMedia.year.isNotEmpty)
                    _MiniTag(
                      text: _displayMedia.year,
                      color: tokens.textSecondary,
                      background: tokens.surface2,
                    ),
                  if (_displayMedia.region.isNotEmpty)
                    _MiniTag(
                      text: _displayMedia.region,
                      color: tokens.textSecondary,
                      background: tokens.surface2,
                    ),
                  if (_displayMedia.statusText.isNotEmpty)
                    _MiniTag(
                      text: _displayMedia.statusText,
                      color: tokens.textSecondary,
                      background: tokens.surface2,
                    ),
                  for (final g in genres.take(3))
                    _MiniTag(
                      text: g,
                      color: tokens.textMuted,
                      background: tokens.surface1,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // 动态自动优选片源胶囊（非强制选源，可一键透明查看/切换/固定）
              TvFocusFrame(
                radius: 8,
                child: Material(
                  color: tokens.surface1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: tokens.hairline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _openSourcePickerSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_awesome_rounded,
                            size: 15,
                            color: tokens.accent,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              [
                                '优选片源：${_activeMedia.sourceName}',
                                if (verifiedBadge.isNotEmpty) verifiedBadge,
                                if (activeCand?.ttfbMs != null &&
                                    activeCand!.ttfbMs! > 0)
                                  '${activeCand.ttfbMs}ms',
                              ].join('  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.textPrimary,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _enriching
                                ? '${_cluster.sourceCount} 源 · 补源中'
                                : '切换 (${_cluster.sourceCount} 源)',
                            style: TextStyle(
                              color: tokens.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: tokens.accent,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // 主行动按钮区：高对比钨丝金「智能播放 / 继续观看」+ 片单 + 下载
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  TvFocusFrame(
                    radius: 10,
                    child: FilledButton.icon(
                      autofocus: PlatformEnvironmentService.isTelevision,
                      onPressed: canPlay && !_loading
                          ? () => _play(
                              resume?.$1 ?? firstPlayableRoad,
                              resume?.$2 ?? 0,
                              initialResumeMs: resume?.$3,
                            )
                          : null,
                      icon: const Icon(Icons.play_arrow_rounded, size: 20),
                      label: Text(
                        primaryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (PlatformEnvironmentService.isTelevision)
                    TvSelect<CollectType>(
                      label: '片单',
                      value: collectionStatus,
                      options: [
                        for (final status in CollectType.values)
                          (
                            status,
                            status == CollectType.none ? '未加入' : status.label,
                          ),
                      ],
                      onChanged: _saving ? null : _setCollection,
                    )
                  else
                    PopupMenuButton<CollectType>(
                      enabled: !_saving,
                      tooltip: '设置片单状态',
                      onSelected: _setCollection,
                      itemBuilder: (_) => CollectType.values
                          .map(
                            (status) => PopupMenuItem(
                              value: status,
                              child: Text(
                                status == CollectType.none
                                    ? '移出片单'
                                    : status.label,
                              ),
                            ),
                          )
                          .toList(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 11,
                        ),
                        decoration: BoxDecoration(
                          color: collected ? tokens.accentSoft : tokens.surface1,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: collected
                                ? tokens.accent.withValues(alpha: 0.65)
                                : tokens.hairline,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              collected
                                  ? Icons.bookmark_rounded
                                  : Icons.bookmark_border_rounded,
                              size: 18,
                              color: collected
                                  ? tokens.accent
                                  : tokens.textPrimary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _saving
                                  ? '保存中'
                                  : collected
                                  ? collectionStatus.label
                                  : '加入片单',
                              style: TextStyle(
                                color: collected
                                    ? tokens.accent
                                    : tokens.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDubVariantRow(BuildContext context, KazumiThemeTokens tokens) {
    return Row(
      children: [
        Text(
          '音轨版本',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: tokens.textSecondary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(_cluster.dubVariant.label),
                selected: true,
                showCheckmark: false,
                onSelected: (_) {},
              ),
              for (final sib in _cluster.siblingDubClusters)
                TvFocusFrame(
                  radius: 8,
                  child: ChoiceChip(
                    label: Text('${sib.dubVariant.label} (${sib.sourceCount})'),
                    selected: false,
                    showCheckmark: false,
                    onSelected: (_) => _switchDubCluster(sib),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSeasonSelector(BuildContext context, KazumiThemeTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '季目选择',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: tokens.textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final season in _detail!.seasons)
              TvFocusFrame(
                radius: 8,
                child: ChoiceChip(
                  label: Text(season.name),
                  selected: season.id == _season?.id,
                  showCheckmark: false,
                  onSelected: (_) => _selectSeason(season),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlaybackSection(
    BuildContext context,
    KazumiThemeTokens tokens,
    DownloadTarget? target,
    Map<String, DownloadEpisode> downloads,
  ) {
    final roads = _playlist!.roads;
    if (roads.isEmpty) {
      return const MediaMessage(message: '当前片源暂未提供播放线路，可点击上方切换其他片源。');
    }
    final safeRoadIndex = _roadIndex.clamp(0, roads.length - 1);
    final road = roads[safeRoadIndex];
    final canDownload = target != null && road.episodes.isNotEmpty;
    final isMovie = _displayMedia.ref.kind == MediaKind.movie;

    // 电影单版本：隐藏多余的“第 1 集”选集框，仅保留线路/离线缓存快捷栏
    if (isMovie && road.episodes.length <= 1 && roads.length <= 1) {
      if (!canDownload) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: tokens.surface1,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tokens.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.download_outlined, size: 18, color: tokens.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '支持离线缓存本片',
                style: TextStyle(color: tokens.textSecondary, fontSize: 13),
              ),
            ),
            TvFocusFrame(
              radius: 8,
              child: OutlinedButton.icon(
                onPressed: () => showAdaptiveBottomSheet<void>(
                  context: context,
                  builder: (context) => DownloadEpisodeSheet(
                    road: safeRoadIndex,
                    target: target,
                  ),
                ),
                icon: const Icon(Icons.download_rounded, size: 17),
                label: const Text('缓存影片'),
              ),
            ),
          ],
        ),
      );
    }

    final totalEpisodes = road.episodes.length;
    final segmentCount = (totalEpisodes / _episodePageSize).ceil();
    final safeSegment =
        segmentCount <= 1 ? 0 : _episodeSegment.clamp(0, segmentCount - 1);

    final orderedIndices = [
      for (var i = 0; i < totalEpisodes; i++)
        _reverseEpisodes ? totalEpisodes - 1 - i : i,
    ];
    final start = safeSegment * _episodePageSize;
    final end = (start + _episodePageSize).clamp(0, totalEpisodes);
    final visibleIndices = orderedIndices.sublist(start, end);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isMovie ? '播放版本与线路' : '选集播放（共 $totalEpisodes 集）',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (!isMovie && totalEpisodes > 1)
                TvFocusFrame(
                  radius: 8,
                  child: TextButton.icon(
                    onPressed: () => setState(
                      () => _reverseEpisodes = !_reverseEpisodes,
                    ),
                    icon: Icon(
                      _reverseEpisodes
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 16,
                    ),
                    label: Text(_reverseEpisodes ? '倒序' : '正序'),
                  ),
                ),
              if (canDownload)
                TvFocusFrame(
                  radius: 8,
                  child: TextButton.icon(
                    onPressed: () => showAdaptiveBottomSheet<void>(
                      context: context,
                      builder: (context) => DownloadEpisodeSheet(
                        road: safeRoadIndex,
                        target: target,
                      ),
                    ),
                    icon: const Icon(Icons.download_rounded, size: 17),
                    label: const Text('缓存'),
                  ),
                ),
            ],
          ),
          if (roads.length > 1) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < roads.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TvFocusFrame(
                        radius: 8,
                        child: ChoiceChip(
                          label: Text(
                            '${roads[i].name} (${roads[i].episodes.length})',
                          ),
                          selected: i == safeRoadIndex,
                          showCheckmark: false,
                          onSelected: (_) => setState(() {
                            _roadIndex = i;
                            _episodeSegment = 0;
                          }),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (segmentCount > 1) ...[
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var seg = 0; seg < segmentCount; seg++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TvFocusFrame(
                        radius: 8,
                        child: ChoiceChip(
                          label: Text(
                            '${seg * _episodePageSize + 1}-${((seg + 1) * _episodePageSize).clamp(1, totalEpisodes)}',
                          ),
                          selected: seg == safeSegment,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) =>
                              setState(() => _episodeSegment = seg),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (road.episodes.isEmpty)
            Text(
              '当前线路暂无可用剧集。',
              style: TextStyle(color: tokens.textSecondary),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final index in visibleIndices)
                  _DetailEpisodeActions(
                    title: road.episodes[index].title,
                    download: downloads[road.episodes[index].url],
                    enabled: !_loading,
                    onPlay: () => _play(safeRoadIndex, index),
                    onDownload: canDownload
                        ? () => enqueueVisibleEpisodes(
                            target: target,
                            road: safeRoadIndex,
                            episodeNumbers: [index + 1],
                          )
                        : null,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildInfoCards(BuildContext context, KazumiThemeTokens tokens) {
    final rawDesc = _detail?.description ?? '';
    final cleanDesc = rawDesc.isNotEmpty
        ? (html.parseFragment(rawDesc).text ?? '').trim()
        : '';
    final castText = _detail?.castText.trim() ?? '';
    if (cleanDesc.isEmpty && castText.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cleanDesc.isNotEmpty) ...[
            Text(
              '剧情简介',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            if (PlatformEnvironmentService.isTelevision)
              Text(
                cleanDesc,
                style: TextStyle(
                  color: tokens.textSecondary,
                  height: 1.55,
                  fontSize: 14,
                ),
              )
            else
              SelectableText(
                cleanDesc,
                style: TextStyle(
                  color: tokens.textSecondary,
                  height: 1.55,
                  fontSize: 14,
                ),
              ),
          ],
          if (cleanDesc.isNotEmpty && castText.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(color: tokens.hairline, height: 1),
            const SizedBox(height: 16),
          ],
          if (castText.isNotEmpty) ...[
            Text(
              '演职员',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              castText,
              style: TextStyle(
                color: tokens.textSecondary,
                height: 1.45,
                fontSize: 13.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({
    required this.text,
    required this.color,
    required this.background,
  });

  final String text;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _DetailEpisodeActions extends StatelessWidget {
  const _DetailEpisodeActions({
    required this.title,
    required this.enabled,
    required this.onPlay,
    this.download,
    this.onDownload,
  });

  final String title;
  final bool enabled;
  final VoidCallback onPlay;
  final DownloadEpisode? download;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final active = isEpisodeDownloadActive(download);
    final tooltip = switch (download?.status) {
      DownloadStatus.completed => '已缓存',
      DownloadStatus.downloading ||
      DownloadStatus.pending ||
      DownloadStatus.resolving => '正在缓存',
      DownloadStatus.paused => '继续缓存',
      DownloadStatus.failed => '重新缓存',
      _ => '缓存本集',
    };
    final icon = switch (download?.status) {
      DownloadStatus.completed => Icons.download_done_rounded,
      DownloadStatus.downloading ||
      DownloadStatus.pending ||
      DownloadStatus.resolving => Icons.downloading_rounded,
      DownloadStatus.failed => Icons.refresh_rounded,
      _ => Icons.download_rounded,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TvFocusFrame(
          radius: 8,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              backgroundColor: tokens.surface2,
              foregroundColor: tokens.textPrimary,
              side: BorderSide(color: tokens.hairline),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: enabled ? onPlay : null,
            child: Text(title),
          ),
        ),
        if (onDownload != null)
          TvFocusFrame(
            radius: 8,
            child: IconButton(
              tooltip: '$tooltip $title',
              visualDensity: VisualDensity.compact,
              onPressed: enabled && !active ? onDownload : null,
              icon: Icon(
                icon,
                size: 18,
                color: download?.status == DownloadStatus.completed
                    ? tokens.healthy
                    : tokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
