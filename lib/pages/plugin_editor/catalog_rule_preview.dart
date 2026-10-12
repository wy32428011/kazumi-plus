import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/rule_media_catalog_service.dart';

/// 编辑器预览直接走正式来源接口，避免预览通过而实际频道使用另一套实现。
class CatalogRulePreview extends StatefulWidget {
  const CatalogRulePreview({super.key, required this.plugin});
  final Plugin plugin;

  @override
  State<CatalogRulePreview> createState() => _CatalogRulePreviewState();
}

class _CatalogRulePreviewState extends State<CatalogRulePreview> {
  late final RuleMediaProvider _provider = RuleMediaProvider(widget.plugin);
  late MediaKind _kind = _provider.supportedKinds.first;
  final _keyword = TextEditingController();
  CancelToken? _cancelToken;
  int _generation = 0;
  int _page = 1;
  bool _hasMore = false;
  bool _busy = false;
  String _report = '';

  @override
  void dispose() {
    _cancelToken?.cancel();
    _keyword.dispose();
    super.dispose();
  }

  void _cancel() {
    _generation++;
    _cancelToken?.cancel();
    setState(() => _busy = false);
  }

  Future<void> _preview({int page = 1}) async {
    _cancelToken?.cancel();
    final token = _cancelToken = CancelToken();
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _report = '';
    });
    final report = <String, Object?>{};
    try {
      final categories = await _provider.queryCategories(
        _kind,
        cancelToken: token,
      );
      report['分类'] = [
        for (final category in categories)
          {'id': category.id, 'name': category.name},
      ];
      final keyword = _keyword.text.trim();
      final result = keyword.isEmpty
          ? await _provider.queryDiscover(_kind, page: page, cancelToken: token)
          : await _provider.searchMedia(
              _kind,
              keyword,
              page: page,
              cancelToken: token,
            );
      report['页码'] = result.page;
      report['仍有下一页'] = result.hasMore;
      report['条目数'] = result.items.length;
      report['前五条'] = result.items
          .take(5)
          .map((item) => item.toJson())
          .toList();
      if (result.items.isNotEmpty) {
        final detail = await _provider.queryDetail(
          result.items.first,
          cancelToken: token,
        );
        final playlist = await _provider.queryPlaylist(
          detail.summary,
          cancelToken: token,
        );
        report['详情'] = {
          '作品': detail.summary.toJson(),
          '简介': detail.description,
          '演员': detail.castText,
          '季数': detail.seasons.length,
        };
        report['播放线路'] = [
          for (final road in playlist.roads)
            {
              '名称': road.name,
              '播放项数量': road.episodes.length,
              '首项名称': road.episodes.first.title,
              '首项地址': road.episodes.first.url,
            },
        ];
        report['说明'] = '已验证资料与播放列表解析，尚未打开视频播放器。';
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _page = result.page;
        _hasMore = result.hasMore;
        _report = const JsonEncoder.withIndent('  ').convert(report);
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _report =
            '${const JsonEncoder.withIndent('  ').convert(report)}\n\n预览失败：$error';
        _hasMore = false;
      });
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => RuleSection(
    title: '影视资料预览',
    description: '检查分类、分页、详情和播放列表；填写关键词则预览搜索结果。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final kind in _provider.supportedKinds)
              ChoiceChip(
                label: Text(kind.label),
                selected: kind == _kind,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _kind = kind;
                        _hasMore = false;
                        _page = 1;
                        _report = '';
                      }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _keyword,
          enabled: !_busy,
          decoration: const InputDecoration(labelText: '搜索关键词（留空浏览默认分类）'),
          onChanged: (_) => setState(() => _hasMore = false),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? _cancel : () => _preview(),
              icon: Icon(_busy ? Icons.stop : Icons.preview_outlined),
              label: Text(_busy ? '取消预览' : '预览第一页'),
            ),
            if (_hasMore)
              OutlinedButton(
                onPressed: _busy ? null : () => _preview(page: _page + 1),
                child: const Text('预览下一页'),
              ),
          ],
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          ),
        if (_report.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SelectableText(_report),
          ),
      ],
    ),
  );
}
