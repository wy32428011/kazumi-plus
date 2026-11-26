import 'dart:async';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackCachePolicy {
  PlaybackCachePolicy({
    required bool Function() isLocalPlayback,
    required Player? Function() currentPlayer,
    required bool Function() isPrefetchSuspended,
    void Function(bool constrained)? onConstrainedChanged,
  }) : _isLocalPlayback = isLocalPlayback,
       _currentPlayer = currentPlayer,
       _isPrefetchSuspended = isPrefetchSuspended,
       _onConstrainedChanged = onConstrainedChanged;

  // 字节数是上限，实际缓冲时长取决于码率；前向与回看分别限额，
  // 避免长时间播放高码率视频时缓存增长到数 GB。
  static const int _lowMemoryBufferSize = 64 * 1024 * 1024;
  static const int _defaultBufferSize = 256 * 1024 * 1024;

  final bool Function() _isLocalPlayback;
  final Player? Function() _currentPlayer;
  final bool Function() _isPrefetchSuspended;
  final void Function(bool constrained)? _onConstrainedChanged;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  StreamSubscription<void>? _settingsSubscription;

  bool get networkAutomatic =>
      LowMemoryMode.current == LowMemoryMode.auto &&
      !_isLocalPlayback() &&
      MeteredNetworkService.isMetered;

  bool get _constrained => LowMemoryMode.current.isEnabled(
    isMetered: MeteredNetworkService.isMetered,
    isLocalPlayback: _isLocalPlayback(),
  );

  bool get isConstrained => _constrained;

  int get bufferSize =>
      _constrained ? _lowMemoryBufferSize : _defaultBufferSize;

  void startWatching() {
    if (_settingsSubscription != null) {
      return;
    }
    _settingsSubscription = LowMemoryMode.watch().listen((_) => _onChanged());
    MeteredNetworkService.listenable.addListener(_onChanged);
  }

  void stopWatching() {
    MeteredNetworkService.listenable.removeListener(_onChanged);
    unawaited(_settingsSubscription?.cancel());
    _settingsSubscription = null;
  }

  Future<void> apply() async {
    final player = _currentPlayer();
    if (player == null) {
      return;
    }
    try {
      final pp = player.platform as NativePlayer;
      // A stale player's initialization must not block its replacement's writes.
      await pp.waitForPlayerInitialization;
      await _writes.run(() async {
        if (!identical(_currentPlayer(), player)) {
          return;
        }
        final constrained = _constrained;
        _onConstrainedChanged?.call(constrained);
        final forward = constrained ? _lowMemoryBufferSize : _defaultBufferSize;
        final backward = (constrained ? 16 : 64) * 1024 * 1024;
        await pp.setProperty('demuxer-max-bytes', forward.toString());
        await pp.setProperty('demuxer-max-back-bytes', backward.toString());
        if (!identical(_currentPlayer(), player)) return;
        final seconds = _isPrefetchSuspended()
            ? '0'
            : (constrained ? '30' : '150');
        await pp.setProperty('demuxer-readahead-secs', seconds);
        await pp.setProperty('cache-secs', seconds);
      });
    } catch (e) {
      KazumiLogger().w(
        'PlaybackCachePolicy: failed to apply demuxer cache size',
        error: e,
      );
    }
  }

  void _onChanged() {
    unawaited(apply());
  }
}
