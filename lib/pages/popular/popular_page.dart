import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/widget/bangumi_mirror_error_widget.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';
import 'package:kazumi/pages/popular/popular_filter_sheet.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/desktop_window_config.dart';
import 'package:kazumi/bean/appbar/drag_to_move_bar.dart' as dtb;
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

class PopularPage extends StatefulWidget {
  const PopularPage({super.key, required this.controller});

  final PopularController controller;

  @override
  State<PopularPage> createState() => _PopularPageState();
}

class _PopularPageState extends State<PopularPage> {
  late final ScrollController scrollController;
  PopularController get popularController => widget.controller;

  @override
  void initState() {
    super.initState();
    scrollController = ScrollController(
      initialScrollOffset: popularController.scrollOffset,
    );
    scrollController.addListener(scrollListener);
    if (popularController.trendList.isEmpty) {
      popularController.queryBangumiByTrend();
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(scrollListener);
    scrollController.dispose();
    super.dispose();
  }

  void scrollListener() {
    popularController.scrollOffset = scrollController.offset;
    if (scrollController.position.pixels >=
            scrollController.position.maxScrollExtent - 200 &&
        !popularController.isLoadingMore) {
      KazumiLogger().i(
        'PopularPageController: Fetching next recommendation batch',
      );
      if (popularController.isFiltered) {
        popularController.queryFilteredBangumi();
      } else {
        popularController.queryBangumiByTrend();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        scrollCacheExtent: PlatformEnvironmentService.isTelevision
            ? const ScrollCacheExtent.pixels(700)
            : null,
        controller: scrollController,
        slivers: [
          buildSliverAppBar(),
          SliverToBoxAdapter(
            child: _buildFilterBar(),
          ),
          SliverToBoxAdapter(
            child: Observer(
              builder: (_) => AnimatedOpacity(
                opacity: popularController.isLoadingMore ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: popularController.isLoadingMore
                    ? const LinearProgressIndicator(minHeight: 4)
                    : const SizedBox(height: 4),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              StyleString.cardSpace,
              0,
              StyleString.cardSpace,
              0,
            ),
            sliver: Observer(
              builder: (_) {
                if (popularController.isTimeOut) {
                  return SliverToBoxAdapter(
                    child: SizedBox(
                      height: 400,
                      child: BangumiMirrorErrorWidget(
                        onRetry: () {
                          if (!popularController.isFiltered) {
                            popularController.queryBangumiByTrend();
                          } else {
                            popularController.queryFilteredBangumi();
                          }
                        },
                        onSettingsReturned: () {
                          if (mounted) {
                            setState(() {});
                          }
                        },
                      ),
                    ),
                  );
                }
                return contentGrid(
                  popularController.isFiltered
                      ? popularController.bangumiList
                      : popularController.trendList,
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        ),
        child: const Icon(Icons.arrow_upward),
      ),
    );
  }

  Widget contentGrid(List<BangumiItem> bangumiList) {
    if (bangumiList.isEmpty &&
        popularController.isFiltered &&
        !popularController.isLoadingMore) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: GeneralEmptyState(
            icon: Icons.movie_filter_outlined,
            title: '没有找到符合条件的动漫',
            actions: [
              TextButton(
                onPressed: _resetFilters,
                child: const Text('重置筛选条件'),
              ),
            ],
          ),
        ),
      );
    }
    int crossCount = 3;
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.compact['width']!) {
      crossCount = 5;
    }
    if (MediaQuery.sizeOf(context).width > LayoutBreakpoint.medium['width']!) {
      crossCount = 6;
    }
    return SliverPadding(
      padding: const EdgeInsets.all(8),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          // 行间距
          mainAxisSpacing: StyleString.cardSpace - 2,
          // 列间距
          crossAxisSpacing: StyleString.cardSpace,
          // 列数
          crossAxisCount: crossCount,
          mainAxisExtent:
              MediaQuery.of(context).size.width / crossCount / 0.65 +
              MediaQuery.textScalerOf(context).scale(32.0),
        ),
        delegate: SliverChildBuilderDelegate((BuildContext context, int index) {
          return bangumiList.isNotEmpty
              ? BangumiCardV(bangumiItem: bangumiList[index])
              : null;
        }, childCount: bangumiList.isNotEmpty ? bangumiList.length : 10),
      ),
    );
  }

