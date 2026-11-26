import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/rule_media_catalog_service.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/media/work_cluster_matcher.dart';

/// 单次并发扇出检索的结果摘要。
class FanOutSearchSummary {
  const FanOutSearchSummary({
    required this.clusters,
    required this.searchedSources,
    required this.succeededSources,
    required this.captchaPlugins,
    required this.failedSources,
  });

  final List<WorkCluster> clusters;
  final int searchedSources;
  final int succeededSources;
  final List<Plugin> captchaPlugins;
  final Map<String, String> failedSources;
}

/// 按需全源扇出补全与跨源聚合检索服务。
///
/// 职责：
/// - 统一跳过已熔断与处于 30 分钟 CAPTCHA 冷却期的规则（严守反爬合规红线）；
/// - 对单源设置软超时（默认 3.5s），通过 `SourceTrafficGuard` 统一限速；
/// - 将所有命中项送入严苛防误并 `WorkClusterMatcher` 与实测评分 `SourceScoringEngine`。
class SourceFanOutService {
  SourceFanOutService({
    required MediaCatalogService catalog,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
    VodPayloadCache? payloadCache,
    this.perSourceTimeout = const Duration(milliseconds: 3500),
  }) : _catalog = catalog,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance,
       _payloadCache = payloadCache ?? VodPayloadCache.instance;

  final MediaCatalogService _catalog;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;
  final VodPayloadCache _payloadCache;
  final WorkClusterMatcher _matcher = const WorkClusterMatcher();
  final Duration perSourceTimeout;

  List<WorkCluster> _clusterAndRank(
    List<MediaCandidate> candidates, {
    required SourceRecommendationStrategy strategy,
  }) {
    final raw = _matcher.cluster(candidates);
    return raw
        .map((c) => _rerankCluster(c, strategy: strategy))
        .toList(growable: false);
  }

