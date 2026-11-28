import 'dart:math' as math;

import 'package:kazumi/modules/media/media_models.dart';

enum SuperResolutionMode {
  off(
    storageValue: 1,
    label: '关闭',
    description: '使用片源原始分辨率渲染',
  ),
  efficiency(
    storageValue: 2,
    label: '4K 效率档',
    description: '流畅推荐：影视使用 FSR + 细节锐化 + 去色带，动漫使用 Anime4K 提升至 4K',
  ),
  quality(
    storageValue: 3,
    label: '4K 质量档',
    description: '极致清晰：影视使用 FSRCNNX + 细节锐化 + 色度增强，动漫使用高精度 Anime4K 提升至 4K',
  );

  const SuperResolutionMode({
    required this.storageValue,
    required this.label,
    required this.description,
  });

  final int storageValue;
  final String label;
  final String description;

  static SuperResolutionMode fromStorageValue(int value) {
    return SuperResolutionMode.values.firstWhere(
      (mode) => mode.storageValue == value,
      orElse: () => SuperResolutionMode.off,
    );
  }
}

enum SuperResolutionContentProfile {
  auto(
    storageValue: 0,
    label: '自动（按频道）',
    description: '动漫使用动漫模型，电视剧与电影使用影视真人模型',
  ),
  anime(
    storageValue: 1,
    label: '动漫优先',
    description: '始终使用动漫线条增强模型（Anime4K）',
  ),
  liveAction(
    storageValue: 2,
    label: '影视真人优先',
    description: '始终使用真人实拍超分模型（FSR / FSRCNNX）',
  );

  const SuperResolutionContentProfile({
    required this.storageValue,
    required this.label,
    required this.description,
  });

  final int storageValue;
  final String label;
  final String description;

  static SuperResolutionContentProfile fromStorageValue(int value) {
    return SuperResolutionContentProfile.values.firstWhere(
      (profile) => profile.storageValue == value,
      orElse: () => SuperResolutionContentProfile.auto,
    );
  }
}

enum ResolvedEnhancementContent { anime, liveAction }

ResolvedEnhancementContent resolveEnhancementContent(
  SuperResolutionContentProfile profile,
  MediaKind mediaKind,
) {
  switch (profile) {
    case SuperResolutionContentProfile.auto:
      return mediaKind == MediaKind.anime
          ? ResolvedEnhancementContent.anime
          : ResolvedEnhancementContent.liveAction;
    case SuperResolutionContentProfile.anime:
      return ResolvedEnhancementContent.anime;
    case SuperResolutionContentProfile.liveAction:
      return ResolvedEnhancementContent.liveAction;
  }
}

/// 根据源视频尺寸与设备档位计算超分目标输出尺寸（上限 3840、最多 2×，保持宽高比与偶数对齐）。
///
/// 桌面端、Android TV 与质量档始终以 3840 长边为目标上限进行超分/4K 超采样，
/// 确保即使在窗口模式或 1080P 显示器上也能触发 `OUTPUT / LUMA > 1.3` 的 GLSL 超分着色器。
({int width, int height})? computeTargetOutputSize({
  required SuperResolutionMode mode,
  required bool upscaleOutputEnabled,
  required int sourceWidth,
  required int sourceHeight,
  required int viewportPhysicalWidth,
  required int viewportPhysicalHeight,
  bool isDesktop = true,
  bool isTelevision = false,
  String? videoRenderer,
}) {
  if (mode == SuperResolutionMode.off ||
      !upscaleOutputEnabled ||
      videoRenderer == 'mediacodec_embed' ||
      sourceWidth <= 0 ||
      sourceHeight <= 0) {
    return null;
  }

  final sourceLong = math.max(sourceWidth, sourceHeight);
  if (sourceLong >= 3200) {
    return null;
  }

  final int maxTargetLong;
  if (isDesktop || isTelevision || mode == SuperResolutionMode.quality) {
    maxTargetLong = 3840;
  } else {
    final viewportLong = math.max(viewportPhysicalWidth, viewportPhysicalHeight);
    maxTargetLong = math.min(3840, math.max(2560, viewportLong));
  }

  final scale = math.min(2.0, maxTargetLong / sourceLong);
  if (scale <= 1.05) {
    return null;
  }

  final rawWidth = (sourceWidth * scale).round();
  final rawHeight = (sourceHeight * scale).round();
  final targetWidth = math.max(2, (rawWidth ~/ 2) * 2);
  final targetHeight = math.max(2, (rawHeight ~/ 2) * 2);
  return (width: targetWidth, height: targetHeight);
}

class VideoEnhancementPlan {
  const VideoEnhancementPlan({
    required this.mode,
    required this.resolvedContent,
    required this.shaderFiles,
    required this.mpvProperties,
    required this.targetOutputSize,
    required this.activeSummary,
    this.skippedForHighResSource = false,
  });

  final SuperResolutionMode mode;
  final ResolvedEnhancementContent resolvedContent;
  final List<String> shaderFiles;
  final Map<String, String> mpvProperties;
  final ({int width, int height})? targetOutputSize;
  final String activeSummary;
  final bool skippedForHighResSource;
}

