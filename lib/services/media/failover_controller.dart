import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/services/media/candidate_probe_orchestrator.dart';
import 'package:kazumi/services/media/playback_stall_monitor.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:media_kit/media_kit.dart' show VideoTrack;

/// 自动容灾执行结果分类。
enum FailoverDecisionKind {
  /// 第 1 阶：同流多变体 HLS 平滑降一档清晰度。
  stepDownQuality,

  /// 第 2 阶（跨 CDN 直连/HLS）、第 3 阶（同 CDN 直连/HLS）或 第 4 阶（WebView 兜底）切换片源。
  switchCandidate,

  /// 2 秒内 2 个独立 CDN 同时底层不可达，判定为本机断网并立即止损。
  localOffline,

  /// 全部可用备选源均已耗尽。
  exhausted,
}

/// 容灾决策结果。
class FailoverDecision {
  const FailoverDecision({
    required this.kind,
    required this.tier,
    this.lowerTrack,
    this.candidate,
    this.probeResult,
    this.reasonText = '',
  });

  final FailoverDecisionKind kind;
  final int tier;
  final VideoTrack? lowerTrack;
  final MediaCandidate? candidate;
  final CandidateProbeResult? probeResult;
  final String reasonText;
}

/// 播中自动容灾顶部非阻塞暗房轻提示条状态（支持一键撤销回原源）。
class FailoverBannerState {
  const FailoverBannerState({
    required this.fromSourceName,
    required this.toSourceName,
    required this.reasonText,
    required this.tier,
    required this.canUndo,
    required this.createdAt,
  });

  final String fromSourceName;
  final String toSourceName;
  final String reasonText;
  final int tier;
  final bool canUndo;
  final DateTime createdAt;

  String get headline => tier == 1
      ? '已自动降档至 $toSourceName'
      : '已切换至 $toSourceName（$reasonText）';
}

/// 四阶渐进单 `mpv` Make-Before-Break 容灾控制器。
///
/// 严守单实例约束，绝不双实例爆显存；所有备选在后台静默探活确认就绪后才移交播放器热切。
class FailoverController {
  FailoverController({
    SourceScoringEngine? scoringEngine,
    CandidateProbeOrchestrator? probeOrchestrator,
    SourceHealthRepository? healthRepository,
    DateTime Function()? clock,
  }) : _scoring = scoringEngine ?? SourceScoringEngine.instance,
       _prober = probeOrchestrator ?? CandidateProbeOrchestrator.instance,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _clock = clock ?? DateTime.now;

  final SourceScoringEngine _scoring;
  final CandidateProbeOrchestrator _prober;
  final SourceHealthRepository _health;
  final DateTime Function() _clock;

  final Set<String> _failedCandidateKeys = {};
  final Set<String> _penalizedCdnGroups = {};
  final Set<String> _steppedDownCandidateKeys = {};
  final List<(String cdn, DateTime at)> _recentNetworkUnreachable = [];

  Set<String> get failedCandidateKeys => Set.unmodifiable(_failedCandidateKeys);
  Set<String> get penalizedCdnGroups => Set.unmodifiable(_penalizedCdnGroups);

  /// 切集或重新开始播放时重置本次会话容灾黑名单。
  void resetForNewEpisode() {
    _failedCandidateKeys.clear();
    _penalizedCdnGroups.clear();
    _steppedDownCandidateKeys.clear();
    _recentNetworkUnreachable.clear();
  }

  /// 用户手动点选某个来源时将其移出本次会话屏蔽集。
  void clearCandidateFailure(String refKey) {
    _failedCandidateKeys.remove(refKey);
  }

  /// 上报底层网络不可达事件，用于检测 2 秒内 2 个独立 CDN 同时断联（本机断网止损）。
  bool recordNetworkUnreachable(String cdnGroup) {
    final now = _clock();
    _recentNetworkUnreachable.removeWhere(
      (entry) => now.difference(entry.$2) > const Duration(seconds: 2),
    );
    if (cdnGroup.isNotEmpty) {
      _recentNetworkUnreachable.add((cdnGroup, now));
    }
    return _recentNetworkUnreachable.map((e) => e.$1).toSet().length >= 2;
  }

