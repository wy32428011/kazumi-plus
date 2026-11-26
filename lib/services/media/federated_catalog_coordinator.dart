import 'dart:async';

import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/media/work_cluster_matcher.dart';

/// 面向用户的语义分类（屏蔽底层各采集站互不相通的分类 ID）。
class SemanticMediaCategory {
  const SemanticMediaCategory({
    required this.id,
    required this.label,
    required this.keywords,
  });

  final String id;
  final String label;
  final List<String> keywords;

  static const all = SemanticMediaCategory(
    id: 'all',
    label: '全部',
    keywords: [],
  );

  static const List<SemanticMediaCategory> movieCategories = [
    all,
    SemanticMediaCategory(id: 'action', label: '动作', keywords: ['动作']),
    SemanticMediaCategory(id: 'scifi', label: '科幻', keywords: ['科幻']),
    SemanticMediaCategory(
      id: 'suspense',
      label: '悬疑惊悚',
      keywords: ['悬疑', '惊悚', '犯罪'],
    ),
    SemanticMediaCategory(id: 'comedy', label: '喜剧', keywords: ['喜剧']),
    SemanticMediaCategory(id: 'drama', label: '剧情', keywords: ['剧情']),
    SemanticMediaCategory(id: 'romance', label: '爱情', keywords: ['爱情']),
    SemanticMediaCategory(id: 'horror', label: '恐怖', keywords: ['恐怖']),
    SemanticMediaCategory(id: 'war', label: '战争', keywords: ['战争']),
    SemanticMediaCategory(
      id: 'documentary',
      label: '纪录片',
      keywords: ['纪录', '记录'],
    ),
    SemanticMediaCategory(
      id: 'animation',
      label: '动画电影',
      keywords: ['动画', '动漫电影'],
    ),
  ];

  static const List<SemanticMediaCategory> tvCategories = [
    all,
    SemanticMediaCategory(
      id: 'cn',
      label: '国产剧',
      keywords: ['国产', '大陆', '内地'],
    ),
    SemanticMediaCategory(
      id: 'us_eu',
      label: '欧美剧',
      keywords: ['欧美', '美剧', '英剧'],
    ),
    SemanticMediaCategory(
      id: 'jp_kr',
      label: '日韩剧',
      keywords: ['日剧', '韩剧', '日韩', '日本', '韩国'],
    ),
    SemanticMediaCategory(
      id: 'hk_tw',
      label: '港台剧',
      keywords: ['港剧', '台剧', '港台', '香港', '台湾'],
    ),
    SemanticMediaCategory(
      id: 'sea',
      label: '海外剧',
      keywords: ['泰剧', '海外', '新马'],
    ),
    SemanticMediaCategory(
      id: 'short',
      label: '短剧',
      keywords: ['短剧', '微剧'],
    ),
  ];

  static List<SemanticMediaCategory> forKind(MediaKind kind) => switch (kind) {
    MediaKind.movie => movieCategories,
    MediaKind.tv => tvCategories,
    MediaKind.anime => const [all],
  };

  static SemanticMediaCategory byId(MediaKind kind, String? id) {
    final list = forKind(kind);
    if (id == null || id.isEmpty) return list.first;
    return list.firstWhere((c) => c.id == id, orElse: () => list.first);
  }
}

/// 单页联邦发现结果。
class FederatedCatalogPage {
  const FederatedCatalogPage({
    required this.clusters,
    required this.anchorNames,
    required this.hasMore,
    required this.succeededAnchors,
    required this.totalAnchors,
    required this.captchaPlugins,
  });

  final List<WorkCluster> clusters;
  final List<String> anchorNames;
  final bool hasMore;
  final int succeededAnchors;
  final int totalAnchors;
  final List<Plugin> captchaPlugins;
}

