import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_page.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

/// 保留原动漫页面及控制器，影视频道仅在首次打开时加载。
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

  @override
  Widget build(BuildContext context) => Column(
    children: [
      SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: SizedBox(
            width: double.infinity,
            child: PlatformEnvironmentService.isTelevision
                ? Row(
                    children: [
                      for (final kind in MediaKind.values)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            child: TvAction(
                              label: kind.label,
                              selected: _kind == kind,
                              onPressed: () => _select(kind),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                child: Center(
                                  child: Text(
                                    kind.label,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  )
                : SegmentedButton<MediaKind>(
                    segments: const [
                      ButtonSegment(
                        value: MediaKind.anime,
                        label: Text('动漫'),
                        icon: Icon(Icons.animation),
                      ),
                      ButtonSegment(
                        value: MediaKind.tv,
                        label: Text('电视剧'),
                        icon: Icon(Icons.tv),
                      ),
                      ButtonSegment(
                        value: MediaKind.movie,
                        label: Text('电影'),
                        icon: Icon(Icons.movie_outlined),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (selection) =>
                        _select(selection.single),
                  ),
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
  );
}
