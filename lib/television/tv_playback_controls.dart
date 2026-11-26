import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/utils/format.dart';

/// 返回键由播放路由统一处理；第一下收起操作层，第二下才退出播放。
class TvPlaybackOverlayController extends ChangeNotifier {
  bool _visible = true;
  bool get visible => _visible;
  void show() {
    if (!_visible) {
      _visible = true;
      notifyListeners();
    }
  }

  bool hideIfVisible() {
    if (!_visible) return false;
    _visible = false;
    notifyListeners();
    return true;
  }

  /// 状态覆盖层移除后恢复内部焦点，不改变控制层显示状态或播放会话。
  void requestFocus() => notifyListeners();
}

/// 仅用于遥控器视图的选集标签，不替代任何作品或存储模型。
class TvPlaybackRoad {
  const TvPlaybackRoad({required this.name, required this.episodes});
  final String name;
  final List<String> episodes;
}

class TvPlaybackControls extends StatefulWidget {
  const TvPlaybackControls({
    super.key,
    required this.controller,
    required this.child,
    required this.title,
    required this.position,
    required this.duration,
    required this.playing,
    required this.rate,
    required this.onToggle,
    required this.onPlay,
    required this.onPause,
    required this.onSeek,
    required this.onRate,
    required this.onExit,
    this.loading = false,
    this.roads = const [],
    this.roadIndex = 0,
    this.episodeIndex = 0,
    this.onEpisodeSelected,
    this.onQuickOpenDrawer,
    this.extraActions = const [],
    this.autoHideDuration = const Duration(seconds: 5),
  });
  final TvPlaybackOverlayController controller;
  final Widget child;
  final String title;
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool loading;
  final double rate;
  final Future<void> Function() onToggle;
  final Future<void> Function() onPlay;
  final Future<void> Function() onPause;
  final Future<void> Function(Duration) onSeek;
  final Future<void> Function(double) onRate;
  final VoidCallback onExit;
  final List<TvPlaybackRoad> roads;
  final int roadIndex;
  final int episodeIndex;
  final Future<void> Function(int road, int episode)? onEpisodeSelected;

  /// HUD 隐藏时按上键（Up）一键拉起右侧「片源与清晰度」抽屉。
  final Future<void> Function()? onQuickOpenDrawer;
  final List<Widget> extraActions;
  final Duration autoHideDuration;

  @override
  State<TvPlaybackControls> createState() => _TvPlaybackControlsState();
}

class _TvPlaybackControlsState extends State<TvPlaybackControls> {
  static const Color _darkroomSurface = Color(0xEB14161A);
  static const Color _darkroomHairline = Color(0xFF2B303A);
  static const Color _tungstenAccent = Color(0xFFE5B95C);

