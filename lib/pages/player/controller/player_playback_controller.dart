// ignore_for_file: library_private_types_in_public_api

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/player/hls_proxy_service.dart';
import 'package:kazumi/services/player/playback_cache_policy.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

part 'player_playback_controller.g.dart';

/// 构造 `PlayerConfiguration`，统一启用 mpv/libass 字幕渲染并在 Android 下绑定随包字体。
/// `mediacodec_embed` 不走 mpv GPU 字幕管线，回退到 Flutter `SubtitleView`。
PlayerConfiguration buildMediaPlayerConfiguration({
  required int bufferSize,
  required MPVLogLevel logLevel,
  required bool adBlocker,
  required bool isAndroid,
  String? videoRenderer,
}) {
  final useLibass = videoRenderer != 'mediacodec_embed';
  return PlayerConfiguration(
    bufferSize: bufferSize,
    osc: false,
    logLevel: logLevel,
    adBlocker: adBlocker,
    libass: useLibass,
    libassAndroidFont:
        useLibass && isAndroid ? 'assets/fonts/MiSans-Regular.ttf' : null,
    libassAndroidFontName: useLibass && isAndroid ? 'MiSans' : null,
  );
}

class PlayerPlaybackController = _PlayerPlaybackController
    with _$PlayerPlaybackController;

final class _OwnedPlayer {
  _OwnedPlayer(this.player, {this.hlsProxySessionId});

  final Player player;
  final String? hlsProxySessionId;
  Future<void>? _disposeFuture;

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    if (hlsProxySessionId != null) {
      HlsProxyService.instance.closeSession(hlsProxySessionId);
    }
    try {
      await player.dispose();
    } catch (error, stackTrace) {
      KazumiLogger().e(
        'PlayerPlaybackController: failed to dispose media player',
        error: error,
        stackTrace: stackTrace,
      );
      try {
        await player.stop();
      } catch (_) {}
    }
  }
}

abstract class _PlayerPlaybackController with Store {
  _PlayerPlaybackController({
    required this.shaderAssetService,
    required this.debug,
    required this.videoUrl,
    required this.isLocalPlayback,
  });

  final ShaderAssetService shaderAssetService;
  final PlayerDebugController debug;
  final String Function() videoUrl;
  final bool Function() isLocalPlayback;
  late final PlaybackCachePolicy cachePolicy = PlaybackCachePolicy(
    isLocalPlayback: isLocalPlayback,
    currentPlayer: () => mediaPlayer,
    isPrefetchSuspended: () => _prefetchSuspendWanted,
    onConstrainedChanged: (constrained) {
      HlsProxyService.instance.setConstrained(
        _ownedPlayer?.hlsProxySessionId,
        constrained,
      );
    },
  );

  _OwnedPlayer? _ownedPlayer;
  Player? get mediaPlayer => _ownedPlayer?.player;
  VideoController? videoController;

  final AsyncSerialQueue _prefetchWrites = AsyncSerialQueue();
  bool _prefetchSuspendWanted = false;

  static const String _defaultNetworkTimeout = '20';

  String get _streamBufferSize {
    if (Platform.isAndroid || Platform.isIOS) {
      return cachePolicy.isConstrained ? '262144' : '524288'; // 256KiB / 512KiB
    }
    return '1048576'; // 1MiB (桌面端)
  }

  HlsProxyFinder? _buildProxyFinder() {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (proxyEnable) {
      final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
      final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
      if (parsed != null) {
        return (_) => 'PROXY ${parsed.$1}:${parsed.$2}';
      }
    } else if (SystemProxyService.isActive) {
      return SystemProxyService.findProxy;
    }
    return null;
  }

  bool hAenable = true;
  late String hardwareDecoder;
  bool androidEnableOpenSLES = true;
  bool autoPlay = true;
  bool playerDebugMode = false;
  int buttonSkipTime = 80;
  int arrowKeySkipTime = 10;

  /// 历史记录传入的 offset
  int startOffset = 0;

  /// 当前超分辨率模式
  @observable
  SuperResolutionMode superResolutionMode = SuperResolutionMode.off;

  @observable
  double volume = -1;

  /// 手势调节时的精确音量，避免 UI 节流导致累计误差
  double preciseVolume = -1;

  @observable
  bool loading = true;
  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;
  @observable
  double playerSpeed = 1.0;

  bool isCurrentPlayer(Player player) {
    return identical(mediaPlayer, player);
  }

