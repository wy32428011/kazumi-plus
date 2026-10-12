import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/player/controller/player_debug_controller.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/media/media_resume_session.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_playback_controls.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit/media_kit.dart' show Player;
import 'package:window_manager/window_manager.dart';

/// 影视复用原播放内核，作品资料和进度不进入 Bangumi 控制器。
class SourcePlayerPage extends StatefulWidget {
  const SourcePlayerPage({super.key, required this.playbackContext});
  final PlaybackContext playbackContext;

  @override
  State<SourcePlayerPage> createState() => _SourcePlayerPageState();
}

class _SourcePlayerPageState extends State<SourcePlayerPage>
    with WidgetsBindingObserver {
  final _library = SourceMediaLibrary.instance;
  final _resolver = WebViewVideoSourceService();
  final _switches = AsyncSerialQueue();
  final _debug = PlayerDebugController();
  final _tvOverlay = TvPlaybackOverlayController();
  final _audioOwner = Object();
  bool _audioRequested = false;
  AudioController get _audio => inject<AudioController>();
  late final PlayerPlaybackController _playback;
  Timer? _refreshTimer;
  Timer? _saveTimer;
  Timer? _loadTimeout;
  StreamSubscription<bool>? _completedSubscription;
  MediaResumeSession? _resumeSession;
  bool _resumePending = false;
  int _generation = 0;
  int _readyGeneration = -1;
  int _roadIndex = 0;
  int _episodeIndex = 0;
  String _videoUrl = '';
  String? _error;
  bool _loading = true;
  bool _ready = false;
  bool _exiting = false;
  bool _reportedPlayback = false;
  double _speed = 1;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  MediaSummary get _media => widget.playbackContext.media;
  SourcePlaylist get _playlist => widget.playbackContext.playlist;
  PlaybackRoad get _road => _playlist.roads[_roadIndex];
  PlayableEpisode get _episode => _road.episodes[_episodeIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speed = GStorage.getSetting(SettingsKeys.defaultPlaySpeed);
    _playback = PlayerPlaybackController(
      shaderAssetService: inject<ShaderAssetService>(),
      debug: _debug,
      videoUrl: () => _videoUrl,
      isLocalPlayback: () => false,
    );
    _debug.playerLogLevel = GStorage.getSetting(SettingsKeys.playerLogLevel);
    _playback.playerSpeed = _speed;
    if (PlatformEnvironmentService.isTelevision) {
      unawaited(_bindAudioSession());
    }
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || _exiting) return;
      if (!_ready) {
        _syncAudioSession();
        return;
      }
      _playback.syncPlaybackState();
      setState(() {
        _position = _playback.playerPosition;
        _duration = _playback.playerDuration;
      });
      _syncAudioSession();
      // 记录实际视频参数与推进的位置，供运行验收核对。
      if (!_resumePending &&
          !_reportedPlayback &&
          _debug.playerWidth > 0 &&
          _position.inSeconds >= 2) {
        _reportedPlayback = true;
        _loadTimeout?.cancel();
        KazumiLogger().i(
          'PlusPlayback: decoded media=${_media.ref.key} episode=${_episode.key} '
          'size=${_debug.playerWidth}x${_debug.playerHeight} position=${_position.inMilliseconds}',
          forceLog: true,
        );
      }
    });
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_saveProgress());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_playlist.roads.isEmpty ||
          _playlist.roads.every((road) => road.episodes.isEmpty)) {
        setState(() {
          _loading = false;
          _error = '来源没有提供可播放的内容。';
        });
        return;
      }
      final road = widget.playbackContext.roadIndex.clamp(
        0,
        _playlist.roads.length - 1,
      );
      final episodes = _playlist.roads[road].episodes;
      if (episodes.isEmpty) {
        setState(() {
          _loading = false;
          _error = '所选线路没有剧集，请切换其他线路。';
        });
        return;
      }
      unawaited(
        _switchEpisode(
          road,
          widget.playbackContext.episodeIndex.clamp(0, episodes.length - 1),
        ),
      );
    });
  }

  bool get _canControlAudio =>
      mounted &&
      !_exiting &&
      _ready &&
      !_loading &&
      !_resumePending &&
      _readyGeneration == _generation;

  Future<void> _bindAudioSession() async {
    _audioRequested = true;
    try {
      // 复用应用级音频服务，直接提供影视身份，不创建虚构的 Bangumi 资料。
      await _audio.bindCallbacks(
        owner: _audioOwner,
        artworkUrl: null,
        onPlay: () => _handleAudioPlayback(true),
        onPause: () => _handleAudioPlayback(false),
        onSkipToNext: () => _handleAudioEpisode(1),
        onSkipToPrevious: () => _handleAudioEpisode(-1),
        onSeek: _handleAudioSeek,
      );
      if (!mounted || _exiting) {
        await _releaseAudioSession();
        return;
      }
      _syncAudioSession();
    } catch (error) {
      KazumiLogger().w('影视电视媒体会话绑定失败', error: error);
    }
  }

  Future<void> _handleAudioPlayback(bool playing) async {
    if (playing && !_canControlAudio) return;
    // 系统中断必须能暂停恢复中的实际音频，定位和继续播放仍等待恢复确认。
    if (!mounted || _exiting || !_ready || _readyGeneration != _generation) {
      return;
    }
    final player = _playback.mediaPlayer;
    if (player == null) return;
    try {
      if (playing) {
        await player.play();
      } else {
        await player.pause();
      }
      _syncAudioSession();
    } catch (error) {
      if (mounted && !_exiting) {
        KazumiLogger().w('影视电视媒体键操作失败', error: error);
      }
    }
  }

  Future<void> _handleAudioEpisode(int direction) async {
    if (!_canControlAudio) return;
    final index = _episodeIndex + direction;
    if (index < 0 || index >= _road.episodes.length) return;
    await _switchEpisode(_roadIndex, index);
  }

  Future<void> _handleAudioSeek(Duration requested) async {
    if (!_canControlAudio) return;
    final player = _playback.mediaPlayer;
    if (player == null) return;
    final upper = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds - 1
        : requested.inMilliseconds;
    final position = Duration(
      milliseconds: requested.inMilliseconds.clamp(0, upper < 0 ? 0 : upper),
    );
    try {
      // 捕获旧播放器引用，切集后不能把延迟定位应用到新的播放会话。
      await player.seek(position);
    } catch (error) {
      if (mounted && !_exiting && identical(player, _playback.mediaPlayer)) {
        KazumiLogger().w('影视电视媒体定位失败', error: error);
      }
    }
  }

  void _syncAudioSession() {
    if (!_audioRequested ||
        !_audio.isBoundTo(_audioOwner) ||
        _playlist.roads.isEmpty ||
        _roadIndex >= _playlist.roads.length ||
        _road.episodes.isEmpty ||
        _episodeIndex >= _road.episodes.length) {
      return;
    }
    final player = _playback.mediaPlayer;
    unawaited(
      _audio
          .updateSession(
            owner: _audioOwner,
            mediaId: 'source:${_media.ref.key}:${_road.id}:${_episode.key}',
            title: _media.title,
            album: _media.sourceName,
            artist: _episode.title,
            duration: _duration,
            playing: _ready && !_exiting && (player?.state.playing ?? false),
            loading: _loading || _resumePending,
            buffering: player?.state.buffering ?? false,
            completed: player?.state.completed ?? false,
            updatePosition: _position,
            bufferedPosition: player?.state.buffer ?? Duration.zero,
            speed: _speed,
            queueIndex: _episodeIndex,
            canSkipToNext: _episodeIndex + 1 < _road.episodes.length,
            canSkipToPrevious: _episodeIndex > 0,
          )
          .catchError((Object error) {
            if (mounted && !_exiting) {
              KazumiLogger().w('影视电视媒体状态更新失败', error: error);
            }
          }),
    );
  }

  Future<void> _releaseAudioSession() async {
    if (!_audioRequested) return;
    _audioRequested = false;
    try {
      await _audio.deactivate(owner: _audioOwner);
    } catch (error) {
      KazumiLogger().w('影视电视媒体会话释放失败', error: error);
    }
  }

  Future<void> _switchEpisode(
    int roadIndex,
    int episodeIndex, {
    bool resume = true,
  }) async {
    if (_exiting || roadIndex < 0 || roadIndex >= _playlist.roads.length) {
      return;
    }
    final episodes = _playlist.roads[roadIndex].episodes;
    if (episodeIndex < 0 || episodeIndex >= episodes.length) return;
    final generation = ++_generation;
    // 重试同一集也立即撤销旧控件的 seek 权限，不等待队列清理完成。
    _readyGeneration = -1;
    _resumeSession?.cancel();
    _loadTimeout?.cancel();
    _resolver.cancel();
    _syncAudioSession();
    await _switches.run(() async {
      if (!mounted || _exiting || generation != _generation) return;
      await _saveProgress();
      await _completedSubscription?.cancel();
      _completedSubscription = null;
      _ready = false;
      await _playback.stop();
      if (!mounted || _exiting || generation != _generation) return;
      setState(() {
        _roadIndex = roadIndex;
        _episodeIndex = episodeIndex;
        _loading = true;
        _error = null;
        _position = Duration.zero;
        _duration = Duration.zero;
        _reportedPlayback = false;
      });
      try {
        final provider = inject<MediaCatalogService>().providerById(
          _media.ref.ruleId,
        );
        if (provider == null) throw StateError('原来源已禁用或删除，请返回规则管理恢复来源。');
        final plugin = provider.plugin;
        var offset = 0;
        if (resume && GStorage.getSetting(SettingsKeys.playResume)) {
          final progress = _library.progressFor(_media.ref, _road.id, _episode);
          if (progress != null &&
              (progress.durationMs <= 0 ||
                  progress.positionMs < progress.durationMs - 5000)) {
            offset = progress.positionMs ~/ 1000;
          }
        }
        // Android 的输出重建会补偿定位；保存的位置在其后显式恢复并回读。
        _resumePending = Platform.isAndroid && offset > 0;
        final resumeSession = _resumePending ? MediaResumeSession() : null;
        _resumeSession = resumeSession;
        final path = Uri.parse(_episode.url).path.toLowerCase();
        var format = VideoSourceFormat.auto;
        if (path.endsWith('.m3u8')) {
          _videoUrl = _episode.url;
          format = VideoSourceFormat.hls;
        } else if (RegExp(r'\.(mp4|mkv|webm|mov|avi|m4v|ts)$').hasMatch(path)) {
          _videoUrl = _episode.url;
        } else {
          final resolved = await _resolver.resolve(
            _episode.url,
            useLegacyParser: plugin.useLegacyParser,
            offset: offset,
            timeout: const Duration(seconds: 30),
          );
          _videoUrl = resolved.url;
          format = resolved.format;
        }
        if (!mounted || _exiting || generation != _generation) return;
        _playback.resetForInit();
        final headers = <String, String>{
          'User-Agent': plugin.userAgent.isEmpty
              ? getRandomUA()
              : plugin.userAgent,
          'Referer': plugin.referer.isEmpty ? plugin.baseUrl : plugin.referer,
        };
        _loadTimeout = Timer(const Duration(seconds: 45), () {
          if (_debug.playerWidth == 0 && generation == _generation) {
            _failPlayback('媒体加载超时，请重试或更换线路。', generation);
          }
        });
        final player = await _playback.createVideoController(
          headers,
          plugin.adBlocker,
          canInstall: () => mounted && !_exiting && generation == _generation,
          offset: _resumePending ? 0 : offset,
          videoSourceFormat: format,
          onPlaybackError: (message) => _failPlayback(message, generation),
          honorPlatformDecoderFallback: true,
        );
        if (player == null ||
            !mounted ||
            _exiting ||
            generation != _generation) {
          return;
        }
        await _playback.setPlaybackSpeed(_speed);
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          await _playback.setVolume(
            GStorage.getSetting(SettingsKeys.defaultVolume),
          );
        }
        _playback.loading = false;
        _ready = true;
        _readyGeneration = generation;
        _completedSubscription = player.stream.completed.listen((completed) {
          if (!completed ||
              generation != _generation ||
              _exiting ||
              _resumePending) {
            return;
          }
          unawaited(_saveProgress());
          if (GStorage.getSetting(SettingsKeys.autoPlayNext) &&
              _media.ref.kind == MediaKind.tv &&
              _episodeIndex + 1 < _road.episodes.length) {
            unawaited(_switchEpisode(_roadIndex, _episodeIndex + 1));
          }
        });
        if (mounted) setState(() => _loading = false);
        if (resumeSession != null) {
          unawaited(
            _restoreProgress(resumeSession, player, offset, generation),
          );
        }
      } catch (error, stackTrace) {
        if (!mounted || _exiting || generation != _generation) return;
        KazumiLogger().e(
          'PlusPlayback: 初始化失败',
          error: error,
          stackTrace: stackTrace,
        );
        setState(() {
          _loading = false;
          _error = '播放失败：$error';
        });
        _loadTimeout?.cancel();
      }
    });
  }

  Future<void> _saveProgress() async {
    if (GStorage.getSetting(SettingsKeys.privateMode)) return;
    if (_resumePending) return;
    if (!_ready || _playlist.roads.isEmpty) return;
    final position = _playback.playerPosition;
    final duration = _playback.playerDuration;
    if (duration <= Duration.zero && position <= Duration.zero) return;
    try {
      await _library.recordProgress(
        media: _media,
        road: _road,
        episode: _episode,
        positionMs: position.inMilliseconds,
        durationMs: duration.inMilliseconds,
        season: _playlist.season,
      );
    } catch (error) {
      KazumiLogger().e('PlusPlayback: 保存进度失败', error: error);
    }
  }

  Future<void> _restoreProgress(
    MediaResumeSession session,
    Player player,
    int seconds,
    int generation,
  ) async {
    try {
      await session.restore(
        player: player,
        video: _playback.videoController!,
        position: Duration(seconds: seconds),
        isCurrent: () =>
            mounted &&
            !_exiting &&
            generation == _generation &&
            _playback.isCurrentPlayer(player),
      );
      if (!mounted || _exiting || generation != _generation) return;
      setState(() => _resumePending = false);
      KazumiLogger().i(
        'PlusPlayback: resume confirmed media=${_media.ref.key} '
        'episode=${_episode.key} position=${_playback.playerPosition.inMilliseconds}',
        forceLog: true,
      );
      await _saveProgress();
    } catch (error) {
      if (!mounted ||
          _exiting ||
          generation != _generation ||
          session.isCancelled) {
        return;
      }
      _failPlayback('恢复观看进度失败，旧进度已保留。可重试或从头播放。', generation);
    }
  }

  void _failPlayback(String message, int generation) {
    if (!mounted || _exiting || generation != _generation) return;
    ++_generation;
    _resumeSession?.cancel();
    _loadTimeout?.cancel();
    setState(() {
      _ready = false;
      _loading = false;
      _error = message;
    });
    unawaited(_switches.run(_playback.stop));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_saveProgress());
      if (!GStorage.getSetting(SettingsKeys.backgroundPlayback)) {
        unawaited(_playback.mediaPlayer?.pause());
        unawaited(_playback.setPrefetchSuspended(true));
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_playback.setPrefetchSuspended(false));
    }
  }

  Future<void> _exit() async {
    if (_exiting) return;
    _exiting = true;
    ++_generation;
    _resumeSession?.cancel();
    _resolver.cancel();
    await _saveProgress();
    await _releaseAudioSession();
    await _switches.run(_playback.stop);
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      await windowManager.setFullScreen(false);
    }
    if (mounted) {
      setState(() {});
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    unawaited(_releaseAudioSession());
    _tvOverlay.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _saveTimer?.cancel();
    _loadTimeout?.cancel();
    _completedSubscription?.cancel();
    ++_generation;
    _resumeSession?.cancel();
    _resolver.cancel();
    unawaited(_resolver.dispose());
    unawaited(_switches.run(_playback.stop));
    super.dispose();
  }

  String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  Widget _surface() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => _switchEpisode(_roadIndex, _episodeIndex),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
              if (_resumePending)
                TextButton(
                  onPressed: () =>
                      _switchEpisode(_roadIndex, _episodeIndex, resume: false),
                  child: const Text('从头播放'),
                ),
            ],
          ),
        ),
      );
    }
    if (_loading || _playback.videoController == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final video = Video(
      key: ValueKey(_playback.videoController),
      controller: _playback.videoController!,
      controls: PlatformEnvironmentService.isTelevision
          ? NoVideoControls
          : AdaptiveVideoControls,
      onEnterFullscreen: () async {
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          await windowManager.setFullScreen(true);
        }
      },
      onExitFullscreen: () async {
        if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
          await windowManager.setFullScreen(false);
        }
      },
    );
    if (!_resumePending) return video;
    return Stack(
      children: [
        Positioned.fill(child: AbsorbPointer(child: video)),
        const Positioned(
          left: 16,
          bottom: 16,
          child: Text('正在恢复观看进度…', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final controlsGeneration = _generation;
    final hasRoads = _playlist.roads.isNotEmpty;
    final episodeTitle = hasRoads && _road.episodes.isNotEmpty
        ? _episode.title
        : '';
    return PopScope(
      canPop: _exiting,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (PlatformEnvironmentService.isTelevision &&
              _tvOverlay.hideIfVisible()) {
            return;
          }
          unawaited(_exit());
        }
      },
      child: Scaffold(
        appBar: PlatformEnvironmentService.isTelevision
            ? null
            : AppBar(
                leading: BackButton(onPressed: _exit),
                title: Text(
                  '${_media.title}${episodeTitle.isEmpty ? '' : ' · $episodeTitle'}',
                ),
                actions: [
                  PopupMenuButton<double>(
                    tooltip: '播放速度',
                    initialValue: _speed,
                    onSelected: (value) {
                      setState(() => _speed = value);
                      unawaited(_playback.setPlaybackSpeed(value));
                    },
                    itemBuilder: (_) => [
                      for (final value in [0.75, 1.0, 1.25, 1.5, 2.0])
                        PopupMenuItem(value: value, child: Text('${value}x')),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Center(child: Text('${_speed}x')),
                    ),
                  ),
                ],
              ),
        body: PlatformEnvironmentService.isTelevision
            ? TvPlaybackControls(
                controller: _tvOverlay,
                title:
                    '${_media.title}${episodeTitle.isEmpty ? '' : ' · $episodeTitle'}',
                position: _position,
                duration: _duration,
                playing: _playback.playerPlaying,
                loading:
                    !_ready || _loading || _resumePending || _error != null,
                rate: _speed,
                onToggle: () async {
                  await _playback.mediaPlayer?.playOrPause();
                },
                onPlay: () async {
                  await _playback.mediaPlayer?.play();
                },
                onPause: () async {
                  await _playback.mediaPlayer?.pause();
                },
                onSeek: (position) async {
                  final player = _playback.mediaPlayer;
                  if (!_ready ||
                      _loading ||
                      _resumePending ||
                      _exiting ||
                      player == null ||
                      controlsGeneration != _generation ||
                      _readyGeneration != controlsGeneration) {
                    return;
                  }
                  if (!_playback.isCurrentPlayer(player)) return;
                  await player.seek(position);
                },
                onRate: (value) async {
                  setState(() => _speed = value);
                  await _playback.setPlaybackSpeed(value);
                },
                onExit: () => unawaited(_exit()),
                roads: [
                  for (final road in _playlist.roads)
                    TvPlaybackRoad(
                      name: road.name,
                      episodes: [
                        for (final episode in road.episodes) episode.title,
                      ],
                    ),
                ],
                roadIndex: _roadIndex,
                episodeIndex: _episodeIndex,
                onEpisodeSelected: (road, episode) =>
                    _switchEpisode(road, episode),
                child: ColoredBox(color: Colors.black, child: _surface()),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final wide = constraints.maxWidth >= 900;
                  final surface = ColoredBox(
                    color: Colors.black,
                    child: _surface(),
                  );
                  final panel = _episodePanel();
                  if (wide) {
                    return Row(
                      children: [
                        Expanded(child: surface),
                        SizedBox(width: 280, child: panel),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      AspectRatio(aspectRatio: 16 / 9, child: surface),
                      Expanded(child: panel),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _episodePanel() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text(_media.sourceName, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text('${_time(_position)} / ${_time(_duration)}'),
      const SizedBox(height: 12),
      if (_playlist.roads.isNotEmpty)
        DropdownButtonFormField<int>(
          initialValue: _roadIndex,
          decoration: const InputDecoration(
            labelText: '播放线路',
            border: OutlineInputBorder(),
          ),
          items: [
            for (var i = 0; i < _playlist.roads.length; i++)
              DropdownMenuItem(value: i, child: Text(_playlist.roads[i].name)),
          ],
          onChanged: (value) {
            if (value == null) return;
            final target = _playlist.roads[value];
            final matched = target.episodes.indexWhere(
              (episode) => episode.id == _episode.id,
            );
            unawaited(_switchEpisode(value, matched < 0 ? 0 : matched));
          },
        ),
      const SizedBox(height: 18),
      Text(
        _playlist.season?.name ??
            (_media.ref.kind == MediaKind.movie ? '正片 / 来源版本' : '来源剧集'),
      ),
      const SizedBox(height: 10),
      if (_playlist.roads.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < _road.episodes.length; i++)
              ChoiceChip(
                label: Text(_road.episodes[i].title),
                selected: i == _episodeIndex,
                onSelected: (_) => _switchEpisode(_roadIndex, i),
              ),
          ],
        ),
    ],
  );
}
