import 'dart:async';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// 锁定的上游分支公开此初始化锁，用于排在 Surface 重建的补偿定位之后。
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';

/// 恢复位置确认前不允许保存零位进度；切集、返回及失败可以取消等待。
class MediaResumeSession {
  final _cancelled = Completer<void>();

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  bool get isCancelled => _cancelled.isCompleted;

  Future<T> _awaitActive<T>(Future<T> operation) => Future.any([
    operation,
    _cancelled.future.then<T>((_) => throw StateError('观看进度恢复已取消')),
  ]);

  Future<void> restore({
    required Player player,
    required VideoController video,
    required Duration position,
    required bool Function() isCurrent,
  }) async {
    void checkCurrent() {
      if (isCancelled || !isCurrent()) throw StateError('观看进度恢复已取消');
    }

    await _awaitActive(
      video.waitUntilFirstFrameRendered.timeout(const Duration(seconds: 45)),
    );
    checkCurrent();

    Future<void> seekAndConfirm() async {
      checkCurrent();
      final landed = Completer<void>();
      final subscription = player.stream.position.listen((actual) {
        if (!landed.isCompleted &&
            (actual.inMilliseconds - position.inMilliseconds).abs() <= 3000) {
          landed.complete();
        }
      });
      try {
        // 先监听后定位，命令提交成功不等于原生位置已更新。
        await _awaitActive(
          player.seek(position).timeout(const Duration(seconds: 30)),
        );
        await _awaitActive(landed.future.timeout(const Duration(seconds: 30)));
        checkCurrent();
      } finally {
        await subscription.cancel();
      }
    }

    if (Platform.isAndroid) {
      final platform = await _awaitActive(video.platform.future);
      checkCurrent();
      if (platform is AndroidVideoController) {
        final surfaceReady = Completer<void>();
        void checkSurface() {
          final wid = platform.wid.value;
          if (wid != null && wid != 0 && !surfaceReady.isCompleted) {
            surfaceReady.complete();
          }
        }

        platform.wid.addListener(checkSurface);
        checkSurface();
        try {
          await _awaitActive(
            surfaceReady.future.timeout(const Duration(seconds: 30)),
          );
          checkCurrent();
          // widListener 也使用此锁；恢复必须排在输出重建及内部 seek 之后。
          await _awaitActive(
            platform.lock.synchronized(
              seekAndConfirm,
              timeout: const Duration(seconds: 30),
            ),
          );
        } finally {
          platform.wid.removeListener(checkSurface);
        }
        return;
      }
    }
    await seekAndConfirm();
  }
}