  Future<Player?> _discardIfNotCurrent(_OwnedPlayer candidate) async {
    if (identical(_ownedPlayer, candidate)) {
      return candidate.player;
    }
    await candidate.dispose();
    return null;
  }

  Future<void> _cancelDebugInfo() async {
    try {
      await debug.cancel();
    } catch (_) {}
  }

  @action
  void resetForInit() {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    startOffset = 0;
  }

  /// 本次会话是否从距结尾 [nearEndWatchedThreshold] 以内的位置起播。
  /// 这样的"播放完成"并非真正看完，应从头重播而非切下一集
  bool get resumedNearEnd {
    if (startOffset <= 0 || duration <= Duration.zero) {
      return false;
    }
    return Duration(seconds: startOffset) >= duration - nearEndWatchedThreshold;
  }

  /// 从头重播当前视频。[startOffset] 在重播落地后才归零，
  /// 避免自动连播在此期间抢先触发
  Future<void> restartFromBeginning() async {
    final player = mediaPlayer;
    if (player == null) {
      return;
    }
    try {
      await player.seek(Duration.zero);
      if (!isCurrentPlayer(player)) {
        return;
      }
      await player.play();
      startOffset = 0;
    } catch (e) {
      KazumiLogger().w(
        'PlayerController: failed to restart from beginning',
        error: e,
      );
    }
  }

