import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_quality_sheet.dart';
import 'package:kazumi/pages/player/player_super_resolution_sheet.dart';
import 'package:kazumi/services/player/audio_controller.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

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
    test('upscales 1080p to 4K on desktop even in windowed or 1080p display', () {
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.efficiency,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 1280,
          viewportPhysicalHeight: 720,
          isDesktop: true,
          isTelevision: false,
        ),
        (width: 3840, height: 2160),
      );
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.efficiency,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 0,
          viewportPhysicalHeight: 0,
          isDesktop: true,
          isTelevision: false,
        ),
        (width: 3840, height: 2160),
      );
    });

    test('preserves 2.39:1 cinema aspect ratio when upscaling to 4K width', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.quality,
        upscaleOutputEnabled: true,
        sourceWidth: 1920,
        sourceHeight: 804,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
        isDesktop: true,
        isTelevision: false,
      );
      expect(size, (width: 3840, height: 1608));
    });

    test('mobile handheld efficiency upscales at least to 1440p and quality to 4K', () {
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.efficiency,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 1920,
          viewportPhysicalHeight: 1080,
          isDesktop: false,
          isTelevision: false,
        ),
        (width: 2560, height: 1440),
      );
      expect(
        computeTargetOutputSize(
          mode: SuperResolutionMode.quality,
          upscaleOutputEnabled: true,
          sourceWidth: 1920,
          sourceHeight: 1080,
          viewportPhysicalWidth: 1920,
          viewportPhysicalHeight: 1080,
          isDesktop: false,
          isTelevision: false,
        ),
        (width: 3840, height: 2160),
      );
    });

    test('caps 720p upscale at 2x even on 4K viewport', () {
      final size = computeTargetOutputSize(
        mode: SuperResolutionMode.efficiency,
        upscaleOutputEnabled: true,
        sourceWidth: 1280,
        sourceHeight: 720,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
        isDesktop: true,
        isTelevision: false,
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
          isDesktop: true,
          isTelevision: false,
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
          isDesktop: true,
          isTelevision: false,
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
    test('selects pure fragment Anime4K chains for anime efficiency and quality', () {
      final efficiencyPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.efficiency,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.anime,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        sharpenEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 2560,
        viewportPhysicalHeight: 1440,
      );
      expect(efficiencyPlan.resolvedContent, ResolvedEnhancementContent.anime);
      expect(efficiencyPlan.shaderFiles, [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_M.glsl',
        'Anime4K_Upscale_CNN_x2_M.glsl',
      ]);
      expect(efficiencyPlan.activeSummary, '4K 动漫·效率');
      expect(efficiencyPlan.mpvProperties['deband'], 'yes');
      expect(efficiencyPlan.mpvProperties['deband-grain'], '6');
      expect(efficiencyPlan.mpvProperties['scale'], 'spline36');
      expect(efficiencyPlan.targetOutputSize, (width: 2560, height: 1440));

      final desktopQualityPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.anime,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        sharpenEnabled: true,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 1920,
        viewportPhysicalHeight: 1080,
      );
      expect(desktopQualityPlan.shaderFiles, [
        'Anime4K_Clamp_Highlights.glsl',
        'Anime4K_Restore_CNN_VL.glsl',
        'Anime4K_Upscale_CNN_x2_VL.glsl',
        'KrigBilateral.glsl',
      ]);
      expect(desktopQualityPlan.mpvProperties['scale'], 'ewa_lanczos');
      expect(desktopQualityPlan.mpvProperties['sigmoid-upscaling'], 'yes');
      expect(desktopQualityPlan.mpvProperties['deband-grain'], '8');
      expect(desktopQualityPlan.activeSummary, '4K 动漫·质量');
      expect(desktopQualityPlan.targetOutputSize, (width: 3840, height: 2160));
    });

    test('selects FSR/FSRCNNX with optional adaptive-sharpen for tv/movie', () {
      final tvPlan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.efficiency,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        sharpenEnabled: true,
        isDesktop: false,
        isTelevision: true,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 3840,
        viewportPhysicalHeight: 2160,
      );
      expect(tvPlan.resolvedContent, ResolvedEnhancementContent.liveAction);
      expect(tvPlan.shaderFiles, ['FSR.glsl', 'adaptive-sharpen.glsl']);
      expect(tvPlan.activeSummary, '4K 影视·效率');
      expect(tvPlan.mpvProperties['scale'], 'bilinear');
      expect(tvPlan.targetOutputSize, (width: 3840, height: 2160));

      final desktopQualityNoSharpen = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.tv,
        debandEnabled: false,
        upscaleOutputEnabled: true,
        sharpenEnabled: false,
        isDesktop: true,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 1280,
        viewportPhysicalHeight: 720,
      );
      expect(desktopQualityNoSharpen.shaderFiles, [
        'FSRCNNX_x2_16-0-4-1.glsl',
        'KrigBilateral.glsl',
      ]);
      expect(desktopQualityNoSharpen.activeSummary, '4K 影视·质量');
      expect(desktopQualityNoSharpen.mpvProperties['deband'], 'no');
      expect(
        desktopQualityNoSharpen.mpvProperties.containsKey('deband-grain'),
        isFalse,
      );
      expect(
        desktopQualityNoSharpen.targetOutputSize,
        (width: 3840, height: 2160),
      );

      final mobileQuality = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        sharpenEnabled: true,
        isDesktop: false,
        isTelevision: false,
        sourceWidth: 1920,
        sourceHeight: 1080,
        viewportPhysicalWidth: 2400,
        viewportPhysicalHeight: 1080,
      );
      expect(mobileQuality.shaderFiles, [
        'FSRCNNX_x2_8-0-4-1.glsl',
        'KrigBilateral.glsl',
        'adaptive-sharpen.glsl',
      ]);
      expect(mobileQuality.targetOutputSize, (width: 3840, height: 2160));
    });

    test('skips shaders and resizing for 4K source', () {
      final plan = buildVideoEnhancementPlan(
        mode: SuperResolutionMode.quality,
        profile: SuperResolutionContentProfile.auto,
        mediaKind: MediaKind.movie,
        debandEnabled: true,
        upscaleOutputEnabled: true,
        sharpenEnabled: true,
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
        sharpenEnabled: true,
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
        sharpenEnabled: true,
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

  group('4K UI panels', () {
    late Directory tempDir;
    late PathProviderPlatform originalPaths;

    setUpAll(() async {
      tempDir = await Directory.systemTemp.createTemp('kazumi_sr_ui_test_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
      Hive.init(tempDir.path);
      await GStorage.init();
    });

    tearDownAll(() async {
      await Hive.close();
      PathProviderPlatform.instance = originalPaths;
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets(
      'PlayerSourceQualityPanel and PlayerSuperResolutionPanel render 4K controls with zero BackdropFilter',
      (tester) async {
        final controls = PlayerControlsController(
          shaderAssetService: ShaderAssetService(),
          audioController: AudioController(),
        );
        final quality = PlaybackQualityController(canInteract: () => true);
        addTearDown(() {
          quality.dispose();
          controls.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerSourceQualityPanel(
                controller: quality,
                controlsController: controls,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.text('本地 4K 超分增强'), findsOneWidget);
        expect(find.text('4K 效率档'), findsOneWidget);
        expect(find.text('4K 质量档'), findsOneWidget);

        SuperResolutionMode? selectedMode;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlayerSuperResolutionPanel(
                playerController: controls,
                onSelectMode: (mode) async {
                  selectedMode = mode;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.text('本地 4K 超分增强'), findsOneWidget);

        await tester.tap(find.text('4K 质量档'));
        await tester.pump();
        expect(selectedMode, SuperResolutionMode.quality);

        final sharpenFinder = find.text('细节锐化增强（Adaptive Sharpen）');
        await tester.scrollUntilVisible(sharpenFinder, 200);
        expect(sharpenFinder, findsOneWidget);

        final upscaleFinder = find.text('强制 4K 渲染输出（最高 3840×2160）');
        await tester.scrollUntilVisible(upscaleFinder, 200);
        expect(upscaleFinder, findsOneWidget);
      },
    );
  });
}
