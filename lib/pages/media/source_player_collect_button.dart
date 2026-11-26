import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/player/player_panel_hold.dart';
import 'package:kazumi/services/media/source_media_library.dart';

/// 收藏入口沿用动漫的菜单样式，实际只读写影视片单。
class SourcePlayerCollectButton extends StatefulWidget {
  const SourcePlayerCollectButton({
    super.key,
    required this.media,
    required this.acquirePlayerPanelHold,
  });

  final MediaSummary media;
  final PlayerPanelHold Function() acquirePlayerPanelHold;

  @override
  State<SourcePlayerCollectButton> createState() =>
      _SourcePlayerCollectButtonState();
}

class _SourcePlayerCollectButtonState extends State<SourcePlayerCollectButton> {
  final _library = SourceMediaLibrary.instance;
  PlayerPanelHold? _hold;
  bool _saving = false;

  CollectType get _type {
    for (final collection in _library.collections) {
      if (collection.media.ref == widget.media.ref) {
        return CollectType.fromValue(collection.status);
      }
    }
    return CollectType.none;
  }

  String _label(CollectType type) =>
      type == CollectType.none ? '未追' : type.label;

  IconData _icon(CollectType type) => switch (type) {
    CollectType.none => Icons.favorite_border,
    CollectType.watching => Icons.favorite,
    CollectType.planToWatch => Icons.star_rounded,
    CollectType.onHold => Icons.pending_actions,
    CollectType.watched => Icons.done,
    CollectType.abandoned => Icons.heart_broken,
  };

  Future<void> _select(CollectType type) async {
    if (_saving || _type == type) return;
    _saving = true;
    try {
      if (type == CollectType.none) {
        await _library.removeCollection(widget.media.ref);
      } else {
        await _library.setCollection(widget.media, status: type.value);
      }
    } catch (_) {
      if (mounted) KazumiDialog.showToast(message: '保存片单失败，请重试。');
    } finally {
      _saving = false;
    }
  }

  void _releaseHold() {
    _hold?.release();
    _hold = null;
  }

  @override
  void dispose() {
    _releaseHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _library,
    builder: (context, _) {
      final type = _type;
      return KazumiMenuButton(
        onOpen: () => _hold ??= widget.acquirePlayerPanelHold(),
        onClose: _releaseHold,
        crossAxisUnconstrained: false,
        builder: (context, toggle) => IconButton(
          onPressed: toggle,
          tooltip: _label(type),
          icon: Icon(_icon(type), color: Colors.white),
        ),
        menuChildren: [
          for (final option in CollectType.values)
            KazumiMenuItem(
              label: _label(option),
              selected: option == type,
              onPressed: () => _select(option),
            ),
        ],
      );
    },
  );
}
