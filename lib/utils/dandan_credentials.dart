import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/storage/storage.dart';

// 用户设置页填写的凭证优先；其次是编译期 --dart-define，
// 最后回退环境变量与项目根目录 / 可执行文件目录的 .kazumi_build_defines.env。
const _compileTimeAppId = String.fromEnvironment('DANDANAPI_APPID');
const _compileTimeAppSecret = String.fromEnvironment('DANDANAPI_KEY');

class _DandanCredentialStore {
  String appId = '';
  String appSecret = '';
  var _loaded = false;

  void reload() {
    _loaded = false;
    load();
  }

  void load() {
    if (_loaded) return;
    _loaded = true;
    appId = '';
    appSecret = '';

    try {
      final storedId = GStorage.getSetting<String>(
        SettingsKeys.danmakuDandanAppId,
      ).trim();
      final storedSecret = GStorage.getSetting<String>(
        SettingsKeys.danmakuDandanAppSecret,
      ).trim();
      if (storedId.isNotEmpty && storedSecret.isNotEmpty) {
        appId = storedId;
        appSecret = storedSecret;
        return;
      }
    } catch (_) {
      // 单元测试或 Storage 未初始化时回退编译期 / 环境变量。
    }

    if (_compileTimeAppId.isNotEmpty && _compileTimeAppSecret.isNotEmpty) {
      appId = _compileTimeAppId;
      appSecret = _compileTimeAppSecret;
      return;
    }

    final envId = Platform.environment['DANDANAPI_APPID'] ?? '';
    final envSecret = Platform.environment['DANDANAPI_KEY'] ?? '';
    if (envId.isNotEmpty && envSecret.isNotEmpty) {
      appId = envId;
      appSecret = envSecret;
      return;
    }

    for (final file in _candidateFiles()) {
      final values = _read(file);
      if (values == null) continue;
      final id = values['DANDANAPI_APPID'] ?? '';
      final secret = values['DANDANAPI_KEY'] ?? '';
      if (id.isEmpty || secret.isEmpty) continue;
      appId = id;
      appSecret = secret;
      return;
    }
  }

  List<File> _candidateFiles() {
    final files = <File>[File('.kazumi_build_defines.env')];
    try {
      final executableDir = File(Platform.resolvedExecutable).parent;
      files.add(File('${executableDir.path}/.kazumi_build_defines.env'));
    } catch (_) {}
    return files;
  }

  Map<String, String>? _read(File file) {
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      if (text.isEmpty) return null;
      if (text.startsWith('{')) {
        final decoded = jsonDecode(text);
        if (decoded is! Map) return null;
        return {
          for (final entry in decoded.entries)
            '${entry.key}': '${entry.value}',
        };
      }
      final values = <String, String>{};
      for (final line in text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final separator = trimmed.indexOf('=');
        if (separator <= 0) continue;
        values[trimmed.substring(0, separator).trim()] =
            trimmed.substring(separator + 1).trim();
      }
      return values;
    } catch (_) {
      return null;
    }
  }
}

final _store = _DandanCredentialStore();

Map<String, String> get dandanCredentials {
  _store.load();
  return {'id': _store.appId, 'value': _store.appSecret};
}

bool get dandanCredentialsConfigured {
  _store.load();
  return _store.appId.isNotEmpty && _store.appSecret.isNotEmpty;
}

void reloadDandanCredentials() {
  _store.reload();
}
