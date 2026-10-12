import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';

class SourceDetailPage extends StatefulWidget {
  const SourceDetailPage({super.key, required this.media});
  final MediaSummary media;

  @override
  State<SourceDetailPage> createState() => _SourceDetailPageState();
}

class _SourceDetailPageState extends State<SourceDetailPage> {
  final _catalog = inject<MediaCatalogService>();
  final _library = SourceMediaLibrary.instance;
  MediaDetail? _detail;
  SourcePlaylist? _playlist;
  MediaSeason? _season;
  int _roadIndex = 0;
  int _generation = 0;
  CancelToken? _cancel;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  MediaSummary get _media => _detail?.summary ?? widget.media;
  MediaProvider? get _provider =>
      _catalog.providerById(widget.media.ref.ruleId);

  @override
  void initState() {
    super.initState();
    unawaited(_loadDetail());
  }

  Future<void> _loadDetail() async {
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _playlist = null;
    });
    final provider = _provider;
    if (provider == null) {
      setState(() {
        _loading = false;
        _error = '此来源已停用或移除。已保留片单和历史中的资料，可在规则管理中恢复来源。';
      });
      return;
    }
    try {
      final detail = await provider.queryDetail(
        widget.media,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      final history = _library.historyFor(widget.media.ref);
      MediaSeason? season;
      for (final item in detail.seasons) {
        if (item.id == (_season?.id ?? history?.seasonId)) season = item;
      }
      season ??= detail.seasons.isEmpty ? null : detail.seasons.first;
      setState(() {
        _detail = detail;
        _season = season;
      });
      final playlist = await provider.queryPlaylist(
        detail.summary,
        season: season,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      _setPlaylist(playlist);
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      setState(() => _error = '无法获取来源资料或播放列表，请重试。已保存的资料仍然保留。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  void _setPlaylist(SourcePlaylist playlist) {
    final history = _library.historyFor(widget.media.ref);
    final road = playlist.roads.indexWhere(
      (item) => item.id == history?.roadId,
    );
    setState(() {
      _playlist = SourcePlaylist(
        roads: playlist.roads,
        season: playlist.season ?? _season,
      );
      _roadIndex = road < 0 ? 0 : road;
    });
  }

  Future<void> _selectSeason(MediaSeason season) async {
    if (_season?.id == season.id) return;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    final generation = ++_generation;
    setState(() {
      _season = season;
      _loading = true;
      _playlist = null;
      _error = null;
    });
    try {
      final provider = _provider;
      if (provider == null) throw StateError('来源不可用');
      final playlist = await provider.queryPlaylist(
        _media,
        season: season,
        cancelToken: token,
      );
      if (!mounted || generation != _generation) return;
      _setPlaylist(playlist);
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          (error is DioException && CancelToken.isCancel(error))) {
        return;
      }
      setState(() => _error = '本季播放列表暂时不可用，请重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  /// 续播按来源、线路及剧集稳定标识匹配，不按列表下标猜测。
  (int, int)? _resumePosition() {
    final playlist = _playlist;
    final history = _library.historyFor(widget.media.ref);
    if (playlist == null || history == null) return null;
    if (history.seasonId != null &&
        history.seasonId != (_season?.id ?? playlist.season?.id)) {
      return null;
    }
    for (var roadIndex = 0; roadIndex < playlist.roads.length; roadIndex++) {
      final road = playlist.roads[roadIndex];
      if (road.id != history.roadId) continue;
      final episode = road.episodes.indexWhere(
        (item) => item.id == history.episodeId,
      );
      if (episode >= 0) return (roadIndex, episode);
    }
    return null;
  }

  Future<void> _play(int roadIndex, int episodeIndex) async {
    final playlist = _playlist;
    if (playlist == null || _provider == null) {
      KazumiDialog.showToast(message: '来源已停用或移除，请恢复来源后再播放。');
      return;
    }
    await context.pushNamed(
      '/media/play',
      arguments: PlaybackContext(
        media: _media,
        playlist: playlist,
        roadIndex: roadIndex,
        episodeIndex: episodeIndex,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _setCollection(CollectType status) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (status == CollectType.none) {
        await _library.removeCollection(_media.ref);
      } else {
        await _library.setCollection(_media, status: status.value);
      }
    } catch (_) {
      KazumiDialog.showToast(message: '保存片单失败，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    ++_generation;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: SysAppBar(
      title: Text(_media.title, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
    body: AnimatedBuilder(
      animation: _library,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1040),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(),
                  const SizedBox(height: 24),
                  if (_loading) const LinearProgressIndicator(),
                  if (_error != null)
                    MediaMessage(message: _error!, onRetry: _loadDetail),
                  if (_detail != null) ...[
                    if (_detail!.description.isNotEmpty) ...[
                      Text(
                        '剧情简介',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      if (PlatformEnvironmentService.isTelevision)
                        Text(
                          html.parseFragment(_detail!.description).text ?? '',
                        )
                      else
                        SelectableText(
                          html.parseFragment(_detail!.description).text ?? '',
                        ),
                      const SizedBox(height: 20),
                    ],
                    if (_detail!.castText.isNotEmpty) ...[
                      Text(
                        '演职员',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(_detail!.castText),
                      const SizedBox(height: 20),
                    ],
                    if (_detail!.seasons.isNotEmpty) ...[
                      Text(
                        '选择季',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final season in _detail!.seasons)
                            TvFocusFrame(
                              child: ChoiceChip(
                                label: Text(season.name),
                                selected: season.id == _season?.id,
                                onSelected: (_) => _selectSeason(season),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                  if (_playlist != null) _episodes(),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _header() {
    final collected = _library.isCollected(_media.ref);
    final resume = _resumePosition();
    final history = _library.historyFor(_media.ref);
    var collectionStatus = CollectType.none;
    for (final entry in _library.collections) {
      if (entry.media.ref == _media.ref) {
        collectionStatus = CollectType.fromValue(entry.status);
      }
    }
    final firstPlayableRoad =
        _playlist?.roads.indexWhere((road) => road.episodes.isNotEmpty) ?? -1;
    final info = <String>[
      _media.ref.kind.label,
      _media.year,
      _media.region,
      _media.statusText,
      if (_media.ratingText.isNotEmpty) '来源评分 ${_media.ratingText}',
    ].where((text) => text.isNotEmpty).join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NetworkImgLayer(
          src: _media.posterUrl,
          width: MediaQuery.sizeOf(context).width < 500 ? 100 : 156,
          height: MediaQuery.sizeOf(context).width < 500 ? 148 : 230,
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _media.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(info),
              const SizedBox(height: 6),
              Text(
                '资料与片源：${_media.sourceName}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (PlatformEnvironmentService.isTelevision)
                    TvSelect<CollectType>(
                      label: '片单',
                      value: collectionStatus,
                      options: [
                        for (final status in CollectType.values)
                          (
                            status,
                            status == CollectType.none ? '未收藏' : status.label,
                          ),
                      ],
                      onChanged: _saving ? null : _setCollection,
                    )
                  else
                    PopupMenuButton<CollectType>(
                      enabled: !_saving,
                      tooltip: '设置片单状态',
                      onSelected: _setCollection,
                      itemBuilder: (_) => CollectType.values
                          .map(
                            (status) => PopupMenuItem(
                              value: status,
                              child: Text(
                                status == CollectType.none
                                    ? '移出片单'
                                    : status.label,
                              ),
                            ),
                          )
                          .toList(),
                      child: Chip(
                        avatar: Icon(
                          collected ? Icons.favorite : Icons.favorite_outline,
                          size: 18,
                        ),
                        label: Text(
                          _saving
                              ? '保存中'
                              : collected
                              ? '已加入片单'
                              : '加入片单',
                        ),
                      ),
                    ),
                  if (resume != null ||
                      (PlatformEnvironmentService.isTelevision &&
                          firstPlayableRoad >= 0))
                    FilledButton.icon(
                      autofocus: PlatformEnvironmentService.isTelevision,
                      onPressed: () => _play(
                        resume?.$1 ?? firstPlayableRoad,
                        resume?.$2 ?? 0,
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(resume != null ? '继续观看' : '开始播放'),
                    ),
                ],
              ),
              if (history != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '上次看到 ${history.episodeTitle} · ${_duration(history.positionMs)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (history != null && _playlist != null && resume == null)
                const Text('原观看集数或线路暂不可用，请手动选择播放项。'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _episodes() {
    final roads = _playlist!.roads;
    if (roads.isEmpty) return const MediaMessage(message: '来源暂未提供播放线路。');
    final road = roads[_roadIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _media.ref.kind == MediaKind.movie ? '观看电影' : '选集播放',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        if (PlatformEnvironmentService.isTelevision)
          TvSelect<int>(
            label: '播放线路',
            value: _roadIndex,
            options: [
              for (var index = 0; index < roads.length; index++)
                (
                  index,
                  '${roads[index].name} · ${roads[index].episodes.length} ${_media.ref.kind == MediaKind.movie ? '项' : '集'}',
                ),
            ],
            onChanged: (value) => setState(() => _roadIndex = value),
          )
        else
          DropdownButton<int>(
            value: _roadIndex,
            isExpanded: true,
            items: [
              for (var index = 0; index < roads.length; index++)
                DropdownMenuItem(
                  value: index,
                  child: Text(
                    '${roads[index].name} · 可用 ${roads[index].episodes.length} ${_media.ref.kind == MediaKind.movie ? '项' : '集'}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _roadIndex = value);
            },
          ),
        if (road.episodes.isEmpty) const Text('当前线路没有可用剧集。'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var index = 0; index < road.episodes.length; index++)
              TvFocusFrame(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => _play(_roadIndex, index),
                  child: Text(road.episodes[index].title),
                ),
              ),
          ],
        ),
      ],
    );
  }

  String _duration(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    return '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  }
}