VideoEnhancementPlan buildVideoEnhancementPlan({
  required SuperResolutionMode mode,
  required SuperResolutionContentProfile profile,
  required MediaKind mediaKind,
  required bool debandEnabled,
  required bool upscaleOutputEnabled,
  bool sharpenEnabled = true,
  required bool isDesktop,
  required bool isTelevision,
  required int sourceWidth,
  required int sourceHeight,
  required int viewportPhysicalWidth,
  required int viewportPhysicalHeight,
  String? videoRenderer,
}) {
  final resolvedContent = resolveEnhancementContent(profile, mediaKind);

  if (videoRenderer == 'mediacodec_embed') {
    return VideoEnhancementPlan(
      mode: mode,
      resolvedContent: resolvedContent,
      shaderFiles: const [],
      mpvProperties: const {},
      targetOutputSize: null,
      activeSummary: '关闭',
    );
  }

  if (mode == SuperResolutionMode.off) {
    return VideoEnhancementPlan(
      mode: mode,
      resolvedContent: resolvedContent,
      shaderFiles: const [],
      mpvProperties: const {
        'deband': 'no',
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'correct-downscaling': 'no',
        'sigmoid-upscaling': 'no',
      },
      targetOutputSize: null,
      activeSummary: '关闭',
    );
  }

  final isHighResSource =
      sourceWidth > 0 &&
      sourceHeight > 0 &&
      math.max(sourceWidth, sourceHeight) >= 3200;
  if (isHighResSource) {
    return VideoEnhancementPlan(
      mode: mode,
      resolvedContent: resolvedContent,
      shaderFiles: const [],
      mpvProperties: const {
        'deband': 'no',
        'scale': 'bilinear',
        'cscale': 'bilinear',
        'dscale': 'bilinear',
        'correct-downscaling': 'no',
        'sigmoid-upscaling': 'no',
      },
      targetOutputSize: null,
      activeSummary: '已为4K片源（免超分）',
      skippedForHighResSource: true,
    );
  }

  final List<String> shaderFiles;
  final String activeSummary;
  switch ((resolvedContent, mode)) {
    case (ResolvedEnhancementContent.anime, SuperResolutionMode.efficiency):
      shaderFiles = const [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ];
      activeSummary = '4K 动漫·效率';
    case (ResolvedEnhancementContent.anime, SuperResolutionMode.quality):
      shaderFiles = isDesktop
          ? const [
              'Anime4K_Clamp_Highlights.glsl',
              'Anime4K_Restore_CNN_VL.glsl',
              'Anime4K_Upscale_CNN_x2_VL.glsl',
              'KrigBilateral.glsl',
            ]
          : const [
              'Anime4K_Clamp_Highlights.glsl',
              'Anime4K_Restore_CNN_M.glsl',
              'Anime4K_Upscale_CNN_x2_M.glsl',
              'KrigBilateral.glsl',
            ];
      activeSummary = '4K 动漫·质量';
    case (ResolvedEnhancementContent.liveAction, SuperResolutionMode.efficiency):
      shaderFiles = [
        'FSR.glsl',
        if (sharpenEnabled) 'adaptive-sharpen.glsl',
      ];
      activeSummary = '4K 影视·效率';
    case (ResolvedEnhancementContent.liveAction, SuperResolutionMode.quality):
      shaderFiles = [
        isDesktop ? 'FSRCNNX_x2_16-0-4-1.glsl' : 'FSRCNNX_x2_8-0-4-1.glsl',
        'KrigBilateral.glsl',
        if (sharpenEnabled) 'adaptive-sharpen.glsl',
      ];
      activeSummary = '4K 影视·质量';
    case (_, SuperResolutionMode.off):
      shaderFiles = const [];
      activeSummary = '关闭';
  }

  final Map<String, String> mpvProperties;
  if (mode == SuperResolutionMode.efficiency) {
    mpvProperties = {
      'deband': debandEnabled ? 'yes' : 'no',
      if (debandEnabled) ...{
        'deband-iterations': '1',
        'deband-threshold': '35',
        'deband-range': '16',
        'deband-grain': '6',
      },
      'scale': isTelevision ? 'bilinear' : 'spline36',
      'cscale': 'bilinear',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'sigmoid-upscaling': 'no',
    };
  } else {
    mpvProperties = {
      'deband': debandEnabled ? 'yes' : 'no',
      if (debandEnabled) ...{
        'deband-iterations': isDesktop ? '2' : '1',
        'deband-threshold': '45',
        'deband-range': '16',
        'deband-grain': '8',
      },
      'scale': isDesktop ? 'ewa_lanczos' : 'spline36',
      'cscale': 'mitchell',
      'dscale': 'mitchell',
      'correct-downscaling': 'yes',
      'sigmoid-upscaling': isDesktop ? 'yes' : 'no',
    };
  }

  final targetOutputSize = computeTargetOutputSize(
    mode: mode,
    upscaleOutputEnabled: upscaleOutputEnabled,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    viewportPhysicalWidth: viewportPhysicalWidth,
    viewportPhysicalHeight: viewportPhysicalHeight,
    isDesktop: isDesktop,
    isTelevision: isTelevision,
    videoRenderer: videoRenderer,
  );

  return VideoEnhancementPlan(
    mode: mode,
    resolvedContent: resolvedContent,
    shaderFiles: shaderFiles,
    mpvProperties: mpvProperties,
    targetOutputSize: targetOutputSize,
    activeSummary: activeSummary,
  );
}

SuperResolutionMode? evaluateAutoDowngradeMode({
  required SuperResolutionMode currentMode,
  required int droppedDeltaInWindow,
  required int consecutiveHighDropWindows,
  required bool autoDowngradeEnabled,
  int dropThresholdPerWindow = 18,
  int requiredConsecutiveWindows = 2,
}) {
  if (!autoDowngradeEnabled || currentMode == SuperResolutionMode.off) {
    return null;
  }
  if (droppedDeltaInWindow < dropThresholdPerWindow ||
      consecutiveHighDropWindows < requiredConsecutiveWindows) {
    return null;
  }
  return currentMode == SuperResolutionMode.quality
      ? SuperResolutionMode.efficiency
      : SuperResolutionMode.off;
}
