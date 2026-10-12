import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/media/media_request_state.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

class MediaSearchArgs {
  const MediaSearchArgs({required this.kind, this.ruleId});
  final MediaKind kind;
  final String? ruleId;
}

/// 每个频道独立保存分页及位置；退出应用后仍记住来源与分类。
class _BrowseSnapshot extends MediaResultState {
  String? ruleId;
  String? categoryId;
  List<MediaCategory> categories = [];
  bool categoriesLoaded = false;
  double offset = 0;
}

class SourceBrowsePage extends StatefulWidget {
  const SourceBrowsePage({super.key, required this.kind});
  final MediaKind kind;

  @override
  State<SourceBrowsePage> createState() => _SourceBrowsePageState();
}

class _SourceBrowsePageState extends State<SourceBrowsePage> {
  static final Map<MediaKind, _BrowseSnapshot> _saved = {};
  final _catalog = inject<MediaCatalogService>();
  final _library = SourceMediaLibrary.instance;
  late final _BrowseSnapshot _state;
  late final ScrollController _scroll;
  CancelToken? _cancel;
  int _generation = 0;
  bool _verifying = false;
  MediaCaptchaRequest? _captchaRequest;

  MediaProvider? get _provider =>
      _state.ruleId == null ? null : _catalog.providerById(_state.ruleId!);

  @override
  void initState() {
    super.initState();
    _state = _saved.putIfAbsent(widget.kind, _BrowseSnapshot.new);
    _state.ruleId ??= _library.preference('${widget.kind.name}.source');
    _state.categoryId ??= _library.preference('${widget.kind.name}.category');
    _scroll = ScrollController(initialScrollOffset: _state.offset)
      ..addListener(_onScroll);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final providers = _catalog.providersFor(widget.kind);
    if (_state.ruleId != null &&
        !providers.any((provider) => provider.ruleId == _state.ruleId)) {
      // 来源被停用时明确提示，不把其他站点的数据写入旧来源状态。
      _state.reset();
      _state.ruleId = null;
      _state.categories = [];
      _state.categoriesLoaded = false;
      _state.categoryId = null;
      setState(
        () => _state.failure = const MediaRequestFailure(
          '上次使用的来源已停用或移除，请选择其他来源。',
        ),
      );
      return;
    }
    _state.ruleId ??= providers.isEmpty ? null : providers.first.ruleId;
    if (_state.ruleId == null) {
      setState(
        () => _state.failure = MediaRequestFailure(
          '没有启用的${widget.kind.label}来源，请在规则管理中启用影视规则。',
        ),
      );
      return;
    }
    if (_state.items.isEmpty) await _load(reset: true);
    if (mounted) setState(() {});
  }

  void _onScroll() {
    _state.offset = _scroll.offset;
    if (_scroll.position.extentAfter < 500 &&
        _state.canLoadAutomatically &&
        !_verifying) {
      unawaited(_load(automatic: true));
    }
  }

