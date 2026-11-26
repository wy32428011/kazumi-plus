import 'dart:math' as math;

import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/source_health_repository.dart';

/// 候选源评分细项与最终得分。
class SourceScoreResult {
  const SourceScoreResult({
    required this.score,
    required this.autoEligible,
    required this.effectiveCdnGroup,
    required this.isSameCdnAsPenalized,
    required this.breakdown,
    this.disqualifyReason = '',
  });

  final double score;
  final bool autoEligible;
  final String effectiveCdnGroup;
  final bool isSameCdnAsPenalized;
  final Map<String, double> breakdown;
  final String disqualifyReason;
}

/// 实测驱动片源自动推荐评分引擎。
///
/// 严格执行公式：
/// `Score = A_avail * (w_res * S_res + w_speed * S_speed + w_stab * S_stab)`
/// `        + B_align + B_pin - P_cdn - P_lazy`
/// 废弃基于静态站点名硬编码的画质置顶，全面由实播分辨率、延迟吞吐、稳定性与跨 CDN 相关性决定排序。
class SourceScoringEngine {
  SourceScoringEngine({
    SourceHealthRepository? healthRepository,
    DateTime Function()? clock,
  }) : _health = healthRepository ?? SourceHealthRepository.instance,
       _clock = clock ?? DateTime.now;

  static final SourceScoringEngine instance = SourceScoringEngine();

  final SourceHealthRepository _health;
  final DateTime Function() _clock;

  static const double cdnCorrelationPenalty = 0.45;
  static const double alignBonus = 0.08;
  static const double camPenalty = 0.30;
  static const double pinBonus = 0.30;
  static const double lazyWebviewPenalty = 0.25;
  static const double antiCrawlerPenalty = 0.35;

  /// 根据档位返回权重 `(wRes, wSpeed, wStab)`。
  static ({double wRes, double wSpeed, double wStab}) weightsFor(
    SourceRecommendationStrategy strategy,
  ) {
    return switch (strategy) {
      SourceRecommendationStrategy.balanced => (
        wRes: 0.42,
        wSpeed: 0.30,
        wStab: 0.28,
      ),
      SourceRecommendationStrategy.qualityFirst => (
        wRes: 0.62,
        wSpeed: 0.18,
        wStab: 0.20,
      ),
      SourceRecommendationStrategy.speedFirst => (
        wRes: 0.22,
        wSpeed: 0.48,
        wStab: 0.30,
      ),
    };
  }

  /// 将像素宽高映射为归一化画质分 `S_res`：
  /// - 4K (≥3840×1440 或 ≥2000p) -> 1.00
  /// - 1440P -> 0.88
  /// - 1080P (≥1920×720 或 ≥1000p) -> 0.78
  /// - 720P -> 0.55
  /// - ≤480P (如猫眼 800×448) -> 0.28
  static double rawResolutionScore(int width, int height) {
    if (width <= 0 || height <= 0) return 0.50;
    final longSide = math.max(width, height);
    final shortSide = math.min(width, height);
    if ((longSide >= 3600 && shortSide >= 1440) || shortSide >= 2000) {
      return 1.00;
    }
    if ((longSide >= 2400 && shortSide >= 1000) || shortSide >= 1400) {
      return 0.88;
    }
    if ((longSide >= 1800 && shortSide >= 720) || shortSide >= 1000) {
      return 0.78;
    }
    if ((longSide >= 1200 && shortSide >= 480) || shortSide >= 680) {
      return 0.55;
    }
    return 0.28;
  }

  /// 计算速度分 `S_speed`：
  /// `0.6 * clamp(1 - log2(max(ttfbMs, 200)/200)/5.0, 0, 1) + 0.4 * clamp(throughputKbps/8000, 0, 1)`
  static double computeSpeedScore({
    double? ttfbMs,
    double? throughputKbps,
  }) {
    final double ttfbScore;
    if (ttfbMs != null && ttfbMs > 0) {
      final ratio = math.max(ttfbMs, 200.0) / 200.0;
      final log2Val = math.log(ratio) / math.ln2;
      ttfbScore = (1.0 - log2Val / 5.0).clamp(0.0, 1.0);
    } else {
      ttfbScore = 0.50;
    }

    final double throughputScore;
    if (throughputKbps != null && throughputKbps > 0) {
      throughputScore = (throughputKbps / 8000.0).clamp(0.0, 1.0);
    } else {
      throughputScore = 0.50;
    }

    return 0.6 * ttfbScore + 0.4 * throughputScore;
  }

  /// 计算稳定度分 `S_stab`：`startupSuccessRate * exp(-0.35 * stallRatePer10Min)`。
  static double computeStabilityScore({
    required double startupSuccessRate,
    required double stallRatePer10Min,
  }) {
    final rate = startupSuccessRate.clamp(0.0, 1.0);
    final stall = math.max(0.0, stallRatePer10Min);
    return (rate * math.exp(-0.35 * stall)).clamp(0.0, 1.0);
  }

