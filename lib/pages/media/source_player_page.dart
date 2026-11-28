import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/media_error_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_episode_sheet.dart';
import 'package:kazumi/pages/download/download_target.dart';
import 'package:kazumi/pages/media/source_playback_session.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_item.dart';
import 'package:kazumi/pages/player/player_quality_sheet.dart';
import 'package:kazumi/pages/video/episode_selection_panel.dart';
import 'package:kazumi/pages/video/player_content_tabs.dart';
import 'package:kazumi/pages/video/video_page_layout.dart';
import 'package:kazumi/pages/video/video_side_panel.dart';
import 'package:kazumi/pages/video/video_system_bars.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/services/player/timed_shutdown_service.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_playback_controls.dart';
import 'package:kazumi/utils/device.dart';
import 'package:mobx/mobx.dart' as mobx;
import 'package:screen_brightness_platform_interface/screen_brightness_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

enum _SourcePlayerFocusPhase { player, loading, error }

/// 影视沿用动漫的布局和通用控件，来源身份与进度留在独立会话中。
class SourcePlayerPage extends StatefulWidget {
  const SourcePlayerPage({super.key, required this.playbackContext});

  final PlaybackContext playbackContext;

  @override
  State<SourcePlayerPage> createState() => _SourcePlayerPageState();
}

