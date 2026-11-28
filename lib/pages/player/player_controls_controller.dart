import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';

import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_models.dart';
import 'package:kazumi/pages/player/controller/player_panel_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/pages/player/controller/player_screenshot_controller.dart';
import 'package:kazumi/pages/player/controller/player_seek_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/services/player/external_playback_launcher.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/utils/device.dart';

export 'package:kazumi/pages/player/controller/player_models.dart';

/// 动漫与影视共用的播放操作；作品身份、弹幕及观看记录不进入此层。
class PlayerControlsController implements Disposable {
  PlayerControlsController({
    required this.shaderAssetService,
    required this.audioController,
    bool Function()? canInteract,
  }) : canInteract = canInteract ?? _alwaysInteract;

  static bool _alwaysInteract() => true;

  final ShaderAssetService shaderAssetService;
  final AudioController audioController;

  /// 音频宿主绑定和最终释放使用同一身份，旧页不能释放新页的通知。
  final Object audioOwner = Object();
  bool Function() canInteract;
  bool get interactionsEnabled => !_initializations.isClosed && canInteract();

  /// 仅动漫包装注册这些副作用；通用操作无需创建空弹幕或同步会话。
  void Function()? onBeforeSeek;
  Future<void> Function(bool enableSync)? onSeekCompleted;
  void Function(bool playing)? onBeforePlayingChanged;
  Future<void> Function(bool playing, bool enableSync)? onPlayingChanged;
  void Function()? onSpeedChanged;

  final AsyncSessionOwner _initializations = AsyncSessionOwner();
  Future<void>? _shutdownFuture;
  final PlayerPanelController panel = PlayerPanelController();
  final PlayerScreenshotController screenshots = PlayerScreenshotController();
  final PlayerDebugController debug = PlayerDebugController();
  late final PlaybackQualityController quality = PlaybackQualityController(
    canInteract: () => interactionsEnabled && !playback.loading,
  );
  late final PlayerPlaybackController playback = PlayerPlaybackController(
    shaderAssetService: shaderAssetService,
    debug: debug,
    videoUrl: () => videoUrl,
    isLocalPlayback: () => isLocalPlayback,
  );
  late final PlayerSeekController seeking = PlayerSeekController(
    playback: playback,
    onBeforeSeek: () => onBeforeSeek?.call(),
    canInteract: () => interactionsEnabled,
    pause: pause,
    play: play,
    onSeekCompleted: (enableSync) async {
      await onSeekCompleted?.call(enableSync);
    },
  );
  late final ExternalPlaybackLauncher externalPlayback =
      ExternalPlaybackLauncher(
        videoUrl: () => videoUrl,
        referer: () => referer,
      );

  String videoUrl = '';
  String referer = '';
  String? coverUrl;
  bool isLocalPlayback = false;
  Timer? hideVolumeUITimer;
  Timer? _volumeGestureSyncTimer;
  double? _pendingGestureVolume;
  bool muted = false;
  double _preMuteVolume = 100;

  /// 平台音量监听为全局资源，旧播放器只回收自己仍持有的监听。
  static Object? _volumeListenerOwner;
  Object? _volumeBindingOwner;

  Future<void> toggleMute() async {
    if (!interactionsEnabled) return;
    if (!muted && playback.volume > 0) {
      _preMuteVolume = playback.volume;
      muted = true;
      _persistMuteState();
      await setVolume(0);
    } else {
      muted = false;
      _persistMuteState();
      await setVolume(_preMuteVolume > 0 ? _preMuteVolume : 100);
    }
  }

  void _persistMuteState() {
    if (!isDesktop()) return;
    unawaited(GStorage.putSetting<bool>(SettingsKeys.playerMuted, muted));
  }

  /// 主动调高音量时同时退出静音，保持快捷键、手势与按钮语义一致。
  void _clearMuteIfNeeded(double value) {
    if (muted && value > 0) {
      muted = false;
      _persistMuteState();
    }
  }

