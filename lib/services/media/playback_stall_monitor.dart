import 'dart:collection';

/// 播中卡顿或故障触发原因。
enum StallTriggerReason {
  /// 起播黑屏超时（直连/HLS > 12s，WebView > 20s）或播放器致命打开错误。
  startupBlackScreen,

  /// 连续缓冲且进度推进 < 200ms 超过阈值（桌面/Wi-Fi 8s，移动受限 11s）。
  sustainedStall,

  /// 60 秒滑窗内发生 ≥ 3 次 ≥ 2s 再缓冲且超前缓冲 < 3s。
  frequentRebuffering,

  /// 本地 HLS 代理优先分片连续失败且超前缓冲 < 4s。
  proxyPrioritySegmentFailure,
}

/// 单帧采样快照（供 `PlaybackStallMonitor.sample` 评估）。
class PlaybackHealthSample {
  const PlaybackHealthSample({
    required this.playing,
    required this.loading,
    required this.resumePending,
    required this.completed,
    required this.backgroundSuspended,
    required this.seeking,
    required this.qualitySwitching,
    required this.manualSwitchInProgress,
    required this.buffering,
    required this.position,
    required this.buffer,
    required this.playerWidth,
    this.isConstrainedNetwork = false,
  });

  final bool playing;
  final bool loading;
  final bool resumePending;
  final bool completed;
  final bool backgroundSuspended;
  final bool seeking;
  final bool qualitySwitching;
  final bool manualSwitchInProgress;
  final bool buffering;
  final Duration position;
  final Duration buffer;
  final int playerWidth;
  final bool isConstrainedNetwork;

  Duration get bufferAhead {
    final diff = buffer - position;
    return diff.isNegative ? Duration.zero : diff;
  }
}

