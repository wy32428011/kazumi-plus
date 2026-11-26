import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

typedef HlsProxyFinder = String Function(Uri url);

/// 探针阶段已拉取的 M3U8 清单种子，供 `HlsProxyService` 零拷贝复用（TTL ≤ 15s）。
class HlsPreFetchedSeed {
  const HlsPreFetchedSeed({
    required this.sourceUrl,
    required this.finalUrl,
    required this.playlistBody,
    required this.resolvedCdnGroup,
    required this.fetchedAt,
  });

  final String sourceUrl;
  final String finalUrl;
  final String playlistBody;
  final String resolvedCdnGroup;
  final DateTime fetchedAt;

  bool isFresh({
    DateTime? now,
    Duration ttl = const Duration(seconds: 15),
  }) => (now ?? DateTime.now()).difference(fetchedAt) <= ttl;
}

/// 代理优先分片拉取失败回调载荷（用于 failoverAware 模式下快速触发容灾）。
class HlsProxySegmentFailure {
  const HlsProxySegmentFailure({
    required this.segmentUrl,
    required this.cdnGroup,
    required this.attempts,
    required this.error,
  });

  final String segmentUrl;
  final String cdnGroup;
  final int attempts;
  final Object error;
}

/// 准备完成的本地 HLS 代理会话句柄。
class HlsProxyPreparedSession {
  const HlsProxyPreparedSession({
    required this.sessionId,
    required this.localPlaylistUrl,
    required this.adFilteredByProxy,
    this.resolvedCdnGroup = '',
    this.usedPreFetchedSeed = false,
  });

  final String sessionId;
  final String localPlaylistUrl;
  final bool adFilteredByProxy;
  final String resolvedCdnGroup;
  final bool usedPreFetchedSeed;
}

/// 本地 HLS 并发分片预取代理服务。
///
/// 通过在 `127.0.0.1` 启动轻量 HTTP 代理，将远程 `.m3u8` 改写为本地地址，
/// 并针对当前播放/Seek 位置维护滑动窗口并发预取与内存 LRU 缓存，
/// 以缓解片源 CDN 单连接限速导致的连续缓冲问题。
class HlsProxyService {
  HlsProxyService({
    HttpClient Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory;

  static final HlsProxyService instance = HlsProxyService();

  final HttpClient Function()? _httpClientFactory;
  HttpServer? _server;
  Future<HttpServer>? _startingServer;
  final Map<String, _HlsProxySession> _sessions = {};
  final Random _random = Random();
  int _sessionCounter = 0;

  int? get port => _server?.port;

  Future<HttpServer> _ensureServer() async {
    final existing = _server;
    if (existing != null) {
      return existing;
    }
    return _startingServer ??= _startServer();
  }

  Future<HttpServer> _startServer() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.idleTimeout = const Duration(seconds: 60);
      server.listen(
        _handleRequest,
        onError: (Object error, StackTrace stackTrace) {
          KazumiLogger().w('HlsProxy: server stream error', error: error);
        },
      );
      _server = server;
      return server;
    } finally {
      _startingServer = null;
    }
  }

  /// 预拉取并校验远程 HLS 播放列表；若不适合代理（如非 M3U8、Live 流、
  /// 含 `#EXT-X-BYTERANGE` 或请求失败）则返回 `null`，调用方应回退直连播放。
  Future<HlsProxyPreparedSession?> prepareSession({
    required String url,
    required Map<String, String> headers,
    required bool adBlockerEnabled,
    int startOffsetSeconds = 0,
    bool constrained = false,
    bool prefetchSuspended = false,
    HlsProxyFinder? findProxy,
    Duration initialTimeout = const Duration(seconds: 8),
    HlsPreFetchedSeed? preFetchedSeed,
    bool failoverAware = false,
    void Function(HlsProxySegmentFailure failure)? onPrioritySegmentFailure,
    void Function(String cdnGroup)? onCdnGroupResolved,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }

    final server = await _ensureServer();
    final sessionId =
        '${++_sessionCounter}_${_random.nextInt(1 << 24).toRadixString(16)}';

    final effectiveSeed =
        preFetchedSeed != null &&
            preFetchedSeed.sourceUrl == url &&
            preFetchedSeed.isFresh()
        ? preFetchedSeed
        : null;

    final session = _HlsProxySession(
      sessionId: sessionId,
      basePath: '/s/$sessionId',
      sourceUrl: url,
      headers: Map<String, String>.from(headers),
      adBlockerEnabled: adBlockerEnabled,
      startOffsetSeconds: startOffsetSeconds,
      constrained: constrained,
      prefetchSuspended: prefetchSuspended,
      findProxy: findProxy,
      httpClientFactory: _httpClientFactory,
      preFetchedSeed: effectiveSeed,
      failoverAware: failoverAware,
      onPrioritySegmentFailure: onPrioritySegmentFailure,
      onCdnGroupResolved: onCdnGroupResolved,
    );

    try {
      final ready = await session.prepare(timeout: initialTimeout);
      if (!ready) {
        session.dispose();
        return null;
      }
      _sessions[sessionId] = session;
      return HlsProxyPreparedSession(
        sessionId: sessionId,
        localPlaylistUrl:
            'http://127.0.0.1:${server.port}/s/$sessionId/playlist.m3u8',
        adFilteredByProxy: adBlockerEnabled,
        resolvedCdnGroup: session.resolvedCdnGroup,
        usedPreFetchedSeed: effectiveSeed != null,
      );
    } catch (e) {
      session.dispose();
      KazumiLogger().w('HlsProxy: prepare failed, fallback to direct', error: e);
      return null;
    }
  }