/// K=3 动态跨 CDN 锚点联邦发现协调器 + 电影频道 `4K-AV` 独立异步补充轨。
///
/// 绝不对全部 14 源并发轰炸，而是按健康分与 CDN 多样性动态挑选 K=3 个独立锚点源拉取，
/// 经 `WorkClusterMatcher` 防误并聚簇与 `SourceScoringEngine` 排序后输出去重作品墙。
class FederatedCatalogCoordinator {
  FederatedCatalogCoordinator({
    required MediaCatalogService catalog,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
    VodPayloadCache? payloadCache,
    this.anchorCount = 3,
    this.anchorTimeout = const Duration(milliseconds: 5500),
  }) : _catalog = catalog,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance,
       _payloadCache = payloadCache ?? VodPayloadCache.instance;

  final MediaCatalogService _catalog;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;
  final VodPayloadCache _payloadCache;
  final WorkClusterMatcher _matcher = const WorkClusterMatcher();
  final int anchorCount;
  final Duration anchorTimeout;

  /// 冷启动默认 3 个实测 1080P 且 CDN 独立的锚点（已移除低清猫眼与断链魔都）。
  static const List<String> coldStartPreferredAnchors = [
    'kazumi-plus.iqiyi',
    'kazumi-plus.zy360',
    'kazumi-plus.hongniu',
  ];

  static const String fourKavRuleId = 'kazumi-plus.4kav';

  /// 缓存各源的分类列表，避免翻页重复拉分类接口。
  final Map<String, List<MediaCategory>> _categoryCache = {};

  /// 按健康状态 + 跨 CDN 多样性动态选择 K=3 个锚点（排除已熔断/CAPTCHA 冷却/`4kav` 独立轨）。
  List<MediaProvider> selectAnchors(MediaKind kind, {DateTime? now}) {
    final clockNow = now ?? DateTime.now();
    final providers = _catalog
        .providersFor(kind)
        .where((p) => p.ruleId != fourKavRuleId)
        .toList();
    if (providers.isEmpty) return const [];

    final healthy = <MediaProvider>[];
    for (final provider in providers) {
      final identityKey = SourceHealthRepository.pluginIdentityKey(
        provider.plugin,
      );
      if (_health.isSourceInCaptchaCooldown(identityKey, kind, now: clockNow)) {
        continue;
      }
      final health = _health.healthFor(identityKey, kind);
      if (health != null && health.isCircuitOpen(clockNow)) continue;
      healthy.add(provider);
    }
    final pool = healthy.isNotEmpty ? healthy : providers;

    // 排序：实测综合分优先；冷启动无实测记录时优先选 3 个验证过的独立 1080P 锚点。
    pool.sort((a, b) {
      final keyA = SourceHealthRepository.pluginIdentityKey(a.plugin);
      final keyB = SourceHealthRepository.pluginIdentityKey(b.plugin);
      final hasHistA = _health.healthFor(keyA, kind) != null;
      final hasHistB = _health.healthFor(keyB, kind) != null;
      if (!hasHistA && !hasHistB) {
        final idxA = coldStartPreferredAnchors.indexOf(a.ruleId);
        final idxB = coldStartPreferredAnchors.indexOf(b.ruleId);
        final rankA = idxA < 0 ? 100 : idxA;
        final rankB = idxB < 0 ? 100 : idxB;
        if (rankA != rankB) return rankA.compareTo(rankB);
      }
      final scoreA = _scoring.scorePlugin(a.plugin, kind, now: clockNow);
      final scoreB = _scoring.scorePlugin(b.plugin, kind, now: clockNow);
      final diff = scoreB.compareTo(scoreA);
      if (diff != 0) return diff;
      return a.ruleId.compareTo(b.ruleId);
    });

    // 跨 CDN 多样性筛选（同一 cdnGroup 不占 2 个锚点位）。
    final selected = <MediaProvider>[];
    final seenCdns = <String>{};
    final deferred = <MediaProvider>[];
    for (final provider in pool) {
      if (selected.length >= anchorCount) break;
      final identityKey = SourceHealthRepository.pluginIdentityKey(
        provider.plugin,
      );
      final cdn = _health.healthFor(identityKey, kind)?.lastCdnGroup ?? '';
      if (cdn.isEmpty || seenCdns.add(cdn)) {
        selected.add(provider);
      } else {
        deferred.add(provider);
      }
    }
    for (final provider in deferred) {
      if (selected.length >= anchorCount) break;
      selected.add(provider);
    }
    return selected;
  }

