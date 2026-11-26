import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

/// 银盐放映室统一首页壳层：动漫 / 电视剧 / 电影三频道并列，配全局检索入口。
///
/// 保留原动漫页面及控制器，影视频道仅在首次打开时懒加载。
class MediaHomePage extends StatefulWidget {
  const MediaHomePage({super.key, required this.animeController});
  final PopularController animeController;

  @override
  State<MediaHomePage> createState() => _MediaHomePageState();
}

class _MediaHomePageState extends State<MediaHomePage> {
  late MediaKind _kind;
  final Set<MediaKind> _visited = {};

  @override
  void initState() {
    super.initState();
    _kind = MediaKind.parse(
      SourceMediaLibrary.instance.preference('home.kind'),
    );
    _visited.add(_kind);
  }

  void _select(MediaKind kind) {
    setState(() {
      _kind = kind;
      _visited.add(kind);
    });
    unawaited(
      SourceMediaLibrary.instance.setPreference('home.kind', kind.name),
    );
  }

  void _openSearch() {
    if (_kind == MediaKind.anime) {
      context.pushNamed('/search/');
    } else {
      context.pushNamed(
        '/media/search',
        arguments: MediaSearchArgs(kind: _kind),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final isTv = PlatformEnvironmentService.isTelevision;
    final compact = MediaQuery.sizeOf(context).width < 600;

    return ColoredBox(
      color: tokens.canvas,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.surface1,
              border: Border(
                bottom: BorderSide(color: tokens.hairline, width: 1),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  isTv ? 28 : 16,
                  isTv ? 16 : 10,
                  isTv ? 28 : 16,
                  isTv ? 12 : 10,
                ),
                child: isTv
                    ? _buildTvHeader(context, tokens)
                    : _buildStandardHeader(context, tokens, compact: compact),
              ),
            ),
          ),
          Expanded(
            // 频道栏已经避开状态栏，内页不再重复预留顶部安全区。
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: IndexedStack(
                index: _kind.index,
                children: [
                  for (final kind in MediaKind.values)
                    ExcludeFocus(
                      excluding: kind != _kind,
                      child: !_visited.contains(kind)
                          ? const SizedBox.shrink()
                          : kind == MediaKind.anime
                          ? PopularPage(controller: widget.animeController)
                          : SourceBrowsePage(key: ValueKey(kind), kind: kind),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTvHeader(BuildContext context, KazumiThemeTokens tokens) {
    return Row(
      children: [
        for (final kind in MediaKind.values)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: TvAction(
              label: kind.label,
              selected: _kind == kind,
              radius: 10,
              onPressed: () => _select(kind),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _kind == kind ? tokens.accentSoft : tokens.surface2,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _kind == kind
                        ? tokens.accent.withValues(alpha: 0.7)
                        : tokens.hairline,
                  ),
                ),
                child: Text(
                  kind.label,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color:
                        _kind == kind ? tokens.accent : tokens.textSecondary,
                    fontWeight:
                        _kind == kind ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        const Spacer(),
        TvAction(
          label: '搜索${_kind.label}',
          radius: 10,
          onPressed: _openSearch,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: tokens.surface2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: tokens.hairline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_rounded, size: 18, color: tokens.accent),
                const SizedBox(width: 8),
                Text(
                  '搜索${_kind.label}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: tokens.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStandardHeader(
    BuildContext context,
    KazumiThemeTokens tokens, {
    required bool compact,
  }) {
    final switcher = Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: tokens.surface2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.hairline),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (final kind in MediaKind.values)
            compact
                ? Expanded(child: _channelTab(context, tokens, kind))
                : _channelTab(context, tokens, kind),
        ],
      ),
    );

    final searchPill = Material(
      color: tokens.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openSearch,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 12 : 14,
            vertical: 9,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_rounded, size: 18, color: tokens.accent),
              if (!compact) ...[
                const SizedBox(width: 8),
                Text(
                  _kind == MediaKind.anime
                      ? '搜索番剧名称…'
                      : '全源聚合搜索${_kind.label}…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    return Row(
      children: [
        if (compact) Expanded(child: switcher) else switcher,
        const SizedBox(width: 10),
        if (!compact) const Spacer(),
        searchPill,
      ],
    );
  }

  Widget _channelTab(
    BuildContext context,
    KazumiThemeTokens tokens,
    MediaKind kind,
  ) {
    final active = _kind == kind;
    return Material(
      color: active ? tokens.accentSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _select(kind),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Center(
            child: Text(
              kind.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: active ? tokens.accent : tokens.textSecondary,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
