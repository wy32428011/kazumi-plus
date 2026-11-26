import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 构造 HLS 解复用器（FFmpeg hls demuxer）的网络复用与重连参数。
/// 保留 media_kit 默认必需的 `strict`、`allowed_extensions`、`hls_ad_filter`
/// 与 `protocol_whitelist`，并补齐分片持久连接、提前建连和断流重连。
String buildHlsDemuxerLavfOptions({
  required bool adBlockerEnabled,
  List<String> protocolWhitelist = const [
    'udp',
    'rtp',
    'tcp',
    'tls',
    'data',
    'file',
    'http',
    'httpproxy',
    'https',
    'crypto',
  ],
}) {
  return [
    'seg_max_retry=8',
    'http_persistent=1',
    'http_multiple=1',
    'tcp_nodelay=1',
    'reconnect=1',
    'reconnect_streamed=1',
    'reconnect_delay_max=5',
    'reconnect_on_network_error=1',
    'reconnect_on_http_error=429,5xx',
    'strict=experimental',
    'allowed_extensions=ALL',
    'hls_ad_filter=${adBlockerEnabled ? 1 : 0}',
    'protocol_whitelist=[${protocolWhitelist.join(',')}]',
  ].join(',');
}

/// HLS 变体在新版 mpv 中属于不同版本分组，必须展开才能选择全部轨道。
/// 仅对 HLS 使用，不能将多版本 MKV 的不同剪辑当作同一画质列表。
Future<void> configureHlsPlayback(
  NativePlayer player, {
  bool adBlockerEnabled = false,
  List<String>? protocolWhitelist,
}) async {
  await player.setProperty('hls-bitrate', 'no');
  await player.setProperty('demuxer-lavf-format', 'hls');
  await player.setProperty('flatten-editions', 'yes');
  await player.setProperty(
    'demuxer-lavf-o',
    buildHlsDemuxerLavfOptions(
      adBlockerEnabled: adBlockerEnabled,
      protocolWhitelist:
          protocolWhitelist ?? const PlayerConfiguration().protocolWhitelist,
    ),
  );
}

/// 只展示解复用器实际提供的视频轨道，不从片源名称推测画质。
List<VideoTrack> playableVideoTracks(Iterable<VideoTrack> tracks) {
  final ids = <String>{};
  return tracks
      .where(
        (track) =>
            track.id != 'auto' &&
            track.id != 'no' &&
            track.image != true &&
            track.albumart != true &&
            ids.add(track.id),
      )
      .toList()
    ..sort((a, b) {
      final pixels = ((b.w ?? 0) * (b.h ?? 0)).compareTo(
        (a.w ?? 0) * (a.h ?? 0),
      );
      return pixels != 0 ? pixels : (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    });
}

String videoResolutionLabel(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return '分辨率未知';
  }
  // 宽银幕影片常裁去黑边；同时显示原始尺寸，避免将档位当成像素实测值。
  final longSide = width > height ? width : height;
  final shortSide = width > height ? height : width;
  final String tier;
  if (longSide >= 3840 && shortSide >= 1440) {
    tier = '4K';
  } else if (longSide >= 2560 && shortSide >= 1080) {
    tier = '1440P';
  } else if (longSide >= 1920 && shortSide >= 720) {
    tier = '1080P';
  } else if (longSide >= 1280 && shortSide >= 480) {
    tier = '720P';
  } else {
    tier = '${shortSide}P';
  }
  return '$tier · $width×$height';
}

String videoTrackLabel(VideoTrack track) {
  final resolution = videoResolutionLabel(track.w, track.h);
  final bitrate = track.bitrate;
  return '$resolution${bitrate != null && bitrate > 0 ? ' · ${(bitrate / 1000000).toStringAsFixed(1)} Mbps' : ''}';
}

