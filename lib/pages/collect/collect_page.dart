import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/bangumi/sync_priority.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/media_widgets.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/modules/collect/collect_sync_plan.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/pages/collect/collect_sync_dialog.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_focus.dart';

class CollectPage extends StatefulWidget {
  const CollectPage({super.key, required this.controller});

  final CollectController controller;

  @override
  State<CollectPage> createState() => _CollectPageState();
}

class _CollectPageState extends State<CollectPage> with KazumiDialogOwner {
  CollectController get collectController => widget.controller;
  bool get _syncDialogOpen => dialogs.isRunning;
  final Set<int> _pendingIds = {};
  late CollectLayout _layout;
  final _sourceLibrary = SourceMediaLibrary.instance;
  final Set<String> _pendingSourceIds = {};
  MediaKind? _kind;
  CollectType? _status;
  String _query = '';

  Future<bool> _syncStep(
    CollectSyncStep step, {
    required ValueChanged<String> onError,
    required void Function(String message, int current, int total) onProgress,
  }) => switch (step) {
    CollectSyncStep.webDav => collectController.syncCollectibles(
      onError: onError,
    ),
    CollectSyncStep.bangumi => collectController.syncCollectiblesBangumi(
      onError: onError,
      onProgress: onProgress,
    ),
    CollectSyncStep.upload => collectController.uploadCollectiblesToWebDav(
      onError: onError,
    ),
  };

  @override
  void initState() {
    super.initState();
    // Read once; page switches never change the saved default.
    _layout = CollectLayout.fromValue(
      GStorage.getSetting(SettingsKeys.defaultCollectLayout),
    );
    collectController.loadCollectibles();
  }

  void _changeLayout(CollectLayout layout) {
    if (_layout == layout) return;
    setState(() => _layout = layout);
  }

