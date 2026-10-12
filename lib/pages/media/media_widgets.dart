import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

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
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        for (final kind in <MediaKind?>[null, ...MediaKind.values])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TvFocusFrame(
              child: ChoiceChip(
                label: Text(kind?.label ?? '全部'),
                selected: selected == kind,
                onSelected: (_) => onChanged(kind),
              ),
            ),
          ),
      ],
    ),
  );
}

class SourceMediaCard extends StatelessWidget {
  const SourceMediaCard({super.key, required this.media});
  final MediaSummary media;

  @override
  Widget build(BuildContext context) => TvAction(
    key: ValueKey(media.ref.key),
    label: media.title,
    onPressed: () => context.pushNamed('/media/detail', arguments: media),
    child: Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        canRequestFocus: !PlatformEnvironmentService.isTelevision,
        onTap: () => context.pushNamed('/media/detail', arguments: media),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => NetworkImgLayer(
                  src: media.posterUrl,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    media.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      media.year,
                      media.statusText,
                    ].where((text) => text.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
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

/// 收藏和历史使用本地快照展示，来源离线时也保留封面和标题。
class SourceMediaTile extends StatelessWidget {
  const SourceMediaTile({
    super.key,
    required this.media,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
  final MediaSummary media;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => TvFocusFrame(
    child: Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: NetworkImgLayer(src: media.posterUrl, width: 46, height: 68),
        title: Text(media.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            '${media.ref.kind.label} · ${media.sourceName}',
            if (subtitle?.isNotEmpty == true) subtitle!,
          ].join('\n'),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: subtitle?.isNotEmpty == true,
        trailing: trailing,
        onTap:
            onTap ?? () => context.pushNamed('/media/detail', arguments: media),
      ),
    ),
  );
}

class MediaMessage extends StatelessWidget {
  const MediaMessage({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    ),
  );
}