  /// 在指定频道内对所有健康来源执行聚合搜索并输出防误并 [WorkCluster] 列表。
  Future<FanOutSearchSummary> searchClustered({
    required MediaKind kind,
    required String keyword,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    CancelToken? cancelToken,
    void Function(FanOutSearchSummary partial)? onProgress,
  }) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return const FanOutSearchSummary(
        clusters: [],
        searchedSources: 0,
        succeededSources: 0,
        captchaPlugins: [],
        failedSources: {},
      );
    }

    final providers = _catalog.providersFor(kind);
    final now = DateTime.now();
    final activeProviders = <MediaProvider>[];
    final captchaPlugins = <Plugin>[];
    final failedSources = <String, String>{};

    for (final provider in providers) {
      final identityKey = SourceHealthRepository.pluginIdentityKey(
        provider.plugin,
      );
      if (_health.isSourceInCaptchaCooldown(identityKey, kind, now: now)) {
        captchaPlugins.add(provider.plugin);
        continue;
      }
      final health = _health.healthFor(identityKey, kind);
      if (health != null && health.isCircuitOpen(now)) {
        failedSources[provider.plugin.name] = '熔断冷却中';
        continue;
      }
      activeProviders.add(provider);
    }

    final collected = <MediaCandidate>[];
    var searched = 0;
    var succeeded = 0;

    FanOutSearchSummary buildSnapshot() {
      final clusters = _clusterAndRank(collected, strategy: strategy);
      return FanOutSearchSummary(
        clusters: clusters,
        searchedSources: searched,
        succeededSources: succeeded,
        captchaPlugins: List.unmodifiable(captchaPlugins),
        failedSources: Map.unmodifiable(failedSources),
      );
    }

    await Future.wait(
      activeProviders.map((provider) async {
        if (cancelToken?.isCancelled == true) return;
        final identityKey = SourceHealthRepository.pluginIdentityKey(
          provider.plugin,
        );
        final localCancel = CancelToken();
        cancelToken?.whenCancel.then((err) {
          if (!localCancel.isCancelled) localCancel.cancel(err);
        });
        final sw = Stopwatch()..start();
        try {
          final page = await provider
              .searchMedia(kind, trimmed, page: 1, cancelToken: localCancel)
              .timeout(perSourceTimeout);
          sw.stop();
          if (cancelToken?.isCancelled == true) return;

          succeeded++;
          _health.recordSuccess(
            pluginIdentityKey: identityKey,
            kind: kind,
            ttfbMs: sw.elapsedMilliseconds,
          );
          for (final item in page.items) {
            collected.add(_buildCandidate(item, provider.plugin));
          }
        } on CaptchaRequiredException {
          sw.stop();
          _health.recordFailure(
            pluginIdentityKey: identityKey,
            kind: kind,
            failureKind: SourceFailureKind.captchaRequired,
            message: '搜索触发人工验证',
          );
          if (!captchaPlugins.any((p) => p.ruleId == provider.plugin.ruleId)) {
            captchaPlugins.add(provider.plugin);
          }
        } on TimeoutException {
          sw.stop();
          if (!localCancel.isCancelled) localCancel.cancel('soft timeout');
          failedSources[provider.plugin.name] = '搜索超时';
        } catch (error) {
          sw.stop();
          if (cancelToken?.isCancelled == true) return;
          if (error is DioException &&
              CancelToken.isCancel(error)) {
            return;
          }
          failedSources[provider.plugin.name] = '$error';
        } finally {
          searched++;
          if (cancelToken?.isCancelled != true && onProgress != null) {
            onProgress(buildSnapshot());
          }
        }
      }),
    );

    return buildSnapshot();
  }

  /// 为指定作品（已有部分候选或单条 `MediaSummary`）按需后台补全其余健康源与 `4K-AV`。
  Future<WorkCluster> enrichWorkCluster({
    required WorkCluster seedCluster,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    CancelToken? cancelToken,
    void Function(WorkCluster updated)? onUpdate,
  }) async {
    final kind = seedCluster.kind;
    final queryTitle = MediaTextNormalizer.cleanQueryTitle(
      seedCluster.primaryTitle,
    ).trim();
    if (queryTitle.isEmpty) return seedCluster;

    final existingRuleIds = {
      for (final c in seedCluster.candidates) c.ruleId,
      for (final sibling in seedCluster.siblingDubClusters)
        for (final c in sibling.candidates) c.ruleId,
    };

    final providers = _catalog.providersFor(kind);
    final now = DateTime.now();
    final targetProviders = <MediaProvider>[];
    for (final provider in providers) {
      if (existingRuleIds.contains(provider.ruleId)) continue;
      final identityKey = SourceHealthRepository.pluginIdentityKey(
        provider.plugin,
      );
      if (_health.isSourceInCaptchaCooldown(identityKey, kind, now: now)) {
        continue;
      }
      final health = _health.healthFor(identityKey, kind);
      if (health != null && health.isCircuitOpen(now)) continue;
      targetProviders.add(provider);
    }

    if (targetProviders.isEmpty) {
      return _rerankCluster(seedCluster, strategy: strategy);
    }

    final pool = <MediaCandidate>[
      ...seedCluster.candidates,
      for (final sib in seedCluster.siblingDubClusters) ...sib.candidates,
    ];
    final seenRefKeys = pool.map((c) => c.refKey).toSet();

    WorkCluster extractMatched() {
      final clusters = _clusterAndRank(pool, strategy: strategy);
      final seedRefKeys = seedCluster.memberRefKeys;
      for (final cluster in clusters) {
        if (cluster.candidates.any((c) => seedRefKeys.contains(c.refKey))) {
          return cluster;
        }
      }
      return _rerankCluster(seedCluster, strategy: strategy);
    }

    await Future.wait(
      targetProviders.map((provider) async {
        if (cancelToken?.isCancelled == true) return;
        final identityKey = SourceHealthRepository.pluginIdentityKey(
          provider.plugin,
        );
        final localCancel = CancelToken();
        cancelToken?.whenCancel.then((err) {
          if (!localCancel.isCancelled) localCancel.cancel(err);
        });
        try {
          final page = await provider
              .searchMedia(kind, queryTitle, page: 1, cancelToken: localCancel)
              .timeout(perSourceTimeout);
          if (cancelToken?.isCancelled == true) return;

          var added = false;
          for (final item in page.items) {
            if (seenRefKeys.add(item.ref.key)) {
              pool.add(_buildCandidate(item, provider.plugin));
              added = true;
            }
          }
          if (added && onUpdate != null && cancelToken?.isCancelled != true) {
            onUpdate(extractMatched());
          }
        } on CaptchaRequiredException {
          _health.recordFailure(
            pluginIdentityKey: identityKey,
            kind: kind,
            failureKind: SourceFailureKind.captchaRequired,
            message: '补源触发人工验证',
          );
        } catch (_) {
          if (!localCancel.isCancelled) localCancel.cancel('fanout error');
        }
      }),
    );

    return extractMatched();
  }

  /// 将单条 [MediaSummary] 包装成最小 [WorkCluster]（用于旧入口/单源视图无缝升级）。
  WorkCluster seedClusterFromSummary(
    MediaSummary summary, {
    MediaDetail? detail,
    SourcePlaylist? playlist,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
  }) {
    final provider = _catalog.providerById(summary.ref.ruleId);
    final candidate = _buildCandidate(
      summary,
      provider?.plugin,
      detail: detail,
      playlist: playlist,
    );
    final clusters = _clusterAndRank([candidate], strategy: strategy);
    return clusters.first;
  }

  MediaCandidate _buildCandidate(
    MediaSummary summary,
    Plugin? plugin, {
    MediaDetail? detail,
    SourcePlaylist? playlist,
  }) {
    final cached = _payloadCache.get(summary.ref);
    final rich = cached?.richMeta ??
        RichMediaMeta(
          dubVariant: MediaTextNormalizer.detectDubVariant(
            title: summary.title,
            region: summary.region,
          ),
          seasonToken: MediaTextNormalizer.extractExplicitSeasonToken(
            summary.title,
          ),
          isCamOrTs: MediaTextNormalizer.detectCamOrTs(
            summary.title,
            statusText: summary.statusText,
          ),
        );
    final identityKey = plugin != null
        ? SourceHealthRepository.pluginIdentityKey(plugin)
        : summary.ref.ruleId;
    final health = _health.bestAvailableHealthFor(
      identityKey,
      summary.ref.kind,
    );

    return MediaCandidate(
      summary: summary,
      richMeta: rich,
      detail: detail ?? cached?.detail,
      playlist: playlist ?? cached?.playlist,
      ttfbMs: health?.ewmaTtfbMs?.round(),
      throughputKbps: health?.ewmaThroughputKbps?.round(),
      cdnGroup: health?.lastCdnGroup ?? '',
      streamProfile: health?.lastVerifiedProfile,
      isLazyWebview:
          plugin != null &&
          plugin.searchMode != RuleMode.api &&
          !plugin.useNativePlayer,
      hasAntiCrawler: plugin?.antiCrawlerConfig.enabled ?? false,
    );
  }

  WorkCluster _rerankCluster(
    WorkCluster cluster, {
    required SourceRecommendationStrategy strategy,
  }) {
    final ranked = _scoring.rankCandidates(
      cluster.candidates,
      kind: cluster.kind,
      strategy: strategy,
    );
    final rankedSiblings = cluster.siblingDubClusters
        .map((sib) => _rerankCluster(sib, strategy: strategy))
        .toList(growable: false);
    return cluster.copyWith(
      candidates: ranked,
      siblingDubClusters: rankedSiblings,
    );
  }
}

/// 将 [RuleMediaCatalogService] 绑定到实时健康评分引擎的便捷入口。
void bindCatalogToHealthScoring(
  MediaCatalogService catalog, {
  SourceScoringEngine? scoringEngine,
}) {
  if (catalog is RuleMediaCatalogService) {
    final engine = scoringEngine ?? SourceScoringEngine.instance;
    catalog.setScoreProvider(
      (plugin, kind) => engine.scorePlugin(plugin, kind),
    );
  }
}
