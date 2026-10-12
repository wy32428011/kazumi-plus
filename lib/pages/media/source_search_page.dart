import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/media/media_captcha_dialog.dart';
import 'package:kazumi/pages/media/media_request_state.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

class _SearchGroup extends MediaResultState {
  _SearchGroup({required this.ruleId, required this.name});
  final String ruleId;
  final String name;
  MediaCaptchaRequest? captchaRequest;
  bool started = false;
}

/// 聚合搜索保留来源边界；同名作品在不同来源下独立展示和保存。
class SourceSearchPage extends StatefulWidget {
  const SourceSearchPage({super.key, required this.args});
  final MediaSearchArgs args;

  @override
  State<SourceSearchPage> createState() => _SourceSearchPageState();
}

class _SourceSearchPageState extends State<SourceSearchPage> {
  static const _allSources = '';
  final _catalog = inject<MediaCatalogService>();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, _SearchGroup> _groups = {};
  String _selected = _allSources;
  String _keyword = '';
  CancelToken _cancel = CancelToken();
  int _generation = 0;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    final providers = _catalog.providersFor(widget.args.kind);
    _selected =
        providers.any((provider) => provider.ruleId == widget.args.ruleId)
        ? widget.args.ruleId!
        : (providers.isEmpty ? _allSources : providers.first.ruleId);
  }

  Future<void> _search() async {
    final keyword = _input.text.trim();
    if (keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    _cancel.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;
    final providers = _catalog
        .providersFor(widget.args.kind)
        .where(
          (provider) =>
              _selected == _allSources || provider.ruleId == _selected,
        )
        .toList();
    setState(() {
      _keyword = keyword;
      _groups.clear();
      for (final provider in providers) {
        _groups[provider.ruleId] = _SearchGroup(
          ruleId: provider.ruleId,
          name: provider.plugin.name,
        );
      }
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    // 限定并发数，单源超时或验证码不阻塞其他来源返回。
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < providers.length &&
          mounted &&
          generation == _generation) {
        final group = _groups[providers[cursor++].ruleId];
        if (group != null && !group.started) {
          await _loadGroup(group, generation: generation, token: token);
        }
      }
    }

    await Future.wait(
      List.generate(providers.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> _loadGroup(
    _SearchGroup group, {
    int? generation,
    CancelToken? token,
  }) async {
    generation ??= _generation;
    token ??= _cancel;
    if (group.loading || !group.hasMore || token.isCancelled) return;
    final provider = _catalog.providerById(group.ruleId);
    final channel = provider?.plugin.catalog?.channels[widget.args.kind.name];
    if (provider == null || channel == null) {
      setState(
        () => group.failure = const MediaRequestFailure('此来源已停用或移除，请选择其他来源。'),
      );
      return;
    }
    final keyword = _keyword;
    final nextPage = group.page + 1;
    group.captchaRequest = MediaCaptchaRequest(
      plugin: provider.plugin,
      operation: channel.search,
      label: '搜索第 $nextPage 页',
      variables: {
        'source': '',
        'seasonId': '',
        'keyword': keyword,
        'page': nextPage,
        'categoryId': channel.defaultCategoryId,
        'mediaType': widget.args.kind.name,
      },
    );
    setState(() {
      group.started = true;
      group.loading = true;
      group.failure = null;
    });
    try {
      final page = await provider.searchMedia(
        widget.args.kind,
        keyword,
        page: nextPage,
        cancelToken: token,
      );
      if (!mounted || generation != _generation || token.isCancelled) return;
      setState(() => group.applyPage(page, automatic: false));
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          token.isCancelled ||
          mediaRequestCancelled(error)) {
        return;
      }
      setState(() => group.failure = describeMediaFailure(error));
    } finally {
      if (mounted && generation == _generation) {
        setState(() => group.loading = false);
      }
    }
  }

  Future<void> _verify(_SearchGroup group) async {
    final request = group.captchaRequest;
    if (_verifying || request == null) return;
    final generation = _generation;
    setState(() => _verifying = true);
    try {
      final verified = await verifyMediaCaptcha(context, request);
      if (verified && mounted && generation == _generation) {
        await _loadGroup(group);
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => group.failure = describeMediaFailure(error));
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
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
    final providers = _catalog.providersFor(widget.args.kind);
    final selected =
        _selected == _allSources ||
            providers.any((provider) => provider.ruleId == _selected)
        ? _selected
        : null;
    return Scaffold(
      appBar: SysAppBar(title: Text('${widget.args.kind.label}搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: PlatformEnvironmentService.isTelevision
                ? TvSelect<String>(
                    label: '搜索来源',
                    value: selected ?? _allSources,
                    options: [
                      (_allSources, '全部来源 · 分组搜索'),
                      for (final provider in providers)
                        (provider.ruleId, provider.plugin.name),
                    ],
                    onChanged: _verifying ? null : _changeSource,
                  )
                : DropdownButton<String>(
                    value: selected,
                    isExpanded: true,
                    hint: const Text('原来源已不可用，请重新选择'),
                    items: [
                      const DropdownMenuItem(
                        value: _allSources,
                        child: Text('全部来源 · 分组搜索'),
                      ),
                      for (final provider in providers)
                        DropdownMenuItem(
                          value: provider.ruleId,
                          child: Text(
                            provider.plugin.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _verifying ? null : _changeSource,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: PlatformEnvironmentService.isTelevision
                ? TvSearchBox(
                    controller: _input,
                    hint: '搜索${widget.args.kind.label}名称',
                    autofocus: true,
                    enabled: !_verifying,
                    onSubmitted: (_) => unawaited(_search()),
                  )
                : TextField(
                    controller: _input,
                    autofocus: true,
                    enabled: !_verifying,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '搜索${widget.args.kind.label}名称',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        tooltip: '搜索',
                        icon: const Icon(Icons.search),
                        onPressed: _verifying ? null : _search,
                      ),
                    ),
                  ),
          ),
          if (_groups.values.any((group) => group.loading))
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _groups.isEmpty
                ? MediaMessage(
                    message: providers.isEmpty
                        ? '没有启用的当前频道来源，请先导入或启用影视规则。'
                        : _keyword.isEmpty
                        ? '输入片名，可选择全部来源分别查找。'
                        : '没有可用的选定来源。',
                  )
                : CustomScrollView(
                    scrollCacheExtent: PlatformEnvironmentService.isTelevision
                        ? const ScrollCacheExtent.pixels(700)
                        : null,
                    controller: _scroll,
                    slivers: [
                      for (final group in _groups.values) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                            child: Row(
                              children: [
                                const Icon(Icons.hub_outlined, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    group.name,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                Text('${group.items.length} 部'),
                              ],
                            ),
                          ),
                        ),
                        if (group.items.isNotEmpty) _grid(group),
                        SliverToBoxAdapter(child: _groupFooter(group)),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  void _changeSource(String? value) {
    if (value == null || value == _selected) return;
    _cancel.cancel();
    ++_generation;
    setState(() {
      _selected = value;
      _groups.clear();
    });
    if (_input.text.trim().isNotEmpty) unawaited(_search());
  }

  Widget _groupFooter(_SearchGroup group) {
    if (group.loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (group.failure != null) {
      return MediaFailureNotice(
        failure: group.failure!,
        onRetry: () => _loadGroup(group),
        onVerify: _verifying ? null : () => _verify(group),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (group.notice != null)
            Text(group.notice!, textAlign: TextAlign.center)
          else if (group.items.isEmpty)
            Text(group.page == 0 ? '等待搜索' : '此来源暂无符合频道的结果。'),
          if (group.hasMore)
            TextButton(
              onPressed: () => _loadGroup(group),
              child: Text('仅加载 ${group.name} 的下一页'),
            ),
        ],
      ),
    );
  }

  Widget _grid(_SearchGroup group) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = (constraints.crossAxisExtent / 175).floor().clamp(2, 7);
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
            (context, index) => SourceMediaCard(media: group.items[index]),
            childCount: group.items.length,
          ),
        );
      },
    ),
  );
}