  /// 对单个 [MediaCandidate] 计算实测综合评分。
  SourceScoreResult scoreCandidate(
    MediaCandidate candidate, {
    required MediaKind kind,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    Set<String> penalizedCdnGroups = const {},
    bool isExactEpisodeAligned = false,
    bool isDisabled = false,
    DateTime? now,
  }) {
    final ts = now ?? _clock();
    final identityKey = candidate.ruleId.isNotEmpty
        ? candidate.ruleId
        : candidate.sourceName;
    final health = _health.bestAvailableHealthFor(identityKey, kind);
    final effectiveCdnGroup = candidate.cdnGroup.isNotEmpty
        ? candidate.cdnGroup
        : (health?.lastCdnGroup ?? '');

    // 1. A_avail
    double avail = 1.0;
    var autoEligible = true;
    var disqualifyReason = '';

    if (isDisabled || candidate.probeStatus == CandidateProbeStatus.disabled) {
      avail = 0.0;
      autoEligible = false;
      disqualifyReason = '已禁用';
    } else if (candidate.probeStatus == CandidateProbeStatus.captchaRequired ||
        _health.isSourceInCaptchaCooldown(identityKey, kind, now: ts)) {
      avail = 0.0;
      autoEligible = false;
      disqualifyReason = '需人工验证（冷却 30 分钟）';
    } else if (candidate.probeStatus == CandidateProbeStatus.circuitOpen ||
        (health != null && health.isCircuitOpen(ts))) {
      avail = 0.0;
      autoEligible = false;
      disqualifyReason = '熔断冷却中';
    } else if (candidate.probeStatus == CandidateProbeStatus.failed) {
      avail = 0.0;
      autoEligible = false;
      disqualifyReason = candidate.lastError.isNotEmpty
          ? candidate.lastError
          : '本次探活失败';
    } else if (health != null && health.isHalfOpen(ts)) {
      avail = 0.35;
    }

    // 2. S_res（本次 mpv 解码 ×1.0 > 探针 M3U8 RESOLUTION ×0.90 > 历史 mpv 中位数 ×0.85 > 中性 0.50）
    double sRes = 0.50;
    final currentProfile = candidate.streamProfile;
    if (currentProfile != null &&
        currentProfile.width > 0 &&
        currentProfile.height > 0) {
      final raw = rawResolutionScore(
        currentProfile.width,
        currentProfile.height,
      );
      final multiplier =
          currentProfile.provenance == StreamProfileProvenance.mpvTrackList
          ? 1.00
          : 0.90;
      sRes = (raw * multiplier).clamp(0.0, 1.0);
    } else if (health != null && health.hasVerifiedResolution) {
      final raw = rawResolutionScore(
        health.medianWidth!,
        health.medianHeight!,
      );
      sRes = (raw * 0.85).clamp(0.0, 1.0);
    }

    // 3. S_speed
    final effectiveTtfb =
        candidate.ttfbMs?.toDouble() ?? health?.ewmaTtfbMs;
    final effectiveThroughput =
        candidate.throughputKbps?.toDouble() ?? health?.ewmaThroughputKbps;
    final sSpeed = computeSpeedScore(
      ttfbMs: effectiveTtfb,
      throughputKbps: effectiveThroughput,
    );

    // 4. S_stab
    final sStab = computeStabilityScore(
      startupSuccessRate: health?.startupSuccessRate ?? 0.85,
      stallRatePer10Min: health?.stallRatePer10Min ?? 0.0,
    );

    // 5. B_align & B_pin
    double bAlign = 0.0;
    if (isExactEpisodeAligned) {
      bAlign += alignBonus;
    }
    if (candidate.richMeta.isCamOrTs) {
      bAlign -= camPenalty;
    }
    final bPin = candidate.isPinned ? pinBonus : 0.0;

    // 6. P_cdn（会话内失败 CDN 或健康库近期降级 CDN 均施加 -0.45 惩罚）
    final cdnHealth = effectiveCdnGroup.isEmpty
        ? null
        : _health.cdnHealthFor(effectiveCdnGroup);
    final isSameCdnAsPenalized =
        effectiveCdnGroup.isNotEmpty &&
        penalizedCdnGroups.contains(effectiveCdnGroup);
    final isCdnDegraded =
        isSameCdnAsPenalized || (cdnHealth?.isDegraded(ts) == true);
    final pCdn = isCdnDegraded ? cdnCorrelationPenalty : 0.0;

    // 7. P_lazy
    double pLazy = 0.0;
    if (candidate.isLazyWebview) {
      pLazy += lazyWebviewPenalty;
    }
    if (candidate.hasAntiCrawler) {
      pLazy += antiCrawlerPenalty;
    }

    final weights = weightsFor(strategy);
    final coreScore =
        avail *
        (weights.wRes * sRes + weights.wSpeed * sSpeed + weights.wStab * sStab);
    final totalScore = autoEligible
        ? (coreScore + bAlign + bPin - pCdn - pLazy)
        : -1.0;

    return SourceScoreResult(
      score: totalScore,
      autoEligible: autoEligible,
      effectiveCdnGroup: effectiveCdnGroup,
      isSameCdnAsPenalized: isSameCdnAsPenalized,
      disqualifyReason: disqualifyReason,
      breakdown: {
        'avail': avail,
        'res': sRes,
        'speed': sSpeed,
        'stab': sStab,
        'align': bAlign,
        'pin': bPin,
        'cdnPenalty': -pCdn,
        'lazyPenalty': -pLazy,
      },
    );
  }

