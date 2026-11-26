import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/plugin/captcha_verification_service.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/theme/kazumi_theme_tokens.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:url_launcher/url_launcher.dart';

part 'source_alias_dialog.dart';
part 'source_captcha_flow.dart';
part 'source_sheet_view.dart';

class SourceSheet extends StatefulWidget {
  const SourceSheet({super.key, required this.infoController});

  final InfoController infoController;

  @override
  State<SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<SourceSheet> with KazumiDialogOwner {
  final CollectController _collectController = inject<CollectController>();
  final PluginsController _pluginsController = inject<PluginsController>();
  final Map<String, String> _sourceKeywords = {};

  late final String _keyword;
  late final PluginSearchService _searchService;
  late final _SourceCaptchaFlow _captchaFlow;

  @override
  void initState() {
    super.initState();
    final item = widget.infoController.bangumiItem;
    _keyword = item.nameCn.isEmpty ? item.name : item.nameCn;
    _searchService = PluginSearchService(
      infoController: widget.infoController,
      pluginsController: _pluginsController,
    );
    _captchaFlow = _SourceCaptchaFlow(
      onVerified: _showVerifiedResult,
      onCancelled: (plugin) => _retry(plugin.name),
    );
    _searchService.queryAllSource(_keyword);
  }

  @override
  void dispose() {
    _searchService.cancel();
    _captchaFlow.dispose();
    super.dispose();
  }

  String _keywordFor(String name) => _sourceKeywords[name] ?? _keyword;

  Plugin _pluginFor(String name) =>
      _pluginsController.pluginList.firstWhere((plugin) => plugin.name == name);

  void _querySource(String keyword, String pluginName) {
    final trimmed = keyword.trim();
    if (!mounted || trimmed.isEmpty) return;
    setState(() => _sourceKeywords[pluginName] = trimmed);
    _searchService.querySource(trimmed, pluginName);
  }

  void _retry(String name) => _querySource(_keywordFor(name), name);

  void _showVerifiedResult(Plugin plugin, String pageHtml) {
    if (!mounted) return;
    if (_searchService.applyHarvestedSearchResult(plugin.name, pageHtml)) {
      KazumiDialog.showToast(message: '验证成功');
      return;
    }
    _captchaFlow.showSuccess(
      plugin.name,
      onComplete: () => _retry(plugin.name),
    );
  }

  Future<void> _openInBrowser(String name) async {
    final plugin = _pluginFor(name);
    final targetUrl = plugin.usesApiSearch
        ? plugin.baseUrl
        : plugin.searchURL.replaceAll(
            '@keyword',
            Uri.encodeQueryComponent(_keywordFor(name)),
          );
    try {
      if (await launchUrl(
        Uri.parse(targetUrl),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (error) {
      KazumiLogger().w('SourceSheet: failed to open browser', error: error);
    }
    if (mounted) KazumiDialog.showToast(message: '无法打开浏览器，请稍后重试');
  }

  List<AnimeSourceCandidate> _collectAlternateSources(
    Plugin selectedPlugin,
    SearchItem selectedItem,
  ) {
    final targetNorm = MediaTextNormalizer.normalizeTitleForMatching(
      selectedItem.name.isNotEmpty ? selectedItem.name : _keyword,
    );
    final selectedIdentity = SourceHealthRepository.pluginIdentityKey(
      selectedPlugin,
    );
    final seenPluginIds = <String>{selectedIdentity};
    final alternates = <AnimeSourceCandidate>[];

    for (final response in widget.infoController.pluginSearchResponseList) {
      if (response.data.isEmpty) continue;
      final plugin = _pluginsController.pluginList
          .where(
            (p) =>
                p.name == response.pluginName &&
                p.enabled &&
                p.supportedMediaTypes.contains('anime'),
          )
          .firstOrNull;
      if (plugin == null) continue;
      final identity = SourceHealthRepository.pluginIdentityKey(plugin);
      if (!seenPluginIds.add(identity)) continue;

      SearchItem best = response.data.first;
      for (final item in response.data) {
        final norm = MediaTextNormalizer.normalizeTitleForMatching(item.name);
        if (norm == targetNorm) {
          best = item;
          break;
        }
        if (targetNorm.isNotEmpty &&
            (norm.contains(targetNorm) || targetNorm.contains(norm))) {
          best = item;
        }
      }
      alternates.add(
        AnimeSourceCandidate(
          plugin: plugin,
          title: best.name,
          src: best.src,
        ),
      );
    }

    alternates.sort((a, b) {
      final scoreB = SourceScoringEngine.instance.scorePlugin(
        b.plugin,
        MediaKind.anime,
      );
      final scoreA = SourceScoringEngine.instance.scorePlugin(
        a.plugin,
        MediaKind.anime,
      );
      return scoreB.compareTo(scoreA);
    });
    return alternates;
  }

  Future<void> _openSearchItem(String name, SearchItem searchItem) async {
    if (dialogs.isRunning) return;
    final plugin = _pluginFor(name);
    await dialogs.run(
      (task) async {
        final cancelToken = RuleCancelToken();
        final roads = await task.loading(
          message: '正在获取播放列表',
          barrierDismissible: isDesktop(),
          onCancel: cancelToken.cancel,
          action: () => plugin.queryChapterRoads(
            searchItem.src,
            cancelToken: cancelToken,
          ),
        );
        if (roads.isEmpty) throw ChapterErrorException(plugin.name);
        final alternates = _collectAlternateSources(plugin, searchItem);
        task.withContext(
          (context) => context.pushNamed(
            '/video/',
            arguments: OnlineVideoPlaybackArgs(
              bangumiItem: widget.infoController.bangumiItem,
              plugin: plugin,
              title: searchItem.name,
              src: searchItem.src,
              roads: roads,
              alternateSources: alternates,
            ),
          ),
        );
      },
      onError: (error, stackTrace) {
        KazumiLogger().w('SourceSheet: failed to query playlist', error: error);
        KazumiDialog.showToast(message: '未能获取播放列表，请重试或选择其他结果');
      },
    );
  }

  void _showAliasPicker(String pluginName) {
    if (widget.infoController.bangumiItem.alias.isEmpty) {
      KazumiDialog.showToast(message: '无可用别名，试试修改检索关键词');
      return;
    }
    _showAliasPickerDialog(
      sourceName: pluginName,
      aliases: widget.infoController.bangumiItem.alias,
      onAliasSelected: (alias) => _querySource(alias, pluginName),
      onAliasesChanged: () => _collectController.updateLocalCollect(
        widget.infoController.bangumiItem,
      ),
    );
  }

  void _showCustomKeyword(String pluginName) => _showCustomKeywordDialog(
    initialKeyword: _keywordFor(pluginName),
    sourceName: pluginName,
    onSubmit: (keyword) {
      final item = widget.infoController.bangumiItem;
      if (!item.alias.contains(keyword)) {
        item.alias.add(keyword);
        _collectController.updateLocalCollect(item);
      }
      _querySource(keyword, pluginName);
    },
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: SourceHealthRepository.instance,
    builder: (context, _) => Observer(
      builder: (context) {
        // 仅展示已启用且支持动漫的规则，并按跨频道共享实测健康评分降序排列。
        final healthRepo = SourceHealthRepository.instance;
        final scoring = SourceScoringEngine.instance;
        final animePlugins = _pluginsController.pluginList
            .where((p) => p.enabled && p.supportedMediaTypes.contains('anime'))
            .toList()
          ..sort((a, b) {
            final scoreB = scoring.scorePlugin(b, MediaKind.anime);
            final scoreA = scoring.scorePlugin(a, MediaKind.anime);
            return scoreB.compareTo(scoreA);
          });

        final now = DateTime.now();
        final groupsByName = {
          for (final plugin in animePlugins)
            plugin.name: () {
              final identityKey = SourceHealthRepository.pluginIdentityKey(
                plugin,
              );
              final health = healthRepo.bestAvailableHealthFor(
                identityKey,
                MediaKind.anime,
              );
              return _SourceSearchGroup(
                name: plugin.name,
                keyword: _keywordFor(plugin.name),
                status:
                    widget.infoController.pluginSearchStatus[plugin.name] ??
                    PluginSearchStatus.pending,
                results: <SearchItem>[],
                verifiedBadge:
                    health?.lastVerifiedProfile?.isUiVerified == true
                    ? health!.lastVerifiedProfile!.uiBadgeText
                    : '',
                ttfbMs: health?.ewmaTtfbMs?.round(),
                isCircuitOpen: health != null && health.isCircuitOpen(now),
              );
            }(),
        };
        final seenBySource = <String, Set<String>>{};
        String? firstResultSource;
        for (final response in widget.infoController.pluginSearchResponseList) {
          final group = groupsByName[response.pluginName];
          if (group == null) continue;
          final seen = seenBySource.putIfAbsent(group.name, () => <String>{});
          for (final result in response.data) {
            if (seen.add(result.src)) group.results.add(result);
          }
          if (group.hasResults) firstResultSource ??= group.name;
        }
        return _SourceSheetView(
          keyword: _keyword,
          groups: groupsByName.values.toList(),
          firstResultSource: firstResultSource,
          onSourceSearch: _showCustomKeyword,
          onSourceAliasSearch: _showAliasPicker,
          onRetry: _retry,
          onVerify: (name) =>
              _captchaFlow.start(_pluginFor(name), _keywordFor(name)),
          onOpenBrowser: _openInBrowser,
          onPlay: _openSearchItem,
          onClose: () => Navigator.of(context).pop(),
        );
      },
    ),
  );
}
