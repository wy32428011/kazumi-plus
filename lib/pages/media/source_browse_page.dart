import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/media/media_request_state.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/federated_catalog_coordinator.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

class MediaSearchArgs {
  const MediaSearchArgs({required this.kind, this.ruleId});
  final MediaKind kind;
  final String? ruleId;
}

class _FederatedBrowseSnapshot {
  String semanticCategoryId = SemanticMediaCategory.all.id;
  MediaSort sort = MediaSort.latest;
  String? singleSourceRuleId; // 空表示默认内容优先智能聚合；非空表示用户主动切入单源排障视图
  String? singleSourceCategoryId;
  List<MediaCategory> singleSourceCategories = [];
  bool singleSourceCategoriesLoaded = false;

  final List<WorkCluster> clusters = [];
  final MediaResultState singleState = MediaResultState();
  List<WorkCluster> fourKavRail = [];
  bool fourKavLoaded = false;

  int page = 0;
  bool hasMore = true;
  bool loading = false;
  String? errorMessage;
  List<String> anchorNames = const [];
  List<Plugin> captchaPlugins = const [];
  double offset = 0;

  void resetFederated() {
    clusters.clear();
    page = 0;
    hasMore = true;
    loading = false;
    errorMessage = null;
    anchorNames = const [];
    captchaPlugins = const [];
  }
}

/// 内容优先联邦影视发现页（电影 / 电视剧）。
///
/// 主链路彻底取消「先选采集站」下拉框：
/// - 默认由 [FederatedCatalogCoordinator] 动态挑选 K=3 个跨 CDN 健康锚点，输出防误并去重作品墙；
/// - 电影频道异步并行拉取 `4K-AV` 精选补充轨，永不阻塞首屏；
/// - 顶部展示折叠后的「继续观看」横栏与语义分类标签；
/// - 高级用户仍可通过顶部节点胶囊切入「按单源浏览」进行定向排查。
class SourceBrowsePage extends StatefulWidget {
  const SourceBrowsePage({super.key, required this.kind});
  final MediaKind kind;

  @override
  State<SourceBrowsePage> createState() => _SourceBrowsePageState();
}

class _SourceBrowsePageState extends State<SourceBrowsePage> {
  static final Map<MediaKind, _FederatedBrowseSnapshot> _saved = {};
  final _catalog = inject<MediaCatalogService>();
  final _library = SourceMediaLibrary.instance;
  final _health = SourceHealthRepository.instance;
  late final FederatedCatalogCoordinator _coordinator;
  late final _FederatedBrowseSnapshot _state;
  late final ScrollController _scroll;

  CancelToken? _cancel;
  CancelToken? _railCancel;
  int _generation = 0;
  bool _verifying = false;
  MediaCaptchaRequest? _singleCaptchaRequest;

  SourceRecommendationStrategy get _strategy =>
      SourceRecommendationStrategy.parse(
        GStorage.getSetting(SettingsKeys.sourceRecommendationStrategy),
      );

  bool get _isSingleSourceMode =>
      _state.singleSourceRuleId != null &&
      _state.singleSourceRuleId!.isNotEmpty;

  MediaProvider? get _singleProvider => _isSingleSourceMode
      ? _catalog.providerById(_state.singleSourceRuleId!)
      : null;