  Future<void> _load({bool reset = false, bool automatic = false}) async {
    if ((_state.loading || !_state.hasMore) && !reset) return;
    final provider = _provider;
    if (provider == null) {
      if (mounted) {
        setState(
          () => _state.failure = const MediaRequestFailure('来源已停用或移除，请重新选择来源。'),
        );
      }
      return;
    }
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;
    if (reset) {
      _state.reset();
      _state.categoriesLoaded = false;
      _state.offset = 0;
    }
    // jumpTo 会同步触发滚动监听，先锁定请求避免重入分页。
    _state.loading = true;
    if (reset && _scroll.hasClients) _scroll.jumpTo(0);
    setState(() => _state.failure = null);
    try {
      final channel = provider.plugin.catalog?.channels[widget.kind.name];
      if (channel == null) throw const FormatException('规则缺少当前频道的资料配置');
      Map<String, Object?> variables() => {
        'source': '',
        'seasonId': '',
        'keyword': '',
        'page': _state.page + 1,
        'categoryId': _state.categoryId ?? channel.defaultCategoryId,
        'mediaType': widget.kind.name,
      };
      if (!_state.categoriesLoaded) {
        _captchaRequest = MediaCaptchaRequest(
          plugin: provider.plugin,
          operation: channel.categories,
          variables: {
            'source': '',
            'seasonId': '',
            'keyword': '',
            'page': 1,
            'categoryId': '',
            'mediaType': widget.kind.name,
          },
          label: '分类',
        );
        final categories = await provider.queryCategories(
          widget.kind,
          cancelToken: token,
        );
        if (!mounted || generation != _generation) return;
        _state.categories = categories;
        _state.categoriesLoaded = true;
        if (!categories.any((category) => category.id == _state.categoryId)) {
          _state.categoryId = null;
        }
      }
      _captchaRequest = MediaCaptchaRequest(
        plugin: provider.plugin,
        operation: channel.discover,
        variables: variables(),
        label: '目录第 ${_state.page + 1} 页',
      );
      final page = await provider.queryDiscover(
        widget.kind,
        categoryId: _state.categoryId,
        page: _state.page + 1,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _state.applyPage(page, automatic: automatic));
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          mediaRequestCancelled(error)) {
        return;
      }
      setState(() => _state.failure = describeMediaFailure(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _state.loading = false);
      }
    }
  }

  Future<void> _verify() async {
    final request = _captchaRequest;
    if (_verifying || request == null) return;
    final generation = _generation;
    setState(() => _verifying = true);
    try {
      final verified = await verifyMediaCaptcha(context, request);
      // 分类已成功时保留该阶段，目录验证后仅重试原页码。
      if (verified && mounted && generation == _generation) await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _state.failure = describeMediaFailure(error));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _selectSource(String? value) {
    if (value == null || value == _state.ruleId) return;
    _cancel?.cancel();
    ++_generation;
    setState(() {
      _state.reset();
      _state.ruleId = value;
      _state.categoryId = null;
      _state.categories = [];
      _state.categoriesLoaded = false;
    });
    unawaited(_library.setPreference('${widget.kind.name}.source', value));
    unawaited(_library.setPreference('${widget.kind.name}.category', ''));
    unawaited(_load(reset: true));
  }

  Future<void> _manageSources() async {
    await context.pushNamed('/settings/plugin/');
    if (!mounted) return;
    _cancel?.cancel();
    ++_generation;
    _state.loading = false;
    await _initialize();
  }

  @override
  void dispose() {
    _cancel?.cancel();
    ++_generation;
    _state.loading = false;
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final providers = _catalog.providersFor(widget.kind);
    final selected =
        providers.any((provider) => provider.ruleId == _state.ruleId)
        ? _state.ruleId
        : null;
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        title: Text(widget.kind.label),
        actions: [
          IconButton(
            tooltip: '搜索${widget.kind.label}',
            icon: const Icon(Icons.search),
            onPressed: _verifying
                ? null
                : () => context.pushNamed(
                    '/media/search',
                    arguments: MediaSearchArgs(
                      kind: widget.kind,
                      ruleId: selected,
                    ),
                  ),
          ),
          IconButton(
            tooltip: '刷新目录',
            icon: const Icon(Icons.refresh),
            onPressed: _verifying ? null : () => _load(reset: true),
          ),
          IconButton(
            tooltip: '规则管理',
            onPressed: _verifying ? null : _manageSources,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.hub_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: PlatformEnvironmentService.isTelevision
                      ? TvSelect<String>(
                          label: '来源',
                          value: selected ?? '',
                          options: [
                            for (final provider in providers)
                              (provider.ruleId, provider.plugin.name),
                          ],
                          onChanged: _verifying || providers.isEmpty
                              ? null
                              : _selectSource,
                        )
                      : DropdownButton<String>(
                          value: selected,
                          isExpanded: true,
                          hint: const Text('选择来源'),
                          items: providers
                              .map(
                                (provider) => DropdownMenuItem(
                                  value: provider.ruleId,
                                  child: Text(
                                    provider.plugin.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: _verifying ? null : _selectSource,
                        ),
                ),
                if (_state.categories.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: PlatformEnvironmentService.isTelevision
                        ? TvSelect<String>(
                            label: '分类',
                            value: _state.categoryId ?? '',
                            options: [
                              ('', '默认推荐'),
                              for (final category in _state.categories)
                                (category.id, category.name),
                            ],
                            onChanged: _verifying
                                ? null
                                : (value) => _selectCategory(
                                    value.isEmpty ? null : value,
                                  ),
                          )
                        : DropdownButton<String>(
                            value: _state.categoryId,
                            isExpanded: true,
                            hint: const Text('默认推荐'),
                            items: [
                              const DropdownMenuItem<String>(
                                value: null,
                                child: Text('默认推荐'),
                              ),
                              ..._state.categories.map(
                                (category) => DropdownMenuItem(
                                  value: category.id,
                                  child: Text(
                                    category.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: _verifying ? null : _selectCategory,
                          ),
                  ),
                ],
              ],
            ),
          ),
          if (_state.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  void _selectCategory(String? value) {
    setState(() => _state.categoryId = value);
    unawaited(
      _library.setPreference('${widget.kind.name}.category', value ?? ''),
    );
    unawaited(_load(reset: true));
  }

  Widget _footer() {
    if (_state.failure != null) {
      return MediaFailureNotice(
        failure: _state.failure!,
        onRetry: () => _load(),
        onVerify: _verifying ? null : _verify,
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_state.notice != null)
            Text(_state.notice!, textAlign: TextAlign.center),
          if (_state.hasMore)
            TextButton(
              onPressed: _state.loading ? null : () => _load(),
              child: Text(_state.automaticPaused ? '手动加载下一页' : '加载更多'),
            )
          else if (_state.notice == null)
            const Text('已经到底了'),
        ],
      ),
    );
  }

  Widget _results() {
    if (_state.items.isEmpty) {
      if (_state.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_state.failure != null || (_state.page > 0 && _state.hasMore)) {
        return Center(child: _footer());
      }
      return const MediaMessage(message: '当前来源没有符合条件的内容。');
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: CustomScrollView(
        scrollCacheExtent: PlatformEnvironmentService.isTelevision
            ? const ScrollCacheExtent.pixels(700)
            : null,
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverLayoutBuilder(
              builder: (context, constraints) {
                final columns = (constraints.crossAxisExtent / 175)
                    .floor()
                    .clamp(2, 7);
                return SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 12,
                    mainAxisExtent:
                        (constraints.crossAxisExtent - (columns - 1) * 12) /
                            columns *
                            1.45 +
                        80,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) =>
                        SourceMediaCard(media: _state.items[index]),
                    childCount: _state.items.length,
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(child: _footer()),
        ],
      ),
    );
  }
}