class _SourcePlayerPageState extends State<SourcePlayerPage>
    with SingleTickerProviderStateMixin, WindowListener {
  final _keyboardFocus = FocusNode(debugLabel: 'Source player shortcut scope');
  final _episodePanelKey = GlobalKey<EpisodeSelectionPanelState>();
  final _sidePanelKey = GlobalKey<VideoSidePanelState>();
  final _tvOverlay = TvPlaybackOverlayController();
  final _statusFocusScope = FocusScopeNode(debugLabel: '影视播放状态层');
  final _statusRetryFocus = FocusNode(debugLabel: '影视播放重试');
  final _statusBackFocus = FocusNode(debugLabel: '影视播放状态返回');
  final _downloadController = inject<DownloadController>();
  late final SourcePlaybackSession _session;
  late final bool _disableAnimations;
  late final mobx.ReactionDisposer _pipModeListener;
  late final TabController _tabs;
  LocalHistoryEntry? _desktopPipEntry;
  bool _initialized = false;
  bool _leaving = false;
  bool _canPop = false;
  _SourcePlayerFocusPhase? _tvFocusPhase;
  int _focusRevision = 0;

  bool get _statusVisible => _session.loading || _session.errorMessage != null;

  void _scheduleTelevisionFocus() {
    if (!PlatformEnvironmentService.isTelevision) return;
    final phase = _session.errorMessage != null
        ? _SourcePlayerFocusPhase.error
        : _session.loading
        ? _SourcePlayerFocusPhase.loading
        : _SourcePlayerFocusPhase.player;
    if (_tvFocusPhase == phase) return;
    _tvFocusPhase = phase;
    final revision = ++_focusRevision;
    // 覆盖层布局完成后再交接焦点；旧帧不能抢回新状态或其他路由的焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _leaving ||
          revision != _focusRevision ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      switch (phase) {
        case _SourcePlayerFocusPhase.error:
          _statusRetryFocus.requestFocus();
        case _SourcePlayerFocusPhase.loading:
          _statusBackFocus.requestFocus();
        case _SourcePlayerFocusPhase.player:
          _keyboardFocus.requestFocus();
          _tvOverlay.requestFocus();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (isDesktop()) windowManager.addListener(this);
    _disableAnimations = GStorage.getSetting(
      SettingsKeys.playerDisableAnimations,
    );
    _session = SourcePlaybackSession(
      context: widget.playbackContext,
      controls: PlayerControlsController(
        shaderAssetService: inject<ShaderAssetService>(),
        audioController: inject<AudioController>(),
      ),
      catalog: inject<MediaCatalogService>(),
    );
    // 电影隐藏无意义的「选集（第 1 集）」页签，仅展示「片源与清晰度」；
    // 电视剧提供「选集」与「片源与清晰度」，严禁出现弹幕与评论。
    _tabs = TabController(length: _session.isMovie ? 1 : 2, vsync: this);
    _pipModeListener = mobx.reaction<bool>(
      (_) => _session.isPip,
      _syncDesktopPipHistory,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _session.fullscreen.attach(ModalRoute.of(context)!);
    if (isDesktop()) {
      unawaited(
        _session.fullscreen.initializeDesktop(windowManager.isFullScreen),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _session.start();
      if (mounted) _revealCurrentEpisode();
    });
  }

  @override
  void onWindowEnterFullScreen() =>
      _session.fullscreen.onDesktopFullscreenChanged(true);

  @override
  void onWindowLeaveFullScreen() =>
      _session.fullscreen.onDesktopFullscreenChanged(false);

  void _syncDesktopPipHistory(bool isPip) {
    if (!isDesktop() || !mounted) return;
    if (isPip && _desktopPipEntry == null) {
      _desktopPipEntry = LocalHistoryEntry(
        impliesAppBarDismissal: false,
        onRemove: () {
          _desktopPipEntry = null;
          if (_session.isPip) {
            _session.isPip = false;
            unawaited(PipUtils.exitDesktopPIPWindow());
          }
        },
      );
      ModalRoute.of(context)!.addLocalHistoryEntry(_desktopPipEntry!);
    } else if (!isPip) {
      _desktopPipEntry?.remove();
      _desktopPipEntry = null;
    }
  }

  void _revealCurrentEpisode() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _episodePanelKey.currentState?.revealCurrentEpisode();
    });
  }

  Future<void> _changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
  }) async {
    _sidePanelKey.currentState?.close();
    await _session.changeEpisode(
      episode,
      currentRoad: currentRoad,
      offset: offset,
    );
    if (mounted) _revealCurrentEpisode();
  }

  Future<void> _back() async {
    if (_leaving) return;
    if (PlatformEnvironmentService.isTelevision &&
        !_statusVisible &&
        _tvOverlay.hideIfVisible()) {
      return;
    }
    if (isDesktop() && _session.isPip) {
      _desktopPipEntry?.remove();
      return;
    }
    if (_session.isFullscreen) {
      await _session.fullscreen.setFullscreen(false);
      return;
    }
    _leaving = true;
    // 等待最终保存和串行释放完成后，才允许路由真正退出。
    await _session.close();
    if (!mounted) return;
    setState(() => _canPop = true);
    // PopScope 在下一帧才更新许可，不能在 setState 后立即再次返回。
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await Navigator.of(context).maybePop();
  }

  void _pauseForTimedShutdown() => unawaited(_session.controls.pause());

  @override
  void dispose() {
    if (isDesktop()) windowManager.removeListener(this);
    _pipModeListener();
    _desktopPipEntry?.remove();
    _desktopPipEntry = null;
    _tvOverlay.dispose();
    _statusRetryFocus.dispose();
    _statusBackFocus.dispose();
    _statusFocusScope.dispose();
    _keyboardFocus.dispose();
    _tabs.dispose();
    TimedShutdownService().cancel();
    if (!isDesktop()) {
      unawaited(
        ScreenBrightnessPlatform.instance.resetApplicationScreenBrightness(),
      );
    }
    _session.dispose();
    super.dispose();
  }

  /// 按剧集地址标出已缓存状态；地址在同一作品内唯一，与番剧页的匹配方式一致。
  Map<String, DownloadEpisode> _downloadsFor(DownloadTarget? target) {
    if (target == null) return const {};
    final record = _downloadController.getRecordSnapshot(
      '${target.pluginName}_${target.recordId}',
    );
    if (record == null) return const {};
    return {
      for (final episode in record.episodes.values)
        if (episode.episodePageUrl.isNotEmpty) episode.episodePageUrl: episode,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _session,
    builder: (context, _) => Observer(
      builder: (context) {
        final fullscreen =
            PlatformEnvironmentService.isTelevision || _session.isFullscreen;
        final download = _session.downloadTarget;
        final episodes = EpisodeSelectionPanel(
          key: _episodePanelKey,
          title: _session.title,
          roads: _session.roadList,
          selectedRoad: _session.selectedEpisode.road,
          selectedEpisode: _session.selectedEpisode.episode,
          downloads: _downloadsFor(download),
          onEpisodeSelected: (episode, road) =>
              unawaited(_changeEpisode(episode, currentRoad: road)),
          // 来源被禁用或删除时无法解析剧集地址，不提供下载入口。
          onDownload: download == null
              ? null
              : (road) => showAdaptiveBottomSheet<void>(
                  context: context,
                  builder: (context) =>
                      DownloadEpisodeSheet(road: road, target: download),
                ),
          onDownloadEpisode: download == null
              ? null
              : (episode, road) {
                  unawaited(enqueueVisibleEpisodes(
                    target: download,
                    road: road,
                    episodeNumbers: [episode],
                  ));
                },
          isPlaying: _session.controls.playback.playing,
          disableAnimations: _disableAnimations,
        );
        final sourcePanel = PlayerSourceQualityPanel(
          controller: _session.controls.quality,
          sourceFeatures: _session,
          controlsController: _session.controls,
          embedded: true,
        );
        final panel = ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PlayerContentTabs(
                controller: _tabs,
                onEpisodesSelected: _session.isMovie
                    ? () {}
                    : _revealCurrentEpisode,
                showComments: false,
                tabLabels: _session.isMovie
                    ? const ['片源与清晰度']
                    : const ['选集', '片源与清晰度'],
              ),
              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: _session.isMovie
                      ? [sourcePanel]
                      : [episodes, sourcePanel],
                ),
              ),
            ],
          ),
        );
        return PopScope(
          canPop: _canPop,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) unawaited(_back());
          },
          child: VideoSystemBars(
            fullscreen: fullscreen,
            isPip: _session.isPip,
            child: Scaffold(
              body: VideoPageLayout(
                fullscreen: fullscreen,
                isPip: _session.isPip,
                playerBuilder: (context, layout) => ColoredBox(
                  color: Colors.black,
                  child: Focus(
                    focusNode: _keyboardFocus,
                    autofocus: true,
                    child: _player(layout),
                  ),
                ),
                tabs: panel,
                sidePanel: PlatformEnvironmentService.isTelevision
                    ? null
                    : VideoSidePanel(
                        key: _sidePanelKey,
                        fullscreen: _session.isFullscreen,
                        disableAnimations: _disableAnimations,
                        onOpened: _revealCurrentEpisode,
                        onClosed: _keyboardFocus.requestFocus,
                        child: panel,
                      ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _player(VideoPlayerLayout layout) {
    _scheduleTelevisionFocus();
    final covered = PlatformEnvironmentService.isTelevision && _statusVisible;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 状态层只接管焦点和语义；底层实例保持挂载，音频与时钟不重复绑定。
        ExcludeFocus(
          excluding: covered,
          child: ExcludeSemantics(
            excluding: covered,
            child: PlayerItem(
              playerController: _session.controls,
              videoPageController: _session,
              fillsWindow: layout.fillsWindow,
              onToggleSidePanel: layout.hasSidePanel
                  ? () => _sidePanelKey.currentState?.toggle()
                  : null,
              changeEpisode: _changeEpisode,
              onBackPressed: () => unawaited(_back()),
              keyboardFocus: _keyboardFocus,
              pauseForTimedShutdown: _pauseForTimedShutdown,
              disableAnimations: _disableAnimations,
              tvOverlay: _tvOverlay,
            ),
          ),
        ),
        if (_session.loading || _session.errorMessage != null)
          _statusOverlay(layout),
        if (_session.resumePending && _session.errorMessage == null)
          const Positioned(
            left: 16,
            bottom: 76,
            child: IgnorePointer(
              child: Text('正在恢复观看进度…', style: TextStyle(color: Colors.white)),
            ),
          ),
      ],
    );
  }

  Widget _statusOverlay(VideoPlayerLayout layout) {
    final overlay = ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 64, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_session.errorMessage != null) ...[
                    MediaErrorWidget(
                      title: '暂时无法播放',
                      errMsg: _session.errorMessage!,
                      icon: Icons.videocam_off_outlined,
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.icon(
                          focusNode: _statusRetryFocus,
                          onPressed: () => unawaited(_session.retry()),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                        if (_session.sourceOptions.length > 1)
                          OutlinedButton.icon(
                            onPressed: () => unawaited(
                              showPlayerQualitySheet(
                                context,
                                _session.controls.quality,
                                sourceFeatures: _session,
                                controlsController: _session.controls,
                              ),
                            ),
                            icon: const Icon(Icons.swap_horiz_rounded),
                            label: const Text('切换片源'),
                          ),
                      ],
                    ),
                    if (_session.resumePending)
                      TextButton(
                        onPressed: () =>
                            unawaited(_session.retry(fromBeginning: true)),
                        child: const Text('从头播放'),
                      ),
                  ] else ...[
                    LoadingIndicator(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '视频资源解析中，播放器加载中',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: EmbeddedNativeControlArea(
              requireOffset: !_session.isFullscreen,
              child: Row(
                children: [
                  IconButton(
                    focusNode: _statusBackFocus,
                    onPressed: () => unawaited(_back()),
                    tooltip: '返回',
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  const Expanded(
                    child: dtb.DragToMoveArea(child: SizedBox(height: 40)),
                  ),
                  // 紧凑竖屏的错误正文可滚动，顶栏始终保留不被裁切的重试入口。
                  IconButton(
                    focusNode: _session.errorMessage == null
                        ? _statusRetryFocus
                        : null,
                    onPressed: () => unawaited(_session.retry()),
                    tooltip: '重试',
                    icon: const Icon(Icons.refresh, color: Colors.white),
                  ),
                  if (layout.hasSidePanel)
                    IconButton(
                      onPressed: () => _sidePanelKey.currentState?.toggle(),
                      tooltip: '选集',
                      icon: const Icon(
                        Icons.menu_open_rounded,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    return PlatformEnvironmentService.isTelevision
        ? FocusScope(node: _statusFocusScope, child: overlay)
        : overlay;
  }
}
