import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:kazumi/television/tv_focus.dart';

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
    this.extraActions = const [],
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
  final List<Widget> extraActions;

  @override
  State<TvPlaybackControls> createState() => _TvPlaybackControlsState();
}

class _TvPlaybackControlsState extends State<TvPlaybackControls> {
  final _surfaceFocus = FocusNode(debugLabel: '电视播放区域');
  final _playFocus = FocusNode(debugLabel: '电视播放暂停');
  final _progressFocus = FocusNode(debugLabel: '电视播放进度');
  Timer? _seekTimer;
  Duration? _seekTarget;
  int _seekGeneration = 0;
  bool _progressFocused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_visibilityChanged);
    _requestInitialFocus();
  }

  void _requestInitialFocus() =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        (widget.controller.visible ? _playFocus : _surfaceFocus).requestFocus();
      });

  void _visibilityChanged() {
    if (!mounted) return;
    setState(() {});
    _requestInitialFocus();
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
  }

  @override
  void dispose() {
    widget.controller.removeListener(_visibilityChanged);
    _cancelPendingSeek();
    _surfaceFocus.dispose();
    _playFocus.dispose();
    _progressFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleRemote(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.space) {
      if (!widget.loading) unawaited(widget.onToggle());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      if (!widget.loading) {
        unawaited(
          key == LogicalKeyboardKey.mediaPlay
              ? widget.onPlay()
              : widget.onPause(),
        );
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious) {
      _stepEpisode(key == LogicalKeyboardKey.mediaTrackNext ? 1 : -1);
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
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final base = _seekTarget ?? widget.position;
      final target =
          base +
          Duration(seconds: key == LogicalKeyboardKey.arrowRight ? 10 : -10);
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

  void _commitSeek() {
    if (!mounted || widget.loading) {
      _cancelPendingSeek();
      return;
    }
    final target = _seekTarget;
    if (target == null) return;
    _seekTarget = null;
    unawaited(widget.onSeek(target));
    setState(() {});
  }

  void _cancelPendingSeek() {
    ++_seekGeneration;
    _seekTimer?.cancel();
    _seekTimer = null;
    _seekTarget = null;
  }

  Future<void> _selectEpisode() async {
    if (widget.roads.isEmpty || widget.onEpisodeSelected == null) return;
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
    if (mounted) _playFocus.requestFocus();
  }

  String _time(Duration value) {
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${value.inMinutes}:$seconds';
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
        onTap: widget.controller.show,
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (widget.controller.visible)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black87,
                        Colors.transparent,
                        Colors.black87,
                      ],
                      stops: [0, .40, 1],
                    ),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 20, 32, 24),
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
                                    color: Colors.white,
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
                                    color: Colors.white,
                                    fontSize: 22,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Focus(
                            focusNode: _progressFocus,
                            onKeyEvent: _handleProgress,
                            onFocusChange: (value) =>
                                setState(() => _progressFocused = value),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _progressFocused
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '${_time(position)} / ${_time(widget.duration)}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                      const Spacer(),
                                      const Text(
                                        '进度聚焦后，左右调整 10 秒',
                                        style: TextStyle(color: Colors.white70),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  LinearProgressIndicator(
                                    value: fraction,
                                    minHeight: 5,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 12,
                            runSpacing: 10,
                            children: [
                              TvAction(
                                focusNode: _playFocus,
                                label: widget.playing ? '暂停' : '播放',
                                onPressed: widget.loading
                                    ? null
                                    : widget.onToggle,
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
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        widget.loading
                                            ? '加载中'
                                            : widget.playing
                                            ? '暂停'
                                            : '播放',
                                        style: const TextStyle(
                                          color: Colors.white,
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
                                    : (value) =>
                                          unawaited(widget.onRate(value)),
                              ),
                              ...widget.extraActions,
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '方向键移动焦点 · 确认执行操作 · 返回收起操作层，再按返回退出',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white70,
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
          const SizedBox(height: 14),
          Expanded(
            child: GridView.builder(
              scrollCacheExtent: const ScrollCacheExtent.pixels(400),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 170,
                mainAxisExtent: 58,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
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