  /// 拉取单页联邦聚合目录。
  Future<FederatedCatalogPage> loadFederatedPage({
    required MediaKind kind,
    required SemanticMediaCategory category,
    required int page,
    MediaSort sort = MediaSort.latest,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    CancelToken? cancelToken,
  }) async {
    final anchors = selectAnchors(kind);
    if (anchors.isEmpty) {
      return const FederatedCatalogPage(
        clusters: [],
        anchorNames: [],
        hasMore: false,
        succeededAnchors: 0,
        totalAnchors: 0,
        captchaPlugins: [],
      );
    }

    final collected = <MediaCandidate>[];
    final captchaPlugins = <Plugin>[];
    var succeeded = 0;
    var anyHasMore = false;

    await Future.wait(
      anchors.map((provider) async {
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
          final categoryId = await _resolveCategoryId(
            provider,
            kind,
            category,
            cancelToken: localCancel,
          );
          if (cancelToken?.isCancelled == true) return;
          final result = await provider
              .queryDiscover(
                kind,
                page: page,
                categoryId: categoryId,
                sort: sort,
                cancelToken: localCancel,
              )
              .timeout(anchorTimeout);
          sw.stop();
          if (cancelToken?.isCancelled == true) return;
          succeeded++;
          if (result.hasMore) anyHasMore = true;
          _health.recordSuccess(
            pluginIdentityKey: identityKey,
            kind: kind,
            ttfbMs: sw.elapsedMilliseconds,
          );
          for (final summary in result.items) {
            collected.add(_buildCandidate(summary, provider.plugin));
          }
        } on CaptchaRequiredException {
          sw.stop();
          _health.recordFailure(
            pluginIdentityKey: identityKey,
            kind: kind,
            failureKind: SourceFailureKind.captchaRequired,
            message: '联邦发现触发人工验证',
          );
          captchaPlugins.add(provider.plugin);
        } catch (_) {
          sw.stop();
          if (!localCancel.isCancelled) localCancel.cancel('anchor error');
        }
      }),
    );

    final rawClusters = _matcher.cluster(collected);
    final rankedClusters = rawClusters
        .map(
          (cluster) => cluster.copyWith(
            candidates: _scoring.rankCandidates(
              cluster.candidates,
              kind: kind,
              strategy: strategy,
            ),
            siblingDubClusters: [
              for (final sib in cluster.siblingDubClusters)
                sib.copyWith(
                  candidates: _scoring.rankCandidates(
                    sib.candidates,
                    kind: kind,
                    strategy: strategy,
                  ),
                ),
            ],
          ),
        )
        .toList();

    // 排序：按用户所选排序稳定输出；latest 下优先保留多源印证与最新更新顺序。
    rankedClusters.sort((a, b) {
      switch (sort) {
        case MediaSort.rating:
          final ra = double.tryParse(a.ratingText) ?? 0;
          final rb = double.tryParse(b.ratingText) ?? 0;
          if (rb != ra) return rb.compareTo(ra);
          return b.candidates.length.compareTo(a.candidates.length);
        case MediaSort.yearDesc:
          final ya = int.tryParse(a.year) ?? 0;
          final yb = int.tryParse(b.year) ?? 0;
          if (yb != ya) return yb.compareTo(ya);
          return b.candidates.length.compareTo(a.candidates.length);
        case MediaSort.yearAsc:
          final ya = int.tryParse(a.year) ?? 9999;
          final yb = int.tryParse(b.year) ?? 9999;
          if (ya != yb) return ya.compareTo(yb);
          return b.candidates.length.compareTo(a.candidates.length);
        case MediaSort.title:
          return a.primaryTitle.toLowerCase().compareTo(
            b.primaryTitle.toLowerCase(),
          );
        case MediaSort.latest:
          return 0;
      }
    });