  Widget buildSliverAppBar() {
    final theme = Theme.of(context);
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 120,
      elevation: 0,
      titleSpacing: 0,
      centerTitle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      actions: buildActions(),
      title: null,
      flexibleSpace: SafeArea(
        child: dtb.DragToMoveArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double maxExtent = 120 - MediaQuery.of(context).padding.top;
              final t =
                  (1 -
                  ((constraints.maxHeight - kToolbarHeight) /
                          (maxExtent - kToolbarHeight))
                      .clamp(0.0, 1.0));
              // 字重收缩后为 w500，展开时为 w700
              final fontWeight = t < 0.5 ? FontWeight.w700 : FontWeight.w500;
              final fontSize = lerpDouble(28, 20, t)!;
              return Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    top: 8,
                    bottom: 8,
                    right: 60,
                  ),
                  child: SizedBox(
                    height: 44,
                    child: Observer(
                      builder: (_) {
                        final String title = _appBarTitle;
                        if (PlatformEnvironmentService.isTelevision) {
                          return TvSelect<String>(
                            label: '动漫题材',
                            value: popularController.currentTag,
                            options: [
                              for (final tag in ['', ...defaultAnimeTags])
                                (tag, tag.isEmpty ? '全部题材' : tag),
                            ],
                            onChanged: _selectTag,
                          );
                        }
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _showFilterSheet,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.headlineMedium!
                                      .copyWith(
                                        fontWeight: fontWeight,
                                        fontSize: fontSize,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.tune_rounded,
                                size: fontSize * 0.8,
                                color: theme.iconTheme.color,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  String get _appBarTitle {
    if (!popularController.isFiltered) return '热门番组';
    final parts = <String>[];
    if (popularController.currentTag.isNotEmpty) {
      parts.add(popularController.currentTag);
    }
    if (popularController.currentYear.isNotEmpty) {
      parts.add(popularController.currentYear);
    }
    if (popularController.currentSort != 'heat') {
      parts.add(animeSortOptions[popularController.currentSort] ?? '');
    }
    return parts.isEmpty ? '热门番组' : parts.join(' · ');
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Observer(
        builder: (_) {
          return Row(
            children: [
              const Icon(Icons.tune_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: PlatformEnvironmentService.isTelevision
                    ? TvSelect<String>(
                        label: '题材',
                        value: popularController.currentTag,
                        options: [
                          ('', '全部题材'),
                          for (final tag in defaultAnimeTags) (tag, tag),
                        ],
                        onChanged: _selectTag,
                      )
                    : DropdownButton<String>(
                        value: popularController.currentTag,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child:
                                Text('全部题材', overflow: TextOverflow.ellipsis),
                          ),
                          for (final tag in defaultAnimeTags)
                            DropdownMenuItem(
                              value: tag,
                              child: Text(tag, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (tag) =>
                            tag != null ? _selectTag(tag) : null,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PlatformEnvironmentService.isTelevision
                    ? TvSelect<String>(
                        label: '年份',
                        value: popularController.currentYear,
                        options: [
                          ('', '全部年份'),
                          for (final year in animeYearOptions) (year, year),
                        ],
                        onChanged: _selectYear,
                      )
                    : DropdownButton<String>(
                        value: popularController.currentYear,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(
                            value: '',
                            child:
                                Text('全部年份', overflow: TextOverflow.ellipsis),
                          ),
                          for (final year in animeYearOptions)
                            DropdownMenuItem(
                              value: year,
                              child:
                                  Text(year, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (year) =>
                            year != null ? _selectYear(year) : null,
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PlatformEnvironmentService.isTelevision
                    ? TvSelect<String>(
                        label: '排序',
                        value: popularController.currentSort,
                        options: [
                          for (final entry in animeSortOptions.entries)
                            (entry.key, entry.value),
                        ],
                        onChanged: _selectSort,
                      )
                    : DropdownButton<String>(
                        value: popularController.currentSort,
                        isExpanded: true,
                        items: [
                          for (final entry in animeSortOptions.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(
                                entry.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (sort) =>
                            sort != null ? _selectSort(sort) : null,
                      ),
              ),
              if (popularController.isFiltered) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '重置筛选',
                  icon: const Icon(Icons.clear_rounded, size: 20),
                  onPressed: _resetFilters,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  List<Widget> buildActions() {
    return <Widget>[
      Observer(
        builder: (_) => IconButton(
          tooltip: '筛选动漫',
          onPressed: _showFilterSheet,
          icon: Badge(
            isLabelVisible: popularController.isFiltered,
            child: const Icon(Icons.tune_rounded),
          ),
        ),
      ),
      if (PlatformEnvironmentService.isTelevision ||
          MediaQuery.of(context).orientation == Orientation.portrait)
        IconButton(
          tooltip: '搜索',
          onPressed: () => context.pushNamed('/search/'),
          icon: const Icon(Icons.search),
        ),
      IconButton(
        tooltip: '历史记录',
        onPressed: () => context.pushNamed('/settings/history/'),
        icon: const Icon(Icons.history),
      ),
      if (isDesktop() && !DesktopWindowConfig.showWindowButton)
        IconButton(
          tooltip: '退出',
          onPressed: () => windowManager.close(),
          icon: const Icon(Icons.close),
        ),
    ];
  }

  Future<void> _showFilterSheet() async {
    final result = await showAdaptiveBottomSheet<AnimeFilterResult>(
      context: context,
      maxHeightFactor: 0.85,
      builder: (_) => AnimeFilterSheet(
        initialTag: popularController.currentTag,
        initialYear: popularController.currentYear,
        initialSort: popularController.currentSort,
      ),
    );
    if (!mounted || result == null) return;
    popularController.setCurrentTag(result.tag);
    popularController.setCurrentYear(result.year);
    popularController.setCurrentSort(result.sort);
    await _applyCurrentFilters();
  }

  Future<void> _selectTag(String selected) async {
    if (!mounted || selected == popularController.currentTag) return;
    popularController.setCurrentTag(selected);
    await _applyCurrentFilters();
  }

  Future<void> _selectYear(String selected) async {
    if (!mounted || selected == popularController.currentYear) return;
    popularController.setCurrentYear(selected);
    await _applyCurrentFilters();
  }

  Future<void> _selectSort(String selected) async {
    if (!mounted || selected == popularController.currentSort) return;
    popularController.setCurrentSort(selected);
    await _applyCurrentFilters();
  }

  Future<void> _resetFilters() async {
    if (!mounted) return;
    popularController.resetFilters();
    if (scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _applyCurrentFilters() async {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
    if (!popularController.isFiltered) {
      popularController.clearBangumiList();
      if (popularController.trendList.isEmpty) {
        await popularController.queryBangumiByTrend();
      }
    } else {
      await popularController.queryFilteredBangumi(type: 'init');
    }
  }
}
