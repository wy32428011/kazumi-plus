import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

/// 频道筛选在片单和历史中共用，空值表示全部内容。
class MediaKindFilter extends StatelessWidget {
  const MediaKindFilter({
    super.key,
    required this.selected,
    required this.onChanged,
  });
  final MediaKind? selected;
  final ValueChanged<MediaKind?> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          for (final kind in <MediaKind?>[null, ...MediaKind.values])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TvFocusFrame(
                radius: 8,
                child: ChoiceChip(
                  label: Text(kind?.label ?? '全部'),
                  selected: selected == kind,
                  showCheckmark: false,
                  backgroundColor: tokens.surface1,
                  selectedColor: tokens.accentSoft,
                  side: BorderSide(
                    color: selected == kind
                        ? tokens.accent.withValues(alpha: 0.65)
                        : tokens.hairline,
                  ),
                  labelStyle: TextStyle(
                    fontSize: 13,
                    fontWeight:
                        selected == kind ? FontWeight.w600 : FontWeight.w400,
                    color: selected == kind
                        ? tokens.accent
                        : tokens.textSecondary,
                  ),
                  onSelected: (_) => onChanged(kind),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 银盐放映室 2:3 电影海报卡片（支持聚簇作品 [WorkCluster]）。
///
/// 视觉守卫：
/// - 1dp 暗房细边 + 10dp 圆角，无 M3 Card 套娃；
/// - 评分仅展示真实来源评分（非伪造），画质徽章仅消费 `mpv` 实播解码结果；
/// - 元数据精简至 1 行，拒绝中点噪音堆叠。
class WorkClusterCard extends StatelessWidget {
  const WorkClusterCard({
    super.key,
    required this.cluster,
    this.onTap,
    this.compact = false,
  });

  final WorkCluster cluster;
  final VoidCallback? onTap;
  final bool compact;

  void _open(BuildContext context) {
    if (onTap != null) {
      onTap!();
      return;
    }
    context.pushNamed('/media/detail', arguments: cluster);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final recommended = cluster.candidates.isNotEmpty
        ? cluster.recommendedCandidate
        : null;
    final verifiedBadge = recommended?.streamProfile?.uiBadgeText ?? '';
    final rating = cluster.ratingText.trim();
    final metaParts = <String>[
      if (cluster.year.isNotEmpty) cluster.year,
      if (cluster.statusText.isNotEmpty) cluster.statusText,
      if (cluster.statusText.isEmpty && cluster.region.isNotEmpty)
        cluster.region,
    ];

    return TvAction(
      key: ValueKey('cluster-${cluster.clusterKey}'),
      label: cluster.primaryTitle,
      radius: 10,
      onPressed: () => _open(context),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: !PlatformEnvironmentService.isTelevision,
          borderRadius: BorderRadius.circular(10),
          onTap: () => _open(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.surface1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: tokens.hairline, width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) => NetworkImgLayer(
                          src: cluster.posterUrl,
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                      // 底部暗房压角，提升角标对比度
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: 54,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Color(0xCC0B0C0E),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (rating.isNotEmpty)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: _PosterPill(
                            text: rating,
                            background: const Color(0xD90B0C0E),
                            foreground: KazumiThemeTokens.tungstenGold,
                            borderColor: KazumiThemeTokens.tungstenGold
                                .withValues(alpha: 0.45),
                            bold: true,
                          ),
                        ),
                      if (verifiedBadge.isNotEmpty || cluster.sourceCount > 1)
                        Positioned(
                          left: 6,
                          right: 6,
                          bottom: 6,
                          child: Row(
                            children: [
                              if (verifiedBadge.isNotEmpty)
                                _PosterPill(
                                  text: verifiedBadge,
                                  background: const Color(0xD9121316),
                                  foreground: KazumiThemeTokens.tungstenGold,
                                  borderColor: KazumiThemeTokens.tungstenGold
                                      .withValues(alpha: 0.4),
                                  bold: true,
                                ),
                              if (verifiedBadge.isNotEmpty &&
                                  cluster.sourceCount > 1)
                                const SizedBox(width: 4),
                              if (cluster.sourceCount > 1)
                                _PosterPill(
                                  text: '${cluster.sourceCount} 源',
                                  background: const Color(0xCC121316),
                                  foreground: const Color(0xFFE5E7EB),
                                  borderColor: const Color(0x66FFFFFF),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: compact ? 6 : 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cluster.primaryTitle,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        metaParts.take(2).join('  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterPill extends StatelessWidget {
  const _PosterPill({
    required this.text,
    required this.background,
    required this.foreground,
    required this.borderColor,
    this.bold = false,
  });

  final String text;
  final Color background;
  final Color foreground;
  final Color borderColor;
  final bool bold;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: borderColor, width: 0.8),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: foreground,
        fontSize: 10.5,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
        height: 1.15,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    ),
  );
}

/// 单源作品卡片（用于单源回退模式与兼容调用）。
class SourceMediaCard extends StatelessWidget {
  const SourceMediaCard({super.key, required this.media});
  final MediaSummary media;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final rating = media.ratingText.trim();
    final metaParts = <String>[
      if (media.year.isNotEmpty) media.year,
      if (media.statusText.isNotEmpty) media.statusText,
      if (media.statusText.isEmpty && media.region.isNotEmpty) media.region,
    ];
    return TvAction(
      key: ValueKey(media.ref.key),
      label: media.title,
      radius: 10,
      onPressed: () => context.pushNamed('/media/detail', arguments: media),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          canRequestFocus: !PlatformEnvironmentService.isTelevision,
          borderRadius: BorderRadius.circular(10),
          onTap: () => context.pushNamed('/media/detail', arguments: media),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.surface1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: tokens.hairline, width: 1),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) => NetworkImgLayer(
                          src: media.posterUrl,
                          width: constraints.maxWidth,
                          height: constraints.maxHeight,
                          borderRadius: BorderRadius.zero,
                        ),
                      ),
                      if (rating.isNotEmpty)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: _PosterPill(
                            text: rating,
                            background: const Color(0xD90B0C0E),
                            foreground: KazumiThemeTokens.tungstenGold,
                            borderColor: KazumiThemeTokens.tungstenGold
                                .withValues(alpha: 0.45),
                            bold: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      media.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        metaParts.take(2).join('  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 收藏和历史使用本地快照展示，来源离线时也保留封面和标题。
class SourceMediaTile extends StatelessWidget {
  const SourceMediaTile({
    super.key,
    required this.media,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.foldedSourceCount = 1,
  });
  final MediaSummary media;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final int foldedSourceCount;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final channelLine = foldedSourceCount > 1
        ? '${media.ref.kind.label}  已关联 $foldedSourceCount 源'
        : '${media.ref.kind.label}  ${media.sourceName}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TvFocusFrame(
        radius: 10,
        child: Material(
          color: tokens.surface1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: tokens.hairline, width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: NetworkImgLayer(
                src: media.posterUrl,
                width: 46,
                height: 68,
              ),
            ),
            title: Text(
              media.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: tokens.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  channelLine,
                  if (subtitle?.isNotEmpty == true) subtitle!,
                ].join('\n'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tokens.textSecondary,
                  height: 1.35,
                ),
              ),
            ),
            isThreeLine: subtitle?.isNotEmpty == true,
            trailing: trailing,
            onTap:
                onTap ??
                () => context.pushNamed('/media/detail', arguments: media),
          ),
        ),
      ),
    );
  }
}

class MediaMessage extends StatelessWidget {
  const MediaMessage({
    super.key,
    required this.message,
    this.onRetry,
    this.actionLabel = '重试',
  });
  final String message;
  final VoidCallback? onRetry;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.local_movies_outlined,
              size: 40,
              color: tokens.accent.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              FilledButton(onPressed: onRetry, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