/// 严苛布防门控的播中卡顿监测器。
///
/// 门控条件：仅在 `playing && !loading && !resumePending && !completed &&`
/// `!backgroundSuspended && !seeking && !withinPostSeekGrace(5s) &&`
/// `!qualitySwitching && !manualSwitchInProgress` 全部满足时累计卡顿。
class PlaybackStallMonitor {
  PlaybackStallMonitor({
    DateTime Function()? clock,
    this.postSeekGrace = const Duration(seconds: 5),
    this.directStartupTimeout = const Duration(seconds: 12),
    this.webviewStartupTimeout = const Duration(seconds: 20),
    this.desktopSustainedStallThreshold = const Duration(seconds: 8),
    this.mobileSustainedStallThreshold = const Duration(seconds: 11),
    this.rebufferWindow = const Duration(seconds: 60),
    this.minRebufferEpisode = const Duration(seconds: 2),
    this.frequentRebufferCount = 3,
    this.rebufferLowAheadThreshold = const Duration(seconds: 3),
    this.proxyFailureLowAheadThreshold = const Duration(seconds: 4),
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Duration postSeekGrace;
  final Duration directStartupTimeout;
  final Duration webviewStartupTimeout;
  final Duration desktopSustainedStallThreshold;
  final Duration mobileSustainedStallThreshold;
  final Duration rebufferWindow;
  final Duration minRebufferEpisode;
  final int frequentRebufferCount;
  final Duration rebufferLowAheadThreshold;
  final Duration proxyFailureLowAheadThreshold;

  DateTime? _loadStartedAt;
  bool _isWebviewSource = false;
  bool _firstFrameDecoded = false;
  DateTime? _lastSeekAt;
  DateTime? _stallStartedAt;
  Duration? _stallAnchorPosition;
  bool _currentStallRecordedAsRebuffer = false;
  final Queue<DateTime> _rebufferTimestamps = Queue();
  bool _triggeredForCurrentLoad = false;

  bool get hasTriggered => _triggeredForCurrentLoad;
  bool get firstFrameDecoded => _firstFrameDecoded;

  /// 开始加载新集或新片源时重置状态并启动起播黑屏计时器。
  void markLoadStarted({bool isWebviewSource = false}) {
    _loadStartedAt = _clock();
    _isWebviewSource = isWebviewSource;
    _firstFrameDecoded = false;
    _lastSeekAt = null;
    _stallStartedAt = null;
    _stallAnchorPosition = null;
    _currentStallRecordedAsRebuffer = false;
    _rebufferTimestamps.clear();
    _triggeredForCurrentLoad = false;
  }

  /// 完全复位（退出播放或停止监测）。
  void reset() {
    _loadStartedAt = null;
    _firstFrameDecoded = false;
    _lastSeekAt = null;
    _stallStartedAt = null;
    _stallAnchorPosition = null;
    _currentStallRecordedAsRebuffer = false;
    _rebufferTimestamps.clear();
    _triggeredForCurrentLoad = false;
  }

  /// 标记用户刚刚拖动进度条，开启 5 秒寻址宽限期。
  void markSeek() {
    _lastSeekAt = _clock();
    _clearActiveStall();
  }

  /// 外部已处理完一次容灾后允许下一次重新评估。
  void clearTrigger() {
    _triggeredForCurrentLoad = false;
    _clearActiveStall();
  }

  bool isWithinPostSeekGrace([DateTime? now]) {
    final seekAt = _lastSeekAt;
    if (seekAt == null) return false;
    final ts = now ?? _clock();
    return ts.difference(seekAt) < postSeekGrace;
  }

  /// 评估当前样本是否满足严苛布防门控。
  bool isArmed(PlaybackHealthSample sample, [DateTime? now]) {
    final ts = now ?? _clock();
    return sample.playing &&
        !sample.loading &&
        !sample.resumePending &&
        !sample.completed &&
        !sample.backgroundSuspended &&
        !sample.seeking &&
        !isWithinPostSeekGrace(ts) &&
        !sample.qualitySwitching &&
        !sample.manualSwitchInProgress;
  }

  /// 上报本地 HLS 代理优先分片连续失败；仅当超前缓冲 < 4s 且满足基本非暂停态时触发。
  StallTriggerReason? reportProxyPrioritySegmentFailure({
    required PlaybackHealthSample sample,
  }) {
    if (_triggeredForCurrentLoad) return null;
    if (sample.completed ||
        sample.backgroundSuspended ||
        sample.manualSwitchInProgress ||
        sample.qualitySwitching) {
      return null;
    }
    if (!sample.playing && _firstFrameDecoded) return null;
    if (sample.bufferAhead < proxyFailureLowAheadThreshold) {
      _triggeredForCurrentLoad = true;
      return StallTriggerReason.proxyPrioritySegmentFailure;
    }
    return null;
  }

  /// 按播放器时钟推进评估，命中四大触发条件之一时返回对应原因（单次加载仅触发一次，直到重置）。
  StallTriggerReason? sample(PlaybackHealthSample sample) {
    if (_triggeredForCurrentLoad) return null;
    final now = _clock();

    if (sample.playerWidth > 0) {
      _firstFrameDecoded = true;
    }

    // 1. 起播黑屏超时（首帧出画前 playerWidth == 0 超 12s / WebView 20s）
    if (!_firstFrameDecoded &&
        _loadStartedAt != null &&
        !sample.completed &&
        !sample.backgroundSuspended &&
        !sample.manualSwitchInProgress) {
      final timeout = _isWebviewSource
          ? webviewStartupTimeout
          : directStartupTimeout;
      if (now.difference(_loadStartedAt!) >= timeout) {
        _triggeredForCurrentLoad = true;
        return StallTriggerReason.startupBlackScreen;
      }
    }

    // 2. 严苛布防门控：任一屏蔽条件生效立即清空当前卡顿计时，绝不误判。
    if (!isArmed(sample, now)) {
      _clearActiveStall();
      return null;
    }

    // 清理滑窗外历史再缓冲记录。
    while (_rebufferTimestamps.isNotEmpty &&
        now.difference(_rebufferTimestamps.first) > rebufferWindow) {
      _rebufferTimestamps.removeFirst();
    }

    // 3. 持续卡顿 & 高频再缓冲
    if (sample.buffering) {
      if (_stallStartedAt == null) {
        _stallStartedAt = now;
        _stallAnchorPosition = sample.position;
        _currentStallRecordedAsRebuffer = false;
      } else {
        final advancedMs =
            (sample.position - (_stallAnchorPosition ?? sample.position))
                .inMilliseconds
                .abs();
        if (advancedMs >= 200) {
          // 画面实际仍在前进，重置停滞锚点。
          _stallStartedAt = now;
          _stallAnchorPosition = sample.position;
          _currentStallRecordedAsRebuffer = false;
        } else {
          final stalledFor = now.difference(_stallStartedAt!);
          if (!_currentStallRecordedAsRebuffer &&
              stalledFor >= minRebufferEpisode) {
            _currentStallRecordedAsRebuffer = true;
            _rebufferTimestamps.addLast(now);
            if (_rebufferTimestamps.length >= frequentRebufferCount &&
                sample.bufferAhead < rebufferLowAheadThreshold) {
              _triggeredForCurrentLoad = true;
              return StallTriggerReason.frequentRebuffering;
            }
          }

          final threshold = sample.isConstrainedNetwork
              ? mobileSustainedStallThreshold
              : desktopSustainedStallThreshold;
          if (stalledFor >= threshold) {
            _triggeredForCurrentLoad = true;
            return StallTriggerReason.sustainedStall;
          }
        }
      }
    } else {
      _clearActiveStall();
    }

    return null;
  }

  void _clearActiveStall() {
    _stallStartedAt = null;
    _stallAnchorPosition = null;
    _currentStallRecordedAsRebuffer = false;
  }
}