  void setVolumeDuringGesture(double value) {
    if (!interactionsEnabled) return;
    final player = playback.mediaPlayer;
    if (player == null) return;
    _pendingGestureVolume = value.clamp(0.0, 100.0);
    playback.updateVolume(_pendingGestureVolume!);
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = Timer(const Duration(milliseconds: 80), () {
      final vol = _pendingGestureVolume;
      if (vol == null ||
          !interactionsEnabled ||
          !playback.isCurrentPlayer(player)) {
        return;
      }
      unawaited(playback.syncVolumeToDevice(vol));
    });
  }

  Future<void> finishVolumeGesture() async {
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = null;
    final vol = _pendingGestureVolume;
    _pendingGestureVolume = null;
    final player = playback.mediaPlayer;
    if (!interactionsEnabled || player == null) {
      playback.invalidatePreciseVolume();
      return;
    }
    if (vol != null) playback.volume = vol;
    playback.invalidatePreciseVolume();
    await playback.syncVolumeToDevice(vol);
    if (!interactionsEnabled || !playback.isCurrentPlayer(player)) return;
    final resolved = vol ?? playback.volume;
    _clearMuteIfNeeded(resolved);
    _persistDesktopVolume(resolved);
  }

  void _persistDesktopVolume(double value) {
    if (!isDesktop() || muted) return;
    final clamped = value.clamp(0.0, 100.0);
    final stored = GStorage.getSetting(SettingsKeys.defaultVolume);
    if (stored.round() == clamped.round()) return;
    unawaited(GStorage.putSetting<double>(SettingsKeys.defaultVolume, clamped));
  }

  /// 上层会话是唯一初始化调用方；此层只建立媒体和共用设备状态。
  Future<bool> initialize(
    PlayerMediaInitParams params, {
    bool Function()? canInstall,
    bool honorPlatformDecoderFallback = false,
    void Function(String message)? onPlaybackError,
  }) async {
    if (_initializations.isClosed) return false;
    final initialization = _initializations.begin();
    bool isCurrent() => initialization.isActive && (canInstall?.call() ?? true);
    if (!isCurrent()) return false;

    seeking.invalidateInteractiveSeek();
    videoUrl = params.videoUrl;
    isLocalPlayback = params.isLocalPlayback;
    referer = params.referer;
    coverUrl = params.coverUrl;
    playback.resetForInit();
    debug.playerLogLevel = GStorage.getSetting(SettingsKeys.playerLogLevel);
    playback.playerSpeed =
        params.playbackSpeed ??
        GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    panel.aspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting(SettingsKeys.defaultAspectRatioType),
    );
    playback.buttonSkipTime = GStorage.getSetting(SettingsKeys.buttonSkipTime);
    playback.arrowKeySkipTime = GStorage.getSetting(
      SettingsKeys.arrowKeySkipTime,
    );

    try {
      await _releasePlaybackResources();
    } catch (_) {}
    if (!isCurrent()) return false;

    final Player? player;
    try {
      player = await playback.createVideoController(
        params.httpHeaders,
        params.adBlockerEnabled,
        canInstall: isCurrent,
        offset: params.offset,
        mediaKind: params.mediaKind,
        videoSourceFormat: params.videoSourceFormat,
        honorPlatformDecoderFallback: honorPlatformDecoderFallback,
        hlsPreFetchedSeed: params.hlsPreFetchedSeed,
        failoverAware: params.failoverAware,
        onPrioritySegmentFailure: params.onPrioritySegmentFailure,
        onCdnGroupResolved: params.onCdnGroupResolved,
        onPlaybackError: (message) {
          if (isCurrent()) onPlaybackError?.call(message);
        },
      );
    } catch (error) {
      if (!isCurrent()) return false;
      playback.loading = false;
      KazumiLogger().e('PlayerControlsController: 播放器初始化失败', error: error);
      onPlaybackError?.call('播放器初始化失败：$error');
      return false;
    }
    if (player == null || !isCurrent() || !playback.isCurrentPlayer(player)) {
      return false;
    }
    bool ownsPlayer() => isCurrent() && playback.isCurrentPlayer(player!);

