import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_fanout_service.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

/// 内容优先跨源聚簇检索页。
///
/// 通过 [SourceFanOutService] 并发检索全部健康来源并实时流式聚簇去重：
/// - 同部电影/剧集仅展示 1 张海报并标注可用片源数，底层保留全部真实 `MediaRef`；
/// - 跳过已熔断与 CAPTCHA 冷却源，触发人工验证的源在顶部非阻塞提示，绝不静默绕过。
class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key, required this.args});
  final MediaSearchArgs args;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  final _catalog = inject<MediaCatalogService>();
  final _health = SourceHealthRepository.instance;
  late final SourceFanOutService _fanOut;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  CancelToken _cancel = CancelToken();
  int _generation = 0;
  String _keyword = '';
  MediaSort _sort = MediaSort.latest;
  String? _filterRuleId; // 可选：仅过滤显示包含该来源的聚簇
  bool _searching = false;
  bool _verifying = false;
  FanOutSearchSummary? _summary;

  SourceRecommendationStrategy get _strategy =>
      SourceRecommendationStrategy.parse(
        GStorage.getSetting(SettingsKeys.sourceRecommendationStrategy),
      );

  @override
  void initState() {
    super.initState();
    _fanOut = SourceFanOutService(catalog: _catalog);
    final providers = _catalog.providersFor(widget.args.kind);
    if (widget.args.ruleId != null &&
        providers.any((p) => p.ruleId == widget.args.ruleId)) {
      _filterRuleId = widget.args.ruleId;
    }
  }

  Future<void> _search() async {
    final keyword = _input.text.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    _cancel.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;

    setState(() {
      _keyword = keyword;
      _searching = true;
      _summary = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);

    try {
      final result = await _fanOut.searchClustered(
        kind: widget.args.kind,
        keyword: keyword,
        strategy: _strategy,
        cancelToken: token,
        onProgress: (partial) {
          if (!mounted || generation != _generation || token.isCancelled) {
            return;
          }
          setState(() => _summary = partial);
        },
      );
      if (!mounted || generation != _generation || token.isCancelled) return;
      setState(() {
        _summary = result;
        _searching = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
      }
    }
  }

  Future<void> _verifyPlugin(Plugin plugin) async {
    if (_verifying) return;
    final channel = plugin.catalog?.channels[widget.args.kind.name];
    if (channel == null) {
      KazumiDialog.showToast(message: '此规则未配置人工验证流程。');
      return;
    }
    setState(() => _verifying = true);
    try {
      final ok = await verifyMediaCaptcha(
        context,
        MediaCaptchaRequest(
          plugin: plugin,
          operation: channel.search,
          label: '搜索「$_keyword」',
          variables: {
            'source': '',
            'seasonId': '',
            'keyword': _keyword,
            'page': 1,
            'categoryId': channel.defaultCategoryId,
            'mediaType': widget.args.kind.name,
          },
        ),
      );
      if (ok && mounted) {
        _health.clearCaptchaCooldown(
          SourceHealthRepository.pluginIdentityKey(plugin),
          kind: widget.args.kind,
        );
        KazumiDialog.showToast(message: '${plugin.name} 验证通过，正在重新聚合搜索');
        unawaited(_search());
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  List<WorkCluster> _visibleClusters() {
    final raw = _summary?.clusters ?? const <WorkCluster>[];
    final filtered = _filterRuleId == null
        ? List<WorkCluster>.of(raw)
        : raw
              .where(
                (c) => c.candidates.any((cand) => cand.ruleId == _filterRuleId),
              )
              .toList();

    filtered.sort((a, b) {
      switch (_sort) {
        case MediaSort.rating:
          final ra = double.tryParse(a.ratingText) ?? 0;
          final rb = double.tryParse(b.ratingText) ?? 0;
          if (rb != ra) return rb.compareTo(ra);
          return b.sourceCount.compareTo(a.sourceCount);
        case MediaSort.yearDesc:
          final ya = int.tryParse(a.year) ?? 0;
          final yb = int.tryParse(b.year) ?? 0;
          if (yb != ya) return yb.compareTo(ya);
          return b.sourceCount.compareTo(a.sourceCount);
        case MediaSort.yearAsc:
          final ya = int.tryParse(a.year) ?? 9999;
          final yb = int.tryParse(b.year) ?? 9999;
          if (ya != yb) return ya.compareTo(yb);
          return b.sourceCount.compareTo(a.sourceCount);
        case MediaSort.title:
          return a.primaryTitle.toLowerCase().compareTo(
            b.primaryTitle.toLowerCase(),
          );
        case MediaSort.latest:
          // 搜索默认将标题精确命中 + 多源印证靠前展示
          final q = _keyword.toLowerCase();
          final exactA = a.primaryTitle.toLowerCase() == q ? 1 : 0;
          final exactB = b.primaryTitle.toLowerCase() == q ? 1 : 0;
          if (exactB != exactA) return exactB.compareTo(exactA);
          return b.sourceCount.compareTo(a.sourceCount);
      }
    });
    return filtered;
  }

  @override
  void dispose() {
    _cancel.cancel();
    ++_generation;
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final providers = _catalog.providersFor(widget.args.kind);
    final isTv = PlatformEnvironmentService.isTelevision;
    final clusters = _visibleClusters();
    final summary = _summary;

    return Scaffold(
      backgroundColor: tokens.canvas,
      appBar: SysAppBar(
        title: Text('搜索${widget.args.kind.label}'),
      ),
      body: Column(
        children: [
          Container(
            color: tokens.surface1,
            padding: EdgeInsets.fromLTRB(
              isTv ? 28 : 16,
              10,
              isTv ? 28 : 16,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isTv)
                  Row(
                    children: [
                      Expanded(
                        child: TvSearchBox(
                          controller: _input,
                          hint: '输入${widget.args.kind.label}片名（自动全源聚簇去重）',
                          autofocus: true,
                          enabled: !_verifying,
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TvSelect<MediaSort>(
                        label: '排序',
                        value: _sort,
                        options: [
                          for (final s in MediaSort.values) (s, s.label),
                        ],
                        onChanged: (value) => setState(() => _sort = value),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          autofocus: true,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _search(),
                          decoration: InputDecoration(
                            hintText: '输入片名，自动聚合去重全部健康片源…',
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: tokens.accent,
                            ),
                            suffixIcon: _input.text.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.close_rounded),
                                    onPressed: () {
                                      _input.clear();
                                      setState(() {});
                                    },
                                  )
                                : null,
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: _verifying ? null : _search,
                        child: const Text('搜索'),
                      ),
                    ],
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final s in MediaSort.values)
                              Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: ChoiceChip(
                                  label: Text(s.label),
                                  selected: _sort == s,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  backgroundColor: tokens.surface2,
                                  selectedColor: tokens.accentSoft,
                                  side: BorderSide(
                                    color: _sort == s
                                        ? tokens.accent.withValues(alpha: 0.65)
                                        : tokens.hairline,
                                  ),
                                  labelStyle: TextStyle(
                                    fontSize: 12,
                                    color: _sort == s
                                        ? tokens.accent
                                        : tokens.textSecondary,
                                  ),
                                  onSelected: (_) => setState(() => _sort = s),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (_filterRuleId != null)
                      TextButton.icon(
                        onPressed: () => setState(() => _filterRuleId = null),
                        icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                        label: const Text('清除单源筛选'),
                      ),
                  ],
                ),
                if (summary != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _searching
                        ? '正在聚合检索：已完成 ${summary.searchedSources}/${providers.length} 源 · 聚簇 ${clusters.length} 部作品…'
                        : '已检索 ${summary.succeededSources}/${providers.length} 个健康片源 · 聚簇去重 ${clusters.length} 部作品',
                    style: TextStyle(color: tokens.textMuted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: tokens.hairline),
          if (_searching)
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: tokens.accent,
            ),
          if (summary != null && summary.captchaPlugins.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                isTv ? 28 : 16,
                10,
                isTv ? 28 : 16,
                0,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: tokens.surface1,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: tokens.warning.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: tokens.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${summary.captchaPlugins.map((p) => p.name).join('、')} 需要人工验证，已跳过并保留其余片源结果。',
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _verifying
                          ? null
                          : () => _verifyPlugin(summary.captchaPlugins.first),
                      child: Text(_verifying ? '验证中' : '人工验证'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _buildResults(
              context,
              tokens,
              providers: providers,
              clusters: clusters,
              isTv: isTv,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResults(
    BuildContext context,
    KazumiThemeTokens tokens, {
    required List<MediaProvider> providers,
    required List<WorkCluster> clusters,
    required bool isTv,
  }) {
    if (providers.isEmpty) {
      return const MediaMessage(
        message: '没有启用的当前频道来源，请先在规则管理中启用影视规则。',
      );
    }
    if (_keyword.isEmpty) {
      return const MediaMessage(
        message: '输入想看的片名，将自动并发检索全部健康来源并去重合并。',
      );
    }
    if (clusters.isEmpty) {
      if (_searching) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: tokens.accent),
              const SizedBox(height: 12),
              Text(
                '正在全源检索并聚簇去重…',
                style: TextStyle(color: tokens.textSecondary, fontSize: 13),
              ),
            ],
          ),
        );
      }
      return MediaMessage(
        message: '未找到与「$_keyword」匹配的${widget.args.kind.label}，可尝试缩短片名或重试。',
        onRetry: _search,
      );
    }

    final horizontalPad = isTv ? 28.0 : 16.0;
    return CustomScrollView(
      scrollCacheExtent: isTv ? const ScrollCacheExtent.pixels(700) : null,
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(horizontalPad, 16, horizontalPad, 28),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.crossAxisExtent / 168)
                  .floor()
                  .clamp(2, 7);
              const spacing = 12.0;
              final cardWidth =
                  (constraints.crossAxisExtent - (columns - 1) * spacing) /
                  columns;
              return SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: spacing,
                  mainAxisExtent: cardWidth * 1.48 + 64,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) => WorkClusterCard(cluster: clusters[index]),
                  childCount: clusters.length,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
