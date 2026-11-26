import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/services/media/candidate_probe_orchestrator.dart';
import 'package:kazumi/services/media/failover_controller.dart';
import 'package:kazumi/services/media/playback_stall_monitor.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:media_kit/media_kit.dart' show VideoTrack;

MediaCandidate _makeCandidate({
  required String ruleId,
  required String sourceName,
  String cdnGroup = '',
  int? ttfbMs,
  int? throughputKbps,
  VerifiedStreamProfile? streamProfile,
  AudioDubVariant dubVariant = AudioDubVariant.original,
  bool isLazyWebview = false,
  MediaKind kind = MediaKind.movie,
}) {
  return MediaCandidate(
    summary: MediaSummary(
      ref: MediaRef.source(kind: kind, ruleId: ruleId, id: 'work-1'),
      title: '测试影片',
      detailSource: 'https://example.com/$ruleId/1',
      sourceName: sourceName,
    ),
    richMeta: RichMediaMeta(dubVariant: dubVariant),
    cdnGroup: cdnGroup,
    ttfbMs: ttfbMs,
    throughputKbps: throughputKbps,
    streamProfile: streamProfile,
    isLazyWebview: isLazyWebview,
  );
}

Uint8List _fakeTsPayload({int size = 2048}) {
  final data = Uint8List(size);
  for (var i = 0; i < size; i += 188) {
    data[i] = 0x47; // MPEG-TS sync byte
  }
  return data;
}

