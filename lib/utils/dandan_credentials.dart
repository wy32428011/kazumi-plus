import 'dart:convert';
import 'dart:io';

// 编译期 --dart-define 优先。本地调试可把同一对键放进项目根目录的
// .kazumi_build_defines.env（JSON 或 KEY=VALUE），避免未注入凭证时搜索直接 403。
const _compileTimeAppId = String.fromEnvironment('DANDANAPI_APPID');
const _compileTimeAppSecret = String.fromEnvironment('DANDANAPI_KEY');

class _DandanCredentialStore {
  String appId = _compileTimeAppId;
  String appSecret = _compileTimeAppSecret;
  var _loaded = false;

  void load() {
    if (_loaded) return;
    _loaded = true;
    if (appId.isNotEmpty && appSecret.isNotEmpty) return;

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