  /// 执行四阶渐进容灾决策（支持注入 [targetBuilder] 将候选转换为当前集探活目标）。
  Future<FailoverDecision> resolveNext({
    required MediaKind kind,
    required MediaCandidate currentCandidate,
    required List<MediaCandidate> allCandidates,
    required StallTriggerReason triggerReason,
    required SourceRecommendationStrategy strategy,
    required Future<CandidateProbeTarget?> Function(MediaCandidate candidate)
    targetBuilder,
    List<VideoTrack> currentPlayableTracks = const [],
    String? currentSelectedTrackId,
    bool isConstrainedNetwork = false,
    bool Function()? isCancelled,
  }) async {
    final cancelled = isCancelled ?? () => false;
    final now = _clock();

    final currentCdn = currentCandidate.cdnGroup.isNotEmpty
        ? currentCandidate.cdnGroup
        : (_health
                  .bestAvailableHealthFor(currentCandidate.ruleId, kind)
                  ?.lastCdnGroup ??
              '');

    // 第 1 阶：若当前为播中卡顿/高频再缓冲（非起播黑屏/分片死链）且同流存在更低码率轨道，先平滑降一档。
    if ((triggerReason == StallTriggerReason.sustainedStall ||
            triggerReason == StallTriggerReason.frequentRebuffering) &&
        !_steppedDownCandidateKeys.contains(currentCandidate.refKey) &&
        currentPlayableTracks.length > 1) {
      final lower = _findNextLowerTrack(
        currentPlayableTracks,
        currentSelectedTrackId,
      );
      if (lower != null) {
        _steppedDownCandidateKeys.add(currentCandidate.refKey);
        return FailoverDecision(
          kind: FailoverDecisionKind.stepDownQuality,
          tier: 1,
          lowerTrack: lower,
          reasonText: '原线路波动，已平滑降档',
        );
      }
    }

    // 标记当前候选与当前 CDN 组进入会话惩罚集（-0.45 相关性惩罚）。
    _failedCandidateKeys.add(currentCandidate.refKey);
    if (currentCdn.isNotEmpty) {
      _penalizedCdnGroups.add(currentCdn);
    }

    // 记录遥测：播中卡顿写入 stall，起播黑屏/分片失败写入 failure。
    if (triggerReason == StallTriggerReason.sustainedStall ||
        triggerReason == StallTriggerReason.frequentRebuffering) {
      _health.recordStall(
        pluginIdentityKey: currentCandidate.ruleId,
        kind: kind,
        cdnGroup: currentCdn,
        reason: _triggerLabel(triggerReason),
        now: now,
      );
    } else {
      _health.recordFailure(
        pluginIdentityKey: currentCandidate.ruleId,
        kind: kind,
        failureKind: SourceFailureKind.networkTimeout,
        cdnGroup: currentCdn,
        message: _triggerLabel(triggerReason),
        now: now,
      );
    }

    // 仅筛选同配音版本、未失败、未禁用、非 CAPTCHA 冷却、未熔断的候选。
    final untried = allCandidates
        .where(
          (c) =>
              c.refKey != currentCandidate.refKey &&
              !_failedCandidateKeys.contains(c.refKey) &&
              c.richMeta.dubVariant == currentCandidate.richMeta.dubVariant,
        )
        .toList();

    if (untried.isEmpty) {
      return const FailoverDecision(
        kind: FailoverDecisionKind.exhausted,
        tier: 4,
        reasonText: '暂无更多可用片源',
      );
    }

    final ranked = _scoring.rankCandidates(
      untried,
      kind: kind,
      strategy: strategy,
      penalizedCdnGroups: _penalizedCdnGroups,
      activeCdnGroup: currentCdn,
      now: now,
    );

    final eligible = ranked.where((c) => c.isAutoEligible).toList();
    if (eligible.isEmpty) {
      return const FailoverDecision(
        kind: FailoverDecisionKind.exhausted,
        tier: 4,
        reasonText: '其余片源暂不可用或需人工验证',
      );
    }

    final directCrossCdn = <MediaCandidate>[];
    final directSameCdn = <MediaCandidate>[];
    final webviewFallbacks = <MediaCandidate>[];

    for (final candidate in eligible) {
      if (candidate.isLazyWebview) {
        if (!candidate.hasAntiCrawler) {
          webviewFallbacks.add(candidate);
        }
        continue;
      }
      final sameCdn =
          candidate.cdnGroup.isNotEmpty &&
          _penalizedCdnGroups.contains(candidate.cdnGroup);
      if (sameCdn) {
        directSameCdn.add(candidate);
      } else {
        directCrossCdn.add(candidate);
      }
    }

    final batchLimit = isConstrainedNetwork ? 2 : 3;

    // 第 2 阶：优先后台探活「异 CDN」直连/HLS 候选（Make-Before-Break）。
    if (directCrossCdn.isNotEmpty) {
      final tier2 = await _probeBatch(
        candidates: directCrossCdn,
        batchLimit: batchLimit,
        tier: 2,
        targetBuilder: targetBuilder,
        reasonText: '原线路卡顿，已跨 CDN 切换',
        cancelled: cancelled,
      );
      if (tier2 != null) return tier2;
    }

    if (cancelled()) {
      return const FailoverDecision(
        kind: FailoverDecisionKind.exhausted,
        tier: 2,
        reasonText: '容灾已取消',
      );
    }

    // 第 3 阶：异 CDN 耗尽后尝试剩余未熔断「同 CDN」候选。
    if (directSameCdn.isNotEmpty) {
      final tier3 = await _probeBatch(
        candidates: directSameCdn,
        batchLimit: batchLimit,
        tier: 3,
        targetBuilder: targetBuilder,
        reasonText: '已切换至备用线路',
        cancelled: cancelled,
      );
      if (tier3 != null) return tier3;
    }

    if (cancelled()) {
      return const FailoverDecision(
        kind: FailoverDecisionKind.exhausted,
        tier: 3,
        reasonText: '容灾已取消',
      );
    }

    // 第 4 阶：存在非 CAPTCHA 的 WebView 兜底候选时交由播放器执行按需嗅探。
    if (webviewFallbacks.isNotEmpty) {
      return FailoverDecision(
        kind: FailoverDecisionKind.switchCandidate,
        tier: 4,
        candidate: webviewFallbacks.first,
        reasonText: '直连源不可用，已切至网页嗅探兜底',
      );
    }

    return const FailoverDecision(
      kind: FailoverDecisionKind.exhausted,
      tier: 4,
      reasonText: '已尝试全部可用片源均不可播',
    );
  }