    if (isDesktop()) {
      if (playback.volume == -1) {
        muted = GStorage.getSetting(SettingsKeys.playerMuted);
        final remembered = GStorage.getSetting(SettingsKeys.defaultVolume);
        _preMuteVolume = remembered > 0 ? remembered : 100;
        playback.volume = muted ? 0 : remembered;
      }
      // 初始化尚未开放交互，设置音量和倍速不经过用户操作门控。
      await playback.setVolume(playback.volume);
      if (!ownsPlayer()) return false;
    } else {
      final volume = await FlutterVolumeController.getVolume();
      if (!ownsPlayer()) return false;
      playback.volume = (volume ?? 0.0) * 100;
      final volumeOwner = Object();
      _volumeBindingOwner = volumeOwner;
      _volumeListenerOwner = volumeOwner;
      await FlutterVolumeController.updateShowSystemUI(false);
      if (!ownsPlayer()) {
        await _releaseVolumeResources(owner: volumeOwner);
        return false;
      }
      FlutterVolumeController.addListener(
        (volume) {
          if (!ownsPlayer() ||
              !identical(_volumeListenerOwner, volumeOwner) ||
              panel.volumeSeeking) {
            return;
          }
          playback.applyExternalVolume(volume * 100);
          if (!Platform.isAndroid) {
            panel.showVolume = true;
            hideVolumeUITimer?.cancel();
            hideVolumeUITimer = Timer(const Duration(seconds: 1), () {
              panel.showVolume = false;
              hideVolumeUITimer = null;
            });
          }
        },
        category: AudioSessionCategory.playback,
        emitOnStart: false,
      );
      if (!ownsPlayer()) return false;
    }
    await playback.setPlaybackSpeed(playback.playerSpeed);
    if (!ownsPlayer()) return false;
    try {
      onSpeedChanged?.call();
    } catch (_) {}
    playback.loading = false;
    quality.attach(
      player,
      isHls: params.videoSourceFormat == VideoSourceFormat.hls ||
          Uri.tryParse(params.videoUrl)?.path.toLowerCase().endsWith('.m3u8') == true,
    );
    KazumiLogger().i('PlayerControlsController: 播放器初始化完成');
    return true;
  }

  Future<void> setShader(SuperResolutionMode mode, {Player? player}) async {
    if (!interactionsEnabled) return;
    final currentPlayer = player ?? playback.mediaPlayer;
    if (currentPlayer == null || !playback.isCurrentPlayer(currentPlayer)) {
      return;
    }
    await playback.setShader(mode, player: currentPlayer);
  }

  void updateViewportPhysicalSize(int width, int height) =>
      playback.updateViewportPhysicalSize(width, height);

  Future<void> setPlaybackSpeed(double speed) async {
    if (!interactionsEnabled) return;
    final player = playback.mediaPlayer;
    if (player == null) return;
    try {
      await player.setRate(speed);
    } catch (error) {
      KazumiLogger().e('PlayerControlsController: 设置播放速度失败', error: error);
      return;
    }
    if (!interactionsEnabled || !playback.isCurrentPlayer(player)) return;
    playback.playerSpeed = speed;
    try {
      onSpeedChanged?.call();
    } catch (_) {}
  }

  Future<void> setVolume(double value) async {
    if (!interactionsEnabled) return;
    final player = playback.mediaPlayer;
    if (player == null) return;
    await playback.setVolume(value);
    if (!interactionsEnabled || !playback.isCurrentPlayer(player)) return;
    _clearMuteIfNeeded(value);
    _persistDesktopVolume(value);
  }

  void syncPlaybackState() => playback.syncPlaybackState();

  Future<void> playOrPause() async {
    // 恢复进度期间仍可暂停，继续播放则必须通过会话门控。
    if (playback.playerPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration duration, {bool enableSync = true}) =>
      seeking.seekTo(duration, enableSync: enableSync);

  Future<void> seekBy(Duration offset, {bool enableSync = true}) =>
      seeking.seekBy(offset, enableSync: enableSync);

  Future<void> pause({bool enableSync = true}) async {
    final player = playback.mediaPlayer;
    if (player == null) return;
    onBeforePlayingChanged?.call(false);
    try {
      await player.pause();
    } catch (_) {
      return;
    }
    if (!playback.isCurrentPlayer(player)) return;
    playback.playing = false;
    await onPlayingChanged?.call(false, enableSync);
  }

  Future<void> play({bool enableSync = true}) async {
    if (!interactionsEnabled) return;
    final player = playback.mediaPlayer;
    if (player == null) return;
    onBeforePlayingChanged?.call(true);
    try {
      await player.play();
    } catch (_) {
      return;
    }
    if (!playback.isCurrentPlayer(player)) return;
    playback.playing = true;
    await onPlayingChanged?.call(true, enableSync);
  }

  Future<Uint8List?> screenshotPng() async {
    if (!interactionsEnabled) return null;
    final player = playback.mediaPlayer;
    if (player == null) return null;
    final image = await playback.screenshotPng();
    if (!interactionsEnabled || !playback.isCurrentPlayer(player)) return null;
    return image;
  }

  void setButtonForwardTime(int time) {
    playback.buttonSkipTime = time;
    unawaited(GStorage.putSetting(SettingsKeys.buttonSkipTime, time));
  }

  void setArrowKeyForwardTime(int time) {
    playback.arrowKeySkipTime = time;
    unawaited(GStorage.putSetting(SettingsKeys.arrowKeySkipTime, time));
  }

  Future<void> launchExternalPlayer() async {
    if (!interactionsEnabled) return;
    await externalPlayback.launch();
  }

  /// 切集停止不解绑宿主音频会话，也不处理历史或下一集策略。
  Future<void> stop() async {
    _initializations.cancel();
    seeking.invalidateInteractiveSeek();
    await _releasePlaybackResources();
  }

  Future<void> _releasePlaybackResources() async {
    quality.detach();
    hideVolumeUITimer?.cancel();
    hideVolumeUITimer = null;
    _volumeGestureSyncTimer?.cancel();
    _volumeGestureSyncTimer = null;
    _pendingGestureVolume = null;
    await Future.wait([playback.stop(), _releaseVolumeResources()]);
  }

  Future<void> _releaseVolumeResources({Object? owner}) async {
    final bindingOwner = owner ?? _volumeBindingOwner;
    if (bindingOwner == null ||
        !identical(_volumeListenerOwner, bindingOwner)) {
      return;
    }
    _volumeListenerOwner = null;
    if (identical(_volumeBindingOwner, bindingOwner)) {
      _volumeBindingOwner = null;
    }
    FlutterVolumeController.removeListener();
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (error, stackTrace) {
      KazumiLogger().w(
        'PlayerControlsController: 恢复系统音量界面失败',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() => beginShutdown();

  /// 路由会话负责触发一次最终释放，异步清理只作用于自身资源。
  void beginShutdown() {
    _initializations.close();
    seeking.invalidateInteractiveSeek();
    if (_shutdownFuture != null) return;
    screenshots.dispose();
    quality.dispose();
    final shutdown = Future.wait([
      _releasePlaybackResources(),
      audioController.deactivate(owner: audioOwner),
    ]);
    _shutdownFuture = shutdown.then<void>((_) {});
    unawaited(
      _shutdownFuture!.catchError((Object error, StackTrace stackTrace) {
        KazumiLogger().e(
          'PlayerControlsController: 播放资源释放失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }
}
