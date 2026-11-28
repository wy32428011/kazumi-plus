import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/pages/player/player_presentation_context.dart';
import 'package:kazumi/pages/player/player_super_resolution_sheet.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/television/tv_focus.dart';

/// 暗房放映厅调色板（严禁使用 BackdropFilter/ImageFilter.blur）。
class _DarkroomPalette {
  static const bg = Color(0xFF121316);
  static const surface = Color(0xFF191C22);
  static const surfaceElevated = Color(0xFF21252D);
  static const hairline = Color(0xFF2B303A);
  static const tungsten = Color(0xFFD8A85B);
  static const tungstenTint = Color(0x24D8A85B);
  static const textPrimary = Color(0xFFF3F4F6);
  static const textSecondary = Color(0xFFA1A7B3);
  static const textMuted = Color(0xFF6B7280);
  static const healthy = Color(0xFF4ADE80);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
}

/// 统一「片源与清晰度」暗房抽屉入口。
///
/// - 桌面 / 平板宽屏 / TV：右侧滑出暗房抽屉（380dp / TV 420dp，含独立 FocusScope）。
/// - 手机窄屏：底部抽屉（72% 屏高）。
/// - 当 [sourceFeatures] 为空时平滑退化为同流清晰度轨切换面板（向后兼容）。
Future<void> showPlayerQualitySheet(
  BuildContext context,
  PlaybackQualityController controller, {
  PlayerSourceSwitchingFeatures? sourceFeatures,
  PlayerControlsController? controlsController,
  Future<void> Function(SuperResolutionMode mode)? onSuperResolutionSelected,
}) {
  final size = MediaQuery.sizeOf(context);
  final isTv = PlatformEnvironmentService.isTelevision;
  final useSideDrawer = isTv || size.width >= 720;

  if (useSideDrawer) {
    final drawerWidth = isTv ? 420.0 : 380.0;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭片源与清晰度抽屉',
      barrierColor: Colors.black.withValues(alpha: 0.54),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final content = Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: drawerWidth,
            height: double.infinity,
            child: Material(
              color: _DarkroomPalette.bg,
              shape: const Border(
                left: BorderSide(color: _DarkroomPalette.hairline, width: 1),
              ),
              child: SafeArea(
                child: PlayerSourceQualityPanel(
                  controller: controller,
                  sourceFeatures: sourceFeatures,
                  controlsController: controlsController,
                  onSuperResolutionSelected: onSuperResolutionSelected,
                  onClose: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          ),
        );
        return isTv ? FocusScope(autofocus: true, child: content) : content;
      },
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        );
      },
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _DarkroomPalette.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      side: BorderSide(color: _DarkroomPalette.hairline, width: 1),
    ),
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.76,
      child: PlayerSourceQualityPanel(
        controller: controller,
        sourceFeatures: sourceFeatures,
        controlsController: controlsController,
        onSuperResolutionSelected: onSuperResolutionSelected,
        showDragHandle: true,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

/// 向后兼容别名（旧测试或外部调用可能直接构造 PlayerQualityDialog）。
class PlayerQualityDialog extends StatelessWidget {
  const PlayerQualityDialog({
    super.key,
    required this.controller,
    this.sourceFeatures,
    this.controlsController,
    this.onSuperResolutionSelected,
  });

  final PlaybackQualityController controller;
  final PlayerSourceSwitchingFeatures? sourceFeatures;
  final PlayerControlsController? controlsController;
  final Future<void> Function(SuperResolutionMode mode)?
      onSuperResolutionSelected;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: _DarkroomPalette.bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: _DarkroomPalette.hairline, width: 1),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 560),
        child: PlayerSourceQualityPanel(
          controller: controller,
          sourceFeatures: sourceFeatures,
          controlsController: controlsController,
          onSuperResolutionSelected: onSuperResolutionSelected,
          onClose: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
}

/// 一体化「片源与清晰度」暗房面板（亦可嵌入播放器侧边伴随区）。
class PlayerSourceQualityPanel extends StatelessWidget {
  const PlayerSourceQualityPanel({
    super.key,
    required this.controller,
    this.sourceFeatures,
    this.controlsController,
    this.onSuperResolutionSelected,
    this.showDragHandle = false,
    this.onClose,
    this.embedded = false,
  });

