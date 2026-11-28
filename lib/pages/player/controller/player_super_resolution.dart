import 'dart:math' as math;

import 'package:kazumi/modules/media/media_models.dart';

enum SuperResolutionMode {
  off(
    storageValue: 1,
    label: '关闭',
    description: '默认禁用超分辨率',
  ),
  efficiency(
    storageValue: 2,
    label: '效率档',
    description: '效率优先：动漫使用轻量 Anime4K，影视使用 FSR + 去色带',
  ),
  quality(
    storageValue: 3,
    label: '质量档',
    description: '质量优先：动漫使用 ArtCNN，影视使用 FSRCNNX + 去色带',
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
    description: '始终使用动漫线条增强模型（Anime4K / ArtCNN）',
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

/// 根据源视频尺寸与当前物理视口尺寸计算超分目标输出尺寸（上限 3840、最多 2×，保持宽高比与偶数对齐）。
({int width, int height})? computeTargetOutputSize({
  required SuperResolutionMode mode,
  required bool upscaleOutputEnabled,
  required int sourceWidth,
  required int sourceHeight,
  required int viewportPhysicalWidth,
  required int viewportPhysicalHeight,
  String? videoRenderer,
}) {
  if (mode == SuperResolutionMode.off ||
      !upscaleOutputEnabled ||
      videoRenderer == 'mediacodec_embed' ||
      sourceWidth <= 0 ||
      sourceHeight <= 0 ||
      viewportPhysicalWidth <= 0 ||
      viewportPhysicalHeight <= 0) {
    return null;
  }

  final sourceLong = math.max(sourceWidth, sourceHeight);
  if (sourceLong >= 3200) {
    return null;
  }

  final viewportLong = math.max(viewportPhysicalWidth, viewportPhysicalHeight);
  final maxTargetLong = math.min(3840, viewportLong);
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
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ];
      activeSummary = '动漫·Anime4K';
    case (ResolvedEnhancementContent.anime, SuperResolutionMode.quality):
      shaderFiles = isDesktop
          ? const ['ArtCNN_C4F32.glsl', 'KrigBilateral.glsl']
          : const ['ArtCNN_C4F16.glsl', 'KrigBilateral.glsl'];
      activeSummary = '动漫·ArtCNN';
    case (ResolvedEnhancementContent.liveAction, SuperResolutionMode.efficiency):
      shaderFiles = const ['FSR.glsl'];
      activeSummary = '影视·FSR';
    case (ResolvedEnhancementContent.liveAction, SuperResolutionMode.quality):
      shaderFiles = isDesktop
          ? const ['FSRCNNX_x2_16-0-4-1.glsl', 'KrigBilateral.glsl']
          : const ['FSRCNNX_x2_8-0-4-1.glsl', 'KrigBilateral.glsl'];
      activeSummary = '影视·FSRCNNX';
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
        'deband-grain': '12',
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
        'deband-grain': '20',
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