  @override
  void initState() {
    super.initState();
    _coordinator = FederatedCatalogCoordinator(catalog: _catalog);
    _state = _saved.putIfAbsent(widget.kind, _FederatedBrowseSnapshot.new);
    _state.semanticCategoryId =
        _library.preference('${widget.kind.name}.semantic_category') ??
        SemanticMediaCategory.all.id;
    _state.sort = MediaSort.parse(
      _library.preference('${widget.kind.name}.sort'),
    );
    _scroll = ScrollController(initialScrollOffset: _state.offset)
      ..addListener(_onScroll);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final providers = _catalog.providersFor(widget.kind);
    if (providers.isEmpty) {
      if (mounted) {
        setState(() {
          _state.errorMessage =
              '没有启用的${widget.kind.label}来源，请在规则管理中启用影视规则。';
        });
      }
      return;
    }

    if (_isSingleSourceMode) {
      if (_state.singleState.items.isEmpty) {
        await _loadSingleSource(reset: true);
      }
    } else {
      if (_state.clusters.isEmpty) {
        await _loadFederated(reset: true);
      }
      if (widget.kind == MediaKind.movie && !_state.fourKavLoaded) {
        unawaited(_loadFourKavRail());
      }
    }
  }

  void _onScroll() {
    _state.offset = _scroll.offset;
    if (_scroll.position.extentAfter < 600 && !_verifying) {
      if (_isSingleSourceMode) {
        if (_state.singleState.canLoadAutomatically) {
          unawaited(_loadSingleSource(automatic: true));
        }
      } else {
        if (_state.hasMore && !_state.loading && _state.errorMessage == null) {
          unawaited(_loadFederated());
        }
      }
    }
  }

  Future<void> _loadFederated({bool reset = false}) async {
    if (reset) {
      _cancel?.cancel();
      _state.resetFederated();
      _state.offset = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (_state.loading || !_state.hasMore) {
      return;
    }

    final token = _cancel = CancelToken();
    final generation = ++_generation;
    setState(() {
      _state.loading = true;
      _state.errorMessage = null;
    });

    final semantic = SemanticMediaCategory.byId(
      widget.kind,
      _state.semanticCategoryId,
    );
    final nextPage = _state.page + 1;

    try {
      final result = await _coordinator.loadFederatedPage(
        kind: widget.kind,
        category: semantic,
        page: nextPage,
        sort: _state.sort,
        strategy: _strategy,
        cancelToken: token,
      );
      if (!mounted || generation != _generation || token.isCancelled) return;

      final existingKeys = _state.clusters.map((c) => c.clusterKey).toSet();
      final merged = <WorkCluster>[..._state.clusters];
      var addedCount = 0;
      for (final cluster in result.clusters) {
        if (existingKeys.add(cluster.clusterKey)) {
          merged.add(cluster);
          addedCount++;
        } else {
          // 同簇跨页出现时合并候选池
          final idx = merged.indexWhere(
            (c) => c.clusterKey == cluster.clusterKey,
          );
          if (idx >= 0) {
            final current = merged[idx];
            final seenRefs = current.memberRefKeys;
            final extra = cluster.candidates
                .where((cand) => !seenRefs.contains(cand.refKey))
                .toList();
            if (extra.isNotEmpty) {
              merged[idx] = current.copyWith(
                candidates: [...current.candidates, ...extra],
              );
            }
          }
        }
      }

      setState(() {
        _state.clusters
          ..clear()
          ..addAll(merged);
        _state.page = nextPage;
        _state.anchorNames = result.anchorNames;
        _state.captchaPlugins = result.captchaPlugins;
        _state.hasMore = result.hasMore && (addedCount > 0 || nextPage == 1);
        if (_state.clusters.isEmpty && result.succeededAnchors == 0) {
          _state.errorMessage = result.totalAnchors == 0
              ? '当前频道没有可用片源，请前往片源健康与规则中心检查。'
              : '聚合节点暂未响应，请检查网络或重试。';
        }
      });
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          mediaRequestCancelled(error)) {
        return;
      }
      setState(() {
        _state.errorMessage = describeMediaFailure(error).message;
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _state.loading = false);
      }
    }
  }

