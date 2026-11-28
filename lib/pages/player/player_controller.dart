import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:media_kit/media_kit.dart';

import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_panel_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/pages/player/controller/player_screenshot_controller.dart';
import 'package:kazumi/pages/player/controller/player_seek_controller.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/controller/player_syncplay_controller.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/external_playback_launcher.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';

export 'package:kazumi/pages/player/controller/player_models.dart';

/// 动漫业务包装保留原有接口，共有播放操作统一委托给控制层。
class PlayerController implements Disposable {
  PlayerController(
    this.shaderAssetService,
    DownloadController downloadController,
    this.audioController,
  ) {
    danmaku = PlayerDanmakuController(
      isLocalPlayback: () => isLocalPlayback,
      downloadController: downloadController,
    );
    controls
      ..onBeforeSeek = danmaku.clearAndInvalidateScheduledDanmakus
      ..onSeekCompleted = _onSeekCompleted
      ..onBeforePlayingChanged = (playing) {
        if (playing) {
          danmaku.resumeCanvas();
        } else {
          danmaku.pauseCanvas();
        }
      }
      ..onPlayingChanged = (_, enableSync) {
        return _syncPlayingState(enableSync);
      }
      ..onSpeedChanged = updateDanmakuSpeed;
  }

  final ShaderAssetService shaderAssetService;
  final AudioController audioController;
  late final PlayerControlsController controls = PlayerControlsController(
    shaderAssetService: shaderAssetService,
    audioController: audioController,
  );
  late final PlayerDanmakuController danmaku;
  late final PlayerSyncPlayController syncplay = PlayerSyncPlayController(
    bangumiId: () => bangumiId,
    currentEpisode: () => currentEpisode,
    currentRoad: () => currentRoad,
    playing: () => playback.playing,
    currentPosition: () => playback.currentPosition,
    playerPosition: () => playback.playerPosition,
    duration: () => playback.duration,
    pause: pause,
    play: play,
    seek: seek,
  );

  late int bangumiId;
  late int currentEpisode;
  late int currentDanmakuEpisodeNumber;
  late int currentRoad;
  bool _shutdownStarted = false;

  /// 原调用方继续读同一份状态，避免包装层和控件出现双份播放器。
  PlayerPanelController get panel => controls.panel;
  PlayerScreenshotController get screenshots => controls.screenshots;
  PlayerDebugController get debug => controls.debug;
  PlayerPlaybackController get playback => controls.playback;
  PlayerSeekController get seeking => controls.seeking;
  ExternalPlaybackLauncher get externalPlayback => controls.externalPlayback;
  Object get audioOwner => controls.audioOwner;
  String get videoUrl => controls.videoUrl;
  set videoUrl(String value) => controls.videoUrl = value;
  String get referer => controls.referer;
  set referer(String value) => controls.referer = value;
  String? get coverUrl => controls.coverUrl;
  set coverUrl(String? value) => controls.coverUrl = value;
  bool get isLocalPlayback => controls.isLocalPlayback;
  set isLocalPlayback(bool value) => controls.isLocalPlayback = value;
  bool get muted => controls.muted;
  set muted(bool value) => controls.muted = value;
  Timer? get hideVolumeUITimer => controls.hideVolumeUITimer;
  set hideVolumeUITimer(Timer? value) => controls.hideVolumeUITimer = value;

  Future<bool> init(PlaybackInitParams params) async {
    if (_shutdownStarted) return false;
    bangumiId = params.bangumiId;
    currentEpisode = params.episode;
    currentDanmakuEpisodeNumber = params.danmakuEpisodeNumber;
    currentRoad = params.currentRoad;
    final initialized = await controls.initialize(
      PlayerMediaInitParams(
        videoUrl: params.videoUrl,
        offset: params.offset,
        isLocalPlayback: params.isLocalPlayback,
        httpHeaders: params.httpHeaders,
        adBlockerEnabled: params.adBlockerEnabled,
        referer: params.referer,
        videoSourceFormat: params.videoSourceFormat,
        coverUrl: params.coverUrl,
      ),
    );
    if (!initialized || _shutdownStarted) return false;
    if (syncplay.syncplayController?.isConnected ?? false) {
      if (syncplay.syncplayController!.currentFileName !=
          '$bangumiId[$currentEpisode]') {
        unawaited(
          setSyncPlayPlayingBangumi(
            forceSyncPlaying: true,
            forceSyncPosition: 0.0,
          ),
        );
      }
    }
    return true;
  }