  bool get playerPlaying {
    try {
      return mediaPlayer?.state.playing ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerBuffering {
    try {
      return mediaPlayer?.state.buffering ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get playerCompleted {
    try {
      return mediaPlayer?.state.completed ?? false;
    } catch (_) {
      return false;
    }
  }

  double get playerVolume {
    try {
      return mediaPlayer?.state.volume ?? volume;
    } catch (_) {
      return volume;
    }
  }

  Duration get playerPosition {
    try {
      return mediaPlayer?.state.position ?? currentPosition;
    } catch (_) {
      return currentPosition;
    }
  }

  Duration get playerBuffer {
    try {
      return mediaPlayer?.state.buffer ?? buffer;
    } catch (_) {
      return buffer;
    }
  }

  Duration get playerDuration {
    try {
      return mediaPlayer?.state.duration ?? duration;
    } catch (_) {
      return duration;
    }
  }

  /// Android blocks network access for backgrounded apps; a prefetching
  /// demuxer then burns through ffmpeg's reconnect/segment retries and marks
  /// the stream EOF, leaving playback permanently stuck once foregrounded.
  /// Suspending zeroes the readahead window so no new requests are issued
  /// while buffered data stays available. Restoration uses the current cache
  /// policy, including network and low-memory settings. The policy serializes
  /// writes so lifecycle and settings changes share the same ordering.
  Future<void> setPrefetchSuspended(bool suspended) async {
    if (!Platform.isAndroid) {
      return;
    }
    _prefetchSuspendWanted = suspended;
    HlsProxyService.instance.setPrefetchSuspended(
      _ownedPlayer?.hlsProxySessionId,
      suspended,
    );
    await _prefetchWrites.run(cachePolicy.apply);
  }

  Future<Player?> createVideoController(
    Map<String, String> httpHeaders,
    bool adBlockerEnabled, {
    required bool Function() canInstall,
    int offset = 0,
    VideoSourceFormat videoSourceFormat = VideoSourceFormat.auto,
    void Function(String message)? onPlaybackError,
    bool honorPlatformDecoderFallback = false,
    HlsPreFetchedSeed? hlsPreFetchedSeed,
    bool failoverAware = false,
    void Function(HlsProxySegmentFailure failure)? onPrioritySegmentFailure,
    void Function(String cdnGroup)? onCdnGroupResolved,
  }) async {
    startOffset = offset;
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultSuperResolutionMode),
    );
    hAenable = GStorage.getSetting(SettingsKeys.hAenable);
    androidEnableOpenSLES = GStorage.getSetting(
      SettingsKeys.androidEnableOpenSLES,
    );
    hardwareDecoder = GStorage.getSetting(SettingsKeys.hardwareDecoder);
    autoPlay = GStorage.getSetting(SettingsKeys.autoPlay);
    playerDebugMode = GStorage.getSetting(SettingsKeys.playerDebugMode);

    if (!canInstall()) {
      return null;
    }

    final rawVideoUrl = videoUrl();
    final isHls =
        videoSourceFormat == VideoSourceFormat.hls ||
        Uri.tryParse(rawVideoUrl)?.path.toLowerCase().endsWith('.m3u8') == true;

    HlsProxyPreparedSession? preparedHls;
    if (!isLocalPlayback() && isHls) {
      preparedHls = await HlsProxyService.instance.prepareSession(
        url: rawVideoUrl,
        headers: httpHeaders,
        adBlockerEnabled: adBlockerEnabled,
        startOffsetSeconds: offset,
        constrained: cachePolicy.isConstrained,
        prefetchSuspended: _prefetchSuspendWanted,
        findProxy: _buildProxyFinder(),
        preFetchedSeed: hlsPreFetchedSeed,
        failoverAware: failoverAware,
        onPrioritySegmentFailure: onPrioritySegmentFailure,
        onCdnGroupResolved: onCdnGroupResolved,
      );
      if (!canInstall()) {
        HlsProxyService.instance.closeSession(preparedHls?.sessionId);
        return null;
      }
    }

    final bool usingLocalHlsProxy = preparedHls != null;
    final String effectiveVideoUrl = usingLocalHlsProxy
        ? preparedHls.localPlaylistUrl
        : rawVideoUrl;
    final Map<String, String> effectiveHeaders = usingLocalHlsProxy
        ? const <String, String>{}
        : httpHeaders;
    final bool effectiveAdBlocker =
        adBlockerEnabled && !(preparedHls?.adFilteredByProxy ?? false);

    String? videoRenderer;
    if (Platform.isAndroid) {
      final String androidVideoRenderer = GStorage.getSetting(
        SettingsKeys.androidVideoRenderer,
      );

      if (androidVideoRenderer == 'auto') {
        // Android 14 及以上使用基于 Vulkan 的 MPV GPU-NEXT 视频输出，着色器性能更好
        // GPU-NEXT 需要 Vulkan 1.2 支持
        // 避免 Android 13 及以下设备上部分机型 Vulkan 支持不佳导致的黑屏问题
        final int androidSdkVersion =
            await PlatformEnvironmentService.getAndroidSdkVersion();
        if (!canInstall()) {
          HlsProxyService.instance.closeSession(preparedHls?.sessionId);
          return null;
        }
        if (androidSdkVersion >= 34) {
          videoRenderer = 'gpu-next';
        } else {
          videoRenderer = 'gpu';
        }
      } else {
        videoRenderer = androidVideoRenderer;
      }
    }

    if (videoRenderer == 'mediacodec_embed') {
      hAenable = true;
      hardwareDecoder = 'mediacodec';
      superResolutionMode = SuperResolutionMode.off;
    }

    final candidate = _OwnedPlayer(
      Player(
        configuration: buildMediaPlayerConfiguration(
          bufferSize: cachePolicy.bufferSize,
          logLevel: MPVLogLevel.values[debug.playerLogLevel],
          adBlocker: effectiveAdBlocker,
          isAndroid: Platform.isAndroid,
          videoRenderer: videoRenderer,
        ),
      ),
      hlsProxySessionId: preparedHls?.sessionId,
    );
    final player = candidate.player;
    if (!canInstall()) {
      await candidate.dispose();
      return null;
    }
    _ownedPlayer = candidate;
    cachePolicy.startWatching();

    try {
      debug.playerLog.clear();
      await debug.setup(
        player,
        isCurrentPlayer: isCurrentPlayer,
        playerDebugMode: playerDebugMode,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      var pp = player.platform as NativePlayer;
      // 缓存上限已收紧至 64/256 MiB，使用纯内存缓存可避免低速闪存或杀软扫描临时目录造成的 I/O 抖动。
      await pp.setProperty("cache-on-disk", "no");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await cachePolicy.apply();
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 保持适中的底层流读取缓冲区（256KiB-1MiB），避免过大导致 Seek 与起播丢弃重读延迟。
      await pp.setProperty("stream-buffer-size", _streamBufferSize);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 覆盖 media_kit 默认过短的 5 秒硬编码超时，避免弱网瞬时抖动、跨域 CDN 及代理切换引发断流
      await pp.setProperty("network-timeout", _defaultNetworkTimeout);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 起播/Seek 先预热短缓冲再出画，卡顿后恢复阈值控制在 3 秒以平衡流畅度与等待时长。
      await pp.setProperty("cache-pause", "yes");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await pp.setProperty("cache-pause-wait", "3");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      await pp.setProperty("cache-pause-initial", "yes");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 关闭解复用滞后休眠，避免 CDN 连接空闲断链或 TCP 拥塞窗口回落导致二次卡顿。
      await pp.setProperty("demuxer-hysteresis-secs", "0");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 配置流协议层断流自动重连与 TCP 无延迟，增强直连流媒体网络鲁棒性
      await pp.setProperty(
        "stream-lavf-o",
        "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5,reconnect_on_network_error=1,reconnect_on_http_error=429,5xx,tcp_nodelay=1",
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      await pp.setProperty("af", "scaletempo2=max-speed=8");
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }
      if (Platform.isAndroid) {
        await pp.setProperty("volume-max", "100");
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
        if (androidEnableOpenSLES) {
          await pp.setProperty("ao", "opensles");
        } else {
          await pp.setProperty("ao", "audiotrack");
        }
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      // 使用本地 HLS 代理时，由代理自身走上游 HTTP/系统代理，mpv 直连 127.0.0.1。
      if (!usingLocalHlsProxy) {
        final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
        if (proxyEnable) {
          final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
          final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
          if (formattedProxy != null) {
            await pp.setProperty("http-proxy", formattedProxy);
            if (!isCurrentPlayer(player)) {
              return await _discardIfNotCurrent(candidate);
            }
            KazumiLogger().i('Player: HTTP 代理设置成功 $formattedProxy');
          }
        } else if (SystemProxyService.isActive) {
          final proxy = SystemProxyService.proxyFor('https');
          if (proxy != null) {
            await pp.setProperty("http-proxy", 'http://${proxy.$1}:${proxy.$2}');
            if (!isCurrentPlayer(player)) {
              return await _discardIfNotCurrent(candidate);
            }
            KazumiLogger().i('Player: 跟随系统代理 http://${proxy.$1}:${proxy.$2}');
          }
        }
      }

      await pp.setProperty(
        'slang',
        'zh,chs,sc,zh-Hans,zh-CN,chi,zho,cht,tc,zh-Hant,zh-TW,zh-HK',
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      await player.setAudioTrack(AudioTrack.auto());
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      await player.setSubtitleTrack(SubtitleTrack.auto());
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      // 影视的默认自动解码交由平台选择，使上游模拟器兼容分支生效。
      // 用户显式选择、动漫入口及真实设备的硬解能力仍按原配置处理。
      final usePlatformDecoder =
          honorPlatformDecoderFallback &&
          Platform.isAndroid &&
          hAenable &&
          hardwareDecoder == 'auto-safe' &&
          videoRenderer != 'mediacodec_embed';
      videoController ??= VideoController(
        player,
        configuration: VideoControllerConfiguration(
          vo: videoRenderer,
          enableHardwareAcceleration: hAenable,
          enableAndroidSurfaceProducer: false,
          hwdec: usePlatformDecoder
              ? null
              : (hAenable ? hardwareDecoder : 'no'),
          androidAttachSurfaceAfterVideoParameters: false,
        ),
      );
      player.setPlaylistMode(PlaylistMode.none);
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      bool showPlayerError = GStorage.getSetting(SettingsKeys.showPlayerError);
      player.stream.error.listen((event) {
        if (isCurrentPlayer(player)) {
          final actionableMessage = PlayerErrorMapper.toActionableMessage(
            event,
            isBuffering: playerBuffering,
          );
          if (actionableMessage != null) {
            if (canInstall()) onPlaybackError?.call(actionableMessage);
            KazumiDialog.showToast(
              message: actionableMessage,
              showActionButton: true,
            );
          } else if (canInstall() &&
              event.contains('Failed to open') &&
              playerDuration == Duration.zero) {
            // 独立播放页可呈现终止加载失败；已有动漫页仍使用原提示行为。
            onPlaybackError?.call('媒体地址无法打开，请重试或更换线路。');
          } else if (showPlayerError) {
            KazumiDialog.showToast(
              message: '播放器内部错误 ${event.toString()} ${videoUrl()}',
              duration: const Duration(seconds: 5),
              showActionButton: true,
            );
          }
        }
        KazumiLogger().e(
          'PlayerController: Player intent error ${videoUrl()}',
          error: event,
        );
      });

      if (superResolutionMode != SuperResolutionMode.off) {
        await setShader(superResolutionMode, player: player);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      if (isHls) {
        await configureHlsPlayback(pp, adBlockerEnabled: effectiveAdBlocker);
        if (!isCurrentPlayer(player)) {
          return await _discardIfNotCurrent(candidate);
        }
      }

      await player.open(
        Media(
          effectiveVideoUrl,
          start: Duration(seconds: offset),
          httpHeaders: effectiveHeaders,
        ),
        play: autoPlay,
      );
      if (!isCurrentPlayer(player)) {
        return await _discardIfNotCurrent(candidate);
      }

      if (cachePolicy.networkAutomatic) {
        KazumiDialog.showToast(message: '移动数据下已自动开启低内存模式，可在播放设置中改为始终关闭');
      }

      return player;
    } catch (error, stackTrace) {
      if (identical(_ownedPlayer, candidate)) {
        cachePolicy.stopWatching();
        _ownedPlayer = null;
        videoController = null;
      }
      await candidate.dispose();
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    final currentPlayer = player ?? mediaPlayer;
    if (currentPlayer == null) return;
    try {
      var pp = currentPlayer.platform as NativePlayer;
      await pp.waitForPlayerInitialization;
      await pp.waitForVideoControllerInitializationIfAttached;
      if (!identical(mediaPlayer, currentPlayer)) {
        return;
      }
      switch (mode) {
        case SuperResolutionMode.efficiency:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShadersLite,
            ),
          ]);
          break;
        case SuperResolutionMode.quality:
          await pp.command([
            'change-list',
            'glsl-shaders',
            'set',
            buildShadersAbsolutePath(
              shaderAssetService.shadersDirectory.path,
              mpvAnime4KShaders,
            ),
          ]);
          break;
        case SuperResolutionMode.off:
          await pp.command(['change-list', 'glsl-shaders', 'clr', '']);
          break;
      }
      // 命令等待期间可能切集，旧播放器不得覆盖新会话的超分状态。
      if (!isCurrentPlayer(currentPlayer)) return;
      superResolutionMode = mode;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to set shader', error: e);
    }
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer!.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger().e(
        'PlayerController: failed to set playback speed',
        error: e,
      );
    }
  }

  Future<void> setVolume(double value) async {
    updateVolume(value);
    await syncVolumeToDevice(preciseVolume >= 0 ? preciseVolume : volume);
  }

  @action
  void updateVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = value;
    if (volume.toInt() == value.toInt()) {
      return;
    }
    volume = value;
  }

  /// 外部来源（硬件键、系统面板等）变更音量时同步，并清除手势缓存
  @action
  void applyExternalVolume(double value) {
    value = value.clamp(0.0, 100.0);
    preciseVolume = -1;
    volume = value;
  }

  void invalidatePreciseVolume() {
    preciseVolume = -1;
  }

  Future<void> syncVolumeToDevice([double? value]) async {
    final vol = (value ?? volume).clamp(0.0, 100.0);
    try {
      if (isDesktop()) {
        await mediaPlayer!.setVolume(vol);
      } else {
        await FlutterVolumeController.setVolume(vol / 100);
      }
    } catch (_) {}
  }

  @action
  void syncPlaybackState() {
    final player = mediaPlayer;
    if (player == null) return;

    final PlayerState state;
    try {
      state = player.state;
    } catch (_) {
      return;
    }
    if (playing != state.playing) {
      playing = state.playing;
    }
    if (isBuffering != state.buffering) {
      isBuffering = state.buffering;
    }
    if (currentPosition != state.position) {
      currentPosition = state.position;
    }
    if (buffer != state.buffer) {
      buffer = state.buffer;
    }
    if (duration != state.duration) {
      duration = state.duration;
    }
    if (completed != state.completed) {
      completed = state.completed;
    }
  }

  Future<void> playOrPause({
    required Future<void> Function() pause,
    required Future<void> Function() play,
  }) async {
    if (playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> stop() async {
    cachePolicy.stopWatching();
    final ownedPlayer = _ownedPlayer;
    _ownedPlayer = null;
    videoController = null;
    playing = false;
    loading = true;
    // media_kit stops playback as part of disposal before releasing native
    // resources. Debug subscriptions can be cancelled concurrently.
    await Future.wait([
      ownedPlayer?.dispose() ?? Future<void>.value(),
      _cancelDebugInfo(),
    ]);
  }

  Future<Uint8List?> screenshotPng() async {
    final player = mediaPlayer;
    if (player == null) {
      return null;
    }
    // Encode the captured frame natively; PlayerState dimensions may be stale.
    return player.safeScreenshot(format: 'image/png');
  }
}