  final _surfaceFocus = FocusNode(debugLabel: '电视播放区域');
  final _playFocus = FocusNode(debugLabel: '电视播放暂停');
  final _progressFocus = FocusNode(debugLabel: '电视播放进度');
  Timer? _seekTimer;
  Timer? _autoHideTimer;
  Timer? _directSeekBannerTimer;
  Duration? _seekTarget;
  Duration? _directSeekPreview;
  int _directSeekDeltaSeconds = 0;
  int _directSeekRepeatCount = 0;
  int _seekGeneration = 0;
  bool _progressFocused = false;
  bool _modalOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_visibilityChanged);
    _requestInitialFocus();
    _syncAutoHideTimer();
  }

  void _requestInitialFocus() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // 恢复中播放按钮可能暂时禁用；此时交回播放区域以保留媒体暂停键。
        final target = widget.controller.visible && _playFocus.canRequestFocus
            ? _playFocus
            : _surfaceFocus;
        if (target.canRequestFocus) target.requestFocus();
      });

  void _visibilityChanged() {
    if (!mounted) return;
    setState(() {});
    _requestInitialFocus();
    _syncAutoHideTimer();
  }

  void _syncAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    if (!mounted ||
        !widget.controller.visible ||
        !widget.playing ||
        widget.loading ||
        _modalOpen ||
        _seekTarget != null ||
        widget.autoHideDuration <= Duration.zero) {
      return;
    }
    _autoHideTimer = Timer(widget.autoHideDuration, () {
      if (!mounted ||
          !widget.controller.visible ||
          !widget.playing ||
          widget.loading ||
          _modalOpen ||
          _seekTarget != null) {
        return;
      }
      widget.controller.hideIfVisible();
    });
  }

  @override
  void didUpdateWidget(covariant TvPlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cancelPendingSeek();
      oldWidget.controller.removeListener(_visibilityChanged);
      widget.controller.addListener(_visibilityChanged);
    }
    if ((!oldWidget.loading && widget.loading) ||
        oldWidget.roadIndex != widget.roadIndex ||
        oldWidget.episodeIndex != widget.episodeIndex) {
      _cancelPendingSeek();
    }
    if (oldWidget.loading && !widget.loading && widget.controller.visible) {
      _requestInitialFocus();
    }
    if (oldWidget.playing != widget.playing ||
        oldWidget.loading != widget.loading ||
        oldWidget.autoHideDuration != widget.autoHideDuration) {
      _syncAutoHideTimer();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_visibilityChanged);
    _autoHideTimer?.cancel();
    _directSeekBannerTimer?.cancel();
    _cancelPendingSeek();
    _surfaceFocus.dispose();
    _playFocus.dispose();
    _progressFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleRemote(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    // HUD 隐藏时支持 D-pad 左右免唤起直达寻址（±10s，连按加速至 ±30s）。
    if (!widget.controller.visible &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      return _handleDirectSeek(event, key == LogicalKeyboardKey.arrowRight);
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (widget.controller.visible) {
      _syncAutoHideTimer();
    }

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      // 恢复进度期间仍可暂停，重新开始播放须等待会话确认。
      if (!widget.loading) {
        unawaited(widget.onToggle());
      } else if (widget.playing) {
        unawaited(widget.onPause());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      unawaited(widget.onPause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay) {
      if (!widget.loading) unawaited(widget.onPlay());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _stepEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1);
      return KeyEventResult.handled;
    }

    // HUD 隐藏时按上键 1 步拉起右侧片源与清晰度抽屉；关闭后焦点回归播放区。
    if (!widget.controller.visible &&
        key == LogicalKeyboardKey.arrowUp &&
        !widget.loading &&
        widget.onQuickOpenDrawer != null) {
      unawaited(_openQuickDrawer());
      return KeyEventResult.handled;
    }

    final navigation = const [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.gameButtonA,
    ].contains(key);
    if (navigation && !widget.controller.visible) {
      widget.controller.show();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _openQuickDrawer() async {
    final opener = widget.onQuickOpenDrawer;
    if (opener == null || _modalOpen) return;
    _modalOpen = true;
    _syncAutoHideTimer();
    try {
      await opener();
    } finally {
      _modalOpen = false;
      if (mounted) {
        _requestInitialFocus();
        _syncAutoHideTimer();
      }
    }
  }

  KeyEventResult _handleDirectSeek(KeyEvent event, bool forward) {
    if (widget.loading || widget.duration <= Duration.zero) {
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (event is KeyDownEvent) {
        _directSeekRepeatCount = 0;
      } else {
        _directSeekRepeatCount++;
      }
      final stepSeconds = _directSeekRepeatCount >= 2 ? 30 : 10;
      final signedStep = forward ? stepSeconds : -stepSeconds;
      final base = _seekTarget ?? widget.position;
      final target = base + Duration(seconds: signedStep);
      final clamped = Duration(
        milliseconds: target.inMilliseconds.clamp(
          0,
          widget.duration.inMilliseconds,
        ),
      );
      _directSeekBannerTimer?.cancel();
      setState(() {
        _seekTarget = clamped;
        _directSeekPreview = clamped;
        _directSeekDeltaSeconds = signedStep;
      });
      _seekTimer?.cancel();
      final generation = _seekGeneration;
      _seekTimer = Timer(const Duration(milliseconds: 180), () {
        if (generation == _seekGeneration) _commitSeek(fromDirectSeek: true);
      });
    } else if (event is KeyUpEvent) {
      _seekTimer?.cancel();
      _directSeekRepeatCount = 0;
      _commitSeek(fromDirectSeek: true);
    }
    return KeyEventResult.handled;
  }

  void _stepEpisode(int delta) {
    if (widget.loading ||
        widget.onEpisodeSelected == null ||
        widget.roads.isEmpty) {
      return;
    }
    final target = widget.episodeIndex + delta;
    if (target < 0 ||
        target >= widget.roads[widget.roadIndex].episodes.length) {
      return;
    }
    unawaited(widget.onEpisodeSelected!(widget.roadIndex, target));
    widget.controller.show();
    _syncAutoHideTimer();
  }

  KeyEventResult _handleProgress(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    if (widget.loading || widget.duration <= Duration.zero) {
      return KeyEventResult.handled;
    }
    _syncAutoHideTimer();
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final step = event is KeyRepeatEvent ? 30 : 10;
      final base = _seekTarget ?? widget.position;
      final target =
          base +
          Duration(seconds: key == LogicalKeyboardKey.arrowRight ? step : -step);
      setState(
        () => _seekTarget = Duration(
          milliseconds: target.inMilliseconds.clamp(
            0,
            widget.duration.inMilliseconds,
          ),
        ),
      );
      _seekTimer?.cancel();
      final generation = _seekGeneration;
      // 连按只更新预览，松键或短暂停顿后提交，避免大量并发 seek。
      _seekTimer = Timer(const Duration(milliseconds: 180), () {
        if (generation == _seekGeneration) _commitSeek();
      });
    } else if (event is KeyUpEvent) {
      _seekTimer?.cancel();
      _commitSeek();
    }
    return KeyEventResult.handled;
  }

  void _commitSeek({bool fromDirectSeek = false}) {
    if (!mounted || widget.loading) {
      _cancelPendingSeek();
      return;
    }
    final target = _seekTarget;
    if (target == null) return;
    _seekTarget = null;
    unawaited(widget.onSeek(target));
    if (fromDirectSeek) {
      _directSeekBannerTimer?.cancel();
      _directSeekBannerTimer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        setState(() {
          _directSeekPreview = null;
          _directSeekDeltaSeconds = 0;
        });
      });
    }
    setState(() {});
    _syncAutoHideTimer();
  }

  void _cancelPendingSeek() {
    ++_seekGeneration;
    _seekTimer?.cancel();
    _seekTimer = null;
    _seekTarget = null;
    _directSeekRepeatCount = 0;
    _directSeekBannerTimer?.cancel();
    _directSeekBannerTimer = null;
    _directSeekPreview = null;
    _directSeekDeltaSeconds = 0;
  }

  Future<void> _selectEpisode() async {
    if (widget.roads.isEmpty || widget.onEpisodeSelected == null) return;
    _modalOpen = true;
    _syncAutoHideTimer();
    try {
      final selection = await showDialog<(int, int)>(
        context: context,
        builder: (_) => _TvEpisodePicker(
          roads: widget.roads,
          road: widget.roadIndex,
          episode: widget.episodeIndex,
        ),
      );
      if (selection != null && mounted) {
        await widget.onEpisodeSelected!(selection.$1, selection.$2);
      }
    } finally {
      _modalOpen = false;
      if (mounted) {
        _playFocus.requestFocus();
        _syncAutoHideTimer();
      }
    }
  }

  String _time(Duration value) => durationToString(value);

  Widget _buildDirectSeekPill() {
    final preview = _directSeekPreview;
    if (preview == null || widget.controller.visible) {
      return const SizedBox.shrink();
    }
    final fraction = widget.duration.inMilliseconds > 0
        ? (preview.inMilliseconds / widget.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    final deltaText = _directSeekDeltaSeconds >= 0
        ? '+${_directSeekDeltaSeconds}s'
        : '${_directSeekDeltaSeconds}s';
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 42, left: 48, right: 48),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 440),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: _darkroomSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: kTvFocusRingColor,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      _directSeekDeltaSeconds >= 0
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: kTvFocusRingColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      deltaText,
                      style: const TextStyle(
                        color: kTvFocusRingColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_time(preview)} / ${_time(widget.duration)}',
                      style: const TextStyle(
                        color: Color(0xFFF3F4F6),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction,
                    minHeight: 5,
                    color: _tungstenAccent,
                    backgroundColor: const Color(0x33FFFFFF),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final position = _seekTarget ?? widget.position;
    final fraction = widget.duration.inMilliseconds > 0
        ? (position.inMilliseconds / widget.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          )
        : 0.0;
    return Focus(
      focusNode: _surfaceFocus,
      autofocus: true,
      onKeyEvent: _handleRemote,
      child: GestureDetector(
        onTap: () {
          widget.controller.show();
          _syncAutoHideTimer();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            _buildDirectSeekPill(),
            if (widget.controller.visible)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xDC0B0C0E),
                        Colors.transparent,
                        Color(0xE60B0C0E),
                      ],
                      stops: [0, .40, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      // Android TV 5% Overscan 安全边距（水平 48dp / 垂直 27dp）。
                      padding: kTvOverscanPadding,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              TvAction(
                                label: '退出播放',
                                onPressed: widget.onExit,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(
                                    Icons.arrow_back,
                                    color: Color(0xFFF3F4F6),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFF3F4F6),
                                    fontSize: 22,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Focus(
                            focusNode: _progressFocus,
                            onKeyEvent: _handleProgress,
                            onFocusChange: (value) {
                              setState(() => _progressFocused = value);
                              _syncAutoHideTimer();
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: _darkroomSurface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _progressFocused
                                      ? kTvFocusRingColor
                                      : _darkroomHairline,
                                  width: _progressFocused
                                      ? kTvFocusBorderWidth
                                      : 1,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '${_time(position)} / ${_time(widget.duration)}',
                                        style: const TextStyle(
                                          color: Color(0xFFF3F4F6),
                                          fontWeight: FontWeight.w600,
                                          fontFeatures: [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      const Text(
                                        '左右 ±10s · 长按 ±30s',
                                        style: TextStyle(
                                          color: Color(0xFFA1A7B3),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: LinearProgressIndicator(
                                      value: fraction,
                                      minHeight: 5,
                                      color: _tungstenAccent,
                                      backgroundColor: const Color(0x33FFFFFF),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 16,
                            runSpacing: 12,
                            children: [
                              TvAction(
                                focusNode: _playFocus,
                                label: widget.playing ? '暂停' : '播放',
                                onPressed: widget.loading
                                    ? (widget.playing ? widget.onPause : null)
                                    : () {
                                        _syncAutoHideTimer();
                                        return widget.onToggle();
                                      },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 22,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        widget.playing
                                            ? Icons.pause
                                            : Icons.play_arrow,
                                        color: const Color(0xFFF3F4F6),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        widget.loading
                                            ? '加载中'
                                            : widget.playing
                                            ? '暂停'
                                            : '播放',
                                        style: const TextStyle(
                                          color: Color(0xFFF3F4F6),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (widget.onEpisodeSelected != null &&
                                  widget.roads.isNotEmpty) ...[
                                OutlinedButton(
                                  onPressed:
                                      widget.loading || widget.episodeIndex == 0
                                      ? null
                                      : () => _stepEpisode(-1),
                                  child: const Text('上一集'),
                                ),
                                OutlinedButton(
                                  onPressed:
                                      widget.loading ||
                                          widget.episodeIndex + 1 >=
                                              widget
                                                  .roads[widget.roadIndex]
                                                  .episodes
                                                  .length
                                      ? null
                                      : () => _stepEpisode(1),
                                  child: const Text('下一集'),
                                ),
                                OutlinedButton(
                                  onPressed: widget.loading
                                      ? null
                                      : _selectEpisode,
                                  child: const Text('线路 / 选集'),
                                ),
                              ],
                              TvSelect<double>(
                                label: '速度',
                                value: widget.rate,
                                options: const [
                                  (0.75, '0.75x'),
                                  (1.0, '1.0x'),
                                  (1.25, '1.25x'),
                                  (1.5, '1.5x'),
                                  (2.0, '2.0x'),
                                ],
                                onChanged: widget.loading
                                    ? null
                                    : (value) {
                                        _syncAutoHideTimer();
                                        unawaited(widget.onRate(value));
                                      },
                              ),
                              ...widget.extraActions,
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            widget.onQuickOpenDrawer != null
                                ? '无操作 5 秒隐藏 · 左右免唤起快进 · 上键直达片源抽屉 · 返回先收起再退出'
                                : '无操作 5 秒隐藏 · 左右免唤起快进 · 确认执行操作 · 返回先收起再退出',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFA1A7B3),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TvEpisodePicker extends StatefulWidget {
  const _TvEpisodePicker({
    required this.roads,
    required this.road,
    required this.episode,
  });
  final List<TvPlaybackRoad> roads;
  final int road;
  final int episode;
  @override
  State<_TvEpisodePicker> createState() => _TvEpisodePickerState();
}

class _TvEpisodePickerState extends State<_TvEpisodePicker> {
  late int _road = widget.road;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('播放线路与选集'),
    content: SizedBox(
      width: 720,
      height: 360,
      child: Column(
        children: [
          TvSelect<int>(
            label: '线路',
            value: _road,
            autofocus: true,
            options: [
              for (var index = 0; index < widget.roads.length; index++)
                (index, widget.roads[index].name),
            ],
            onChanged: (value) => setState(() => _road = value),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: GridView.builder(
              scrollCacheExtent: const ScrollCacheExtent.pixels(400),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                mainAxisExtent: 58,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: widget.roads[_road].episodes.length,
              itemBuilder: (context, index) => TvAction(
                label: widget.roads[_road].episodes[index],
                selected: _road == widget.road && index == widget.episode,
                onPressed: () => Navigator.of(context).pop((_road, index)),
                child: Center(
                  child: Text(
                    widget.roads[_road].episodes[index],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('关闭'),
      ),
    ],
  );
}
