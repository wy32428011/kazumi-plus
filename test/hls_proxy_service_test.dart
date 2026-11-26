import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/hls_proxy_service.dart';

Future<({int statusCode, String? contentType, Uint8List bytes})> _httpGet(
  String url,
) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return (
      statusCode: res.statusCode,
      contentType: res.headers.contentType?.toString(),
      bytes: builder.takeBytes(),
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late HttpServer upstream;
  late HlsProxyService proxy;
  late Map<String, int> requestCounts;
  late Map<String, String> lastHeaders;
  late int maxConcurrentSegments;
  late int currentConcurrentSegments;
  late Duration segmentDelay;
  late Map<String, String> playlists;

  setUp(() async {
    requestCounts = {};
    lastHeaders = {};
    maxConcurrentSegments = 0;
    currentConcurrentSegments = 0;
    segmentDelay = Duration.zero;
    playlists = {};

    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((HttpRequest req) async {
      final path = req.uri.path;
      requestCounts[path] = (requestCounts[path] ?? 0) + 1;
      req.headers.forEach((name, values) {
        lastHeaders[name.toLowerCase()] = values.join(', ');
      });

      if (playlists.containsKey(path)) {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
          charset: 'utf-8',
        );
        req.response.write(playlists[path]);
        await req.response.close();
        return;
      }

      if (path == '/enc.key') {
        req.response.statusCode = HttpStatus.ok;
        req.response.add(List<int>.generate(16, (i) => i + 1));
        await req.response.close();
        return;
      }

      if (path.startsWith('/sub_') && path.endsWith('.vtt')) {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType(
          'text',
          'vtt',
          charset: 'utf-8',
        );
        req.response.add(utf8.encode('WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n你好字幕\n'));
        await req.response.close();
        return;
      }

      if (path.startsWith('/seg_') && path.endsWith('.ts')) {
        currentConcurrentSegments++;
        if (currentConcurrentSegments > maxConcurrentSegments) {
          maxConcurrentSegments = currentConcurrentSegments;
        }
        try {
          if (segmentDelay > Duration.zero) {
            await Future<void>.delayed(segmentDelay);
          }
          req.response.statusCode = HttpStatus.ok;
          req.response.add(utf8.encode('DATA:$path'));
          await req.response.close();
        } finally {
          currentConcurrentSegments--;
        }
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    proxy = HlsProxyService();
  });

  tearDown(() async {
    await proxy.dispose();
    await upstream.close(force: true);
  });

  String upstreamUrl(String path) => 'http://127.0.0.1:${upstream.port}$path';

  test('rewrites VOD playlist with AES key, forwards headers, and caches prefetched segments', () async {
    playlists['/vod.m3u8'] = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-KEY:METHOD=AES-128,URI="/enc.key",IV=0x00000000000000000000000000000001
#EXTINF:4.0,
/seg_0.ts
#EXTINF:4.0,
/seg_1.ts
#EXTINF:4.0,
/seg_2.ts
#EXTINF:4.0,
/seg_3.ts
#EXTINF:4.0,
/seg_4.ts
#EXT-X-ENDLIST
''';

    segmentDelay = const Duration(milliseconds: 60);

    final prepared = await proxy.prepareSession(
      url: upstreamUrl('/vod.m3u8'),
      headers: const {
        'User-Agent': 'KazumiTestUA/1.0',
        'Referer': 'https://example.test/watch',
      },
      adBlockerEnabled: false,
    );

    expect(prepared, isNotNull);
    expect(lastHeaders['user-agent'], 'KazumiTestUA/1.0');
    expect(lastHeaders['referer'], 'https://example.test/watch');

    final playlistRes = await _httpGet(prepared!.localPlaylistUrl);
    expect(playlistRes.statusCode, HttpStatus.ok);
    final rewritten = utf8.decode(playlistRes.bytes);
    expect(rewritten, contains('/s/${prepared.sessionId}/key/0'));
    expect(rewritten, contains('/s/${prepared.sessionId}/v/0/seg/0.ts'));
    expect(rewritten, contains('/s/${prepared.sessionId}/v/0/seg/4.ts'));

    // Fetch key via local proxy
    final keyRes = await _httpGet(
      'http://127.0.0.1:${proxy.port}/s/${prepared.sessionId}/key/0',
    );
    expect(keyRes.statusCode, HttpStatus.ok);
    expect(keyRes.bytes.length, 16);

    // Fetch segments 0..3 via local proxy
    for (var i = 0; i < 4; i++) {
      final segRes = await _httpGet(
        'http://127.0.0.1:${proxy.port}/s/${prepared.sessionId}/v/0/seg/$i.ts',
      );
      expect(segRes.statusCode, HttpStatus.ok);
      expect(utf8.decode(segRes.bytes), 'DATA:/seg_$i.ts');
    }

    // Wait briefly for in-flight prefetches to settle
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Concurrent prefetching should have overlapped multiple segment requests
    expect(maxConcurrentSegments, greaterThanOrEqualTo(2));
    // Deduplication + LRU cache: each segment fetched from upstream only once
    expect(requestCounts['/seg_0.ts'], 1);
    expect(requestCounts['/seg_1.ts'], 1);
    expect(requestCounts['/seg_2.ts'], 1);
    expect(requestCounts['/seg_3.ts'], 1);

    // Closing session makes subsequent requests 404
    proxy.closeSession(prepared.sessionId);
    final afterClose = await _httpGet(prepared.localPlaylistUrl);
    expect(afterClose.statusCode, HttpStatus.notFound);
  });

  test('preserves Master Playlist variants and proxies variant media playlists', () async {
    playlists['/master.m3u8'] = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
/1080p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1500000,RESOLUTION=1280x720
/720p.m3u8
''';
    playlists['/1080p.m3u8'] = '''
#EXTM3U
#EXT-X-TARGETDURATION:5
#EXTINF:5.0,
/seg_10.ts
#EXTINF:5.0,
/seg_11.ts
#EXT-X-ENDLIST
''';

    final prepared = await proxy.prepareSession(
      url: upstreamUrl('/master.m3u8'),
      headers: const {},
      adBlockerEnabled: false,
    );
    expect(prepared, isNotNull);

    final masterRes = await _httpGet(prepared!.localPlaylistUrl);
    final masterBody = utf8.decode(masterRes.bytes);
    expect(masterBody, contains('RESOLUTION=1920x1080'));
    expect(masterBody, contains('/s/${prepared.sessionId}/variant/0.m3u8'));
    expect(masterBody, contains('/s/${prepared.sessionId}/variant/1.m3u8'));

    final variantRes = await _httpGet(
      'http://127.0.0.1:${proxy.port}/s/${prepared.sessionId}/variant/0.m3u8',
    );
    expect(variantRes.statusCode, HttpStatus.ok);
    expect(
      utf8.decode(variantRes.bytes),
      contains('/s/${prepared.sessionId}/v/0/seg/0.ts'),
    );

    final segRes = await _httpGet(
      'http://127.0.0.1:${proxy.port}/s/${prepared.sessionId}/v/0/seg/0.ts',
    );
    expect(segRes.statusCode, HttpStatus.ok);
    expect(utf8.decode(segRes.bytes), 'DATA:/seg_10.ts');
  });

  test('filters ad discontinuity groups when adBlockerEnabled is true', () async {
    playlists['/with_ads.m3u8'] = '''
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXTINF:5.0,
/seg_ad.ts
#EXT-X-DISCONTINUITY
#EXTINF:60.0,
/seg_main1.ts
#EXTINF:60.0,
/seg_main2.ts
#EXT-X-ENDLIST
''';

    final prepared = await proxy.prepareSession(
      url: upstreamUrl('/with_ads.m3u8'),
      headers: const {},
      adBlockerEnabled: true,
    );
    expect(prepared, isNotNull);
    expect(prepared!.adFilteredByProxy, isTrue);

    final playlistRes = await _httpGet(prepared.localPlaylistUrl);
    final body = utf8.decode(playlistRes.bytes);
    // Only the 2 main segments remain (indices 0 and 1), ad segment stripped
    expect(body, contains('/v/0/seg/0.ts'));
    expect(body, contains('/v/0/seg/1.ts'));
    expect(body, isNot(contains('/v/0/seg/2.ts')));

    final seg0 = await _httpGet(
      'http://127.0.0.1:${proxy.port}/s/${prepared.sessionId}/v/0/seg/0.ts',
    );
    expect(utf8.decode(seg0.bytes), 'DATA:/seg_main1.ts');
  });

  test('falls back (returns null) for unsupported playlists', () async {
    playlists['/byterange.m3u8'] = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-BYTERANGE:1000@0
#EXTINF:6.0,
/seg_0.ts
#EXT-X-ENDLIST
''';
    playlists['/event.m3u8'] = '''
#EXTM3U
#EXT-X-PLAYLIST-TYPE:EVENT
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
/seg_0.ts
''';
    playlists['/live.m3u8'] = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
/seg_0.ts
#EXTINF:6.0,
/seg_1.ts
''';
    playlists['/not_m3u8.m3u8'] = '<html>not a playlist</html>';

    for (final path in [
      '/byterange.m3u8',
      '/event.m3u8',
      '/live.m3u8',
      '/not_m3u8.m3u8',
    ]) {
      final prepared = await proxy.prepareSession(
        url: upstreamUrl(path),
        headers: const {},
        adBlockerEnabled: false,
      );
      expect(prepared, isNull, reason: 'Expected fallback for $path');
    }
  });

  test('starts prefetching from startOffsetSeconds segment', () async {
    final sb = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-TARGETDURATION:10');
    for (var i = 0; i < 12; i++) {
      sb
        ..writeln('#EXTINF:10.0,')
        ..writeln('/seg_$i.ts');
    }
    sb.writeln('#EXT-X-ENDLIST');
    playlists['/offset.m3u8'] = sb.toString();

    final prepared = await proxy.prepareSession(
      url: upstreamUrl('/offset.m3u8'),
      headers: const {},
      adBlockerEnabled: false,
      startOffsetSeconds: 55, // segment index 5 (50..60s)
    );
    expect(prepared, isNotNull);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(requestCounts['/seg_5.ts'], 1);
    expect(requestCounts['/seg_6.ts'], 1);
    expect(requestCounts['/seg_0.ts'], isNull);
  });

  test('preserves WebVTT subtitle extension, MIME type, and skips ad filtering for subtitle variants', () async {
    playlists['/master.m3u8'] = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="中文",LANGUAGE="zh",DEFAULT=YES,AUTOSELECT=YES,URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080,SUBTITLES="subs"
video.m3u8
''';
    playlists['/subs.m3u8'] = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:5.0,
sub_0.vtt
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
sub_1.vtt
#EXT-X-ENDLIST
''';
    playlists['/video.m3u8'] = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXTINF:6.0,
seg_0.ts
#EXT-X-ENDLIST
''';

    final prepared = await proxy.prepareSession(
      url: upstreamUrl('/master.m3u8'),
      headers: const {},
      adBlockerEnabled: true,
    );
    expect(prepared, isNotNull);

    final masterRes = await _httpGet(prepared!.localPlaylistUrl);
    expect(masterRes.statusCode, HttpStatus.ok);
    final masterBody = utf8.decode(masterRes.bytes);
    final subMatch = RegExp(
      r'TYPE=SUBTITLES[^\n]*URI="([^"]+)"',
    ).firstMatch(masterBody);
    expect(subMatch, isNotNull);

    final origin = Uri.parse(prepared.localPlaylistUrl).origin;
    final subPlaylistRes = await _httpGet('$origin${subMatch!.group(1)!}');
    expect(subPlaylistRes.statusCode, HttpStatus.ok);
    final subPlaylistBody = utf8.decode(subPlaylistRes.bytes);
    expect(subPlaylistBody, contains('/seg/0.vtt'));
    expect(subPlaylistBody, contains('/seg/1.vtt'));
    expect(subPlaylistBody, isNot(contains('.ts')));

    final segLine = subPlaylistBody
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.endsWith('/seg/0.vtt'));
    final vttRes = await _httpGet('$origin$segLine');
    expect(vttRes.statusCode, HttpStatus.ok);
    expect(vttRes.contentType, contains('text/vtt'));
    expect(utf8.decode(vttRes.bytes), contains('WEBVTT'));
  });
}