  Future<void> _changeType(BangumiItem item, CollectType type) async {
    if (_syncDialogOpen || _pendingIds.contains(item.id)) return;
    setState(() => _pendingIds.add(item.id));
    try {
      await collectController.addCollect(item, type: type.value);
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _pendingIds.remove(item.id));
    }
  }

  Future<void> _sync() async {
    if (_syncDialogOpen || _pendingIds.isNotEmpty) return;
    final plan = CollectSyncPlan(
      webDavEnabled: GStorage.getSetting(SettingsKeys.webDavEnable),
      webDavCollectiblesEnabled: GStorage.getSetting(
        SettingsKeys.webDavEnableCollect,
      ),
      bangumiEnabled: GStorage.getSetting(SettingsKeys.bangumiSyncEnable),
    );
    await dialogs.run((task) async {
      final destination = await task.show<CollectSyncDestination>(
        builder: (_) => CollectSyncDialog(
          plan: plan,
          priority: BangumiSyncPriority.fromValue(
            GStorage.getSetting(SettingsKeys.bangumiSyncPriority),
          ),
          onSync: _syncStep,
        ),
      );
      task.withContext(
        (context) => context.pushNamed(switch (destination) {
          CollectSyncDestination.webDavSettings => '/settings/webdav/',
          CollectSyncDestination.bangumiSettings => '/settings/bangumi/',
        }),
      );
    }, errorMessage: '同步未完成，请稍后重试');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        toolbarHeight: 72,
        title: Text(
          '片单',
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: '同步动漫收藏；影视片单保存在本机',
              child: StateActionButton.tonal(
                text: '同步动漫',
                onPressed: _syncDialogOpen || _pendingIds.isNotEmpty
                    ? null
                    : _sync,
                icon: Icons.sync_rounded,
              ),
            ),
          ),
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
                  ? Observer(
                      builder: (context) => CollectLibraryView(
                        entries: collectController.collectibles.toList(),
                        showRating: GStorage.getSetting(
                          SettingsKeys.showRating,
                        ),
                        layout: _layout,
                        onLayoutChanged: _changeLayout,
                        canEdit: (item) =>
                            !_syncDialogOpen && !_pendingIds.contains(item.id),
                        onOpen: (item) =>
                            context.pushNamed('/info/', arguments: item),
                        onChangeType: (item, type) =>
                            unawaited(_changeType(item, type)),
                      ),
                    )
                  : AnimatedBuilder(
                      animation: _sourceLibrary,
                      builder: (context, _) =>
                          Observer(builder: (_) => _mixedLibrary()),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeSourceStatus(
    SourceCollection entry,
    CollectType status,
  ) async {
    final key = entry.media.ref.key;
    if (_pendingSourceIds.contains(key)) return;
    setState(() => _pendingSourceIds.add(key));
    try {
      if (status == CollectType.none) {
        await _sourceLibrary.removeCollection(entry.media.ref);
      } else {
        await _sourceLibrary.setCollection(entry.media, status: status.value);
      }
    } catch (_) {
      KazumiDialog.showToast(message: '修改影视片单失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => _pendingSourceIds.remove(key));
    }
  }

  Widget _mixedLibrary() {
    // 跨频道按最近收藏时间排序，动漫记录仍调用原控制器修改和删除。
    final query = _query.trim().toLowerCase();
    final animeEntries = collectController.collectibles.toList();
    final entries = <(DateTime, Object)>[
      if (_kind == null)
        for (final entry in animeEntries)
          if ((_status == null || entry.type == _status!.value) &&
              ('${entry.bangumiItem.nameCn} ${entry.bangumiItem.name}'
                  .toLowerCase()
                  .contains(query)))
            (entry.time, entry),
      for (final entry in _sourceLibrary.collections)
        if ((_kind == null || entry.media.ref.kind == _kind) &&
            (_status == null || entry.status == _status!.value) &&
            ('${entry.media.title} ${entry.media.sourceName}'
                .toLowerCase()
                .contains(query)))
          (entry.updatedAt, entry),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    hintText: '搜索片单',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              DropdownButton<CollectType>(
                value: _status,
                hint: const Text('全部状态'),
                items: [
                  const DropdownMenuItem<CollectType>(
                    value: null,
                    child: Text('全部状态'),
                  ),
                  for (final status in CollectType.values.where(
                    (status) => status.isCollected,
                  ))
                    DropdownMenuItem(value: status, child: Text(status.label)),
                ],
                onChanged: (value) => setState(() => _status = value),
              ),
            ],
          ),
        ),
        Expanded(
          child: entries.isEmpty
              ? const MediaMessage(message: '片单中暂无符合条件的作品。')
              : ListView.builder(
                  key: PageStorageKey(
                    'mixed-collection-${_kind?.name ?? 'all'}',
                  ),
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index].$2;
                    if (entry is SourceCollection) {
                      return SourceMediaTile(
                        key: ValueKey(entry.media.ref.key),
                        media: entry.media,
                        subtitle: CollectType.fromValue(entry.status).label,
                        trailing: PopupMenuButton<CollectType>(
                          tooltip: '修改片单状态',
                          enabled: !_pendingSourceIds.contains(
                            entry.media.ref.key,
                          ),
                          onSelected: (status) =>
                              _changeSourceStatus(entry, status),
                          itemBuilder: (_) => _statusMenu(),
                        ),
                      );
                    }
                    final anime = entry as CollectedBangumi;
                    final item = anime.bangumiItem;
                    return Card(
                      key: ValueKey('bangumi-${item.id}'),
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: TvFocusFrame(
                        radius: 16,
                        child: ListTile(
                          contentPadding: const EdgeInsets.all(12),
                          leading: NetworkImgLayer(
                            src: item.images['large'],
                            width: 46,
                            height: 68,
                          ),
                          title: Text(
                            item.nameCn.isEmpty ? item.name : item.nameCn,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '动漫 · ${CollectType.fromValue(anime.type).label}',
                          ),
                          onTap: () =>
                              context.pushNamed('/info/', arguments: item),
                          trailing: PopupMenuButton<CollectType>(
                            tooltip: '修改片单状态',
                            enabled:
                                !_syncDialogOpen &&
                                !_pendingIds.contains(item.id),
                            onSelected: (status) => _changeType(item, status),
                            itemBuilder: (_) => _statusMenu(),
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

  List<PopupMenuEntry<CollectType>> _statusMenu() => [
    for (final status in CollectType.values)
      PopupMenuItem(
        value: status,
        child: Text(status == CollectType.none ? '移出片单' : status.label),
      ),
  ];
}
