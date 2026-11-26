import 'package:flutter/material.dart';
import 'package:kazumi/pages/player/player_presentation_context.dart';

/// 播中自动容灾非阻塞暗房轻提示条。
///
/// 严禁使用 BackdropFilter / ImageFilter.blur（防 Impeller 视频层崩溃）。
class PlayerFailoverBanner extends StatelessWidget {
  const PlayerFailoverBanner({
    super.key,
    required this.features,
    this.disableAnimations = false,
  });

  final PlayerSourceSwitchingFeatures features;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: features.sourceChanges,
      builder: (context, _) {
        final banner = features.failoverBanner;
        final visible = banner != null;
        final duration = disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 180);

        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: banner == null
                ? const SizedBox.shrink()
                : SafeArea(
                    bottom: false,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: 56,
                          left: 16,
                          right: 16,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Material(
                            color: const Color(0xF0121316),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: const BorderSide(
                                color: Color(0xFFD8A85B),
                                width: 1,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.swap_horiz_rounded,
                                    size: 18,
                                    color: Color(0xFFD8A85B),
                                  ),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      banner.headline,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFF3F4F6),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (banner.canUndo) ...[
                                    const SizedBox(width: 8),
                                    TextButton(
                                      style: TextButton.styleFrom(
                                        foregroundColor: const Color(
                                          0xFFD8A85B,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 4,
                                        ),
                                        minimumSize: const Size(0, 32),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      onPressed: () =>
                                          features.undoLastFailover(),
                                      child: const Text(
                                        '切回原源',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                  IconButton(
                                    tooltip: '关闭提示',
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 28,
                                      minHeight: 28,
                                    ),
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                      color: Color(0xFFA1A7B3),
                                    ),
                                    onPressed: features.dismissFailoverBanner,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