  Future<void> toggleMute() => controls.toggleMute();
  void setVolumeDuringGesture(double value) =>
      controls.setVolumeDuringGesture(value);
  Future<void> finishVolumeGesture() => controls.finishVolumeGesture();
  Future<void> setShader(SuperResolutionMode mode, {Player? player}) =>
      controls.setShader(mode, player: player);
  Future<void> setPlaybackSpeed(double speed) =>
      controls.setPlaybackSpeed(speed);
  void updateDanmakuSpeed() => danmaku.updateDanmakuSpeed(playback.playerSpeed);
  Future<void> setVolume(double value) => controls.setVolume(value);
  void syncPlaybackState() => controls.syncPlaybackState();
  Future<void> playOrPause() => controls.playOrPause();
  Future<void> seek(Duration duration, {bool enableSync = true}) =>
      controls.seek(duration, enableSync: enableSync);
  Future<void> seekBy(Duration offset, {bool enableSync = true}) =>
      controls.seekBy(offset, enableSync: enableSync);
  Future<void> pause({bool enableSync = true}) =>
      controls.pause(enableSync: enableSync);
  Future<void> play({bool enableSync = true}) =>
      controls.play(enableSync: enableSync);
  Future<void> stop() => controls.stop();
  Future<Uint8List?> screenshotPng() => controls.screenshotPng();
  void setButtonForwardTime(int time) => controls.setButtonForwardTime(time);
  void setArrowKeyForwardTime(int time) =>
      controls.setArrowKeyForwardTime(time);
  Future<void> launchExternalPlayer() => controls.launchExternalPlayer();

  Future<void> _onSeekCompleted(bool enableSync) async {
    if (!syncplay.hasSession) return;
    setSyncPlayCurrentPosition();
    if (enableSync) await requestSyncPlaySync(doSeek: true);
  }

  Future<void> _syncPlayingState(bool enableSync) async {
    if (!syncplay.hasSession) return;
    setSyncPlayCurrentPosition();
    if (enableSync) await requestSyncPlaySync();
  }

  @override
  void dispose() => beginShutdown();

  /// 动漫仅释放自己的业务扩展，媒体资源由通用控制层幂等释放。
  void beginShutdown() {
    if (_shutdownStarted) return;
    _shutdownStarted = true;
    controls.beginShutdown();
    unawaited(
      syncplay.dispose().catchError((Object error, StackTrace stackTrace) {
        KazumiLogger().e(
          'PlayerController: 同步播放资源释放失败',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> createSyncPlayRoom(
    String room,
    String username,
    Future<void> Function(int episode, {int currentRoad, int offset})
    changeEpisode,
  ) => syncplay.createRoom(room, username, changeEpisode);

  void setSyncPlayCurrentPosition({
    bool? forceSyncPlaying,
    double? forceSyncPosition,
  }) => syncplay.setCurrentPosition(
    forceSyncPlaying: forceSyncPlaying,
    forceSyncPosition: forceSyncPosition,
  );

  Future<void> setSyncPlayPlayingBangumi({
    bool? forceSyncPlaying,
    double? forceSyncPosition,
  }) => syncplay.setPlayingBangumi(
    forceSyncPlaying: forceSyncPlaying,
    forceSyncPosition: forceSyncPosition,
  );

  Future<void> requestSyncPlaySync({bool? doSeek}) =>
      syncplay.requestSync(doSeek: doSeek);
  Future<void> sendSyncPlayChatMessage(String message) =>
      syncplay.sendChatMessage(message);
  Future<void> exitSyncPlayRoom() => syncplay.exitRoom();
}
