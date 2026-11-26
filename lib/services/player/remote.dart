import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/player/ssdp_discovery.dart';

class RemotePlay {
  Future<void> castVideo(String video, String referer) async {
    if (referer.isNotEmpty) {
      KazumiLogger().i('RemotePlay: 播放设备自行请求地址，Referer 不会附带');
    }
    await KazumiDialog.show(builder: (context) {
      return _CastDialog(video: video);
    });
  }
}

class _CastDialog extends StatefulWidget {
  const _CastDialog({required this.video});

  final String video;

  @override
  State<_CastDialog> createState() => _CastDialogState();
}

class _CastDialogState extends State<_CastDialog> {
  final _discovery = SsdpDiscovery();
  StreamSubscription<List<CastRenderer>>? _subscription;
  List<CastRenderer> _devices = const [];
  String? _error;
  var _casting = false;
  var _starting = false;

  @override
  void initState() {
    super.initState();
    _subscription = _discovery.devices.listen((devices) {
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
      });
    });
    unawaited(_search());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_discovery.dispose());
    super.dispose();
  }

  Future<void> _search() async {
    if (_starting) return;
    _starting = true;
    if (mounted && (_devices.isNotEmpty || _error != null)) {
      setState(() {
        _error = null;
        _devices = const [];
      });
    }
    try {
      await _discovery.start();
    } catch (error) {
      KazumiLogger().w('RemotePlay: discovery failed to start', error: error);
      if (!mounted) return;
      setState(() => _error = '没有可用的局域网网卡');
    } finally {
      _starting = false;
    }
  }

  Future<void> _cast(CastRenderer renderer) async {
    if (_casting) return;
    setState(() => _casting = true);
    KazumiDialog.showToast(message: '尝试投屏至 ${renderer.name}');
    try {
      final player = DLNADevice(renderer.device.info);
      await player.setUrl(widget.video);
      await player.play();
      if (!mounted) return;
      KazumiDialog.showToast(message: '已投屏至 ${renderer.name}');
    } catch (error) {
      KazumiLogger().e(
        'RemotePlay: failed to cast to ${renderer.name}',
        error: error,
      );
      if (!mounted) return;
      KazumiDialog.showToast(message: '投屏失败，请重试或更换设备');
    } finally {
      if (mounted) setState(() => _casting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('远程投屏'),
      content: SizedBox(
        width: 360,
        height: 280,
        child: _devices.isEmpty
            ? Center(
                child: Text(
                  _error ?? '正在搜索局域网设备…',
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.builder(
                itemCount: _devices.length,
                itemBuilder: (context, index) {
                  final device = _devices[index];
                  return ListTile(
                    leading: const Icon(Icons.cast_connected),
                    title: Text(device.name),
                    subtitle: Text(device.typeLabel),
                    enabled: !_casting,
                    onTap: () => _cast(device),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => KazumiDialog.dismiss(),
          child: Text('退出', style: TextStyle(color: colors.outline)),
        ),
        TextButton(
          onPressed: _search,
          child: Text('重新搜索', style: TextStyle(color: colors.outline)),
        ),
      ],
    );
  }
}
