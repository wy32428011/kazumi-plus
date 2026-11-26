import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_traffic_guard.dart';
import 'package:kazumi/services/player/hls_proxy_service.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

/// 轻量 HTTP 探针响应（可注入模拟，便于离线单测）。
class ProbeHttpResponse {
  const ProbeHttpResponse({
    required this.statusCode,
    required this.finalUrl,
    required this.bodyBytes,
    this.headers = const {},
    this.elapsedMs = 0,
  });

  final int statusCode;
  final String finalUrl;
  final Uint8List bodyBytes;
  final Map<String, String> headers;
  final int elapsedMs;

  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);
}

typedef ProbeHttpFetcher = Future<ProbeHttpResponse> Function(
  String url, {
  required Map<String, String> headers,
  required Duration timeout,
  int maxBytes,
  bool Function()? isCancelled,
});

/// 待探活的单个流媒体候选描述。
class CandidateProbeTarget {
  const CandidateProbeTarget({
    required this.id,
    required this.pluginIdentityKey,
    required this.sourceName,
    required this.kind,
    required this.streamUrl,
    this.headers = const {},
    this.isHls,
    this.isLazyWebview = false,
  });

  final String id;
  final String pluginIdentityKey;
  final String sourceName;
  final MediaKind kind;
  final String streamUrl;
  final Map<String, String> headers;
  final bool? isHls;
  final bool isLazyWebview;

  bool get effectiveIsHls {
    if (isHls != null) return isHls!;
    final path = Uri.tryParse(streamUrl)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || streamUrl.toLowerCase().contains('.m3u8');
  }
}

/// 单个候选源的探活结果。
class CandidateProbeResult {
  const CandidateProbeResult({
    required this.target,
    required this.reachable,
    this.failureKind,
    this.errorMessage = '',
    this.ttfbMs = 0,
    this.throughputKbps,
    this.resolvedCdnGroup = '',
    this.masterProfile,
    this.preFetchedSeed,
    this.isNetworkUnreachable = false,
  });

  final CandidateProbeTarget target;
  final bool reachable;
  final SourceFailureKind? failureKind;
  final String errorMessage;
  final int ttfbMs;
  final int? throughputKbps;
  final String resolvedCdnGroup;

  /// 若主清单携带 `#EXT-X-STREAM-INF RESOLUTION`，仅作为排序参考（×0.90），绝不直接展示 UI 4K 徽章。
  final VerifiedStreamProfile? masterProfile;

  /// HLS 探针胜出后零拷贝移交给 `HlsProxyService.prepareSession` 的预取种子。
  final HlsPreFetchedSeed? preFetchedSeed;

  /// 是否属于底层 Socket / DNS 不可达（用于 2 组独立 CDN 本机断网止损判定）。
  final bool isNetworkUnreachable;
}

/// 错峰对冲探活编排结果。
class HedgedProbeOutcome {
  const HedgedProbeOutcome({
    this.winner,
    required this.results,
    this.localOfflineDetected = false,
  });

  final CandidateProbeResult? winner;
  final List<CandidateProbeResult> results;
  final bool localOfflineDetected;
}

/// 三级错峰对冲探针编排器（Tier-1 轻探针 + 分片可达性检验 + 零拷贝移交 + 本机断网止损）。
class CandidateProbeOrchestrator {
  CandidateProbeOrchestrator({
    SourceHealthRepository? healthRepository,
    SourceTrafficGuard? trafficGuard,
    ProbeHttpFetcher? fetcher,
    DateTime Function()? clock,
    this.probeTimeout = const Duration(milliseconds: 3500),
    this.hedgeDelay = const Duration(milliseconds: 350),
    this.tlsRetryDelay = const Duration(milliseconds: 250),
    this.useTrafficGuard = true,
  }) : _health = healthRepository ?? SourceHealthRepository.instance,
       _trafficGuard = trafficGuard ?? SourceTrafficGuard.instance,
       _fetcher = fetcher ?? _defaultHttpFetch,
       _clock = clock ?? DateTime.now;

  static final CandidateProbeOrchestrator instance =
      CandidateProbeOrchestrator();

