import 'dart:async';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 局域网可投屏的 DLNA 播放设备。
class CastRenderer {
  const CastRenderer({required this.device, required this.typeLabel});

  final DLNADevice device;
  final String typeLabel;

  String get name {
    final friendlyName = device.info.friendlyName.trim();
    if (friendlyName.isNotEmpty) return friendlyName;
    return device.info.URLBase;
  }
}

/// 按本机每个 IPv4 网卡发送 SSDP M-SEARCH。
///
/// dlna_dart 把套接字绑在 0.0.0.0 上，Windows 会从默认路由（常见是 TUN/假 IP
/// 网卡）发出组播，局域网设备收不到，回复也回不来。这里改为绑定具体地址并设置
/// IP_MULTICAST_IF，只接收单播回复，因此不必占用 1900 端口。
class SsdpDiscovery {
  static const _multicastHost = '239.255.255.250';
  static const _multicastPort = 1900;
  static const _searchTargets = <String>[
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
  ];

  final _devices = StreamController<List<CastRenderer>>.broadcast();
  final List<RawDatagramSocket> _sockets = [];
  final Set<String> _locations = {};
  final Map<String, CastRenderer> _found = {};
  Timer? _announce;
  var _closed = false;
  var _epoch = 0;

  Stream<List<CastRenderer>> get devices => _devices.stream;

  Future<void> start() async {
    final epoch = ++_epoch;
    await _shutdown();
    if (epoch != _epoch) return;
    _closed = false;
    await _AndroidMulticastLock.acquire();
    if (epoch != _epoch) {
      await _AndroidMulticastLock.release();
      return;
    }
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    if (epoch != _epoch) return;
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (epoch != _epoch) return;
        if (address.isLoopback || address.type != InternetAddressType.IPv4) {
          continue;
        }
        try {
          final socket = await RawDatagramSocket.bind(
            address,
            0,
            reuseAddress: true,
          );
          if (epoch != _epoch) {
            socket.close();
            continue;
          }
          _setMulticastInterface(socket, address);
          socket.listen((event) {
            if (event != RawSocketEvent.read || _closed) return;
            Datagram? datagram;
            while ((datagram = socket.receive()) != null) {
              _onDatagram(datagram!);
            }
          });
          _sockets.add(socket);
          KazumiLogger().i(
            'RemotePlay: searching via ${interface.name} ${address.address}',
          );
        } catch (error) {
          KazumiLogger().w(
            'RemotePlay: skipped interface ${interface.name} ${address.address}',
            error: error,
          );
        }
      }
    }
    if (epoch != _epoch) return;
    if (_sockets.isEmpty) {
      await _AndroidMulticastLock.release();
      throw StateError('没有可用的 IPv4 网卡');
    }
    _sendSearches();
    _announce = Timer.periodic(const Duration(seconds: 3), (_) {
      if (epoch != _epoch || _closed) return;
      _sendSearches();
    });
  }

  Future<void> stop() async {
    _epoch++;
    _closed = true;
    await _shutdown();
  }

  Future<void> _shutdown() async {
    _announce?.cancel();
    _announce = null;
    for (final socket in _sockets) {
      socket.close();
    }
    _sockets.clear();
    _locations.clear();
    _found.clear();
    await _AndroidMulticastLock.release();
  }

  Future<void> dispose() async {
    await stop();
    await _devices.close();
  }

  void _sendSearches() {
    final address = InternetAddress(_multicastHost);
    for (final socket in _sockets) {
      for (final target in _searchTargets) {
        final message = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: $_multicastHost:$_multicastPort\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $target\r\n'
            '\r\n';
        try {
          socket.send(message.codeUnits, address, _multicastPort);
        } catch (error) {
          KazumiLogger().w('RemotePlay: M-SEARCH failed', error: error);
        }
      }
    }
  }

  void _onDatagram(Datagram datagram) {
    if (_closed) return;
    final message = String.fromCharCodes(datagram.data);
    final location = _header(message, 'LOCATION');
    if (location == null || !_locations.add(location)) return;
    unawaited(_loadDevice(location));
  }

  Future<void> _loadDevice(String location) async {
    try {
      final uri = Uri.parse(location);
      final body = await DLNAHttp.get(uri);
      if (_closed) return;
      final info = DeviceInfoParser(body).parse(uri);
      if (!_canRender(info)) return;
      final renderer = CastRenderer(
        device: DLNADevice(info),
        typeLabel: _typeLabel(info.deviceType),
      );
      _found[info.URLBase] = renderer;
      if (!_devices.isClosed) {
        _devices.add(_found.values.toList());
      }
    } catch (error) {
      KazumiLogger().w(
        'RemotePlay: ignored device description $location',
        error: error,
      );
    }
  }

  bool _canRender(DeviceInfo info) {
    if (info.deviceType.contains('MediaRenderer')) return true;
    for (final service in info.serviceList) {
      final type = '${service['serviceType'] ?? ''} ${service['serviceId'] ?? ''}';
      if (type.contains('AVTransport')) return true;
    }
    return false;
  }

  String _typeLabel(String deviceType) {
    final parts = deviceType.split(':');
    if (parts.length >= 4 && parts[3].isNotEmpty) return parts[3];
    return 'MediaRenderer';
  }

  String? _header(String message, String name) {
    for (final line in message.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      if (line.substring(0, separator).trim().toUpperCase() != name) continue;
      final value = line.substring(separator + 1).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// Linux/Android 的 IP_MULTICAST_IF 是 32，Windows 与 Apple 是 9。
  void _setMulticastInterface(RawDatagramSocket socket, InternetAddress address) {
    final option = Platform.isLinux || Platform.isAndroid ? 32 : 9;
    try {
      socket.setRawOption(
        RawSocketOption(RawSocketOption.levelIPv4, option, address.rawAddress),
      );
    } catch (error) {
      KazumiLogger().w(
        'RemotePlay: multicast interface was not set for ${address.address}',
        error: error,
      );
    }
  }
}

class _AndroidMulticastLock {
  static const _channel = MethodChannel('com.predidit.kazumi/multicast');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (error) {
      KazumiLogger().w('RemotePlay: multicast lock was not acquired', error: error);
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('release');
    } catch (error) {
      KazumiLogger().w('RemotePlay: multicast lock was not released', error: error);
    }
  }
}
