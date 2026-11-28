import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';

void main() {
  group('resolveEnhancementContent', () {
    test('auto profile maps anime to anime and tv/movie to liveAction', () {
      expect(
        resolveEnhancementContent(
          SuperResolutionContentProfile.auto,
          MediaKind.anime,
        ),
        ResolvedEnhancementContent.anime,
      );
      expect(
        resolveEnhancementContent(
          SuperResolutionContentProfile.auto,
          MediaKind.tv,
        ),
        ResolvedEnhancementContent.liveAction,
      );
      expect(
        resolveEnhancementContent(
          SuperResolutionContentProfile.auto,
          MediaKind.movie,
        ),
        ResolvedEnhancementContent.liveAction,
      );
    });

    test('explicit profile overrides mediaKind', () {
      for (final kind in MediaKind.values) {
        expect(
          resolveEnhancementContent(SuperResolutionContentProfile.anime, kind),
          ResolvedEnhancementContent.anime,
        );
        expect(
          resolveEnhancementContent(
            SuperResolutionContentProfile.liveAction,
            kind,
          ),
          ResolvedEnhancementContent.liveAction,
        );
      }
    });
  });

  group('computeTargetOutputSize', () {
    test('upscales 1080p to 4K on 4K viewport', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.efficiency,
        upscaleOutputEnabled: true,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(size, (width: 3840, height: 2160));
    });

    test('preserves 2.39:1 cinema aspect ratio when upscaling to 4K width', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.quality,
        upscaleOutputEnabled: true,
        sourceWidth: 1920,
        sourceHeight: 804,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(size, (width: 3840, height: 1608));
    });

    test('caps target size at viewport resolution (1440p)', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.quality,
        upscaleOutputEnabled: true,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 2560,
        viewportPhysicalHeight: 1440,
      );
      expect(size, (width: 2560, height: 1440));
    });

    test('returns null on 1080p viewport because scale <= 1.05', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.quality,
        upscaleOutputEnabled: true,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 1920,
        viewportPhysicalHeight: 1080,
      );
      expect(size, isNull);
    });

    test('caps 720p upscale at 2x even on 4K viewport', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.efficiency,
        upscaleOutputEnabled: true,
        sourceWidth: 1280,
        sourceHeight: 720,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(size, (width: 2560, height: 1440));
    });

    test('skips native 4K or high-res sources (>= 3200 long edge)', () {
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.quality,
          upscaleOutputEnabled: true,
          sourceWidth: 3840,
          sourceHeight: 2160,
          viewportPhysicalWidth: 3840,
          viewportPhysicalHeight: 2160,
        ),
        isNull,
      );
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.quality,
          upscaleOutputEnabled: true,
          sourceWidth: 3840,
          sourceHeight: 1600,
          viewportPhysicalWidth: 3840,
          viewportPhysicalHeight: 2160,
        ),
        isNull,
      );
    });

    test('returns null when disabled, off, or mediacodec_embed', () {
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.off,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 3840,
          viewportPhysicalHeight: 2160,
        ),
        isNull,
      );
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.quality,
          upscaleOutputEnabled: false,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 3840,
          viewportPhysicalHeight: 2160,
        ),
        isNull,
      );
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.quality,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 3840,
          viewportPhysicalHeight: 2160,
          videoRenderer: 'mediacodec_embed',
        ),
        isNull,
      );
    });

    test('rounds output dimensions to even numbers', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.quality,
        upscaleOutputEnabled: true,
        sourceWidth: 1281,
        sourceHeight: 721,
        viewportPhysicalWidth: 3001,
        viewportPhysicalHeight: 1689,
      );
      expect(size, isNotNull);
      expect(size!.width.isEven, isTrue);
      expect(size.height.isEven, isTrue);
    });
  });

  group('buildVideoEnhancementPlan', () {
    test('selects Anime4K lightweight chain for anime efficiency', () {
      final plan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.efficiency,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.anime,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 2560,
        viewportPhysicalHeight: 1440,
      );
      expect(plan.resolvedContent, ResolvedEnhancementContent.anime);
      expect(plan.shaderFiles, [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_S.glsl',
        'Anime4K_Upscale_CNN_x2_S.glsl',
      ]);
      expect(plan.activeSummary, '动漫·Anime4K');
      expect(plan.mpvProperties['deband'], 'yes');
      expect(plan.mpvProperties['scale'], 'spline36');
      expect(plan.targetOutputSize, (width: 2560, height: 1440));
    });

    test('selects ArtCNN_C4F32 on desktop and C4F16 on mobile for anime quality', () {
      final desktopPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.anime,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(desktopPlan.shaderFiles, ['ArtCNN_C4F32.glsl', 'KrigBilateral.glsl']);
      expect(desktopPlan.mpvProperties['scale'], 'ewa_lanczos');
      expect(desktopPlan.mpvProperties['sigmoid-upscaling'], 'yes');
      expect(desktopPlan.activeSummary, '动漫·ArtCNN');

      final mobilePlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.anime,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(mobilePlan.shaderFiles, ['ArtCNN_C4F16.glsl', 'KrigBilateral.glsl']);
      expect(mobilePlan.mpvProperties['scale'], 'spline36');
      expect(mobilePlan.mpvProperties['sigmoid-upscaling'], 'no');
    });

    test('selects FSR on TV/mobile efficiency and FSRCNNX on quality for tv/movie', () {
      final tvPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.efficiency,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: false,
        isTelevision: true,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(tvPlan.resolvedContent, ResolvedEnhancementContent.liveAction);
      expect(tvPlan.shaderFiles, ['FSR.glsl']);
      expect(tvPlan.activeSummary, '影视·FSR');
      expect(tvPlan.mpvProperties['scale'], 'bilinear');
      expect(tvPlan.targetOutputSize, (width: 3840, height: 2160));

      final desktopQualityPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.tv,
        debandEnabled: false,
        upscaleOutputEnabled: true,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(desktopQualityPlan.shaderFiles, [
        'FSRCNNX_x2_16-0-4-1.glsl',
        'KrigBilateral.glsl',
      ]);
      expect(desktopQualityPlan.activeSummary, '影视·FSRCNNX');
      expect(desktopQualityPlan.mpvProperties['deband'], 'no');
      expect(desktopQualityPlan.mpvProperties.containsKey('deband-grain'), isFalse);

      final mobileQualityPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(mobileQualityPlan.shaderFiles, [
        'FSRCNNX_x2_8-0-4-1.glsl',
        'KrigBilateral.glsl',
      ]);
    });

    test('skips shaders and resizing for 4K source', () {
      final plan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 3840,
        sourceHeight: 2160,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(plan.skippedForHighResSource, isTrue);
      expect(plan.shaderFiles, isEmpty);
      expect(plan.targetOutputSize, isNull);
      expect(plan.activeSummary, '已为4K片源（免超分）');
    });

    test('handles off mode and mediacodec_embed safely', () {
      final offPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.off,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(offPlan.shaderFiles, isEmpty);
      expect(offPlan.targetOutputSize, isNull);
      expect(offPlan.mpvProperties['deband'], 'no');
      expect(offPlan.activeSummary, '关闭');

      final embedPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
        videoRenderer: 'mediacodec_embed',
      );
      expect(embedPlan.shaderFiles, isEmpty);
      expect(embedPlan.mpvProperties, isEmpty);
      expect(embedPlan.targetOutputSize, isNull);
      expect(embedPlan.activeSummary, '关闭');
    });
  });

  group('evaluateAutoDowngradeMode', () {
    test('downgrades quality -> efficiency -> off after consecutive high drops', () {
      expect(
        evaluateAutoDowngradeMode(
          currentMode: SuperResolutionMode.quality,
          droppedDeltaInWindow: 20,
          consecutiveHighDropWindows: 1,
          autoDowngradeEnabled: true,
        ),
        isNull,
      );
      expect(
        evaluateAutoDowngradeMode(
          currentMode: SuperResolutionMode.quality,
          droppedDeltaInWindow: 20,
          consecutiveHighDropWindows: 2,
          autoDowngradeEnabled: true,
        ),
        SuperResolutionMode.efficiency,
      );
      expect(
        evaluateAutoDowngradeMode(
          currentMode: SuperResolutionMode.efficiency,
          droppedDeltaInWindow: 18,
          consecutiveHighDropWindows: 2,
          autoDowngradeEnabled: true,
        ),
        SuperResolutionMode.off,
      );
      expect(
        evaluateAutoDowngradeMode(
          currentMode: SuperResolutionMode.off,
          droppedDeltaInWindow: 50,
          consecutiveHighDropWindows: 5,
          autoDowngradeEnabled: true,
        ),
        isNull,
      );
      expect(
        evaluateAutoDowngradeMode(
          currentMode: SuperResolutionMode.quality,
          droppedDeltaInWindow: 50,
          consecutiveHighDropWindows: 5,
          autoDowngradeEnabled: false,
        ),
        isNull,
      );
    });
  });
}