  final SourceHealthRepository _health;
  final SourceTrafficGuard _trafficGuard;
  final ProbeHttpFetcher _fetcher;
  final DateTime Function() _clock;
  final Duration probeTimeout;
  final Duration hedgeDelay;
  final Duration tlsRetryDelay;
  final bool useTrafficGuard;

  static const int _segmentRangeBytes = 65536;
  static const int _minValidSegmentBytes = 1024;
  static const int _maxPlaylistBytes = 1024 * 1024;

  /// 对单个候选执行完整探活（含 `tlsTransient` 单次退避重试、分片可达性检验、AES-128 16 字节快检与 `.png` 伪装分片放行）。
  Future<CandidateProbeResult> probeSingle(
    CandidateProbeTarget target, {
    bool Function()? isCancelled,
    bool recordTelemetry = true,
  }) async {
    final cancelled = isCancelled ?? () => false;
    if (cancelled()) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: SourceFailureKind.networkTimeout,
        errorMessage: '探活已取消',
      );
    }

    final uri = Uri.tryParse(target.streamUrl.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: SourceFailureKind.decodeError,
        errorMessage: '无效媒体地址',
      );
    }

    final sw = Stopwatch()..start();
    try {
      final result = target.effectiveIsHls
          ? await _probeHls(target, cancelled: cancelled)
          : await _probeDirectMedia(target, cancelled: cancelled);
      sw.stop();

      if (recordTelemetry && !cancelled()) {
        if (result.reachable) {
          _health.recordSuccess(
            pluginIdentityKey: target.pluginIdentityKey,
            kind: target.kind,
            ttfbMs: result.ttfbMs > 0 ? result.ttfbMs : sw.elapsedMilliseconds,
            throughputKbps: result.throughputKbps,
            cdnGroup: result.resolvedCdnGroup,
            now: _clock(),
          );
        } else if (result.failureKind != null) {
          _health.recordFailure(
            pluginIdentityKey: target.pluginIdentityKey,
            kind: target.kind,
            failureKind: result.failureKind!,
            cdnGroup: result.resolvedCdnGroup,
            message: result.errorMessage,
            now: _clock(),
          );
        }
      }
      return result;
    } catch (error) {
      sw.stop();
      final classified = _classifyException(error);
      final cdnGroup = SourceHealthRepository.normalizeCdnGroup(
        target.streamUrl,
      );
      if (recordTelemetry && !cancelled()) {
        _health.recordFailure(
          pluginIdentityKey: target.pluginIdentityKey,
          kind: target.kind,
          failureKind: classified.kind,
          cdnGroup: cdnGroup,
          message: classified.message,
          now: _clock(),
        );
      }
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: classified.kind,
        errorMessage: classified.message,
        ttfbMs: sw.elapsedMilliseconds,
        resolvedCdnGroup: cdnGroup,
        isNetworkUnreachable: classified.isNetworkUnreachable,
      );
    }
  }

  /// 错峰对冲探测：优先探测首选，若 [hedgeDelay]（默认 350ms）未胜出则错峰并发拉起其余跨 CDN 候选；
  /// 首个可用结果胜出后立即返回，并触发 2 组独立 CDN 底层不可达的本机断网止损。
  Future<HedgedProbeOutcome> probeHedged(
    List<CandidateProbeTarget> targets, {
    bool Function()? isCancelled,
    bool recordTelemetry = true,
  }) async {
    if (targets.isEmpty) {
      return const HedgedProbeOutcome(results: []);
    }

    final cancelled = isCancelled ?? () => false;
    var resolvedWinner = false;
    final winnerCompleter = Completer<CandidateProbeResult?>();
    final collected = <CandidateProbeResult>[];
    final unreachableCdns = <(String cdn, DateTime at)>[];
    var localOffline = false;
    var active = 0;
    var allLaunched = false;

    void checkComplete() {
      if (!winnerCompleter.isCompleted && allLaunched && active == 0) {
        winnerCompleter.complete(null);
      }
    }

    void launch(CandidateProbeTarget target) {
      if (resolvedWinner || localOffline || cancelled()) return;
      active++;
      unawaited(
        probeSingle(
          target,
          isCancelled: () => resolvedWinner || localOffline || cancelled(),
          recordTelemetry: recordTelemetry,
        ).then((result) {
          active--;
          collected.add(result);
          if (result.reachable && !resolvedWinner && !cancelled()) {
            resolvedWinner = true;
            if (!winnerCompleter.isCompleted) {
              winnerCompleter.complete(result);
            }
            return;
          }
          if (result.isNetworkUnreachable) {
            final now = _clock();
            final cdn = result.resolvedCdnGroup.isNotEmpty
                ? result.resolvedCdnGroup
                : SourceHealthRepository.normalizeCdnGroup(target.streamUrl);
            unreachableCdns.removeWhere(
              (item) => now.difference(item.$2) > const Duration(seconds: 2),
            );
            if (cdn.isNotEmpty) {
              unreachableCdns.add((cdn, now));
            }
            final distinctCdns = unreachableCdns.map((e) => e.$1).toSet();
            if (distinctCdns.length >= 2) {
              localOffline = true;
              if (!winnerCompleter.isCompleted) {
                winnerCompleter.complete(null);
              }
              return;
            }
          }
          checkComplete();
        }).catchError((Object _) {
          active--;
          checkComplete();
        }),
      );
    }

    // 主候选立即启动。
    launch(targets.first);

    if (targets.length == 1) {
      allLaunched = true;
      checkComplete();
      final winner = await winnerCompleter.future;
      return HedgedProbeOutcome(
        winner: winner,
        results: List.unmodifiable(collected),
        localOfflineDetected: localOffline,
      );
    }

    // 若主候选在 hedgeDelay 内未完成且未胜出，错峰启动其余跨 CDN 备选。
    await Future.any<void>([
      winnerCompleter.future.then((_) {}),
      Future<void>.delayed(hedgeDelay),
    ]);

    if (!resolvedWinner && !localOffline && !cancelled()) {
      for (var i = 1; i < targets.length; i++) {
        launch(targets[i]);
      }
    }
    allLaunched = true;
    checkComplete();

    final winner = await winnerCompleter.future;
    return HedgedProbeOutcome(
      winner: winner,
      results: List.unmodifiable(collected),
      localOfflineDetected: localOffline,
    );
  }

  Future<CandidateProbeResult> _probeHls(
    CandidateProbeTarget target, {
    required bool Function() cancelled,
  }) async {
    final playlistRes = await _fetchWithTlsRetry(
      target.streamUrl,
      headers: target.headers,
      maxBytes: _maxPlaylistBytes,
      cancelled: cancelled,
    );

    final challenge = _checkChallengeOrHttpError(playlistRes, target.streamUrl);
    if (challenge != null) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: challenge.kind,
        errorMessage: challenge.message,
        ttfbMs: playlistRes.elapsedMs,
        resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
          playlistRes.finalUrl,
        ),
      );
    }

    final rootBody = playlistRes.bodyText;
    if (!rootBody.contains('#EXTM3U')) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: _looksLikeCaptchaHtml(rootBody)
            ? SourceFailureKind.captchaRequired
            : SourceFailureKind.emptyPlaylist,
        errorMessage: _looksLikeCaptchaHtml(rootBody)
            ? '站点返回反爬验证页面'
            : '返回内容不是有效的 M3U8 清单',
        ttfbMs: playlistRes.elapsedMs,
        resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
          playlistRes.finalUrl,
        ),
      );
    }

    var mediaBody = rootBody;
    var mediaBaseUrl = playlistRes.finalUrl;
    VerifiedStreamProfile? masterProfile;

    if (M3u8Parser.detectType(rootBody) == M3u8Type.master) {
      final variants = _parseMasterVariants(rootBody, playlistRes.finalUrl);
      if (variants.isEmpty) {
        return CandidateProbeResult(
          target: target,
          reachable: false,
          failureKind: SourceFailureKind.emptyPlaylist,
          errorMessage: '主清单未包含可用子流',
          ttfbMs: playlistRes.elapsedMs,
          resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
            playlistRes.finalUrl,
          ),
        );
      }

      // 选取分辨率最高的变体作为探针与分辨率参考（仅作 ×0.90 排序参考，不作 UI 认证徽章）。
      variants.sort((a, b) {
        final px = (b.width * b.height).compareTo(a.width * a.height);
        return px != 0 ? px : (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
      final bestVariant = variants.first;
      if (bestVariant.width > 0 && bestVariant.height > 0) {
        masterProfile = VerifiedStreamProfile(
          width: bestVariant.width,
          height: bestVariant.height,
          bitrateKbps: bestVariant.bandwidth != null
              ? (bestVariant.bandwidth! / 1000).round()
              : null,
          provenance: StreamProfileProvenance.m3u8MasterInf,
          verifiedAt: _clock(),
        );
      }

      final variantRes = await _fetchWithTlsRetry(
        bestVariant.url,
        headers: target.headers,
        maxBytes: _maxPlaylistBytes,
        cancelled: cancelled,
      );
      final variantErr = _checkChallengeOrHttpError(variantRes, bestVariant.url);
      if (variantErr != null) {
        return CandidateProbeResult(
          target: target,
          reachable: false,
          failureKind: variantErr.kind,
          errorMessage: '子清单不可达：${variantErr.message}',
          ttfbMs: playlistRes.elapsedMs + variantRes.elapsedMs,
          resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
            variantRes.finalUrl,
          ),
        );
      }
      mediaBody = variantRes.bodyText;
      mediaBaseUrl = variantRes.finalUrl;
      if (!mediaBody.contains('#EXTM3U')) {
        return CandidateProbeResult(
          target: target,
          reachable: false,
          failureKind: SourceFailureKind.emptyPlaylist,
          errorMessage: '子清单内容非法（假活清单）',
          ttfbMs: playlistRes.elapsedMs + variantRes.elapsedMs,
          resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
            variantRes.finalUrl,
          ),
        );
      }
    }

    final parsedMedia = M3u8Parser.parseMediaPlaylist(mediaBody, mediaBaseUrl);
    if (parsedMedia.segments.isEmpty) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: SourceFailureKind.emptyPlaylist,
        errorMessage: '媒体清单不含可播分片',
        ttfbMs: playlistRes.elapsedMs,
        resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(mediaBaseUrl),
      );
    }

    final firstSegment = parsedMedia.segments.first;

    // 若采用 AES-128 加密，必须执行 16 字节密钥快检。
    final segKey = firstSegment.key;
    if (segKey != null &&
        segKey.method.toUpperCase() == 'AES-128' &&
        segKey.uri.isNotEmpty) {
      final keyRes = await _fetchWithTlsRetry(
        segKey.uri,
        headers: target.headers,
        maxBytes: 1024,
        cancelled: cancelled,
      );
      final keyErr = _checkChallengeOrHttpError(keyRes, segKey.uri);
      if (keyErr != null || keyRes.bodyBytes.length != 16) {
        return CandidateProbeResult(
          target: target,
          reachable: false,
          failureKind: keyErr?.kind ?? SourceFailureKind.decodeError,
          errorMessage: keyErr != null
              ? 'AES-128 密钥不可达：${keyErr.message}'
              : 'AES-128 密钥长度异常（${keyRes.bodyBytes.length} 字节）',
          ttfbMs: playlistRes.elapsedMs + keyRes.elapsedMs,
          resolvedCdnGroup: SourceHealthRepository.normalizeCdnGroup(
            keyRes.finalUrl,
          ),
        );
      }
    }

    // 校验首个有效分片可达性（不按 MIME 拦截 .png/.jpg 伪装分片，只验 200/206 + 非 HTML + ≥1KB）。
    final segHeaders = <String, String>{
      ...target.headers,
      'Range': 'bytes=0-${_segmentRangeBytes - 1}',
    };
    final segRes = await _fetchWithTlsRetry(
      firstSegment.uri,
      headers: segHeaders,
      maxBytes: _segmentRangeBytes,
      cancelled: cancelled,
    );
    final segCdnGroup = SourceHealthRepository.normalizeCdnGroup(
      segRes.finalUrl,
    );

    final segErr = _checkChallengeOrHttpError(
      segRes,
      firstSegment.uri,
      allowPartialContent: true,
    );
    if (segErr != null) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: segErr.kind,
        errorMessage: '分片不可达（假活拦截）：${segErr.message}',
        ttfbMs: playlistRes.elapsedMs + segRes.elapsedMs,
        resolvedCdnGroup: segCdnGroup,
      );
    }

    if (segRes.bodyBytes.length < _minValidSegmentBytes ||
        _looksLikeHtmlDocument(segRes.bodyBytes)) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: _looksLikeCaptchaBytes(segRes.bodyBytes)
            ? SourceFailureKind.captchaRequired
            : SourceFailureKind.decodeError,
        errorMessage: _looksLikeHtmlDocument(segRes.bodyBytes)
            ? '分片返回 HTML 报错页而非媒体流'
            : '分片体积过小（${segRes.bodyBytes.length} 字节）',
        ttfbMs: playlistRes.elapsedMs + segRes.elapsedMs,
        resolvedCdnGroup: segCdnGroup,
      );
    }

    final elapsedMs = segRes.elapsedMs > 0 ? segRes.elapsedMs : 1;
    final throughputKbps =
        ((segRes.bodyBytes.length * 8.0) / elapsedMs).round();
    final totalTtfbMs = playlistRes.elapsedMs > 0
        ? playlistRes.elapsedMs
        : segRes.elapsedMs;

    final seed = HlsPreFetchedSeed(
      sourceUrl: target.streamUrl,
      finalUrl: playlistRes.finalUrl,
      playlistBody: rootBody,
      resolvedCdnGroup: segCdnGroup,
      fetchedAt: _clock(),
    );

    return CandidateProbeResult(
      target: target,
      reachable: true,
      ttfbMs: totalTtfbMs,
      throughputKbps: throughputKbps,
      resolvedCdnGroup: segCdnGroup,
      masterProfile: masterProfile,
      preFetchedSeed: seed,
    );
  }

  Future<CandidateProbeResult> _probeDirectMedia(
    CandidateProbeTarget target, {
    required bool Function() cancelled,
  }) async {
    final headers = <String, String>{
      ...target.headers,
      'Range': 'bytes=0-${_segmentRangeBytes - 1}',
    };
    final res = await _fetchWithTlsRetry(
      target.streamUrl,
      headers: headers,
      maxBytes: _segmentRangeBytes,
      cancelled: cancelled,
    );
    final cdnGroup = SourceHealthRepository.normalizeCdnGroup(res.finalUrl);
    final err = _checkChallengeOrHttpError(
      res,
      target.streamUrl,
      allowPartialContent: true,
    );
    if (err != null) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: err.kind,
        errorMessage: err.message,
        ttfbMs: res.elapsedMs,
        resolvedCdnGroup: cdnGroup,
      );
    }
    if (res.bodyBytes.length < _minValidSegmentBytes ||
        _looksLikeHtmlDocument(res.bodyBytes)) {
      return CandidateProbeResult(
        target: target,
        reachable: false,
        failureKind: _looksLikeCaptchaBytes(res.bodyBytes)
            ? SourceFailureKind.captchaRequired
            : SourceFailureKind.decodeError,
        errorMessage: _looksLikeHtmlDocument(res.bodyBytes)
            ? '直连地址返回 HTML 而非视频流'
            : '媒体响应体过小',
        ttfbMs: res.elapsedMs,
        resolvedCdnGroup: cdnGroup,
      );
    }

    final elapsedMs = res.elapsedMs > 0 ? res.elapsedMs : 1;
    final throughputKbps = ((res.bodyBytes.length * 8.0) / elapsedMs).round();
    return CandidateProbeResult(
      target: target,
      reachable: true,
      ttfbMs: res.elapsedMs,
      throughputKbps: throughputKbps,
      resolvedCdnGroup: cdnGroup,
    );
  }

  Future<ProbeHttpResponse> _fetchWithTlsRetry(
    String url, {
    required Map<String, String> headers,
    required int maxBytes,
    required bool Function() cancelled,
  }) async {
    Future<ProbeHttpResponse> doOnce() {
      if (!useTrafficGuard) {
        return _fetcher(
          url,
          headers: headers,
          timeout: probeTimeout,
          maxBytes: maxBytes,
          isCancelled: cancelled,
        );
      }
      return _trafficGuard.run<ProbeHttpResponse>(
        url: url,
        method: 'GET',
        deduplicate: false,
        bypassRateLimit: true,
        action: (_) => _fetcher(
          url,
          headers: headers,
          timeout: probeTimeout,
          maxBytes: maxBytes,
          isCancelled: cancelled,
        ),
      );
    }

    try {
      return await doOnce();
    } catch (error) {
      if (!cancelled() && _isTlsTransientError(error)) {
        await Future<void>.delayed(tlsRetryDelay);
        if (!cancelled()) {
          return await doOnce();
        }
      }
      rethrow;
    }
  }

  static ({SourceFailureKind kind, String message})? _checkChallengeOrHttpError(
    ProbeHttpResponse res,
    String url, {
    bool allowPartialContent = false,
  }) {
    final cfMitigated = res.headers['cf-mitigated']?.toLowerCase() ?? '';
    if (cfMitigated.contains('challenge')) {
      return (
        kind: SourceFailureKind.captchaRequired,
        message: 'Cloudflare 反爬验证挑战',
      );
    }

    final ok = allowPartialContent
        ? (res.statusCode == 200 || res.statusCode == 206)
        : (res.statusCode >= 200 && res.statusCode < 300);
    if (ok) return null;

    if (res.statusCode == 403 || res.statusCode == 429 || res.statusCode == 503) {
      if (_looksLikeCaptchaBytes(res.bodyBytes)) {
        return (
          kind: SourceFailureKind.captchaRequired,
          message: 'HTTP ${res.statusCode} 反爬验证挑战',
        );
      }
    }
    if (res.statusCode == 404 || res.statusCode == 410) {
      return (
        kind: SourceFailureKind.http4xxGone,
        message: 'HTTP ${res.statusCode} 资源不存在',
      );
    }
    if (res.statusCode >= 500) {
      return (
        kind: SourceFailureKind.http5xx,
        message: 'HTTP ${res.statusCode} 上游服务错误',
      );
    }
    return (
      kind: SourceFailureKind.http4xxGone,
      message: 'HTTP ${res.statusCode}',
    );
  }

  static bool _looksLikeHtmlDocument(Uint8List bytes) {
    final sampleLen = bytes.length < 512 ? bytes.length : 512;
    if (sampleLen == 0) return false;
    final prefix = utf8
        .decode(bytes.sublist(0, sampleLen), allowMalformed: true)
        .trimLeft()
        .toLowerCase();
    return prefix.startsWith('<!doctype html') ||
        prefix.startsWith('<html') ||
        prefix.startsWith('<head') ||
        prefix.startsWith('<body') ||
        prefix.contains('<title>404') ||
        prefix.contains('<title>403');
  }

  static bool _looksLikeCaptchaBytes(Uint8List bytes) {
    final sampleLen = bytes.length < 2048 ? bytes.length : 2048;
    if (sampleLen == 0) return false;
    final text = utf8.decode(bytes.sublist(0, sampleLen), allowMalformed: true);
    return _looksLikeCaptchaHtml(text);
  }

  static bool _looksLikeCaptchaHtml(String text) {
    final lower = text.toLowerCase();
    return lower.contains('cf-turnstile') ||
        lower.contains('just a moment...') ||
        lower.contains('challenge-platform') ||
        lower.contains('captcha') ||
        lower.contains('人机验证') ||
        lower.contains('安全验证');
  }

  static bool _isTlsTransientError(Object error) {
    final msg = error.toString().toLowerCase();
    return error is HandshakeException ||
        error is TlsException ||
        msg.contains('bad_record_mac') ||
        msg.contains('unexpected eof') ||
        msg.contains('handshake');
  }

  static ({
    SourceFailureKind kind,
    String message,
    bool isNetworkUnreachable,
  })
  _classifyException(Object error) {
    if (_isTlsTransientError(error)) {
      return (
        kind: SourceFailureKind.tlsTransient,
        message: 'TLS 连接瞬时中断',
        isNetworkUnreachable: false,
      );
    }
    if (error is TimeoutException) {
      return (
        kind: SourceFailureKind.networkTimeout,
        message: '探活超时',
        isNetworkUnreachable: false,
      );
    }
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      final unreachable =
          msg.contains('failed host lookup') ||
          msg.contains('network is unreachable') ||
          msg.contains('no route to host') ||
          msg.contains('socket is not connected') ||
          msg.contains('host is down');
      return (
        kind: SourceFailureKind.networkTimeout,
        message: '网络连接失败：${error.message}',
        isNetworkUnreachable: unreachable,
      );
    }
    return (
      kind: SourceFailureKind.networkTimeout,
      message: '$error',
      isNetworkUnreachable: false,
    );
  }

  static List<_MasterVariantInfo> _parseMasterVariants(
    String content,
    String baseUrl,
  ) {
    final baseUri = Uri.parse(baseUrl);
    final lines = const LineSplitter().convert(content);
    final variants = <_MasterVariantInfo>[];
    int width = 0;
    int height = 0;
    int? bandwidth;
    var pendingStreamInf = false;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingStreamInf = true;
        width = 0;
        height = 0;
        bandwidth = null;
        final resMatch = RegExp(
          r'RESOLUTION=(\d+)x(\d+)',
          caseSensitive: false,
        ).firstMatch(line);
        if (resMatch != null) {
          width = int.tryParse(resMatch.group(1) ?? '') ?? 0;
          height = int.tryParse(resMatch.group(2) ?? '') ?? 0;
        }
        final bwMatch = RegExp(
          r'BANDWIDTH=(\d+)',
          caseSensitive: false,
        ).firstMatch(line);
        if (bwMatch != null) {
          bandwidth = int.tryParse(bwMatch.group(1) ?? '');
        }
        continue;
      }
      if (line.startsWith('#')) continue;
      if (pendingStreamInf) {
        variants.add(
          _MasterVariantInfo(
            url: baseUri.resolve(line).toString(),
            width: width,
            height: height,
            bandwidth: bandwidth,
          ),
        );
        pendingStreamInf = false;
      }
    }
    return variants;
  }

  static Future<ProbeHttpResponse> _defaultHttpFetch(
    String url, {
    required Map<String, String> headers,
    required Duration timeout,
    int maxBytes = 65536,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = timeout;
    final sw = Stopwatch()..start();
    try {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri).timeout(timeout);
      req.followRedirects = true;
      req.maxRedirects = 5;
      headers.forEach((key, value) {
        final lower = key.toLowerCase();
        if (lower == 'host' ||
            lower == 'content-length' ||
            lower == 'connection') {
          return;
        }
        req.headers.set(key, value);
      });
      final res = await req.close().timeout(timeout);
      var resolvedUri = uri;
      for (final redirect in res.redirects) {
        resolvedUri = resolvedUri.resolveUri(redirect.location);
      }

      final builder = BytesBuilder(copy: false);
      final completer = Completer<Uint8List>();
      late final StreamSubscription<List<int>> sub;
      sub = res.listen(
        (chunk) {
          if (isCancelled?.call() == true) {
            unawaited(sub.cancel());
            if (!completer.isCompleted) {
              completer.complete(builder.takeBytes());
            }
            return;
          }
          final remaining = maxBytes - builder.length;
          if (remaining <= 0) {
            unawaited(sub.cancel());
            if (!completer.isCompleted) {
              completer.complete(builder.takeBytes());
            }
            return;
          }
          if (chunk.length <= remaining) {
            builder.add(chunk);
          } else {
            builder.add(chunk.sublist(0, remaining));
            unawaited(sub.cancel());
            if (!completer.isCompleted) {
              completer.complete(builder.takeBytes());
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(builder.takeBytes());
          }
        },
        onError: (Object err, StackTrace st) {
          if (!completer.isCompleted) {
            completer.completeError(err, st);
          }
        },
        cancelOnError: true,
      );

      final bytes = await completer.future.timeout(timeout);
      sw.stop();

      final responseHeaders = <String, String>{};
      res.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      });

      return ProbeHttpResponse(
        statusCode: res.statusCode,
        finalUrl: resolvedUri.toString(),
        bodyBytes: bytes,
        headers: responseHeaders,
        elapsedMs: sw.elapsedMilliseconds,
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _MasterVariantInfo {
  const _MasterVariantInfo({
    required this.url,
    required this.width,
    required this.height,
    required this.bandwidth,
  });

  final String url;
  final int width;
  final int height;
  final int? bandwidth;
}
