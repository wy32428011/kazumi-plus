import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';

class PlayerItemSurface extends StatefulWidget {
  const PlayerItemSurface({
    super.key,
    required this.playerController,
  });

  final PlayerControlsController playerController;

  @override
  State<PlayerItemSurface> createState() => _PlayerItemSurfaceState();
}

class _PlayerItemSurfaceState extends State<PlayerItemSurface> {
  int _lastReportedWidth = 0;
  int _lastReportedHeight = 0;

  void _reportViewportSize(int width, int height) {
    if (width <= 0 || height <= 0) return;
    if (_lastReportedWidth == width && _lastReportedHeight == height) {
      return;
    }
    _lastReportedWidth = width;
    _lastReportedHeight = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.playerController.updateViewportPhysicalSize(width, height);
    });
  }

  @override
  Widget build(BuildContext context) {
    final playerController = widget.playerController;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxHeight.isFinite) {
          _reportViewportSize(
            (constraints.maxWidth * devicePixelRatio).round(),
            (constraints.maxHeight * devicePixelRatio).round(),
          );
        }
        return Observer(
          builder: (context) {
            if (playerController.playback.loading ||
                playerController.playback.videoController == null) {
              return Container(
                color: Colors.black,
                child: const Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }

            final aspectRatioMode = playerController.panel.aspectRatioMode;
            final videoController = playerController.playback.videoController!;
            final video = Video(
              key: ValueKey(videoController),
              controller: videoController,
              controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
              fit: aspectRatioMode.fit,
              subtitleViewConfiguration: SubtitleViewConfiguration(
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 40.0,
                  background: Paint()..color = Colors.transparent,
                  decoration: TextDecoration.none,
                  fontWeight: FontWeight.w600,
                  shadows: const [
                    Shadow(
                      offset: Offset(1.0, 1.0),
                      blurRadius: 3.0,
                      color: Color.fromARGB(220, 0, 0, 0),
                    ),
                    Shadow(
                      offset: Offset(-1.0, -1.0),
                      blurRadius: 3.0,
                      color: Color.fromARGB(180, 0, 0, 0),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                padding: const EdgeInsets.all(24.0),
              ),
            );

            final frameAspectRatio = aspectRatioMode.frameAspectRatio;
            if (frameAspectRatio == null) {
              return video;
            }
            return AspectRatio(
              aspectRatio: frameAspectRatio,
              child: video,
            );
          },
        );
      },
    );
  }
}