  final PlaybackQualityController controller;
  final PlayerSourceSwitchingFeatures? sourceFeatures;
  final PlayerControlsController? controlsController;
  final Future<void> Function(SuperResolutionMode mode)?
      onSuperResolutionSelected;
  final bool showDragHandle;
  final VoidCallback? onClose;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      controller,
      if (sourceFeatures != null) sourceFeatures!.sourceChanges,
    ];
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        final features = sourceFeatures;
        final options = features?.sourceOptions ?? const <PlayerSourceOption>[];
        final activeOptions = options
            .where((o) => o.isHealthyOrActive)
            .toList(growable: false);
        final unavailableOptions = options
            .where((o) => !o.isHealthyOrActive)
            .toList(growable: false);
        final isSwitching =
            controller.switching || (features?.isSwitchingSource ?? false);

        return DefaultTextStyle.merge(
          style: const TextStyle(color: _DarkroomPalette.textPrimary),
          child: Material(
            color: _DarkroomPalette.bg,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showDragHandle)
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 10, bottom: 4),
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _DarkroomPalette.hairline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                if (!embedded) _buildHeader(context, features),
                if (isSwitching || (features?.isDiscoveringSources ?? false))
                  const LinearProgressIndicator(
                    minHeight: 2,
                    color: _DarkroomPalette.tungsten,
                    backgroundColor: _DarkroomPalette.surface,
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _buildTelemetryCard(features),
                      if (controlsController != null) ...[
                        const SizedBox(height: 12),
                        _buildSuperResolutionCard(
                          context,
                          controlsController!,
                        ),
                      ],
                      if (features != null) ...[
                        const SizedBox(height: 12),
                        _buildStrategyBar(features),
                      ],
                      if (features != null &&
                          features.availableDubVariants.length > 1) ...[
                        const SizedBox(height: 12),
                        _buildDubVariantRow(features),
                      ],
                      if (controller.tracks.length > 1 || features == null) ...[
                        const SizedBox(height: 16),
                        _buildSameStreamTracksSection(context, features),
                      ],
                      if (features != null) ...[
                        const SizedBox(height: 16),
                        _buildSourceListSection(
                          context,
                          features,
                          activeOptions,
                        ),
                        if (unavailableOptions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _buildUnavailableSection(
                            context,
                            features,
                            unavailableOptions,
                          ),
                        ],
                      ],
                      if (controller.error case final String error) ...[
                        const SizedBox(height: 12),
                        Semantics(
                          liveRegion: true,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: _DarkroomPalette.danger.withValues(
                                alpha: 0.12,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _DarkroomPalette.danger.withValues(
                                  alpha: 0.4,
                                ),
                              ),
                            ),
                            child: Text(
                              error,
                              style: const TextStyle(
                                color: _DarkroomPalette.danger,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(
    BuildContext context,
    PlayerSourceSwitchingFeatures? features,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _DarkroomPalette.hairline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              features != null ? '片源与清晰度' : '清晰度',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _DarkroomPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (features != null)
            IconButton(
              tooltip: '重新检测可用片源',
              onPressed: features.isDiscoveringSources
                  ? null
                  : () => unawaited(features.refreshSources()),
              icon: const Icon(
                Icons.refresh_rounded,
                size: 20,
                color: _DarkroomPalette.textSecondary,
              ),
            ),
          if (onClose != null)
            IconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(
                Icons.close_rounded,
                size: 20,
                color: _DarkroomPalette.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTelemetryCard(PlayerSourceSwitchingFeatures? features) {
    final currentQuality = controller.currentLabel;
    final sourceLabel = features?.currentSourceLabel ?? '';
    final cdnGroup = features?.currentCdnGroup ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _DarkroomPalette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _DarkroomPalette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(
                Icons.monitor_heart_outlined,
                size: 16,
                color: _DarkroomPalette.tungsten,
              ),
              Text(
                sourceLabel.isNotEmpty
                    ? '当前片源：$sourceLabel'
                    : '当前画面：$currentQuality',
                style: const TextStyle(
                  color: _DarkroomPalette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (sourceLabel.isNotEmpty)
                _TagPill(
                  text: currentQuality,
                  foreground: _DarkroomPalette.tungsten,
                  background: _DarkroomPalette.tungstenTint,
                  borderColor: _DarkroomPalette.tungsten.withValues(
                    alpha: 0.45,
                  ),
                ),
            ],
          ),
          if (sourceLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '当前画面：$currentQuality',
              style: const TextStyle(
                color: _DarkroomPalette.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
          if (cdnGroup.isNotEmpty || controller.tracks.length > 1) ...[
            const SizedBox(height: 6),
            Text(
              [
                if (cdnGroup.isNotEmpty) '节点组 $cdnGroup',
                if (controller.tracks.length > 1)
                  '同流 ${controller.tracks.length} 档清晰度',
                '画质徽章仅采信播放器实测解码',
              ].join(' / '),
              style: const TextStyle(
                color: _DarkroomPalette.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuperResolutionCard(
    BuildContext context,
    PlayerControlsController controls,
  ) {
    final selectHandler =
        onSuperResolutionSelected ?? (mode) => controls.setShader(mode);
    return Observer(
      builder: (context) {
        final activeMode = controls.playback.superResolutionMode;
        final summary = controls.playback.activeEnhancementSummary;
        final outW = controls.debug.outputWidth;
        final outH = controls.debug.outputHeight;
        final isActive = activeMode != SuperResolutionMode.off;
        final statusText = !isActive
            ? '未开启'
            : (outW > 0 && outH > 0 ? '$summary · $outW×$outH' : summary);

        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _DarkroomPalette.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? _DarkroomPalette.tungsten.withValues(alpha: 0.5)
                  : _DarkroomPalette.hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.four_k_rounded,
                    size: 18,
                    color: _DarkroomPalette.tungsten,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '本地 4K 超分增强',
                      style: TextStyle(
                        color: _DarkroomPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      foregroundColor: _DarkroomPalette.tungsten,
                    ),
                    onPressed: () => unawaited(
                      showPlayerSuperResolutionSheet(
                        context,
                        playerController: controls,
                        onSelectMode: selectHandler,
                      ),
                    ),
                    child: const Text(
                      '详细设置',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                statusText,
                style: TextStyle(
                  color: isActive
                      ? _DarkroomPalette.tungsten
                      : _DarkroomPalette.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < SuperResolutionMode.values.length; i++)
                    ...[
                      if (i > 0) const SizedBox(width: 8),
                      Expanded(
                        child: _SuperResolutionSegmentButton(
                          label: SuperResolutionMode.values[i].label,
                          selected:
                              activeMode == SuperResolutionMode.values[i],
                          onTap: () => unawaited(
                            selectHandler(SuperResolutionMode.values[i]),
                          ),
                        ),
                      ),
                    ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStrategyBar(PlayerSourceSwitchingFeatures features) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _DarkroomPalette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _DarkroomPalette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '卡顿自动切换备用源',
                      style: TextStyle(
                        color: _DarkroomPalette.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '优先跨节点后台探活就绪后再无感接续进度',
                      style: TextStyle(
                        color: _DarkroomPalette.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: features.autoFailoverEnabled,
                activeThumbColor: _DarkroomPalette.tungsten,
                activeTrackColor: _DarkroomPalette.tungstenTint,
                onChanged: (value) =>
                    unawaited(features.setAutoFailoverEnabled(value)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final strategy in SourceRecommendationStrategy.values) ...[
                Expanded(
                  child: _StrategyChip(
                    label: strategy.label,
                    selected: features.recommendationStrategy == strategy,
                    onTap: () =>
                        unawaited(features.setRecommendationStrategy(strategy)),
                  ),
                ),
                if (strategy != SourceRecommendationStrategy.values.last)
                  const SizedBox(width: 6),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDubVariantRow(PlayerSourceSwitchingFeatures features) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '语言与配音版本',
          style: TextStyle(
            color: _DarkroomPalette.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final variant in features.availableDubVariants)
              ChoiceChip(
                label: Text(variant.label),
                selected: features.selectedDubVariant == variant,
                backgroundColor: _DarkroomPalette.surface,
                selectedColor: _DarkroomPalette.tungstenTint,
                side: BorderSide(
                  color: features.selectedDubVariant == variant
                      ? _DarkroomPalette.tungsten
                      : _DarkroomPalette.hairline,
                ),
                labelStyle: TextStyle(
                  color: features.selectedDubVariant == variant
                      ? _DarkroomPalette.tungsten
                      : _DarkroomPalette.textSecondary,
                  fontSize: 12,
                ),
                showCheckmark: false,
                onSelected: (_) => features.selectDubVariant(variant),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildSameStreamTracksSection(
    BuildContext context,
    PlayerSourceSwitchingFeatures? features,
  ) {
    final hintText = controller.tracks.length > 1
        ? '卡顿时可选较低分辨率或码率；更高清晰度需要更充足的带宽。'
        : controller.tracks.isEmpty
        ? '正在等待视频轨道信息。若无法识别，请尝试其他线路。'
        : features != null
        ? '当前线路仅提供一种画质。如需 4K 或 1080P，可直接切换下方其他片源。'
        : '当前线路仅提供一种画质。需要 4K 或 1080P 时，请更换提供对应画质的片源或线路。';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '当前流视频轨道',
          style: TextStyle(
            color: _DarkroomPalette.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          hintText,
          style: const TextStyle(
            color: _DarkroomPalette.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        for (final track in controller.tracks)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            minVerticalPadding: 10,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: controller.selectedId == track.id
                    ? _DarkroomPalette.tungsten
                    : _DarkroomPalette.hairline,
              ),
            ),
            tileColor: controller.selectedId == track.id
                ? _DarkroomPalette.tungstenTint
                : _DarkroomPalette.surface,
            selected: controller.selectedId == track.id,
            enabled:
                !controller.switching &&
                controller.canInteract() &&
                controller.tracks.length > 1,
            title: Text(
              videoTrackLabel(track),
              style: const TextStyle(
                color: _DarkroomPalette.textPrimary,
                fontSize: 13,
              ),
            ),
            subtitle: Text(
              '视频轨道 ${track.id}${track.codec == null ? '' : ' / ${track.codec}'}',
              style: const TextStyle(
                color: _DarkroomPalette.textSecondary,
                fontSize: 11,
              ),
            ),
            trailing: controller.selectedId == track.id
                ? const Icon(
                    Icons.check_rounded,
                    color: _DarkroomPalette.tungsten,
                    semanticLabel: '已选择',
                  )
                : null,
            onTap: () => controller.select(track),
          ),
      ],
    );
  }

  Widget _buildSourceListSection(
    BuildContext context,
    PlayerSourceSwitchingFeatures features,
    List<PlayerSourceOption> options,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '可用片源（${options.length}）',
              style: const TextStyle(
                color: _DarkroomPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (features.isDiscoveringSources)
              const Text(
                '后台发现更多片源…',
                style: TextStyle(
                  color: _DarkroomPalette.tungsten,
                  fontSize: 11,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (options.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _DarkroomPalette.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _DarkroomPalette.hairline),
            ),
            child: const Text(
              '暂无其他可用片源，可点击右上角刷新重新检索。',
              style: TextStyle(
                color: _DarkroomPalette.textSecondary,
                fontSize: 12,
              ),
            ),
          )
        else
          for (final option in options) ...[
            _SourceOptionTile(
              option: option,
              disabled: features.isSwitchingSource,
              onSelect: () => unawaited(features.switchToSource(option.id)),
              onTogglePin: () =>
                  unawaited(features.togglePinSource(option.id)),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _buildUnavailableSection(
    BuildContext context,
    PlayerSourceSwitchingFeatures features,
    List<PlayerSourceOption> options,
  ) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        color: _DarkroomPalette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: _DarkroomPalette.hairline),
        ),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          iconColor: _DarkroomPalette.textSecondary,
          collapsedIconColor: _DarkroomPalette.textSecondary,
          title: Text(
            '暂不可用或需验证（${options.length}）',
            style: const TextStyle(
              color: _DarkroomPalette.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          children: [
            for (final option in options)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            option.sourceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _DarkroomPalette.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            option.errorReason.isNotEmpty
                                ? option.errorReason
                                : _probeStatusLabel(option.probeStatus),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _DarkroomPalette.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (option.canOpenManualCaptcha)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _DarkroomPalette.tungsten,
                          side: const BorderSide(
                            color: _DarkroomPalette.tungsten,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 32),
                        ),
                        onPressed: () => unawaited(
                          features.openCaptchaVerification(context, option.id),
                        ),
                        child: const Text(
                          '人工验证',
                          style: TextStyle(fontSize: 12),
                        ),
                      )
                    else
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: _DarkroomPalette.textSecondary,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          minimumSize: const Size(0, 32),
                        ),
                        onPressed: features.isSwitchingSource
                            ? null
                            : () =>
                                  unawaited(features.switchToSource(option.id)),
                        child: const Text(
                          '仍要尝试',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _probeStatusLabel(CandidateProbeStatus status) {
    return switch (status) {
      CandidateProbeStatus.idle => '待检测',
      CandidateProbeStatus.probing => '探活中',
      CandidateProbeStatus.ready => '已就绪',
      CandidateProbeStatus.degraded => '较慢',
      CandidateProbeStatus.failed => '本次不可达',
      CandidateProbeStatus.captchaRequired => '需人工验证（冷却中）',
      CandidateProbeStatus.circuitOpen => '连续故障冷却中',
      CandidateProbeStatus.disabled => '规则已禁用',
    };
  }
}

class _StrategyChip extends StatelessWidget {
  const _StrategyChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TvFocusFrame(
      radius: 8,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? _DarkroomPalette.tungstenTint
                : _DarkroomPalette.surfaceElevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? _DarkroomPalette.tungsten
                  : _DarkroomPalette.hairline,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected
                  ? _DarkroomPalette.tungsten
                  : _DarkroomPalette.textSecondary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _SourceOptionTile extends StatelessWidget {
  const _SourceOptionTile({
    required this.option,
    required this.disabled,
    required this.onSelect,
    required this.onTogglePin,
  });

  final PlayerSourceOption option;
  final bool disabled;
  final VoidCallback onSelect;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final verifiedBadge = option.verifiedProfile?.uiBadgeText ?? '';

    return TvFocusFrame(
      radius: 10,
      child: Material(
        color: option.isCurrent
            ? _DarkroomPalette.tungstenTint
            : _DarkroomPalette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: option.isCurrent
                ? _DarkroomPalette.tungsten
                : _DarkroomPalette.hairline,
            width: option.isCurrent ? 1.2 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: disabled || option.isCurrent ? null : onSelect,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              option.sourceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _DarkroomPalette.textPrimary,
                                fontSize: 14,
                                fontWeight: option.isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (option.isCurrent) ...[
                            const SizedBox(width: 6),
                            const _TagPill(
                              text: '当前',
                              foreground: _DarkroomPalette.bg,
                              background: _DarkroomPalette.tungsten,
                            ),
                          ],
                          if (verifiedBadge.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _TagPill(
                              text: '实测 $verifiedBadge',
                              foreground: _DarkroomPalette.healthy,
                              background: _DarkroomPalette.healthy.withValues(
                                alpha: 0.14,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (option.ttfbMs != null && option.ttfbMs! > 0)
                            Text(
                              '${option.ttfbMs}ms',
                              style: const TextStyle(
                                color: _DarkroomPalette.textSecondary,
                                fontSize: 11,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          if (option.isSameCdnAsCurrent && !option.isCurrent)
                            const _TagPill(
                              text: '同源镜像',
                              foreground: _DarkroomPalette.warning,
                              background: Color(0x22F59E0B),
                            )
                          else if (option.cdnGroup.isNotEmpty &&
                              !option.isCurrent)
                            const _TagPill(
                              text: '独立节点',
                              foreground: _DarkroomPalette.textSecondary,
                              background: _DarkroomPalette.surfaceElevated,
                            ),
                          if (option.isLazyWebview)
                            const _TagPill(
                              text: '网页嗅探',
                              foreground: _DarkroomPalette.textSecondary,
                              background: _DarkroomPalette.surfaceElevated,
                            ),
                          if (option.episodeSummary.isNotEmpty)
                            Text(
                              option.episodeSummary,
                              style: const TextStyle(
                                color: _DarkroomPalette.textMuted,
                                fontSize: 11,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: option.isPinned ? '取消优先固定此源' : '为此作品固定优先源',
                  onPressed: onTogglePin,
                  icon: Icon(
                    option.isPinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    size: 18,
                    color: option.isPinned
                        ? _DarkroomPalette.tungsten
                        : _DarkroomPalette.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TagPill extends StatelessWidget {
  const _TagPill({
    required this.text,
    required this.foreground,
    required this.background,
    this.borderColor,
  });

  final String text;
  final Color foreground;
  final Color background;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(5),
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _SuperResolutionSegmentButton extends StatelessWidget {
  const _SuperResolutionSegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? _DarkroomPalette.tungstenTint
          : _DarkroomPalette.surfaceElevated,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? _DarkroomPalette.tungsten
                  : _DarkroomPalette.hairline,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected
                  ? _DarkroomPalette.tungsten
                  : _DarkroomPalette.textPrimary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