    return FederatedCatalogPage(
      clusters: rankedClusters,
      anchorNames: [for (final p in anchors) p.plugin.name],
      hasMore: anyHasMore,
      succeededAnchors: succeeded,
      totalAnchors: anchors.length,
      captchaPlugins: captchaPlugins,
    );
  }

  /// 独立异步加载 `4K-AV` 精选补充轨（不阻塞首屏目录）。
  Future<List<WorkCluster>> loadFourKavRail({
    required MediaKind kind,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    CancelToken? cancelToken,
  }) async {
    final provider = _catalog.providerById(fourKavRuleId);
    if (provider == null) return const [];
    if (!provider.supportedKinds.contains(kind)) return const [];
    final identityKey = SourceHealthRepository.pluginIdentityKey(
      provider.plugin,
    );
    final now = DateTime.now();
    if (_health.isSourceInCaptchaCooldown(identityKey, kind, now: now)) {
      return const [];
    }
    final health = _health.healthFor(identityKey, kind);
    if (health != null && health.isCircuitOpen(now)) return const [];

    try {
      final page = await provider
          .queryDiscover(kind, page: 1, cancelToken: cancelToken)
          .timeout(const Duration(milliseconds: 6500));
      if (cancelToken?.isCancelled == true) return const [];
      final candidates = [
        for (final item in page.items.take(12))
          _buildCandidate(item, provider.plugin),
      ];
      return _matcher
          .cluster(candidates)
          .map(
            (c) => c.copyWith(
              candidates: _scoring.rankCandidates(
                c.candidates,
                kind: kind,
                strategy: strategy,
              ),
            ),
          )
          .toList(growable: false);
    } on CaptchaRequiredException {
      _health.recordFailure(
        pluginIdentityKey: identityKey,
        kind: kind,
        failureKind: SourceFailureKind.captchaRequired,
        message: '4KAV 补充轨触发人工验证',
      );
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<String?> _resolveCategoryId(
    MediaProvider provider,
    MediaKind kind,
    SemanticMediaCategory semantic, {
    CancelToken? cancelToken,
  }) async {
    if (semantic.id == SemanticMediaCategory.all.id ||
        semantic.keywords.isEmpty) {
      return null;
    }
    final cacheKey = '${provider.ruleId}|${kind.name}';
    var categories = _categoryCache[cacheKey];
    if (categories == null) {
      try {
        categories = await provider
            .queryCategories(kind, cancelToken: cancelToken)
            .timeout(const Duration(milliseconds: 2500));
        _categoryCache[cacheKey] = categories;
      } catch (_) {
        return null;
      }
    }
    for (final keyword in semantic.keywords) {
      for (final cat in categories) {
        if (cat.name.contains(keyword)) {
          return cat.id;
        }
      }
    }
    return null;
  }

  MediaCandidate _buildCandidate(MediaSummary summary, Plugin plugin) {
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
    final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
    final health = _health.bestAvailableHealthFor(
      identityKey,
      summary.ref.kind,
    );

    return MediaCandidate(
      summary: summary,
      richMeta: rich,
      detail: cached?.detail,
      playlist: cached?.playlist,
      ttfbMs: health?.ewmaTtfbMs?.round(),
      throughputKbps: health?.ewmaThroughputKbps?.round(),
      cdnGroup: health?.lastCdnGroup ?? '',
      streamProfile: health?.lastVerifiedProfile,
      isLazyWebview:
          plugin.searchMode != RuleMode.api && !plugin.useNativePlayer,
      hasAntiCrawler: plugin.antiCrawlerConfig.enabled,
    );
  }
}
