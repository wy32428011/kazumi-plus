import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/history/history_list_view.dart';
import 'package:kazumi/pages/history/history_record_tile.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/utils/device.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.controller});

  final HistoryController controller;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  bool _editing = false;
  bool _clearing = false;
  final Set<String> _deleting = {};
  final _sourceLibrary = SourceMediaLibrary.instance;
  MediaKind? _kind;
  String _query = '';

  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  Future<void> _deleteHistory(History history) async {
    if (_clearing || _deleting.contains(history.key)) return;
    setState(() => _deleting.add(history.key));
    try {
      await widget.controller.deleteHistory(history);
      if (mounted &&
          widget.controller.histories.isEmpty &&
          _sourceLibrary.histories.isEmpty) {
        setState(() => _editing = false);
      }
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '删除失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _deleting.remove(history.key));
    }
  }

  Future<void> _clearHistory() async {
    if (_clearing || _deleting.isNotEmpty) return;
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('清空历史记录？'),
        content: Text(
          '将删除全部频道的 ${widget.controller.histories.length + _sourceLibrary.histories.length} 条观看记录，包括动漫在线、缓存及影视记录。此操作无法撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空全部'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      await widget.controller.clearAll();
      for (final history in _sourceLibrary.histories) {
        await _sourceLibrary.removeHistory(history.media.ref);
      }
      if (mounted) setState(() => _editing = false);
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '清空失败，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _sourceLibrary,
      builder: (context, _) => Observer(
        builder: (context) {
          final entries = widget.controller.histories.toList();
          return PopScope(
            canPop: !_editing,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop && _editing) {
                setState(() => _editing = false);
              }
            },
            child: Scaffold(
              appBar: SysAppBar(
                title: Text(
                  '历史记录',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                actions: [
                  if (entries.isNotEmpty ||
                      _sourceLibrary.histories.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _editing
                          ? FilledButton.tonal(
                              onPressed: _clearing
                                  ? null
                                  : () => setState(() => _editing = false),
                              child: const Text('完成'),
                            )
                          : IconButton.filledTonal(
                              tooltip: '管理历史记录',
                              onPressed: () => setState(() => _editing = true),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                    ),
                    if (_editing)
                      IconButton(
                        tooltip: '清空全部历史记录',
                        onPressed: _clearing || _deleting.isNotEmpty
                            ? null
                            : _clearHistory,
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                  ],
                ],
              ),
              body: SafeArea(
                top: false,
                bottom: false,
                child: Column(
                  children: [
                    MediaKindFilter(
                      selected: _kind,
                      onChanged: (kind) => setState(() => _kind = kind),
                    ),
                    Expanded(
                      child: _kind == MediaKind.anime
                          ? HistoryListView(
                              entries: entries,
                              editing: _editing,
                              itemBuilder: (history, borderRadius) =>
                                  _HistoryCard(
                                    history: history,
                                    borderRadius: borderRadius,
                                    editing: _editing,
                                    busy:
                                        _clearing ||
                                        _deleting.contains(history.key),
                                    onDelete: () => _deleteHistory(history),
                                  ),
                            )
                          : _mixedHistory(entries),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _deleteSourceHistory(FoldedSourceHistory folded) async {
    final key = folded.primary.media.ref.key;
    if (_clearing || _deleting.contains(key)) return;
    setState(() => _deleting.add(key));
    try {
      await _sourceLibrary.removeHistoryCluster(folded.linkedRefs);
      if (mounted &&
          widget.controller.histories.isEmpty &&
          _sourceLibrary.histories.isEmpty) {
        setState(() => _editing = false);
      }
    } catch (_) {
      KazumiDialog.showToast(message: '删除影视历史失败，请重试。');
    } finally {
      if (mounted) setState(() => _deleting.remove(key));
    }
  }

  Widget _mixedHistory(List<History> animeEntries) {
    final query = _query.trim().toLowerCase();
    final foldedSources = _sourceLibrary.foldedHistories(kind: _kind);
    final entries = <(DateTime, Object)>[
      if (_kind == null)
        for (final entry in animeEntries)
          if ('${entry.bangumiItem.name} ${entry.bangumiItem.nameCn} ${entry.adapterName}'
              .toLowerCase()
              .contains(query))
            (entry.lastWatchTime, entry),
      for (final folded in foldedSources)
        if ('${folded.primary.media.title} ${folded.primary.media.sourceName}'
            .toLowerCase()
            .contains(query))
          (folded.primary.updatedAt, folded),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: '搜索片名或来源',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const MediaMessage(message: '暂无符合条件的观看记录。')
              : ListView.builder(
                  key: PageStorageKey('mixed-history-${_kind?.name ?? 'all'}'),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index].$2;
                    if (entry is History) {
                      return Padding(
                        key: ValueKey(entry.key),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        child: _HistoryCard(
                          history: entry,
                          onDelete: () => _deleteHistory(entry),
                          editing: _editing,
                          busy: _clearing || _deleting.contains(entry.key),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      );
                    }
                    final folded = entry as FoldedSourceHistory;
                    final source = folded.primary;
                    final position = Duration(milliseconds: source.positionMs);
                    final date = MaterialLocalizations.of(
                      context,
                    ).formatShortDate(source.updatedAt.toLocal());
                    return SourceMediaTile(
                      key: ValueKey(source.media.ref.key),
                      media: source.media,
                      foldedSourceCount: folded.sourceCount,
                      subtitle:
                          '${source.seasonName == null ? '' : '${source.seasonName} · '}${source.episodeTitle}'
                          '\n看到 ${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')} · $date',
                      onTap: _editing || _clearing
                          ? () {}
                          : () => context.pushNamed(
                              '/media/detail',
                              arguments: source.media,
                            ),
                      trailing: _editing
                          ? IconButton(
                              tooltip: '删除记录',
                              icon: const Icon(Icons.delete_outline),
                              onPressed:
                                  _clearing ||
                                      _deleting.contains(source.media.ref.key)
                                  ? null
                                  : () => _deleteSourceHistory(folded),
                            )
                          : PopupMenuButton<String>(
                              tooltip: '记录操作',
                              onSelected: (value) {
                                if (value == 'delete') {
                                  _deleteSourceHistory(folded);
                                } else {
                                  context.pushNamed(
                                    '/media/detail',
                                    arguments: source.media,
                                  );
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'detail',
                                  child: Text('详情与继续观看'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除记录'),
                                ),
                              ],
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _HistoryCard extends StatefulWidget {
  const _HistoryCard({
    required this.history,
    required this.onDelete,
    required this.editing,
    required this.busy,
    required this.borderRadius,
  });

  final History history;
  final bool editing;
  final bool busy;
  final Future<void> Function() onDelete;
  final BorderRadius borderRadius;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> with KazumiDialogOwner {
  final CollectController _collectController = inject<CollectController>();
  final HistoryPlaybackService _playbackService =
      inject<HistoryPlaybackService>();
  bool _updatingCollect = false;

  Future<void> _play() async {
    if (widget.editing || widget.busy || dialogs.isRunning) return;
    await dialogs.run((task) async {
      final cancelToken = RuleCancelToken();
      final result = await task.loading(
        message: '获取中',
        barrierDismissible: isDesktop(),
        onCancel: cancelToken.cancel,
        action: () =>
            _playbackService.open(widget.history, cancelToken: cancelToken),
      );
      switch (result) {
        case HistoryPlaybackReady(:final args):
          task.withContext(
            (context) => context.pushNamed('/video/', arguments: args),
          );
        case HistoryPlaybackUnavailable(:final reason):
          KazumiDialog.showToast(message: reason);
      }
    }, errorMessage: '暂时无法继续播放，请稍后重试');
  }

  Future<void> _changeCollect(CollectType type) async {
    if (_updatingCollect) return;
    setState(() => _updatingCollect = true);
    try {
      await _collectController.addCollect(
        widget.history.bangumiItem,
        type: type.value,
      );
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _updatingCollect = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        // getCollectType reads storage, so track the observable list explicitly.
        _collectController.collectibles.length;
        return HistoryRecordTile(
          history: widget.history,
          borderRadius: widget.borderRadius,
          editing: widget.editing,
          busy: widget.busy,
          onPlay: _play,
          onDelete: widget.onDelete,
          onDetails: () => context.pushNamed(
            '/info/',
            arguments: widget.history.bangumiItem,
          ),
          collectType: CollectType.fromValue(
            _collectController.getCollectType(widget.history.bangumiItem),
          ),
          onChangeCollect: _updatingCollect ? null : _changeCollect,
        );
      },
    );
  }
}
