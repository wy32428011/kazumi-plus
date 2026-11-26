import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/player_quality_sheet.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  test('quality labels include actual dimensions including cropped movies', () {
    expect(videoResolutionLabel(3840, 1608), '4K · 3840×1608');
    expect(videoResolutionLabel(1920, 806), '1080P · 1920×806');
    expect(videoResolutionLabel(800, 448), '448P · 800×448');
    expect(videoResolutionLabel(null, null), '分辨率未知');
  });

  test(
    'only real video tracks are offered, sorted by resolution then bitrate',
    () {
      final tracks = playableVideoTracks([
        VideoTrack.auto(),
        VideoTrack.no(),
        const VideoTrack('cover', null, null, albumart: true),
        const VideoTrack('image', null, null, image: true),
        const VideoTrack('low', null, null, w: 1280, h: 720, bitrate: 8000000),
        const VideoTrack(
          'high',
          null,
          null,
          w: 3840,
          h: 2160,
          bitrate: 6000000,
        ),
        const VideoTrack('high', null, null, w: 3840, h: 2160),
        const VideoTrack('unknown', '4K', null),
      ]);
      expect(tracks.map((track) => track.id), ['high', 'low', 'unknown']);
      expect(videoTrackLabel(tracks.last), '分辨率未知');
    },
  );

  test('HLS audio follows the selected variant without changing language', () {
    final tracks = <Map<String, dynamic>>[
      {
        'id': 2,
        'type': 'video',
        'program-ids': [1],
      },
      {
        'id': 1,
        'type': 'audio',
        'program-ids': [0],
        'selected': true,
        'lang': 'zh',
      },
      {
        'id': 2,
        'type': 'audio',
        'program-ids': [1],
        'lang': 'zh',
      },
      {
        'id': 3,
        'type': 'audio',
        'program-ids': [1],
        'lang': 'en',
      },
    ];
    expect(matchingHlsAudio('2', tracks), '2');
    tracks[1]['program-ids'] = [0, 1];
    expect(matchingHlsAudio('2', tracks), isNull); // 共享独立音轨
    tracks[1]['program-ids'] = [0];
    tracks[1]['external'] = true;
    expect(matchingHlsAudio('2', tracks), isNull); // 外部音轨不改
    tracks[1]['external'] = false;
    tracks[2]['lang'] = 'ja';
    expect(matchingHlsAudio('2', tracks), isNull); // 不替换为另一语言
    tracks[2]['lang'] = 'zh';
    tracks.add({
      'id': 4,
      'type': 'audio',
      'program-ids': [1],
      'lang': 'zh',
    });
    expect(matchingHlsAudio('2', tracks), isNull); // 歧义时保留原音轨
  });

  test('HLS demuxer-lavf-o enables persistent, multiple, and reconnect options', () {
    final disabled = buildHlsDemuxerLavfOptions(adBlockerEnabled: false);
    expect(disabled, contains('seg_max_retry=8'));
    expect(disabled, contains('http_persistent=1'));
    expect(disabled, contains('http_multiple=1'));
    expect(disabled, contains('tcp_nodelay=1'));
    expect(disabled, contains('reconnect=1'));
    expect(disabled, contains('reconnect_on_http_error=429,5xx'));
    expect(disabled, contains('hls_ad_filter=0'));
    expect(disabled, contains('protocol_whitelist=['));

    final enabled = buildHlsDemuxerLavfOptions(adBlockerEnabled: true);
    expect(enabled, contains('hls_ad_filter=1'));
  });

  for (final size in [const Size(375, 812), const Size(812, 375)]) {
    testWidgets('quality dialog fits $size with large text and dark theme', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = PlaybackQualityController(canInteract: () => true);
      addTearDown(controller.dispose);
      controller.tracks = [
        const VideoTrack('1', null, null, w: 3840, h: 1608, bitrate: 18000000),
        const VideoTrack('2', null, null, w: 1920, h: 1080, bitrate: 4000000),
      ];
      controller.width = 1920;
      controller.height = 1080;
      controller.selectedId = '2';
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: PlayerQualityDialog(controller: controller)),
        ),
      );
      expect(find.text('清晰度'), findsOneWidget);
      expect(find.text('当前画面：1080P · 1920×1080'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('single-quality source explains why 4K cannot be selected', (
    tester,
  ) async {
    final controller = PlaybackQualityController(canInteract: () => true);
    addTearDown(controller.dispose);
    controller.tracks = [const VideoTrack('1', null, null, w: 800, h: 448)];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlayerQualityDialog(controller: controller)),
      ),
    );
    expect(find.textContaining('仅提供一种画质'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  final fixture = Platform.environment['QUALITY_FIXTURE'];
  final libmpv = Platform.environment['QUALITY_LIBMPV'];
  test(
    'native HLS track switch retains position, pause, speed and audio',
    () async {
      MediaKit.ensureInitialized(libmpv: libmpv);
      final player = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          logLevel: MPVLogLevel.debug,
        ),
      );
      final quality = PlaybackQualityController(canInteract: () => true);
      try {
        final native = player.platform as NativePlayer;
        await native.setProperty('ao', 'null');
        await configureHlsPlayback(native);
        final errors = <String>[];
        final logSubscription = player.stream.log.listen((event) {
          if (event.prefix.contains('lavf') || event.text.contains('hls')) {
            errors.add(event.toString());
          }
        });
        addTearDown(logSubscription.cancel);
        final errorSubscription = player.stream.error.listen(errors.add);
        addTearDown(errorSubscription.cancel);
        await player.setVideoTrack(VideoTrack.auto());
        await player.open(Media(fixture!), play: false);
        await _until(
          () => playableVideoTracks(player.state.tracks.video).length == 2,
          describe: () => 'tracks=${player.state.tracks.video}, errors=$errors',
        );
        quality.attach(player, isHls: true);
        await player.setRate(1.25);
        await player.seek(const Duration(seconds: 6));
        await _until(() => player.state.position.inSeconds >= 5);
        final position = player.state.position;
        final audio = await native.getProperty('aid');
        final high = quality.tracks.first;
        final low = quality.tracks.last;
        expect(high.w, 3840);
        expect(high.h, 2160);
        expect(low.w, 1920);
        expect(low.h, 1080);
        await quality.select(high);
        await _until(() => player.state.width == 3840);
        expect(player.state.playing, isFalse);
        expect(
          (player.state.position - position).inMilliseconds.abs(),
          lessThan(500),
        );
        expect(player.state.rate, 1.25);
        expect(await native.getProperty('aid'), isNot(audio));
        expect(player.state.track.video.id, high.id);
        await player.play();
        await quality.select(low);
        await _until(() => player.state.width == 1920);
        expect(player.state.playing, isTrue);
        expect(player.state.rate, 1.25);
        expect(await native.getProperty('aid'), audio);
        expect(quality.error, isNull);
        quality.detach();
        await quality.select(high);
        expect(quality.tracks, isEmpty);
        expect(player.state.track.video.id, low.id);
      } finally {
        quality.dispose();
        await player.dispose();
      }
    },
    skip: fixture == null || libmpv == null
        ? '设置 QUALITY_FIXTURE 和 QUALITY_LIBMPV 可运行原生播放器验证'
        : false,
  );
}

Future<void> _until(
  bool Function() ready, {
  String Function()? describe,
}) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 15)) {
      throw StateError('等待原生播放器状态超时：${describe?.call() ?? '画面或位置未更新'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