  void setPrefetchSuspended(String? sessionId, bool suspended) {
    if (sessionId == null) return;
    _sessions[sessionId]?.setPrefetchSuspended(suspended);
  }

  void setConstrained(String? sessionId, bool constrained) {
    if (sessionId == null) return;
    _sessions[sessionId]?.setConstrained(constrained);
  }

  void closeSession(String? sessionId) {
    if (sessionId == null) return;
    final session = _sessions.remove(sessionId);
    session?.dispose();
  }

  Future<void> dispose() async {
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    // Expected: /s/<sessionId>/...
    if (segments.length < 3 || segments[0] != 's') {
      await _writeError(request, HttpStatus.notFound);
      return;
    }
    final session = _sessions[segments[1]];
    if (session == null || session.closed) {
      await _writeError(request, HttpStatus.notFound);
      return;
    }

    try {
      await session.handleRequest(request, segments.sublist(2));
    } catch (_) {
      await _writeError(request, HttpStatus.badGateway);
    }
  }

  static Future<void> _writeError(HttpRequest request, int statusCode) async {
    try {
      request.response.statusCode = statusCode;
      await request.response.close();
    } catch (_) {}
  }
}

class _HlsProxySession {
  _HlsProxySession({
    required this.sessionId,
    required this.basePath,
    required this.sourceUrl,
    required this.headers,
    required this.adBlockerEnabled,
    required this.startOffsetSeconds,
    required bool constrained,
    required bool prefetchSuspended,
    required HlsProxyFinder? findProxy,
    HttpClient Function()? httpClientFactory,
    HlsPreFetchedSeed? preFetchedSeed,
    this.failoverAware = false,
    this.onPrioritySegmentFailure,
    this.onCdnGroupResolved,
  }) : _constrained = constrained,
       _prefetchSuspended = prefetchSuspended,
       _preFetchedSeed = preFetchedSeed,
       _resolvedCdnGroup = preFetchedSeed?.resolvedCdnGroup ?? '' {
    _client = httpClientFactory?.call() ?? HttpClient();
    _client.maxConnectionsPerHost = 6;
    _client.connectionTimeout = failoverAware
        ? const Duration(seconds: 6)
        : const Duration(seconds: 12);
    _client.idleTimeout = const Duration(seconds: 30);
    if (findProxy != null) {
      _client.findProxy = findProxy;
    }
  }

  final String sessionId;
  final String basePath;
  final String sourceUrl;
  final Map<String, String> headers;
  final bool adBlockerEnabled;
  final int startOffsetSeconds;
  final HlsPreFetchedSeed? _preFetchedSeed;
  final bool failoverAware;
  final void Function(HlsProxySegmentFailure failure)? onPrioritySegmentFailure;
  final void Function(String cdnGroup)? onCdnGroupResolved;

  String _resolvedCdnGroup;
  String get resolvedCdnGroup => _resolvedCdnGroup;

  late final HttpClient _client;
  bool _constrained;
  bool _prefetchSuspended;
  bool _closed = false;
  bool get closed => _closed;

  int get _maxConcurrency => _constrained ? 2 : 4;
  int get _prefetchAhead => _constrained ? 3 : 6;
  int get _maxCacheBytes =>
      _constrained ? 12 * 1024 * 1024 : 32 * 1024 * 1024;

  void _updateResolvedCdnGroup(String url) {
    final cdn = SourceHealthRepository.normalizeCdnGroup(url);
    if (cdn.isEmpty || cdn == _resolvedCdnGroup) return;
    _resolvedCdnGroup = cdn;
    try {
      onCdnGroupResolved?.call(cdn);
    } catch (_) {}
  }

  String? _rootPlaylistBody;

  final List<String> _variantUrls = [];
  final Set<int> _subtitleVariantIds = {};
  final Map<int, _VariantMediaState> _variants = {};
  final Map<int, Future<_VariantMediaState?>> _variantLoads = {};

  final List<String> _keyUrls = [];
  final Map<String, int> _keyUrlToId = {};
  final Map<int, Uint8List> _keyCache = {};
  final Map<int, Future<Uint8List>> _keyInFlight = {};