  Future<void> _loadFourKavRail() async {
    _railCancel?.cancel();
    final token = _railCancel = CancelToken();
    try {
      final items = await _coordinator.loadFourKavRail(
        kind: widget.kind,
        strategy: _strategy,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;
      setState(() {
        _state.fourKavRail = items;
        _state.fourKavLoaded = true;
      });
    } catch (_) {
      if (mounted && !token.isCancelled) {
        setState(() => _state.fourKavLoaded = true);
      }
    }
  }

  Future<void> _loadSingleSource({
    bool reset = false,
    bool automatic = false,
  }) async {
    final provider = _singleProvider;
    if (provider == null) {
      setState(() {
        _state.singleSourceRuleId = null;
      });
      await _loadFederated(reset: true);
      return;
    }

    if (reset) {
      _cancel?.cancel();
      _state.singleState.reset();
      _state.offset = 0;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (_state.singleState.loading || !_state.singleState.hasMore) {
      return;
    }

    final token = _cancel = CancelToken();
    final generation = ++_generation;
    final nextPage = _state.singleState.page + 1;
    final channel = provider.plugin.catalog?.channels[widget.kind.name];
    _singleCaptchaRequest = channel == null
        ? null
        : MediaCaptchaRequest(
            plugin: provider.plugin,
            operation: channel.discover,
            label: '加载第 $nextPage 页',
            variables: {
              'source': '',
              'seasonId': '',
              'keyword': '',
              'page': nextPage,
              'categoryId':
                  _state.singleSourceCategoryId ?? channel.defaultCategoryId,
              'mediaType': widget.kind.name,
            },
          );

    setState(() {
      _state.singleState.loading = true;
      _state.singleState.failure = null;
    });

    try {
      if (!_state.singleSourceCategoriesLoaded) {
        final cats = await provider.queryCategories(
          widget.kind,
          cancelToken: token,
        );
        if (!mounted || generation != _generation) return;
        _state.singleSourceCategories = cats;
        _state.singleSourceCategoriesLoaded = true;
      }
      final response = await provider.queryDiscover(
        widget.kind,
        categoryId: _state.singleSourceCategoryId,
        sort: _state.sort,
        page: nextPage,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _state.singleState.applyPage(response, automatic: automatic);
      });
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          mediaRequestCancelled(error)) {
        return;
      }
      setState(() {
        _state.singleState.failure = describeMediaFailure(error);
      });
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _state.singleState.loading = false);
      }
    }
  }

  Future<void> _verifyPluginCaptcha(Plugin plugin) async {
    if (_verifying) return;
    final channel = plugin.catalog?.channels[widget.kind.name];
    if (channel == null) {
      KazumiDialog.showToast(message: '该规则未提供验证入口，请检查规则配置。');
      return;
    }
    setState(() => _verifying = true);
    try {
      final ok = await verifyMediaCaptcha(
        context,
        MediaCaptchaRequest(
          plugin: plugin,
          operation: channel.discover,
          label: '恢复 ${plugin.name}',
          variables: {
            'source': '',
            'seasonId': '',
            'keyword': '',
            'page': 1,
            'categoryId': channel.defaultCategoryId,
            'mediaType': widget.kind.name,
          },
        ),
      );
      if (ok && mounted) {
        _health.clearCaptchaCooldown(
          SourceHealthRepository.pluginIdentityKey(plugin),
          kind: widget.kind,
        );
        KazumiDialog.showToast(message: '${plugin.name} 已恢复自动候选资格');
        if (_isSingleSourceMode) {
          await _loadSingleSource(reset: true);
        } else {
          await _loadFederated(reset: true);
        }
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _verifySingleCaptcha() async {
    final req = _singleCaptchaRequest;
    if (_verifying || req == null) return;
    setState(() => _verifying = true);
    try {
      final ok = await verifyMediaCaptcha(context, req);
      if (ok && mounted) {
        _health.clearCaptchaCooldown(
          SourceHealthRepository.pluginIdentityKey(req.plugin),
          kind: widget.kind,
        );
        await _loadSingleSource();
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _selectSemanticCategory(String id) {
    if (_state.semanticCategoryId == id) return;
    setState(() => _state.semanticCategoryId = id);
    unawaited(
      _library.setPreference('${widget.kind.name}.semantic_category', id),
    );
    unawaited(_loadFederated(reset: true));
  }

  void _selectSort(MediaSort sort) {
    if (_state.sort == sort) return;
    setState(() => _state.sort = sort);
    unawaited(_library.setPreference('${widget.kind.name}.sort', sort.name));
    if (_isSingleSourceMode) {
      unawaited(_loadSingleSource(reset: true));
    } else {
      unawaited(_loadFederated(reset: true));
    }
  }

  Future<void> _openSourceModeSheet() async {
    final providers = _catalog.providersFor(widget.kind);
    await showAdaptiveBottomSheet<void>(
      context: context,
      builder: (sheetCtx) {
        final tokens = KazumiThemeTokens.of(sheetCtx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '发现模式与片源节点',
                        style: Theme.of(sheetCtx).textTheme.titleMedium
                            ?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        context.pushNamed('/settings/source-health');
                      },
                      icon: const Icon(Icons.monitor_heart_outlined, size: 18),
                      label: const Text('健康中心'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '默认由实测评分自动挑选 3 个独立节点聚合去重；需要定向排障时可临时切入单源视图。',
                  style: Theme.of(sheetCtx).textTheme.bodySmall?.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      _modeSheetTile(
                        sheetCtx,
                        tokens,
                        title: '智能聚合发现（推荐）',
                        subtitle: _state.anchorNames.isNotEmpty
                            ? '当前锚点：${_state.anchorNames.join(' · ')}'
                            : '动态优选 3 个跨 CDN 健康节点',
                        selected: !_isSingleSourceMode,
                        icon: Icons.auto_awesome_rounded,
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          if (_isSingleSourceMode) {
                            setState(() => _state.singleSourceRuleId = null);
                            unawaited(_loadFederated(reset: true));
                          }
                        },
                      ),
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: Text(
                          '高级：仅浏览单个来源',
                          style: Theme.of(sheetCtx).textTheme.labelMedium
                              ?.copyWith(color: tokens.textMuted),
                        ),
                      ),
                      for (final provider in providers)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: _modeSheetTile(
                            sheetCtx,
                            tokens,
                            title: provider.plugin.name,
                            subtitle: _healthSubtitle(provider.plugin),
                            selected:
                                _state.singleSourceRuleId == provider.ruleId,
                            icon: Icons.dns_outlined,
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              setState(() {
                                _state.singleSourceRuleId = provider.ruleId;
                                _state.singleSourceCategoryId = null;
                                _state.singleSourceCategories = [];
                                _state.singleSourceCategoriesLoaded = false;
                              });
                              unawaited(_loadSingleSource(reset: true));
                            },
                          ),
                        ),
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

  String _healthSubtitle(Plugin plugin) {
    final key = SourceHealthRepository.pluginIdentityKey(plugin);
    final now = DateTime.now();
    if (_health.isSourceInCaptchaCooldown(key, widget.kind, now: now)) {
      return '需人工验证 · 自动池冷却中';
    }
    final h = _health.healthFor(key, widget.kind);
    if (h == null) return '待实测';
    if (h.isCircuitOpen(now)) return '熔断冷却中';
    final parts = <String>[
      if (h.lastVerifiedProfile?.uiBadgeText.isNotEmpty == true)
        '实测 ${h.lastVerifiedProfile!.uiBadgeText}',
      if (h.ewmaTtfbMs != null) '${h.ewmaTtfbMs!.round()}ms',
      if (h.lastCdnGroup.isNotEmpty) h.lastCdnGroup,
    ];
    return parts.isEmpty ? '健康' : parts.join('  ');
  }

  Widget _modeSheetTile(
    BuildContext context,
    KazumiThemeTokens tokens, {
    required String title,
    required String subtitle,
    required bool selected,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return TvFocusFrame(
      radius: 10,
      child: Material(
        color: selected ? tokens.accentSoft : tokens.surface2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: selected
                ? tokens.accent.withValues(alpha: 0.65)
                : tokens.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          dense: true,
          leading: Icon(
            icon,
            size: 20,
            color: selected ? tokens.accent : tokens.textSecondary,
          ),
          title: Text(
            title,
            style: TextStyle(
              color: selected ? tokens.accent : tokens.textPrimary,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.textSecondary, fontSize: 12),
          ),
          trailing: selected
              ? Icon(Icons.check_rounded, color: tokens.accent, size: 18)
              : null,
          onTap: onTap,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancel?.cancel();
    _railCancel?.cancel();
    ++_generation;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    final isLoading = _isSingleSourceMode
        ? _state.singleState.loading
        : _state.loading;

    return ColoredBox(
      color: tokens.canvas,
      child: Column(
        children: [
          _buildControlStrip(context, tokens),
          if (isLoading)
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: tokens.accent,
            ),
          Expanded(
            child: _isSingleSourceMode
                ? _buildSingleSourceBody(context, tokens)
                : _buildFederatedBody(context, tokens),
          ),
        ],
      ),
    );
  }

  Widget _buildControlStrip(BuildContext context, KazumiThemeTokens tokens) {
    final isTv = PlatformEnvironmentService.isTelevision;
    final categories = SemanticMediaCategory.forKind(widget.kind);
    return Container(
      decoration: BoxDecoration(
        color: tokens.canvas,
        border: Border(bottom: BorderSide(color: tokens.hairline, width: 1)),
      ),
      padding: EdgeInsets.fromLTRB(isTv ? 28 : 16, 10, isTv ? 28 : 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 节点状态/发现模式胶囊（默认展示智能聚合，非强制选源下拉框）
              TvFocusFrame(
                radius: 8,
                child: Material(
                  color: _isSingleSourceMode
                      ? tokens.accentSoft
                      : tokens.surface1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: _isSingleSourceMode
                          ? tokens.accent.withValues(alpha: 0.6)
                          : tokens.hairline,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: _openSourceModeSheet,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isSingleSourceMode
                                ? Icons.dns_outlined
                                : Icons.auto_awesome_rounded,
                            size: 15,
                            color: tokens.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isSingleSourceMode
                                ? '单源：${_singleProvider?.plugin.name ?? '已停用'}'
                                : _state.anchorNames.isNotEmpty
                                ? '智能聚合 · ${_state.anchorNames.length} 节点'
                                : '智能聚合',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: tokens.textPrimary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.expand_more_rounded,
                            size: 16,
                            color: tokens.textSecondary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // 排序选择器
              if (isTv)
                TvSelect<MediaSort>(
                  label: '排序',
                  value: _state.sort,
                  options: [
                    for (final s in MediaSort.values) (s, s.label),
                  ],
                  onChanged: _selectSort,
                )
              else
                PopupMenuButton<MediaSort>(
                  tooltip: '排序方式',
                  initialValue: _state.sort,
                  onSelected: _selectSort,
                  itemBuilder: (_) => [
                    for (final s in MediaSort.values)
                      PopupMenuItem(
                        value: s,
                        child: Row(
                          children: [
                            Expanded(child: Text(s.label)),
                            if (s == _state.sort)
                              Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: tokens.accent,
                              ),
                          ],
                        ),
                      ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.surface1,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tokens.hairline),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.sort_rounded,
                          size: 15,
                          color: tokens.textSecondary,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          _state.sort.label,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tokens.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              TvFocusFrame(
                radius: 8,
                child: IconButton(
                  tooltip: '刷新发现页',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    if (_isSingleSourceMode) {
                      unawaited(_loadSingleSource(reset: true));
                    } else {
                      unawaited(_loadFederated(reset: true));
                      if (widget.kind == MediaKind.movie) {
                        unawaited(_loadFourKavRail());
                      }
                    }
                  },
                  icon: Icon(
                    Icons.refresh_rounded,
                    size: 19,
                    color: tokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_isSingleSourceMode)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final cat in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TvFocusFrame(
                        radius: 8,
                        child: ChoiceChip(
                          label: Text(cat.label),
                          selected: _state.semanticCategoryId == cat.id,
                          showCheckmark: false,
                          visualDensity: VisualDensity.compact,
                          backgroundColor: tokens.surface1,
                          selectedColor: tokens.accentSoft,
                          side: BorderSide(
                            color: _state.semanticCategoryId == cat.id
                                ? tokens.accent.withValues(alpha: 0.65)
                                : tokens.hairline,
                          ),
                          labelStyle: TextStyle(
                            fontSize: 12.5,
                            fontWeight: _state.semanticCategoryId == cat.id
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _state.semanticCategoryId == cat.id
                                ? tokens.accent
                                : tokens.textSecondary,
                          ),
                          onSelected: (_) => _selectSemanticCategory(cat.id),
                        ),
                      ),
                    ),
                ],
              ),
            )
          else if (_state.singleSourceCategories.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _singleCatChip(tokens, null, '全部'),
                  for (final cat in _state.singleSourceCategories)
                    _singleCatChip(tokens, cat.id, cat.name),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _singleCatChip(KazumiThemeTokens tokens, String? id, String label) {
    final selected = _state.singleSourceCategoryId == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TvFocusFrame(
        radius: 8,
        child: ChoiceChip(
          label: Text(label),
          selected: selected,
          showCheckmark: false,
          visualDensity: VisualDensity.compact,
          backgroundColor: tokens.surface1,
          selectedColor: tokens.accentSoft,
          side: BorderSide(
            color: selected
                ? tokens.accent.withValues(alpha: 0.65)
                : tokens.hairline,
          ),
          labelStyle: TextStyle(
            fontSize: 12.5,
            color: selected ? tokens.accent : tokens.textSecondary,
          ),
          onSelected: (_) {
            setState(() => _state.singleSourceCategoryId = id);
            unawaited(_loadSingleSource(reset: true));
          },
        ),
      ),
    );
  }

  Widget _buildFederatedBody(BuildContext context, KazumiThemeTokens tokens) {
    final isTv = PlatformEnvironmentService.isTelevision;
    final horizontalPad = isTv ? 28.0 : 16.0;

    if (_state.clusters.isEmpty) {
      if (_state.loading) {
        return _buildSkeletonGrid(tokens, horizontalPad);
      }
      if (_state.errorMessage != null) {
        return MediaMessage(
          message: _state.errorMessage!,
          onRetry: () => _loadFederated(reset: true),
        );
      }
      return MediaMessage(
        message: '当前分类暂无内容，请切换分类或刷新。',
        onRetry: () => _loadFederated(reset: true),
      );
    }

    return AnimatedBuilder(
      animation: _library,
      builder: (context, _) {
        final recentHistories = _library
            .foldedHistories(kind: widget.kind)
            .take(8)
            .toList(growable: false);

        return RefreshIndicator(
          color: tokens.accent,
          onRefresh: () async {
            await _loadFederated(reset: true);
            if (widget.kind == MediaKind.movie) {
              unawaited(_loadFourKavRail());
            }
          },
          child: CustomScrollView(
            scrollCacheExtent: isTv
                ? const ScrollCacheExtent.pixels(700)
                : null,
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              // 1. 需人工验证的非阻塞提示条（绝不绕过，也不阻塞其他健康源）
              if (_state.captchaPlugins.isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPad,
                      12,
                      horizontalPad,
                      0,
                    ),
                    child: _CaptchaNoticeBanner(
                      plugins: _state.captchaPlugins,
                      verifying: _verifying,
                      onVerify: _verifyPluginCaptcha,
                    ),
                  ),
                ),

              // 2. 继续观看横向架（仅当本频道存在历史记录时呈现）
              if (recentHistories.isNotEmpty)
                SliverToBoxAdapter(
                  child: _ContinueWatchingShelf(
                    histories: recentHistories,
                    horizontalPadding: horizontalPad,
                  ),
                ),

              // 3. 电影频道 4K-AV 独立异步精选补充轨（不虚标 4K，仅以实测或来源名呈现）
              if (widget.kind == MediaKind.movie &&
                  _state.fourKavRail.isNotEmpty)
                SliverToBoxAdapter(
                  child: _FourKavSupplementRail(
                    clusters: _state.fourKavRail,
                    horizontalPadding: horizontalPad,
                  ),
                ),

              // 4. 聚合作品墙标题行
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPad,
                    16,
                    horizontalPad,
                    10,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${SemanticMediaCategory.byId(widget.kind, _state.semanticCategoryId).label}${widget.kind.label}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: tokens.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '已去重 ${_state.clusters.length} 部',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 5. 2:3 电影海报主网格
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = (constraints.crossAxisExtent / 168)
                        .floor()
                        .clamp(2, 7);
                    const spacing = 12.0;
                    final cardWidth =
                        (constraints.crossAxisExtent -
                            (columns - 1) * spacing) /
                        columns;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 16,
                        crossAxisSpacing: spacing,
                        mainAxisExtent: cardWidth * 1.48 + 64,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, index) =>
                            WorkClusterCard(cluster: _state.clusters[index]),
                        childCount: _state.clusters.length,
                      ),
                    );
                  },
                ),
              ),

              // 6. 底部翻页状态
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 28),
                  child: Center(
                    child: _state.loading
                        ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.accent,
                            ),
                          )
                        : _state.hasMore
                        ? OutlinedButton(
                            onPressed: _loadFederated,
                            child: const Text('加载更多作品'),
                          )
                        : Text(
                            '已显示当前全部聚合结果',
                            style: TextStyle(
                              color: tokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSingleSourceBody(
    BuildContext context,
    KazumiThemeTokens tokens,
  ) {
    final state = _state.singleState;
    final isTv = PlatformEnvironmentService.isTelevision;
    final horizontalPad = isTv ? 28.0 : 16.0;

    if (state.items.isEmpty) {
      if (state.loading) return _buildSkeletonGrid(tokens, horizontalPad);
      if (state.failure != null) {
        return Center(
          child: MediaFailureNotice(
            failure: state.failure!,
            onRetry: () => _loadSingleSource(),
            onVerify: _verifying ? null : _verifySingleCaptcha,
          ),
        );
      }
      return const MediaMessage(message: '当前来源没有符合条件的内容。');
    }

    final sortedItems = state.items.sortedBy(_state.sort);
    return RefreshIndicator(
      color: tokens.accent,
      onRefresh: () => _loadSingleSource(reset: true),
      child: CustomScrollView(
        scrollCacheExtent: isTv ? const ScrollCacheExtent.pixels(700) : null,
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: EdgeInsets.all(horizontalPad),
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
                    (context, index) =>
                        SourceMediaCard(media: sortedItems[index]),
                    childCount: sortedItems.length,
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: state.failure != null
                ? MediaFailureNotice(
                    failure: state.failure!,
                    onRetry: () => _loadSingleSource(),
                    onVerify: _verifying ? null : _verifySingleCaptcha,
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    child: Center(
                      child: state.hasMore
                          ? OutlinedButton(
                              onPressed: state.loading
                                  ? null
                                  : () => _loadSingleSource(),
                              child: Text(
                                state.automaticPaused ? '手动加载下一页' : '加载更多',
                              ),
                            )
                          : Text(
                              '已经到底了',
                              style: TextStyle(
                                color: tokens.textMuted,
                                fontSize: 12,
                              ),
                            ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeletonGrid(KazumiThemeTokens tokens, double horizontalPad) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth = constraints.maxWidth - horizontalPad * 2;
        final columns = (usableWidth / 168).floor().clamp(2, 7);
        const spacing = 12.0;
        final cardWidth = (usableWidth - (columns - 1) * spacing) / columns;
        return GridView.builder(
          padding: EdgeInsets.all(horizontalPad),
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 16,
            crossAxisSpacing: spacing,
            mainAxisExtent: cardWidth * 1.48 + 64,
          ),
          itemCount: columns * 3,
          itemBuilder: (_, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: tokens.surface1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: tokens.hairline),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 13,
                decoration: BoxDecoration(
                  color: tokens.surface2,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              FractionallySizedBox(
                widthFactor: 0.55,
                alignment: Alignment.centerLeft,
                child: Container(
                  height: 10,
                  decoration: BoxDecoration(
                    color: tokens.surface2,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CaptchaNoticeBanner extends StatelessWidget {
  const _CaptchaNoticeBanner({
    required this.plugins,
    required this.verifying,
    required this.onVerify,
  });

  final List<Plugin> plugins;
  final bool verifying;
  final ValueChanged<Plugin> onVerify;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_user_outlined, size: 18, color: tokens.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${plugins.map((p) => p.name).join('、')} 需要人工验证，已自动跳过且不阻塞当前浏览。',
              style: TextStyle(color: tokens.textSecondary, fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: verifying ? null : () => onVerify(plugins.first),
            child: Text(verifying ? '验证中' : '人工验证'),
          ),
        ],
      ),
    );
  }
}

class _ContinueWatchingShelf extends StatelessWidget {
  const _ContinueWatchingShelf({
    required this.histories,
    required this.horizontalPadding,
  });

  final List<FoldedSourceHistory> histories;
  final double horizontalPadding;

  String _formatTime(int ms) {
    final d = Duration(milliseconds: ms);
    if (d.inHours > 0) {
      return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            16,
            horizontalPadding,
            10,
          ),
          child: Text(
            '继续观看',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: tokens.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: histories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final folded = histories[index];
              final item = folded.primary;
              final progress = item.durationMs > 0
                  ? (item.positionMs / item.durationMs).clamp(0.0, 1.0)
                  : 0.0;
              return SizedBox(
                width: 248,
                child: TvAction(
                  label: '继续观看 ${item.media.title}',
                  radius: 10,
                  onPressed: () => context.pushNamed(
                    '/media/detail',
                    arguments: item.media,
                  ),
                  child: Material(
                    color: tokens.surface1,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: tokens.hairline),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      canRequestFocus: !PlatformEnvironmentService.isTelevision,
                      onTap: () => context.pushNamed(
                        '/media/detail',
                        arguments: item.media,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: NetworkImgLayer(
                                src: item.media.posterUrl,
                                width: 52,
                                height: 74,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    item.media.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: tokens.textPrimary,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item.episodeTitle}  ${_formatTime(item.positionMs)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: tokens.textSecondary,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(2),
                                    child: LinearProgressIndicator(
                                      value: progress,
                                      minHeight: 3,
                                      backgroundColor: tokens.surface3,
                                      color: tokens.accent,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FourKavSupplementRail extends StatelessWidget {
  const _FourKavSupplementRail({
    required this.clusters,
    required this.horizontalPadding,
  });

  final List<WorkCluster> clusters;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            16,
            horizontalPadding,
            10,
          ),
          child: Row(
            children: [
              Text(
                '高码率补充精选',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: tokens.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '独立异步轨 · 不阻塞主目录',
                style: TextStyle(color: tokens.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 236,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            itemCount: clusters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) => SizedBox(
              width: 132,
              child: WorkClusterCard(cluster: clusters[index], compact: true),
            ),
          ),
        ),
      ],
    );
  }
}