  Future<FailoverDecision?> _probeBatch({
    required List<MediaCandidate> candidates,
    required int batchLimit,
    required int tier,
    required Future<CandidateProbeTarget?> Function(MediaCandidate candidate)
    targetBuilder,
    required String reasonText,
    required bool Function() cancelled,
  }) async {
    final diverse = SourceScoringEngine.selectDiverseTopK(
      candidates,
      k: candidates.length,
    );

    var cursor = 0;
    while (cursor < diverse.length && !cancelled()) {
      final slice = diverse.sublist(
        cursor,
        (cursor + batchLimit).clamp(0, diverse.length),
      );
      cursor += slice.length;

      final targetToCandidate = <String, MediaCandidate>{};
      final targets = <CandidateProbeTarget>[];
      for (final candidate in slice) {
        if (cancelled()) return null;
        final target = await targetBuilder(candidate);
        if (target == null) {
          _failedCandidateKeys.add(candidate.refKey);
          continue;
        }
        targetToCandidate[target.id] = candidate;
        targets.add(target);
      }

      if (targets.isEmpty) continue;

      final outcome = await _prober.probeHedged(
        targets,
        isCancelled: cancelled,
      );

      if (outcome.localOfflineDetected) {
        return const FailoverDecision(
          kind: FailoverDecisionKind.localOffline,
          tier: 2,
          reasonText: '检测到本机网络连接中断，已停止自动切源',
        );
      }

      for (final res in outcome.results) {
        if (res.isNetworkUnreachable &&
            recordNetworkUnreachable(res.resolvedCdnGroup)) {
          return const FailoverDecision(
            kind: FailoverDecisionKind.localOffline,
            tier: 2,
            reasonText: '检测到本机网络连接中断，已停止自动切源',
          );
        }
        if (!res.reachable) {
          final failed = targetToCandidate[res.target.id];
          if (failed != null) {
            _failedCandidateKeys.add(failed.refKey);
            if (res.resolvedCdnGroup.isNotEmpty &&
                res.failureKind != SourceFailureKind.http4xxGone &&
                res.failureKind != SourceFailureKind.tlsTransient) {
              _penalizedCdnGroups.add(res.resolvedCdnGroup);
            }
          }
        }
      }

      final winner = outcome.winner;
      if (winner != null) {
        final winningCandidate = targetToCandidate[winner.target.id];
        if (winningCandidate != null) {
          return FailoverDecision(
            kind: FailoverDecisionKind.switchCandidate,
            tier: tier,
            candidate: winningCandidate.copyWith(
              probeStatus: CandidateProbeStatus.ready,
              ttfbMs: winner.ttfbMs,
              throughputKbps: winner.throughputKbps,
              cdnGroup: winner.resolvedCdnGroup.isNotEmpty
                  ? winner.resolvedCdnGroup
                  : winningCandidate.cdnGroup,
              streamProfile:
                  winner.masterProfile ?? winningCandidate.streamProfile,
            ),
            probeResult: winner,
            reasonText: reasonText,
          );
        }
      }
    }
    return null;
  }

  static VideoTrack? _findNextLowerTrack(
    List<VideoTrack> sortedTracks,
    String? selectedId,
  ) {
    if (sortedTracks.length <= 1) return null;
    final idx = selectedId == null
        ? 0
        : sortedTracks.indexWhere((t) => t.id == selectedId);
    final currentIndex = idx < 0 ? 0 : idx;
    if (currentIndex + 1 < sortedTracks.length) {
      return sortedTracks[currentIndex + 1];
    }
    return null;
  }

  static String _triggerLabel(StallTriggerReason reason) {
    return switch (reason) {
      StallTriggerReason.startupBlackScreen => '起播黑屏超时',
      StallTriggerReason.sustainedStall => '持续卡顿',
      StallTriggerReason.frequentRebuffering => '高频缓冲',
      StallTriggerReason.proxyPrioritySegmentFailure => '分片拉取失败',
    };
  }
}