  final List<String> _mapUrls = [];
  final Map<String, int> _mapUrlToId = {};
  final Map<int, Uint8List> _mapCache = {};
  final Map<int, Future<Uint8List>> _mapInFlight = {};

  // LRU segment cache keyed by "$variantId:$segIndex".
  final LinkedHashMap<String, Uint8List> _segmentCache = LinkedHashMap();
  int _cachedBytes = 0;

  // Deduplicates concurrent requests for the same segment.
  final Map<String, Future<Uint8List>> _segmentInFlight = {};

  // Background prefetch scheduler.
  final Queue<_PrefetchTask> _prefetchQueue = Queue();
  final Set<String> _prefetchQueuedKeys = {};
  int _activePrefetchCount = 0;

  void setPrefetchSuspended(bool suspended) {
    _prefetchSuspended = suspended;
    if (!suspended && !_closed) {
      _pumpPrefetchQueue();
    }
  }

  void setConstrained(bool constrained) {
    _constrained = constrained;
    _evictIfNeeded();
    if (!_closed && !_prefetchSuspended) {
      _pumpPrefetchQueue();
    }
  }

  Future<bool> prepare({required Duration timeout}) async {
    final _FetchedText? fetched;
    final seed = _preFetchedSeed;
    if (seed != null && seed.playlistBody.isNotEmpty) {
      fetched = _FetchedText(body: seed.playlistBody, finalUrl: seed.finalUrl);
      if (seed.resolvedCdnGroup.isNotEmpty) {
        _resolvedCdnGroup = seed.resolvedCdnGroup;
      }
    } else {
      fetched = await _fetchText(sourceUrl, timeout: timeout);
    }
    if (fetched == null || _closed) return false;
    final content = fetched.body;
    final finalUrl = fetched.finalUrl;

    if (!content.contains('#EXTM3U')) {
      return false;
    }

    if (M3u8Parser.detectType(content) == M3u8Type.master) {
      _rootPlaylistBody = _rewriteMasterPlaylist(content, finalUrl);
      if (_variantUrls.isEmpty) {
        return false;
      }
      return true;
    }

    final mediaState = await _buildMediaState(
      variantId: 0,
      content: content,
      baseUrl: finalUrl,
      timeout: timeout,
    );
    if (mediaState == null) {
      return false;
    }
    _variants[0] = mediaState;
    _rootPlaylistBody = mediaState.rewrittenPlaylist;
    if (_resolvedCdnGroup.isEmpty && mediaState.segments.isNotEmpty) {
      _updateResolvedCdnGroup(mediaState.segments.first.uri);
    }

    final startIndex = _segmentIndexForOffset(
      mediaState.segments,
      startOffsetSeconds,
    );
    mediaState.lastRequestedIndex = startIndex;
    if (!_prefetchSuspended) {
      _schedulePrefetch(mediaState, startIndex);
    }
    return true;
  }

  Future<void> handleRequest(
    HttpRequest request,
    List<String> subPath,
  ) async {
    final isHead = request.method.toUpperCase() == 'HEAD';

    // /playlist.m3u8
    if (subPath.length == 1 && subPath[0] == 'playlist.m3u8') {
      final body = _rootPlaylistBody;
      if (body == null) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }
      await _writeBytes(
        request,
        Uint8List.fromList(utf8.encode(body)),
        contentType: 'application/vnd.apple.mpegurl; charset=utf-8',
        headOnly: isHead,
      );
      return;
    }