  /// 对整组候选重新打分并按降序排列（不可自动参选者沉底）。
  List<MediaCandidate> rankCandidates(
    List<MediaCandidate> candidates, {
    required MediaKind kind,
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    Set<String> penalizedCdnGroups = const {},
    String activeCdnGroup = '',
    bool Function(MediaCandidate candidate)? isExactEpisodeAligned,
    DateTime? now,
  }) {
    final ts = now ?? _clock();
    final scored = <(MediaCandidate, SourceScoreResult)>[];

    for (final candidate in candidates) {
      final result = scoreCandidate(
        candidate,
        kind: kind,
        strategy: strategy,
        penalizedCdnGroups: penalizedCdnGroups,
        isExactEpisodeAligned: isExactEpisodeAligned?.call(candidate) ?? false,
        now: ts,
      );
      var status = candidate.probeStatus;
      if (status == CandidateProbeStatus.idle ||
          status == CandidateProbeStatus.ready) {
        final identityKey = candidate.ruleId.isNotEmpty
            ? candidate.ruleId
            : candidate.sourceName;
        final health = _health.bestAvailableHealthFor(identityKey, kind);
        if (_health.isSourceInCaptchaCooldown(identityKey, kind, now: ts)) {
          status = CandidateProbeStatus.captchaRequired;
        } else if (health != null && health.isCircuitOpen(ts)) {
          status = CandidateProbeStatus.circuitOpen;
        }
      }

      final sameAsActive =
          activeCdnGroup.isNotEmpty &&
          result.effectiveCdnGroup.isNotEmpty &&
          result.effectiveCdnGroup == activeCdnGroup;

      scored.add((
        candidate.copyWith(
          score: result.score,
          scoreBreakdown: result.breakdown,
          cdnGroup: result.effectiveCdnGroup,
          probeStatus: status,
          isSameCdnAsActive: sameAsActive,
          lastError: candidate.lastError.isNotEmpty
              ? candidate.lastError
              : result.disqualifyReason,
        ),
        result,
      ));
    }

    scored.sort((a, b) {
      if (a.$2.autoEligible != b.$2.autoEligible) {
        return a.$2.autoEligible ? -1 : 1;
      }
      final diff = b.$1.score.compareTo(a.$1.score);
      if (diff != 0) return diff;
      return a.$1.ruleId.compareTo(b.$1.ruleId);
    });

    return [for (final item in scored) item.$1];
  }

  /// 为 `RuleMediaCatalogService.setScoreProvider` 或动漫 `SourceSheet` 直接按插件打分。
  double scorePlugin(
    Plugin plugin,
    MediaKind kind, {
    SourceRecommendationStrategy strategy =
        SourceRecommendationStrategy.balanced,
    Set<String> penalizedCdnGroups = const {},
    DateTime? now,
  }) {
    final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
    final synthetic = MediaCandidate(
      summary: MediaSummary(
        ref: MediaRef.source(
          kind: kind,
          ruleId: identityKey,
          id: identityKey,
        ),
        title: plugin.name,
        detailSource: plugin.baseUrl,
        sourceName: plugin.name,
      ),
      isLazyWebview:
          plugin.searchMode != RuleMode.api && !plugin.useNativePlayer,
      hasAntiCrawler: plugin.antiCrawlerConfig.enabled,
    );
    return scoreCandidate(
      synthetic,
      kind: kind,
      strategy: strategy,
      penalizedCdnGroups: penalizedCdnGroups,
      isDisabled: !plugin.enabled,
      now: now,
    ).score;
  }

  /// 从已排序候选中挑选来自不同 `cdnGroup` 的 Top-K（Tier-0 探针与 K=3 锚点共用）。
  static List<MediaCandidate> selectDiverseTopK(
    List<MediaCandidate> rankedCandidates, {
    required int k,
  }) {
    if (k <= 0 || rankedCandidates.isEmpty) return const [];
    final eligible = rankedCandidates.where((c) => c.isAutoEligible).toList();
    if (eligible.isEmpty) return const [];

    final selected = <MediaCandidate>[];
    final seenCdns = <String>{};
    final deferred = <MediaCandidate>[];

    for (final candidate in eligible) {
      if (selected.length >= k) break;
      final cdn = candidate.cdnGroup;
      if (cdn.isEmpty || seenCdns.add(cdn)) {
        selected.add(candidate);
      } else {
        deferred.add(candidate);
      }
    }

    for (final candidate in deferred) {
      if (selected.length >= k) break;
      selected.add(candidate);
    }

    return selected;
  }
}
