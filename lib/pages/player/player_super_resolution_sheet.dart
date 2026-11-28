import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/pages/player/player_controls_controller.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class _SrPalette {
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
}

/// 打开「本地 4K 超分增强」暗房抽屉 / 底部面板。
Future<void> showPlayerSuperResolutionSheet(
  BuildContext context, {
  required PlayerControlsController playerController,
  required Future<void> Function(SuperResolutionMode mode) onSelectMode,
}) {
  final size = MediaQuery.sizeOf(context);
  final isTv = PlatformEnvironmentService.isTelevision;
  final useSideDrawer = isTv || size.width >= 720;

  if (useSideDrawer) {
    final drawerWidth = isTv ? 420.0 : 380.0;
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭 4K 超分增强面板',
      barrierColor: Colors.black.withValues(alpha: 0.54),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final content = Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: drawerWidth,
            height: double.infinity,
            child: Material(
              color: _SrPalette.bg,
              shape: const Border(
                left: BorderSide(color: _SrPalette.hairline, width: 1),
              ),
              child: SafeArea(
                child: PlayerSuperResolutionPanel(
                  playerController: playerController,
                  onSelectMode: onSelectMode,
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
    backgroundColor: _SrPalette.bg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      side: BorderSide(color: _SrPalette.hairline, width: 1),
    ),
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.78,
      child: PlayerSuperResolutionPanel(
        playerController: playerController,
        onSelectMode: onSelectMode,
        showDragHandle: true,
        onClose: () => Navigator.of(sheetContext).pop(),
      ),
    ),
  );
}

class PlayerSuperResolutionPanel extends StatefulWidget {
  const PlayerSuperResolutionPanel({
    super.key,
    required this.playerController,
    required this.onSelectMode,
    this.showDragHandle = false,
    this.onClose,
  });

  final PlayerControlsController playerController;
  final Future<void> Function(SuperResolutionMode mode) onSelectMode;
  final bool showDragHandle;
  final VoidCallback? onClose;

  @override
  State<PlayerSuperResolutionPanel> createState() =>
      _PlayerSuperResolutionPanelState();
}

class _PlayerSuperResolutionPanelState
    extends State<PlayerSuperResolutionPanel> {
  late SuperResolutionContentProfile _profile;
  late bool _sharpenEnabled;
  late bool _debandEnabled;
  late bool _upscaleOutputEnabled;

  @override
  void initState() {
    super.initState();
    _profile = SuperResolutionContentProfile.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.superResolutionContentProfile),
    );
    _sharpenEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionSharpenEnabled,
    );
    _debandEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionDebandEnabled,
    );
    _upscaleOutputEnabled = GStorage.getSetting<bool>(
      SettingsKeys.superResolutionUpscaleOutput,
    );
  }

  Future<void> _updateProfile(SuperResolutionContentProfile profile) async {
    await GStorage.putSetting<int>(
      SettingsKeys.superResolutionContentProfile,
      profile.storageValue,
    );
    if (!mounted) return;
    setState(() => _profile = profile);
    await widget.playerController.refreshSuperResolution();
  }

  Future<void> _toggleSetting(
    SettingKey<bool> key,
    bool value,
    void Function(bool) assign,
  ) async {
    await GStorage.putSetting<bool>(key, value);
    if (!mounted) return;
    setState(() => assign(value));
    await widget.playerController.refreshSuperResolution();
  }

  @override
  Widget build(BuildContext context) {
    final playback = widget.playerController.playback;
    final debug = widget.playerController.debug;

    return DefaultTextStyle.merge(
      style: const TextStyle(color: _SrPalette.textPrimary),
      child: Material(
        color: _SrPalette.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showDragHandle)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _SrPalette.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            _buildHeader(),
            Expanded(
              child: Observer(
                builder: (context) {
                  final mode = playback.superResolutionMode;
                  final summary = playback.activeEnhancementSummary;
                  final srcW = debug.playerWidth;
                  final srcH = debug.playerHeight;
                  final outW = debug.outputWidth;
                  final outH = debug.outputHeight;
                  final isActive = mode != SuperResolutionMode.off;

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _buildStatusCard(
                        isActive: isActive,
                        summary: summary,
                        srcW: srcW,
                        srcH: srcH,
                        outW: outW,
                        outH: outH,
                        droppedFrames: debug.droppedFrames,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '超分档位（即点即生效）',
                        style: TextStyle(
                          color: _SrPalette.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final option in SuperResolutionMode.values) ...[
                        _buildModeCard(
                          option: option,
                          selected: option == mode,
                          onTap: () => unawaited(widget.onSelectMode(option)),
                        ),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 10),
                      const Text(
                        '内容模型与实时微调',
                        style: TextStyle(
                          color: _SrPalette.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildProfileSelector(playback.currentMediaKind.label),
                      const SizedBox(height: 10),
                      _buildSwitchTile(
                        title: '细节锐化增强（Adaptive Sharpen）',
                        subtitle: '在超分放大后强化边缘与纹理清晰度（影视实时感最明显）',
                        value: _sharpenEnabled,
                        onChanged: (v) => unawaited(
                          _toggleSetting(
                            SettingsKeys.superResolutionSharpenEnabled,
                            v,
                            (val) => _sharpenEnabled = val,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildSwitchTile(
                        title: '低码率去色带（Deband）',
                        subtitle: '减轻暗场色块与压缩断层，不损失轮廓锐度',
                        value: _debandEnabled,
                        onChanged: (v) => unawaited(
                          _toggleSetting(
                            SettingsKeys.superResolutionDebandEnabled,
                            v,
                            (val) => _debandEnabled = val,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildSwitchTile(
                        title: '强制 4K 渲染输出（最高 3840×2160）',
                        subtitle: '窗口/1080P屏也以 4K 超采样渲染；片源本身为 4K 时自动跳过',
                        value: _upscaleOutputEnabled,
                        onChanged: (v) => unawaited(
                          _toggleSetting(
                            SettingsKeys.superResolutionUpscaleOutput,
                            v,
                            (val) => _upscaleOutputEnabled = val,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        debug.activeShaders.isEmpty
                            ? '当前未挂载超分着色器'
                            : '当前着色器链：${debug.activeShaders}',
                        style: const TextStyle(
                          color: _SrPalette.textMuted,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _SrPalette.hairline, width: 1),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _SrPalette.tungstenTint,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: _SrPalette.tungsten.withValues(alpha: 0.5),
              ),
            ),
            child: const Text(
              '4K',
              style: TextStyle(
                color: _SrPalette.tungsten,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '本地 4K 超分增强',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _SrPalette.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (widget.onClose != null)
            IconButton(
              tooltip: '关闭',
              onPressed: widget.onClose,
              icon: const Icon(
                Icons.close_rounded,
                size: 20,
                color: _SrPalette.textSecondary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    required bool isActive,
    required String summary,
    required int srcW,
    required int srcH,
    required int outW,
    required int outH,
    required int droppedFrames,
  }) {
    final String resolutionText;
    if (srcW <= 0 || srcH <= 0) {
      resolutionText = '等待视频流分辨率…';
    } else if (outW > 0 && outH > 0) {
      resolutionText = '源片 $srcW×$srcH  →  渲染 $outW×$outH';
    } else {
      resolutionText = '源片 $srcW×$srcH（原生输出）';
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _SrPalette.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isActive
              ? _SrPalette.tungsten.withValues(alpha: 0.45)
              : _SrPalette.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isActive
                      ? _SrPalette.tungsten
                      : _SrPalette.surfaceElevated,
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  isActive ? summary : '未开启',
                  style: TextStyle(
                    color: isActive ? Colors.black : _SrPalette.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '丢帧 $droppedFrames',
                style: TextStyle(
                  color: droppedFrames > 0
                      ? _SrPalette.tungsten
                      : _SrPalette.healthy,
                  fontSize: 12,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            resolutionText,
            style: const TextStyle(
              color: _SrPalette.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeCard({
    required SuperResolutionMode option,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? _SrPalette.tungstenTint : _SrPalette.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? _SrPalette.tungsten : _SrPalette.hairline,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                size: 20,
                color: selected
                    ? _SrPalette.tungsten
                    : _SrPalette.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      option.label,
                      style: TextStyle(
                        color: selected
                            ? _SrPalette.tungsten
                            : _SrPalette.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      option.description,
                      style: const TextStyle(
                        color: _SrPalette.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileSelector(String mediaKindLabel) {
    final items = <(SuperResolutionContentProfile, String)>[
      (SuperResolutionContentProfile.auto, '自动（$mediaKindLabel）'),
      (SuperResolutionContentProfile.liveAction, '影视真人'),
      (SuperResolutionContentProfile.anime, '动漫'),
    ];
    return Row(
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _ProfileChip(
              label: items[i].$2,
              selected: _profile == items[i].$1,
              onTap: () => unawaited(_updateProfile(items[i].$1)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Material(
      color: _SrPalette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: _SrPalette.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile.adaptive(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        activeThumbColor: _SrPalette.tungsten,
        activeTrackColor: _SrPalette.tungstenTint,
        title: Text(
          title,
          style: const TextStyle(
            color: _SrPalette.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            color: _SrPalette.textSecondary,
            fontSize: 11,
          ),
        ),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
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
      color: selected ? _SrPalette.tungstenTint : _SrPalette.surface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? _SrPalette.tungsten : _SrPalette.hairline,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? _SrPalette.tungsten : _SrPalette.textSecondary,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