    // /variant/<id>.m3u8
    if (subPath.length == 2 &&
        subPath[0] == 'variant' &&
        subPath[1].endsWith('.m3u8')) {
      final idStr = subPath[1].substring(0, subPath[1].length - 5);
      final variantId = int.tryParse(idStr);
      if (variantId == null ||
          variantId < 0 ||
          variantId >= _variantUrls.length) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }
      final state = await _loadVariant(variantId);
      if (state == null || _closed) {
        await HlsProxyService._writeError(request, HttpStatus.badGateway);
        return;
      }
      await _writeBytes(
        request,
        Uint8List.fromList(utf8.encode(state.rewrittenPlaylist)),
        contentType: 'application/vnd.apple.mpegurl; charset=utf-8',
        headOnly: isHead,
      );
      return;
    }

    // /v/<variantId>/seg/<segIndex>.<ext>
    if (subPath.length == 4 && subPath[0] == 'v' && subPath[2] == 'seg') {
      final variantId = int.tryParse(subPath[1]);
      final fileName = subPath[3];
      final dot = fileName.lastIndexOf('.');
      final segIndex = int.tryParse(
        dot > 0 ? fileName.substring(0, dot) : fileName,
      );
      if (variantId == null || segIndex == null) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }
      final variant = _variants[variantId];
      if (variant == null ||
          segIndex < 0 ||
          segIndex >= variant.segments.length) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }

      variant.lastRequestedIndex = segIndex;
      if (!_prefetchSuspended) {
        _schedulePrefetch(variant, segIndex + 1);
      }

      final bytes = await _getSegmentBytes(variant, segIndex, priority: true);
      if (_closed) {
        await HlsProxyService._writeError(request, HttpStatus.serviceUnavailable);
        return;
      }
      final ext = dot > 0 ? fileName.substring(dot + 1).toLowerCase() : 'ts';
      final contentType = _segmentContentType(ext);
      await _writeBytes(
        request,
        bytes,
        contentType: contentType,
        headOnly: isHead,
      );
      return;
    }

    // /key/<keyId>
    if (subPath.length == 2 && subPath[0] == 'key') {
      final keyId = int.tryParse(subPath[1]);
      if (keyId == null || keyId < 0 || keyId >= _keyUrls.length) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }
      final bytes = await _getSmallResource(
        id: keyId,
        url: _keyUrls[keyId],
        cache: _keyCache,
        inFlight: _keyInFlight,
      );
      await _writeBytes(
        request,
        bytes,
        contentType: 'application/octet-stream',
        headOnly: isHead,
      );
      return;
    }

    // /map/<mapId>
    if (subPath.length == 2 && subPath[0] == 'map') {
      final mapId = int.tryParse(subPath[1]);
      if (mapId == null || mapId < 0 || mapId >= _mapUrls.length) {
        await HlsProxyService._writeError(request, HttpStatus.notFound);
        return;
      }
      final bytes = await _getSmallResource(
        id: mapId,
        url: _mapUrls[mapId],
        cache: _mapCache,
        inFlight: _mapInFlight,
      );
      await _writeBytes(
        request,
        bytes,
        contentType: 'video/mp4',
        headOnly: isHead,
      );
      return;
    }

    await HlsProxyService._writeError(request, HttpStatus.notFound);
  }

  String _rewriteMasterPlaylist(String content, String baseUrl) {
    final lines = content.split(RegExp(r'\r?\n'));
    final sb = StringBuffer();
    bool expectVariantUri = false;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-MEDIA:')) {
        final isSubtitle = RegExp(
          r'(?:^|,)TYPE=SUBTITLES(?:,|$)',
        ).hasMatch(line.substring('#EXT-X-MEDIA:'.length));
        final rewritten = _rewriteQuotedUriAttribute(
          line,
          baseUrl,
          (resolvedUrl) {
            final id = _registerVariantUrl(resolvedUrl);
            if (isSubtitle) {
              _subtitleVariantIds.add(id);
            }
            return '$basePath/variant/$id.m3u8';
          },
        );
        sb.writeln(rewritten);
        continue;
      }

      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        expectVariantUri = true;
        sb.writeln(line);
        continue;
      }

      if (expectVariantUri && !line.startsWith('#')) {
        expectVariantUri = false;
        final resolved = M3u8Parser.resolveUrl(baseUrl, line);
        final id = _registerVariantUrl(resolved);
        sb.writeln('$basePath/variant/$id.m3u8');
        continue;
      }

      if (line.startsWith('#EXT')) {
        expectVariantUri = false;
      }
      sb.writeln(line);
    }

    return sb.toString();
  }

  int _registerVariantUrl(String url) {
    final existing = _variantUrls.indexOf(url);
    if (existing >= 0) return existing;
    _variantUrls.add(url);
    return _variantUrls.length - 1;
  }

  Future<_VariantMediaState?> _loadVariant(int variantId) {
    final cached = _variants[variantId];
    if (cached != null) return Future.value(cached);
    return _variantLoads.putIfAbsent(variantId, () async {
      try {
        final fetched = await _fetchText(_variantUrls[variantId]);
        if (fetched == null || _closed) return null;
        final state = await _buildMediaState(
          variantId: variantId,
          content: fetched.body,
          baseUrl: fetched.finalUrl,
        );
        if (state == null) return null;
        _variants[variantId] = state;
        final startIndex = _segmentIndexForOffset(
          state.segments,
          startOffsetSeconds,
        );
        state.lastRequestedIndex = startIndex;
        if (!_prefetchSuspended) {
          _schedulePrefetch(state, startIndex);
        }
        return state;
      } finally {
        _variantLoads.remove(variantId);
      }
    });
  }

  Future<_VariantMediaState?> _buildMediaState({
    required int variantId,
    required String content,
    required String baseUrl,
    Duration? timeout,
    int depth = 0,
  }) async {
    if (!content.contains('#EXTM3U')) return null;
    // 含 BYTERANGE 的播放列表直接回退 mpv 原生处理，避免字节偏移错位。
    if (content.contains('#EXT-X-BYTERANGE')) return null;

    final hasEndList = content.contains('#EXT-X-ENDLIST');
    final isExplicitEvent = content.contains('#EXT-X-PLAYLIST-TYPE:EVENT');
    if (isExplicitEvent) return null;

    final parsed = _parseRichMediaPlaylist(content, baseUrl);
    if (parsed.segments.isEmpty) return null;

    // 部分源将单个嵌套 .m3u8 包装在媒体列表中，自动展开一层。
    if (depth == 0 &&
        parsed.segments.length == 1 &&
        Uri.tryParse(parsed.segments.first.uri)?.path.toLowerCase().endsWith(
              '.m3u8',
            ) ==
            true) {
      final nested = await _fetchText(
        parsed.segments.first.uri,
        timeout: timeout,
      );
      if (nested == null || _closed) return null;
      return _buildMediaState(
        variantId: variantId,
        content: nested.body,
        baseUrl: nested.finalUrl,
        timeout: timeout,
        depth: depth + 1,
      );
    }

    final isSubtitleVariant = _subtitleVariantIds.contains(variantId);

    // 若缺少 ENDLIST 且分片数很少，大概率是直播滑动窗口，回退直连（字幕清单可能只有极少分片）。
    if (!isSubtitleVariant && !hasEndList && parsed.segments.length < 10) {
      return null;
    }

    // 多个分片中混入嵌套 .m3u8 时回退直连，避免阻塞初始化。
    if (parsed.segments.any(
      (s) => Uri.tryParse(s.uri)?.path.toLowerCase().endsWith('.m3u8') == true,
    )) {
      return null;
    }

    var segments = parsed.segments;
    final applyAdFilter = adBlockerEnabled && !isSubtitleVariant;
    if (applyAdFilter) {
      final m3u8Segs = segments
          .map(
            (s) => M3u8Segment(
              duration: s.duration,
              uri: s.uri,
              discontinuityGroup: s.discontinuityGroup,
              key: s.key,
            ),
          )
          .toList(growable: false);
      final filtered = M3u8AdFilter.filterAds(m3u8Segs);
      if (filtered.length != m3u8Segs.length) {
        final keptGroups = filtered.map((e) => e.discontinuityGroup).toSet();
        segments = segments
            .where((s) => keptGroups.contains(s.discontinuityGroup))
            .toList(growable: false);
      }
    }
    if (segments.isEmpty) return null;

    final targetDuration = applyAdFilter
        ? segments.fold<double>(
            0,
            (maxVal, s) => s.duration > maxVal ? s.duration : maxVal,
          )
        : parsed.targetDuration;

    final rewritten = _rewriteMediaPlaylist(
      variantId: variantId,
      segments: segments,
      targetDuration: targetDuration > 0 ? targetDuration : 6,
      version: parsed.version,
    );

    return _VariantMediaState(
      variantId: variantId,
      segments: segments,
      rewrittenPlaylist: rewritten,
    );
  }

  String _rewriteMediaPlaylist({
    required int variantId,
    required List<_RichSegment> segments,
    required double targetDuration,
    required int version,
  }) {
    final sb = StringBuffer();
    sb.writeln('#EXTM3U');
    sb.writeln('#EXT-X-VERSION:$version');
    sb.writeln('#EXT-X-TARGETDURATION:${targetDuration.ceil()}');
    sb.writeln('#EXT-X-MEDIA-SEQUENCE:0');
    sb.writeln('#EXT-X-PLAYLIST-TYPE:VOD');

    M3u8Key? lastKey;
    String? lastMapUrl;
    int lastDiscontinuityGroup = segments.first.discontinuityGroup;

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.discontinuityGroup != lastDiscontinuityGroup) {
        sb.writeln('#EXT-X-DISCONTINUITY');
        lastDiscontinuityGroup = seg.discontinuityGroup;
        lastKey = null;
        lastMapUrl = null;
      }

      if (seg.mapUrl != lastMapUrl) {
        if (seg.mapUrl != null) {
          final mapId = _registerMapUrl(seg.mapUrl!);
          sb.writeln('#EXT-X-MAP:URI="$basePath/map/$mapId"');
        }
        lastMapUrl = seg.mapUrl;
      }

      if (seg.key != lastKey) {
        if (seg.key == null) {
          sb.writeln('#EXT-X-KEY:METHOD=NONE');
        } else {
          final keyId = _registerKeyUrl(seg.key!.uri);
          final localKey = M3u8Key(
            method: seg.key!.method,
            uri: '$basePath/key/$keyId',
            iv: seg.key!.iv,
          );
          sb.writeln(localKey.toString());
        }
        lastKey = seg.key;
      }

      sb.writeln('#EXTINF:${seg.duration.toStringAsFixed(6)},');
      final ext = _segmentExtension(seg.uri);
      sb.writeln('$basePath/v/$variantId/seg/$i.$ext');
    }

    sb.writeln('#EXT-X-ENDLIST');
    return sb.toString();
  }

  static String _segmentExtension(String uri) {
    final segPath = Uri.tryParse(uri)?.path.toLowerCase() ?? '';
    if (segPath.endsWith('.vtt')) return 'vtt';
    if (segPath.endsWith('.webvtt')) return 'webvtt';
    if (segPath.endsWith('.srt')) return 'srt';
    if (segPath.endsWith('.ass')) return 'ass';
    if (segPath.endsWith('.ssa')) return 'ssa';
    if (segPath.endsWith('.ttml')) return 'ttml';
    if (segPath.endsWith('.m4s')) return 'm4s';
    if (segPath.endsWith('.mp4')) return 'mp4';
    if (segPath.endsWith('.m4a')) return 'm4a';
    if (segPath.endsWith('.aac')) return 'aac';
    if (segPath.endsWith('.mp3')) return 'mp3';
    return 'ts';
  }

  static String _segmentContentType(String ext) {
    switch (ext) {
      case 'vtt':
      case 'webvtt':
        return 'text/vtt; charset=utf-8';
      case 'srt':
        return 'application/x-subrip; charset=utf-8';
      case 'ass':
      case 'ssa':
        return 'text/plain; charset=utf-8';
      case 'ttml':
        return 'application/ttml+xml; charset=utf-8';
      case 'm4s':
      case 'mp4':
      case 'm4a':
        return 'video/iso.segment';
      case 'aac':
        return 'audio/aac';
      case 'mp3':
        return 'audio/mpeg';
      default:
        return 'video/mp2t';
    }
  }

  int _registerKeyUrl(String url) {
    return _keyUrlToId.putIfAbsent(url, () {
      _keyUrls.add(url);
      return _keyUrls.length - 1;
    });
  }

  int _registerMapUrl(String url) {
    return _mapUrlToId.putIfAbsent(url, () {
      _mapUrls.add(url);
      return _mapUrls.length - 1;
    });
  }

  int _segmentIndexForOffset(List<_RichSegment> segments, int offsetSeconds) {
    if (offsetSeconds <= 0 || segments.isEmpty) return 0;
    double elapsed = 0;
    for (var i = 0; i < segments.length; i++) {
      elapsed += segments[i].duration;
      if (elapsed > offsetSeconds) {
        return i;
      }
    }
    return segments.length - 1;
  }

  void _schedulePrefetch(_VariantMediaState variant, int startIndex) {
    if (_closed || _prefetchSuspended) return;
    final endExclusive = min(
      variant.segments.length,
      startIndex + _prefetchAhead,
    );
    for (var i = startIndex; i < endExclusive; i++) {
      final key = '${variant.variantId}:$i';
      if (_segmentCache.containsKey(key) ||
          _segmentInFlight.containsKey(key) ||
          _prefetchQueuedKeys.contains(key)) {
        continue;
      }
      _prefetchQueuedKeys.add(key);
      _prefetchQueue.add(_PrefetchTask(variant: variant, segIndex: i));
    }
    _pumpPrefetchQueue();
  }

  void _pumpPrefetchQueue() {
    while (!_closed &&
        !_prefetchSuspended &&
        _activePrefetchCount < _maxConcurrency &&
        _prefetchQueue.isNotEmpty) {
      final task = _prefetchQueue.removeFirst();
      final key = '${task.variant.variantId}:${task.segIndex}';
      _prefetchQueuedKeys.remove(key);

      // 若播放器已经 Seek 离开该窗口，丢弃过期预取任务。
      final anchor = task.variant.lastRequestedIndex;
      if (task.segIndex < anchor ||
          task.segIndex > anchor + _prefetchAhead) {
        continue;
      }
      if (_segmentCache.containsKey(key) || _segmentInFlight.containsKey(key)) {
        continue;
      }

      _activePrefetchCount++;
      unawaited(
        _getSegmentBytes(task.variant, task.segIndex, priority: false)
            .catchError((Object _) => Uint8List(0))
            .whenComplete(() {
              _activePrefetchCount--;
              _pumpPrefetchQueue();
            }),
      );
    }
  }

  Future<Uint8List> _getSegmentBytes(
    _VariantMediaState variant,
    int segIndex, {
    required bool priority,
  }) {
    final key = '${variant.variantId}:$segIndex';
    final cached = _segmentCache.remove(key);
    if (cached != null) {
      // LRU touch
      _segmentCache[key] = cached;
      return Future.value(cached);
    }

    final existing = _segmentInFlight[key];
    if (existing != null) {
      return existing;
    }

    final url = variant.segments[segIndex].uri;
    final effectiveRetries = priority ? (failoverAware ? 2 : 3) : 2;
    final future = _fetchBytesWithRetry(
      url,
      maxRetries: effectiveRetries,
      priority: priority,
    )
        .then((bytes) {
          if (!_closed && bytes.isNotEmpty) {
            _putSegmentCache(key, bytes);
          }
          return bytes;
        })
        .catchError((Object error, StackTrace stackTrace) {
          if (priority && failoverAware && !_closed) {
            try {
              onPrioritySegmentFailure?.call(
                HlsProxySegmentFailure(
                  segmentUrl: url,
                  cdnGroup: _resolvedCdnGroup.isNotEmpty
                      ? _resolvedCdnGroup
                      : SourceHealthRepository.normalizeCdnGroup(url),
                  attempts: effectiveRetries,
                  error: error,
                ),
              );
            } catch (_) {}
          }
          Error.throwWithStackTrace(error, stackTrace);
        })
        .whenComplete(() {
          _segmentInFlight.remove(key);
        });

    _segmentInFlight[key] = future;
    return future;
  }

  void _putSegmentCache(String key, Uint8List bytes) {
    final previous = _segmentCache.remove(key);
    if (previous != null) {
      _cachedBytes -= previous.length;
    }
    _segmentCache[key] = bytes;
    _cachedBytes += bytes.length;
    _evictIfNeeded();
  }

  void _evictIfNeeded() {
    while (_cachedBytes > _maxCacheBytes && _segmentCache.length > 1) {
      final oldestKey = _segmentCache.keys.first;
      final removed = _segmentCache.remove(oldestKey);
      if (removed != null) {
        _cachedBytes -= removed.length;
      }
    }
  }

  Future<Uint8List> _getSmallResource({
    required int id,
    required String url,
    required Map<int, Uint8List> cache,
    required Map<int, Future<Uint8List>> inFlight,
  }) {
    final cached = cache[id];
    if (cached != null) return Future.value(cached);
    return inFlight.putIfAbsent(id, () async {
      try {
        final bytes = await _fetchBytesWithRetry(url, maxRetries: 3);
        if (!_closed) {
          cache[id] = bytes;
        }
        return bytes;
      } finally {
        inFlight.remove(id);
      }
    });
  }

  Future<_FetchedText?> _fetchText(String url, {Duration? timeout}) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 12);
    for (var attempt = 0; attempt < 2; attempt++) {
      if (_closed) return null;
      try {
        final uri = Uri.parse(url);
        final req = await _client.getUrl(uri).timeout(effectiveTimeout);
        _applyHeaders(req);
        req.followRedirects = true;
        req.maxRedirects = 5;
        final res = await req.close().timeout(effectiveTimeout);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          await res.drain<void>();
          if (_isRetryableStatus(res.statusCode) && attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            continue;
          }
          return null;
        }
        final bytes = await _collectBytes(res).timeout(effectiveTimeout);
        var resolvedUri = uri;
        for (final redirect in res.redirects) {
          resolvedUri = resolvedUri.resolveUri(redirect.location);
        }
        return _FetchedText(
          body: utf8.decode(bytes, allowMalformed: true),
          finalUrl: resolvedUri.toString(),
        );
      } catch (_) {
        if (attempt == 0 && !_closed) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        return null;
      }
    }
    return null;
  }

  Future<Uint8List> _fetchBytesWithRetry(
    String url, {
    required int maxRetries,
    bool priority = false,
  }) async {
    final connectTimeout = (failoverAware && priority)
        ? const Duration(seconds: 6)
        : const Duration(seconds: 15);
    final bodyTimeout = (failoverAware && priority)
        ? const Duration(seconds: 12)
        : const Duration(seconds: 30);
    Object? lastError;
    for (var attempt = 0; attempt < maxRetries; attempt++) {
      if (_closed) {
        throw const HttpException('HLS proxy session closed');
      }
      try {
        final uri = Uri.parse(url);
        final req = await _client.getUrl(uri).timeout(connectTimeout);
        _applyHeaders(req);
        req.followRedirects = true;
        req.maxRedirects = 5;
        final res = await req.close().timeout(connectTimeout);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          await res.drain<void>();
          if (_isRetryableStatus(res.statusCode) && attempt + 1 < maxRetries) {
            await Future<void>.delayed(
              Duration(milliseconds: 200 * (attempt + 1)),
            );
            continue;
          }
          throw HttpException('Upstream HTTP ${res.statusCode}', uri: uri);
        }
        var resolvedUri = uri;
        for (final redirect in res.redirects) {
          resolvedUri = resolvedUri.resolveUri(redirect.location);
        }
        _updateResolvedCdnGroup(resolvedUri.toString());
        return await _collectBytes(res).timeout(bodyTimeout);
      } catch (e) {
        lastError = e;
        if (_closed || attempt + 1 >= maxRetries) {
          rethrow;
        }
        await Future<void>.delayed(
          Duration(milliseconds: 200 * (attempt + 1)),
        );
      }
    }
    throw lastError ?? const HttpException('Upstream fetch failed');
  }

  void _applyHeaders(HttpClientRequest request) {
    headers.forEach((key, value) {
      final lower = key.toLowerCase();
      if (lower == 'host' ||
          lower == 'content-length' ||
          lower == 'connection') {
        return;
      }
      request.headers.set(key, value);
    });
  }

  static bool _isRetryableStatus(int code) {
    return code == 429 || (code >= 500 && code < 600);
  }

  static Future<Uint8List> _collectBytes(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<void> _writeBytes(
    HttpRequest request,
    Uint8List bytes, {
    required String contentType,
    required bool headOnly,
  }) async {
    try {
      final response = request.response;
      response.statusCode = HttpStatus.ok;
      response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      response.contentLength = bytes.length;
      if (!headOnly) {
        response.add(bytes);
      }
      await response.close();
    } catch (_) {
      // mpv 在 seek 或切集时会主动关闭本地连接，忽略写端异常。
    }
  }

  static String _rewriteQuotedUriAttribute(
    String line,
    String baseUrl,
    String Function(String resolvedUrl) replace,
  ) {
    return line.replaceFirstMapped(RegExp(r'URI="([^"]+)"'), (match) {
      final raw = match.group(1)!;
      final resolved = M3u8Parser.resolveUrl(baseUrl, raw);
      return 'URI="${replace(resolved)}"';
    });
  }

  static _ParsedRichPlaylist _parseRichMediaPlaylist(
    String content,
    String baseUrl,
  ) {
    final lines = content.split(RegExp(r'\r?\n')).map((l) => l.trim());
    final segments = <_RichSegment>[];
    double targetDuration = 0;
    int version = 3;
    int discontinuityGroup = 0;
    M3u8Key? currentKey;
    String? currentMapUrl;
    double currentDuration = 0;

    for (final line in lines) {
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-VERSION:')) {
        version =
            int.tryParse(line.substring('#EXT-X-VERSION:'.length)) ?? version;
      } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
        targetDuration =
            double.tryParse(line.substring('#EXT-X-TARGETDURATION:'.length)) ??
            targetDuration;
      } else if (line == '#EXT-X-DISCONTINUITY') {
        discontinuityGroup++;
      } else if (line.startsWith('#EXT-X-KEY:')) {
        currentKey = _parseKeyLine(line, baseUrl);
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line);
        if (uriMatch != null) {
          currentMapUrl = M3u8Parser.resolveUrl(baseUrl, uriMatch.group(1)!);
        }
      } else if (line.startsWith('#EXTINF:')) {
        final durationStr = line.substring('#EXTINF:'.length).split(',')[0];
        currentDuration = double.tryParse(durationStr) ?? 0;
      } else if (!line.startsWith('#')) {
        segments.add(
          _RichSegment(
            duration: currentDuration,
            uri: M3u8Parser.resolveUrl(baseUrl, line),
            discontinuityGroup: discontinuityGroup,
            key: currentKey,
            mapUrl: currentMapUrl,
          ),
        );
        currentDuration = 0;
      }
    }

    return _ParsedRichPlaylist(
      segments: segments,
      targetDuration: targetDuration,
      version: version,
    );
  }

  static M3u8Key? _parseKeyLine(String line, String baseUrl) {
    final attrs = line.substring('#EXT-X-KEY:'.length);
    final methodMatch = RegExp(r'METHOD=([^,]+)').firstMatch(attrs);
    final method = methodMatch?.group(1) ?? 'NONE';
    if (method == 'NONE') return null;

    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(attrs);
    final uri = uriMatch != null
        ? M3u8Parser.resolveUrl(baseUrl, uriMatch.group(1)!)
        : '';
    final ivMatch = RegExp(r'IV=(0x[0-9a-fA-F]+)').firstMatch(attrs);
    return M3u8Key(method: method, uri: uri, iv: ivMatch?.group(1));
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _prefetchQueue.clear();
    _prefetchQueuedKeys.clear();
    _segmentCache.clear();
    _cachedBytes = 0;
    _keyCache.clear();
    _mapCache.clear();
    _client.close(force: true);
  }
}

class _FetchedText {
  const _FetchedText({required this.body, required this.finalUrl});
  final String body;
  final String finalUrl;
}

class _ParsedRichPlaylist {
  const _ParsedRichPlaylist({
    required this.segments,
    required this.targetDuration,
    required this.version,
  });

  final List<_RichSegment> segments;
  final double targetDuration;
  final int version;
}

class _RichSegment {
  const _RichSegment({
    required this.duration,
    required this.uri,
    required this.discontinuityGroup,
    this.key,
    this.mapUrl,
  });

  final double duration;
  final String uri;
  final int discontinuityGroup;
  final M3u8Key? key;
  final String? mapUrl;
}

class _VariantMediaState {
  _VariantMediaState({
    required this.variantId,
    required this.segments,
    required this.rewrittenPlaylist,
  });

  final int variantId;
  final List<_RichSegment> segments;
  final String rewrittenPlaylist;
  int lastRequestedIndex = 0;
}

class _PrefetchTask {
  const _PrefetchTask({required this.variant, required this.segIndex});

  final _VariantMediaState variant;
  final int segIndex;
}