void main() {
  group('SourceScoringEngine 实测评分与防虚标/同CDN惩罚', () {
    test('448P 实测源严格降权低于 1080P 与 4K 实测源', () {
      var now = DateTime(2026, 11, 26, 12, 0);
      final health = SourceHealthRepository(clock: () => now);
      final engine = SourceScoringEngine(healthRepository: health);

      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.maoyan',
        kind: MediaKind.movie,
        ttfbMs: 120,
        verifiedProfile: VerifiedStreamProfile(
          width: 800,
          height: 448,
          provenance: StreamProfileProvenance.mpvTrackList,
          verifiedAt: now,
        ),
        now: now,
      );
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.iqiyi',
        kind: MediaKind.movie,
        ttfbMs: 160,
        verifiedProfile: VerifiedStreamProfile(
          width: 1920,
          height: 1080,
          provenance: StreamProfileProvenance.mpvTrackList,
          verifiedAt: now,
        ),
        now: now,
      );
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.4kav',
        kind: MediaKind.movie,
        ttfbMs: 220,
        verifiedProfile: VerifiedStreamProfile(
          width: 3840,
          height: 2160,
          provenance: StreamProfileProvenance.mpvTrackList,
          verifiedAt: now,
        ),
        now: now,
      );

      final ranked = engine.rankCandidates(
        [
          _makeCandidate(ruleId: 'kazumi-plus.maoyan', sourceName: '猫眼'),
          _makeCandidate(ruleId: 'kazumi-plus.iqiyi', sourceName: '爱奇艺资源'),
          _makeCandidate(ruleId: 'kazumi-plus.4kav', sourceName: '4KAV'),
        ],
        kind: MediaKind.movie,
        strategy: SourceRecommendationStrategy.balanced,
        now: now,
      );

      expect(ranked.first.ruleId, 'kazumi-plus.4kav');
      expect(ranked[1].ruleId, 'kazumi-plus.iqiyi');
      expect(ranked.last.ruleId, 'kazumi-plus.maoyan');
      expect(ranked.first.score, greaterThan(ranked[1].score));
      expect(ranked[1].score, greaterThan(ranked.last.score));
    });

    test('m3u8MasterInf 不具备 UI 实测资格，且排序权重低于 mpvTrackList', () {
      final now = DateTime(2026, 11, 26, 12, 0);
      final health = SourceHealthRepository(clock: () => now);
      final engine = SourceScoringEngine(healthRepository: health);

      final masterOnly = VerifiedStreamProfile(
        width: 1920,
        height: 1080,
        provenance: StreamProfileProvenance.m3u8MasterInf,
        verifiedAt: now,
      );
      final mpvVerified = VerifiedStreamProfile(
        width: 1920,
        height: 1080,
        provenance: StreamProfileProvenance.mpvTrackList,
        verifiedAt: now,
      );

      expect(masterOnly.isUiVerified, isFalse);
      expect(mpvVerified.isUiVerified, isTrue);

      final scoreMaster = engine.scoreCandidate(
        _makeCandidate(
          ruleId: 'rule.master',
          sourceName: '仅清单声明',
          streamProfile: masterOnly,
          ttfbMs: 150,
        ),
        kind: MediaKind.movie,
        now: now,
      );
      final scoreMpv = engine.scoreCandidate(
        _makeCandidate(
          ruleId: 'rule.mpv',
          sourceName: '实播解码',
          streamProfile: mpvVerified,
          ttfbMs: 150,
        ),
        kind: MediaKind.movie,
        now: now,
      );
      expect(scoreMpv.score, greaterThan(scoreMaster.score));
    });

    test('同 CDN 相关性 -0.45 惩罚使同源镜像排在独立 CDN 之后', () {
      final now = DateTime(2026, 11, 26, 12, 0);
      final health = SourceHealthRepository(clock: () => now);
      final engine = SourceScoringEngine(healthRepository: health);

      final mirror = _makeCandidate(
        ruleId: 'kazumi-plus.xinlang',
        sourceName: '新浪',
        cdnGroup: 'shared-cdn.example',
        ttfbMs: 100,
      );
      final independent = _makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        sourceName: '360资源',
        cdnGroup: 'independent-cdn.example',
        ttfbMs: 180,
      );

      final ranked = engine.rankCandidates(
        [mirror, independent],
        kind: MediaKind.movie,
        penalizedCdnGroups: const {'shared-cdn.example'},
        now: now,
      );

      expect(ranked.first.ruleId, 'kazumi-plus.zy360');
      expect(ranked.last.ruleId, 'kazumi-plus.xinlang');
      expect(ranked.first.score - ranked.last.score, greaterThan(0.25));
    });

    test('CAPTCHA 触发后自动池冷却 30 分钟且不自动绕过', () {
      var now = DateTime(2026, 11, 26, 12, 0);
      final health = SourceHealthRepository(clock: () => now);
      final engine = SourceScoringEngine(healthRepository: health);

      health.recordFailure(
        pluginIdentityKey: 'kazumi-plus.test',
        kind: MediaKind.movie,
        failureKind: SourceFailureKind.captchaRequired,
        message: '需要人工验证',
        now: now,
      );

      expect(
        health.isSourceInCaptchaCooldown(
          'kazumi-plus.test',
          MediaKind.movie,
          now: now.add(const Duration(minutes: 10)),
        ),
        isTrue,
      );

      final scoreInCooldown = engine.scoreCandidate(
        _makeCandidate(ruleId: 'kazumi-plus.test', sourceName: '验证源'),
        kind: MediaKind.movie,
        now: now.add(const Duration(minutes: 10)),
      );
      expect(scoreInCooldown.autoEligible, isFalse);

      // 31 分钟后自动解除冷却
      expect(
        health.isSourceInCaptchaCooldown(
          'kazumi-plus.test',
          MediaKind.movie,
          now: now.add(const Duration(minutes: 31)),
        ),
        isFalse,
      );
    });
  });

  group('CandidateProbeOrchestrator 分片可达性与反假活检验', () {
    test('拦截假活 HLS（清单 200 但首分片 404）', () async {
      final health = SourceHealthRepository();
      final prober = CandidateProbeOrchestrator(
        healthRepository: health,
        useTrafficGuard: false,
        fetcher: (url, {required headers, required timeout, maxBytes = 0, isCancelled}) async {
          if (url.endsWith('.m3u8')) {
            const m3u8 = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
https://cdn.dead.example/seg0.ts
''';
            return ProbeHttpResponse(
              statusCode: 200,
              finalUrl: url,
              bodyBytes: Uint8List.fromList(utf8.encode(m3u8)),
              elapsedMs: 40,
            );
          }
          return ProbeHttpResponse(
            statusCode: 404,
            finalUrl: url,
            bodyBytes: Uint8List(0),
            elapsedMs: 50,
          );
        },
      );

      final result = await prober.probeSingle(
        const CandidateProbeTarget(
          id: 'modu',
          pluginIdentityKey: 'kazumi-plus.modu',
          sourceName: '魔都',
          kind: MediaKind.movie,
          streamUrl: 'https://m3u8.modu.example/index.m3u8',
        ),
      );

      expect(result.reachable, isFalse);
      expect(result.failureKind, SourceFailureKind.http4xxGone);
    });

    test('放行 .png 伪装分片（携带 0x47 MPEG-TS 同步字节）并生成零拷贝 Seed', () async {
      final health = SourceHealthRepository();
      final prober = CandidateProbeOrchestrator(
        healthRepository: health,
        useTrafficGuard: false,
        fetcher: (url, {required headers, required timeout, maxBytes = 0, isCancelled}) async {
          if (url.endsWith('.m3u8')) {
            const m3u8 = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
https://ts-edge.okcdn.example/frame001.png
''';
            return ProbeHttpResponse(
              statusCode: 200,
              finalUrl: url,
              bodyBytes: Uint8List.fromList(utf8.encode(m3u8)),
              elapsedMs: 55,
            );
          }
          return ProbeHttpResponse(
            statusCode: 206,
            finalUrl: url,
            bodyBytes: _fakeTsPayload(size: 4096),
            headers: const {'content-type': 'image/png'},
            elapsedMs: 65,
          );
        },
      );

      final result = await prober.probeSingle(
        const CandidateProbeTarget(
          id: 'ok',
          pluginIdentityKey: 'kazumi-plus.iqiyi',
          sourceName: '爱奇艺资源',
          kind: MediaKind.movie,
          streamUrl: 'https://play.iqiyi.example/v1/index.m3u8',
        ),
      );

      expect(result.reachable, isTrue);
      expect(result.preFetchedSeed, isNotNull);
      expect(result.resolvedCdnGroup, isNotEmpty);
    });

    test('校验 AES-128 密钥 URI 可达性，不可达时拒绝', () async {
      final health = SourceHealthRepository();
      final prober = CandidateProbeOrchestrator(
        healthRepository: health,
        useTrafficGuard: false,
        fetcher: (url, {required headers, required timeout, maxBytes = 0, isCancelled}) async {
          if (url.endsWith('.m3u8')) {
            const m3u8 = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="https://key.dead.example/enc.key"
#EXTINF:6.0,
https://cdn.ok.example/seg0.ts
''';
            return ProbeHttpResponse(
              statusCode: 200,
              finalUrl: url,
              bodyBytes: Uint8List.fromList(utf8.encode(m3u8)),
              elapsedMs: 40,
            );
          }
          if (url.endsWith('enc.key')) {
            return ProbeHttpResponse(
              statusCode: 403,
              finalUrl: url,
              bodyBytes: Uint8List(0),
              elapsedMs: 30,
            );
          }
          return ProbeHttpResponse(
            statusCode: 200,
            finalUrl: url,
            bodyBytes: _fakeTsPayload(),
            elapsedMs: 30,
          );
        },
      );

      final result = await prober.probeSingle(
        const CandidateProbeTarget(
          id: 'aes-fail',
          pluginIdentityKey: 'rule.aes',
          sourceName: '加密源',
          kind: MediaKind.movie,
          streamUrl: 'https://cdn.ok.example/index.m3u8',
        ),
      );

      expect(result.reachable, isFalse);
    });

    test('2 组独立 CDN 同时底层不可达触发本机断网止损', () async {
      final health = SourceHealthRepository();
      final prober = CandidateProbeOrchestrator(
        healthRepository: health,
        useTrafficGuard: false,
        hedgeDelay: Duration.zero,
        fetcher: (url, {required headers, required timeout, maxBytes = 0, isCancelled}) async {
          throw const SocketException('Network is unreachable');
        },
      );

      final outcome = await prober.probeHedged(const [
        CandidateProbeTarget(
          id: 'a',
          pluginIdentityKey: 'rule.a',
          sourceName: '源A',
          kind: MediaKind.movie,
          streamUrl: 'https://cdn-a.alpha.example/index.m3u8',
        ),
        CandidateProbeTarget(
          id: 'b',
          pluginIdentityKey: 'rule.b',
          sourceName: '源B',
          kind: MediaKind.movie,
          streamUrl: 'https://cdn-b.beta.example/index.m3u8',
        ),
      ]);

      expect(outcome.winner, isNull);
      expect(outcome.localOfflineDetected, isTrue);
    });
  });

  group('PlaybackStallMonitor 严苛布防门控', () {
    test('暂停、拖动、切画质、恢复进度、后台挂起时均不误触发容灾', () {
      var now = DateTime(2026, 11, 26, 12, 0, 0);
      final monitor = PlaybackStallMonitor(clock: () => now);
      monitor.markLoadStarted();

      // 解码第一帧后进入正常播放
      expect(
        monitor.sample(
          const PlaybackHealthSample(
            playing: true,
            loading: false,
            resumePending: false,
            completed: false,
            backgroundSuspended: false,
            seeking: false,
            qualitySwitching: false,
            manualSwitchInProgress: false,
            buffering: false,
            position: Duration(seconds: 10),
            buffer: Duration(seconds: 25),
            playerWidth: 1920,
          ),
        ),
        isNull,
      );

      // 暂停状态下缓冲 20 秒绝不触发
      now = now.add(const Duration(seconds: 20));
      expect(
        monitor.sample(
          const PlaybackHealthSample(
            playing: false,
            loading: false,
            resumePending: false,
            completed: false,
            backgroundSuspended: false,
            seeking: false,
            qualitySwitching: false,
            manualSwitchInProgress: false,
            buffering: true,
            position: Duration(seconds: 10),
            buffer: Duration(seconds: 10),
            playerWidth: 1920,
          ),
        ),
        isNull,
      );

      // resumePending 期间绝不触发
      now = now.add(const Duration(seconds: 20));
      expect(
        monitor.sample(
          const PlaybackHealthSample(
            playing: true,
            loading: false,
            resumePending: true,
            completed: false,
            backgroundSuspended: false,
            seeking: false,
            qualitySwitching: false,
            manualSwitchInProgress: false,
            buffering: true,
            position: Duration(seconds: 10),
            buffer: Duration(seconds: 10),
            playerWidth: 1920,
          ),
        ),
        isNull,
      );

      // markSeek 后 5 秒宽限期内绝不触发
      monitor.markSeek();
      now = now.add(const Duration(seconds: 4));
      expect(
        monitor.sample(
          const PlaybackHealthSample(
            playing: true,
            loading: false,
            resumePending: false,
            completed: false,
            backgroundSuspended: false,
            seeking: false,
            qualitySwitching: false,
            manualSwitchInProgress: false,
            buffering: true,
            position: Duration(seconds: 60),
            buffer: Duration(seconds: 60),
            playerWidth: 1920,
          ),
        ),
        isNull,
      );
    });

    test('播放中持续缓冲超过 8 秒触发 sustainedStall', () {
      var now = DateTime(2026, 11, 26, 12, 0, 0);
      final monitor = PlaybackStallMonitor(clock: () => now);
      monitor.markLoadStarted();

      const base = PlaybackHealthSample(
        playing: true,
        loading: false,
        resumePending: false,
        completed: false,
        backgroundSuspended: false,
        seeking: false,
        qualitySwitching: false,
        manualSwitchInProgress: false,
        buffering: true,
        position: Duration(seconds: 30),
        buffer: Duration(seconds: 30),
        playerWidth: 1920,
      );

      expect(monitor.sample(base), isNull);
      now = now.add(const Duration(seconds: 5));
      expect(monitor.sample(base), isNull);
      now = now.add(const Duration(seconds: 4));
      expect(monitor.sample(base), StallTriggerReason.sustainedStall);
    });
  });

  group('FailoverController 四阶渐进容灾', () {
    test('第 1 阶：同流多变体 HLS 播中卡顿先平滑降档', () async {
      final controller = FailoverController();
      final current = _makeCandidate(
        ruleId: 'rule.a',
        sourceName: 'A源',
        cdnGroup: 'cdn-a.example',
      );
      final tracks = [
        const VideoTrack('1', null, null, w: 1920, h: 1080),
        const VideoTrack('2', null, null, w: 1280, h: 720),
      ];

      final decision = await controller.resolveNext(
        kind: MediaKind.movie,
        currentCandidate: current,
        allCandidates: [current],
        triggerReason: StallTriggerReason.sustainedStall,
        strategy: SourceRecommendationStrategy.balanced,
        currentPlayableTracks: tracks,
        currentSelectedTrackId: '1',
        targetBuilder: (_) async => null,
      );

      expect(decision.kind, FailoverDecisionKind.stepDownQuality);
      expect(decision.tier, 1);
      expect(decision.lowerTrack?.id, '2');
    });

    test('第 2 阶：跨 CDN 优先切换且跳过不同配音版本', () async {
      final health = SourceHealthRepository();
      final prober = CandidateProbeOrchestrator(
        healthRepository: health,
        useTrafficGuard: false,
        hedgeDelay: Duration.zero,
        fetcher: (url, {required headers, required timeout, maxBytes = 0, isCancelled}) async {
          if (url.endsWith('.m3u8')) {
            final host = Uri.parse(url).host;
            return ProbeHttpResponse(
              statusCode: 200,
              finalUrl: url,
              bodyBytes: Uint8List.fromList(
                utf8.encode(
                  '#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:6.0,\nhttps://$host/seg0.ts\n',
                ),
              ),
              elapsedMs: 50,
            );
          }
          return ProbeHttpResponse(
            statusCode: 200,
            finalUrl: url,
            bodyBytes: _fakeTsPayload(),
            elapsedMs: 50,
          );
        },
      );
      final controller = FailoverController(
        healthRepository: health,
        scoringEngine: SourceScoringEngine(healthRepository: health),
        probeOrchestrator: prober,
      );

      final current = _makeCandidate(
        ruleId: 'kazumi-plus.haohua',
        sourceName: '豪华',
        cdnGroup: 'shared-cdn.example',
      );
      final sameCdnMirror = _makeCandidate(
        ruleId: 'kazumi-plus.xinlang',
        sourceName: '新浪',
        cdnGroup: 'shared-cdn.example',
      );
      final differentDub = _makeCandidate(
        ruleId: 'kazumi-plus.dub',
        sourceName: '国配源',
        cdnGroup: 'dub-cdn.example',
        dubVariant: AudioDubVariant.mandarinDub,
      );
      final crossCdn = _makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        sourceName: '360资源',
        cdnGroup: 'zy360-cdn.example',
      );

      final decision = await controller.resolveNext(
        kind: MediaKind.movie,
        currentCandidate: current,
        allCandidates: [current, sameCdnMirror, differentDub, crossCdn],
        triggerReason: StallTriggerReason.sustainedStall,
        strategy: SourceRecommendationStrategy.balanced,
        targetBuilder: (candidate) async => CandidateProbeTarget(
          id: candidate.refKey,
          pluginIdentityKey: candidate.ruleId,
          sourceName: candidate.sourceName,
          kind: MediaKind.movie,
          streamUrl: 'https://${candidate.cdnGroup}/index.m3u8',
        ),
      );

      expect(decision.kind, FailoverDecisionKind.switchCandidate);
      expect(decision.tier, 2);
      expect(decision.candidate?.ruleId, 'kazumi-plus.zy360');
    });
  });
}