/// 跟随 HLS program 选择同语言、同用途的音频，避免降画质后仍下载旧的
/// 高码率复用分片。共享音轨、外部音轨和无法唯一匹配的音轨保持不变。
String? matchingHlsAudio(String videoId, List<Map<String, dynamic>> tracks) {
  Set<Object> programs(Map<String, dynamic> track) {
    final ids = track['program-ids'];
    if (ids is List) return ids.whereType<Object>().toSet();
    final id = track['program-id'];
    return id == null ? {} : {id};
  }

  final videos = tracks.where(
    (t) => t['type'] == 'video' && '${t['id']}' == videoId,
  );
  final selected = tracks.where(
    (t) => t['type'] == 'audio' && t['selected'] == true,
  );
  if (videos.length != 1 || selected.length != 1) return null;
  final audio = selected.single;
  if (audio['external'] == true) return null;
  final targetPrograms = programs(videos.single);
  if (targetPrograms.isEmpty || programs(audio).any(targetPrograms.contains)) {
    return null;
  }
  final candidates = tracks.where(
    (t) =>
        t['type'] == 'audio' &&
        t['external'] != true &&
        programs(t).any(targetPrograms.contains) &&
        t['lang'] == audio['lang'] &&
        t['title'] == audio['title'] &&
        t['commentary'] == audio['commentary'] &&
        t['visual-impaired'] == audio['visual-impaired'] &&
        t['hearing-impaired'] == audio['hearing-impaired'],
  );
  return candidates.length == 1 ? '${candidates.single['id']}' : null;
}

class PlaybackQualityController extends ChangeNotifier {
  PlaybackQualityController({required this.canInteract});

  final bool Function() canInteract;
  Player? _player;
  bool _isHls = false;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<VideoTrack> tracks = const [];
  String? selectedId;
  int? width;
  int? height;
  bool switching = false;
  String? error;
  bool _disposed = false;
  int _generation = 0;

  String get currentLabel => videoResolutionLabel(width, height);

  void attach(Player player, {bool isHls = false}) {
    detach();
    _player = player;
    _isHls = isHls;
    void refresh() {
      if (_disposed || !identical(_player, player)) return;
      tracks = playableVideoTracks(player.state.tracks.video);
      selectedId = player.state.track.video.id;
      width = player.state.width;
      height = player.state.height;
      notifyListeners();
    }

    _subscriptions.addAll([
      player.stream.tracks.listen((_) => refresh()),
      player.stream.track.listen((_) => refresh()),
      player.stream.width.listen((_) => refresh()),
      player.stream.height.listen((_) => refresh()),
    ]);
    refresh();
  }

  void detach() {
    _generation++;
    _player = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    tracks = const [];
    selectedId = null;
    width = height = null;
    switching = false;
    error = null;
    if (!_disposed) notifyListeners();
  }

  Future<void> select(VideoTrack track) async {
    final player = _player;
    if (_disposed ||
        player == null ||
        !canInteract() ||
        switching ||
        !tracks.any((candidate) => candidate.id == track.id)) {
      return;
    }
    final generation = _generation;
    switching = true;
    error = null;
    notifyListeners();
    try {
      // 在同一媒体内选择轨道：不重开 URL，不 seek，也不调用 play/pause。
      // HLS 复用音频随 program 切换；独立共享音频及语言偏好保持不变。
      final native = player.platform;
      String? audioId;
      if (_isHls && native is NativePlayer) {
        final raw = jsonDecode(await native.getProperty('track-list'));
        if (generation != _generation || _disposed) return;
        if (raw is List) {
          audioId = matchingHlsAudio(
            track.id,
            raw.whereType<Map<String, dynamic>>().toList(),
          );
        }
      }
      await player.setVideoTrack(track);
      if (generation != _generation || _disposed) return;
      if (audioId != null) {
        final matching = player.state.tracks.audio.where(
          (audio) => audio.id == audioId,
        );
        if (matching.length == 1) await player.setAudioTrack(matching.single);
        if (generation != _generation || _disposed) return;
      }
      selectedId = player.state.track.video.id;
    } catch (_) {
      if (generation != _generation || _disposed) return;
      error = '清晰度切换失败，请重试或更换线路。';
    } finally {
      if (generation == _generation && !_disposed) {
        switching = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}
