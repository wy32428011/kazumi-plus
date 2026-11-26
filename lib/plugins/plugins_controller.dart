import 'dart:io';
import 'dart:convert';
import 'package:mobx/mobx.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/plugin_validity_tracker.dart';
import 'package:kazumi/services/plugin/plugin_install_time_tracker.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/utils/async_single_flight.dart';
import 'package:kazumi/utils/version.dart';

part 'plugins_controller.g.dart';

// 从 1.5.1 版本开始，规则文件储存在单一的 plugins.json 文件中。
// 之前的版本中，规则以分离文件形式存储，版本更新后将这些分离文件合并为单一的 plugins.json 文件。

class PluginsController = _PluginsController with _$PluginsController;

enum PluginUpdateAvailability { unknown, notInCatalog, latest, updatable }

enum PluginCatalogItemStatus { install, installed, update }

enum PluginUpdateResult { updated, requiresNewerClient, failed, notNewer }

class PluginBatchUpdateResult {
  const PluginBatchUpdateResult({
    required this.candidates,
    required this.updated,
    required this.requiresNewerClient,
    required this.failed,
    required this.notNewer,
  });

  final int candidates;
  final int updated;
  final int requiresNewerClient;
  final int failed;
  final int notNewer;

  bool get hasNoCandidates => candidates == 0;
}

typedef PluginCatalogLoader = Future<List<PluginHTTPItem>> Function();
typedef PluginLoader = Future<Plugin> Function(String name);
typedef PluginJsonWriter = Future<void> Function(String jsonData);
typedef PluginErrorReporter =
    void Function(String message, Object error, StackTrace stackTrace);
typedef _PluginUpdateAttempt = ({PluginUpdateResult result, Plugin? plugin});

void _defaultPluginErrorReporter(
  String message,
  Object error,
  StackTrace stackTrace,
) {
  KazumiLogger().e(message, error: error, stackTrace: stackTrace);
}

abstract class _PluginsController with Store {
  _PluginsController({
    PluginCatalogLoader? catalogLoader,
    PluginLoader? pluginLoader,
    PluginJsonWriter? pluginJsonWriter,
    PluginErrorReporter? errorReporter,
  }) : _catalogLoader = catalogLoader ?? PluginCatalogApi.getPluginList,
       _pluginLoader = pluginLoader ?? PluginCatalogApi.getPlugin,
       _pluginJsonWriter = pluginJsonWriter,
       _errorReporter = errorReporter ?? _defaultPluginErrorReporter;

  final PluginCatalogLoader _catalogLoader;
  final PluginLoader _pluginLoader;
  final PluginJsonWriter? _pluginJsonWriter;
  final PluginErrorReporter _errorReporter;
  final AsyncSingleFlight<List<PluginHTTPItem>> _catalogRefreshSingleFlight =
      AsyncSingleFlight<List<PluginHTTPItem>>();
  final AsyncSerialQueue _mutations = AsyncSerialQueue();
  Map<String, PluginHTTPItem> _pluginCatalogByName = const {};
  DateTime? _pluginCatalogRefreshedAt;
  int _optimisticReorderRevision = 0;

  // Reuse a recent catalog across startup, the rule list, and the rule shop.
  // Explicit refresh actions always bypass this window.
  static const _pluginCatalogMaxAge = Duration(minutes: 5);
  static const _maxConcurrentRuleDownloads = 4;

  // 稳定编号与随包资源一一对应，新增来源独立记录安装决定。
  // 排列不代表画质保证；分辨率以每个视频的实际轨道为准。
  static const _plusPresetAssets = {
    'kazumi-plus.maoyan': 'assets/plugins/maoyan.json',
    'kazumi-plus.modu': 'assets/plugins/modu.json',
    'kazumi-plus.haohua': 'assets/plugins/haohua.json',
    'kazumi-plus.xinlang': 'assets/plugins/xinlang.json',
    'kazumi-plus.huya': 'assets/plugins/huya.json',
    'kazumi-plus.jinying': 'assets/plugins/jinying.json',
    'kazumi-plus.ikun': 'assets/plugins/ikun.json',
    'kazumi-plus.guangsu': 'assets/plugins/guangsu.json',
    'kazumi-plus.subo': 'assets/plugins/subo.json',
    'kazumi-plus.baofeng': 'assets/plugins/baofeng.json',
    'kazumi-plus.hongniu': 'assets/plugins/hongniu.json',
    'kazumi-plus.iqiyi': 'assets/plugins/iqiyi.json',
    'kazumi-plus.zy360': 'assets/plugins/zy360.json',
    'kazumi-plus.4kav': 'assets/plugins/4kav.json',
  };

  @observable
  ObservableList<Plugin> pluginList = ObservableList.of([]);

  @observable
  ObservableList<PluginHTTPItem> pluginHTTPList = ObservableList.of([]);

  // 规则有效性追踪器
  final validityTracker = PluginValidityTracker();

  // 规则安装时间追踪器
  final installTimeTracker = PluginInstallTimeTracker();

  String pluginsFileName = "plugins.json";

  Directory? oldPluginDirectory;

  Directory? newPluginDirectory;

  // Initializes the plugin directory and loads all plugins
  Future<void> init() async {
    final directory = await getApplicationSupportDirectory();
    oldPluginDirectory = Directory('${directory.path}/plugins');
    if (!await oldPluginDirectory!.exists()) {
      await oldPluginDirectory!.create(recursive: true);
    }
    newPluginDirectory = Directory('${directory.path}/plugins/v2');
    if (!await newPluginDirectory!.exists()) {
      await newPluginDirectory!.create(recursive: true);
    }
    await _loadAllPlugins();
    await _seedPlusRulesOnce();
  }

  /// 每个随包影视源只处理一次，升级可增量安装且保留删除、禁用决定。
  Future<void> _seedPlusRulesOnce() {
    return _mutations.run(() async {
      final marker = File('${newPluginDirectory!.path}/plus_seed_v1.json');
      final processedRuleIds = await _readPlusSeedRuleIds(marker);
      for (final entry in _plusPresetAssets.entries) {
        if (processedRuleIds.contains(entry.key)) {
          // 已处理的预置源严格保留用户改动（域名、名称、请求头、禁启用或删除决定），绝不覆写。
          continue;
        }
        final raw = await rootBundle.loadString(entry.value);
        final preset = Plugin.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw)),
        );
        preset.validateCatalog();
        if (preset.ruleId != entry.key ||
            preset.plusSchemaVersion != 1 ||
            preset.catalog == null ||
            preset.name.trim().isEmpty ||
            preset.requiresNewerClient) {
          throw FormatException('预置影视来源格式或编号不正确：${entry.value}');
        }
        // 同编号已有规则保持原样，包含用户编辑与禁用状态。
        final alreadyInstalled = pluginList.any(
          (plugin) => pluginIdentityKey(plugin) == pluginIdentityKey(preset),
        );
        if (!alreadyInstalled) {
          // 同名自定义规则不覆盖，仅为新预置选择不冲突的显示名称。
          final originalName = preset.name;
          var suffix = 1;
          while (pluginList.any(
            (plugin) =>
                pluginNameKey(plugin.name) == pluginNameKey(preset.name),
          )) {
            preset.name = '$originalName（Plus ${suffix++}）';
          }
        }
        // 逐项保存成功后才记入处理集合，失败项下次启动仍可重试。
        await _mutateAndPersistNow(() {
          if (!alreadyInstalled) _replacePlugin(preset);
        }, errorMessage: 'Plugin: 预置影视来源「${preset.name}」保存失败');
        final nextRuleIds = {...processedRuleIds, preset.ruleId};
        await _writePlusSeedRuleIds(marker, nextRuleIds);
        processedRuleIds.add(preset.ruleId);
      }
    });
  }

  Future<Set<String>> _readPlusSeedRuleIds(File marker) async {
    if (!await marker.exists()) return <String>{};
    try {
      final data = jsonDecode(await marker.readAsString());
      if (data is! Map<String, dynamic> || data['version'] != 1) {
        throw const FormatException('预置影视来源安装记录格式或版本不正确');
      }
      // 旧标记仅代表暴风已处理，不能据此重新安装用户删除的暴风源。
      if (!data.containsKey('ruleIds')) return {'kazumi-plus.baofeng'};
      final ruleIds = data['ruleIds'];
      if (ruleIds is! List ||
          ruleIds.any(
            (id) => id is! String || id.trim().isEmpty || id.trim() != id,
          )) {
        throw const FormatException('预置影视来源安装记录缺少有效的 ruleIds');
      }
      return ruleIds.cast<String>().toSet();
    } catch (error, stackTrace) {
      // 记录损坏时停止安装，避免把已有删除决定误当成首次启动。
      _errorReporter('Plugin: 预置影视来源安装记录读取失败', error, stackTrace);
      rethrow;
    }
  }

  Future<void> _writePlusSeedRuleIds(File marker, Set<String> ruleIds) async {
    final temporary = File('${marker.path}.tmp');
    try {
      // 同目录临时文件写入并刷盘后替换，保留此前完整的安装记录。
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'ruleIds': ruleIds.toList()}),
        flush: true,
      );
      await temporary.rename(marker.path);
    } catch (error, stackTrace) {
      _errorReporter('Plugin: 预置影视来源安装记录保存失败', error, stackTrace);
      rethrow;
    }
  }

  // Loads all plugins from the directory, populates the plugin list, and saves to plugins.json if needed
  Future<void> _loadAllPlugins() async {
    pluginList.clear();
    KazumiLogger().i('Plugins Directory: ${newPluginDirectory!.path}');
    if (await newPluginDirectory!.exists()) {
      final pluginsFile = File('${newPluginDirectory!.path}/$pluginsFileName');
      if (await pluginsFile.exists()) {
        final jsonString = await pluginsFile.readAsString();
        pluginList.addAll(_getPluginListFromJson(jsonString));
        KazumiLogger().i('Plugin: Current Plugin number: ${pluginList.length}');
      } else {
        // No plugins.json
        var jsonFiles = await _getPluginFiles();
        for (var filePath in jsonFiles) {
          final file = File(filePath);
          final jsonString = await file.readAsString();
          final data = jsonDecode(jsonString);
          final plugin = Plugin.fromJson(data);
          pluginList.add(plugin);
          await file.delete(recursive: true);
        }
        await _savePlugins();
      }
    } else {
      KazumiLogger().w('Plugin: plugin directory does not exist');
    }
  }

  // Retrieves a list of JSON plugin file paths from the plugin directory
  Future<List<String>> _getPluginFiles() async {
    if (await oldPluginDirectory!.exists()) {
      final jsonFiles = oldPluginDirectory!
          .listSync()
          .where((file) => file.path.endsWith('.json') && file is File)
          .map((file) => file.path)
          .toList();
      return jsonFiles;
    } else {
      return [];
    }
  }

  // Copies plugin JSON files from the assets to the plugin directory
  Future<void> copyPluginsToExternalDirectory() async {
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = assetManifest.listAssets();
    final jsonFiles = assets.where(
      (String asset) =>
          asset.startsWith('assets/plugins/') && asset.endsWith('.json'),
    );

    for (var filePath in jsonFiles) {
      final jsonString = await rootBundle.loadString(filePath);
      final plugin = Plugin.fromJson(jsonDecode(jsonString));
      // Plus 预置由首次初始化标记管理，重新进入引导不能恢复已删除来源。
      if (plugin.plusSchemaVersion > 0) continue;
      if (!pluginList.any(
        (current) => pluginIdentityKey(current) == pluginIdentityKey(plugin),
      )) {
        pluginList.add(plugin);
      }
    }
    await _savePlugins();
    KazumiLogger().i(
      'Plugin: ${jsonFiles.length} plugin files copied to ${newPluginDirectory!.path}',
    );
  }

  List<dynamic> _pluginListToJson() {
    final List<dynamic> json = [];
    for (var plugin in pluginList) {
      json.add(plugin.toJson());
    }
    return json;
  }

  // Converts a JSON string into a list of Plugin objects.
  List<Plugin> _getPluginListFromJson(String jsonString) {
    List<dynamic> json = jsonDecode(jsonString);
    List<Plugin> plugins = [];
    for (var j in json) {
      plugins.add(Plugin.fromJson(j));
    }
    return plugins;
  }

  Future<void> removePlugin(Plugin plugin) {
    return _mutateAndPersist(
      () => pluginList.removeWhere(
        (candidate) =>
            pluginIdentityKey(candidate) == pluginIdentityKey(plugin),
      ),
      errorMessage: 'Plugin: failed to persist rule removal',
    );
  }

  bool get isPluginCatalogFresh {
    final refreshedAt = _pluginCatalogRefreshedAt;
    return refreshedAt != null &&
        DateTime.now().difference(refreshedAt) < _pluginCatalogMaxAge;
  }

  void _replacePlugin(
    Plugin plugin, {
    bool preserveEnabled = false,
    Plugin? previous,
  }) {
    plugin.validateCatalog();
    if (previous?.ruleId.isNotEmpty == true &&
        previous!.ruleId != plugin.ruleId) {
      throw const FormatException('已有来源的稳定编号不能修改');
    }
    final replacingKey = pluginIdentityKey(previous ?? plugin);
    if (pluginList.any(
      (current) =>
          pluginIdentityKey(current) != replacingKey &&
          (pluginIdentityKey(current) == pluginIdentityKey(plugin) ||
              pluginNameKey(current.name) == pluginNameKey(plugin.name)),
    )) {
      throw FormatException('存在相同编号或名称的其它来源「${plugin.name}」，请先改名');
    }
    bool flag = false;
    for (int i = 0; i < pluginList.length; ++i) {
      if (pluginIdentityKey(pluginList[i]) == replacingKey) {
        if (preserveEnabled) plugin.enabled = pluginList[i].enabled;
        pluginList.replaceRange(i, i + 1, [plugin]);
        flag = true;
        break;
      }
    }
    if (!flag) {
      if (pluginList.any(
        (current) => pluginNameKey(current.name) == pluginNameKey(plugin.name),
      )) {
        throw FormatException('存在同名的不同来源「${plugin.name}」，请先为新来源改名');
      }
      pluginList.add(plugin);
    }
  }

  Future<T> _mutateAndPersist<T>(
    T Function() mutate, {
    required String errorMessage,
  }) {
    return _mutations.run(
      () => _mutateAndPersistNow(mutate, errorMessage: errorMessage),
    );
  }

  Future<T> _mutateAndPersistNow<T>(
    T Function() mutate, {
    required String errorMessage,
  }) async {
    final previous = List<Plugin>.from(pluginList);
    try {
      final result = mutate();
      await _savePlugins();
      return result;
    } catch (error, stackTrace) {
      pluginList
        ..clear()
        ..addAll(previous);
      _errorReporter(errorMessage, error, stackTrace);
      rethrow;
    }
  }

  Future<void> updatePlugin(Plugin plugin, {Plugin? previous}) {
    return _mutateAndPersist(
      () => _replacePlugin(plugin, previous: previous),
      errorMessage: 'Plugin: failed to persist rule update',
    );
  }

  Future<void> updatePlugins(Iterable<Plugin> plugins) {
    return _mutateAndPersist(() {
      for (final plugin in plugins) {
        _replacePlugin(plugin, preserveEnabled: true);
      }
    }, errorMessage: 'Plugin: failed to persist imported rules');
  }

  Future<void> onReorder(int oldIndex, int newIndex) {
    final previous = List<Plugin>.from(pluginList);
    final plugin = pluginList.removeAt(oldIndex);
    pluginList.insert(newIndex, plugin);
    final jsonData = jsonEncode(_pluginListToJson());
    final revision = ++_optimisticReorderRevision;
    return _mutations.run(() async {
      try {
        await _writePluginsJson(jsonData);
      } catch (error, stackTrace) {
        if (revision == _optimisticReorderRevision) {
          pluginList
            ..clear()
            ..addAll(previous);
        }
        _errorReporter(
          'Plugin: failed to persist rule order',
          error,
          stackTrace,
        );
        rethrow;
      }
    });
  }

  Future<void> _savePlugins() async {
    final jsonData = jsonEncode(_pluginListToJson());
    await _writePluginsJson(jsonData);
  }

  Future<void> _writePluginsJson(String jsonData) async {
    final writer = _pluginJsonWriter;
    if (writer != null) {
      await writer(jsonData);
    } else {
      final pluginsFile = File('${newPluginDirectory!.path}/$pluginsFileName');
      await pluginsFile.writeAsString(jsonData);
      KazumiLogger().i('Plugin: updated plugin file $pluginsFileName');
    }
  }

  Future<List<PluginHTTPItem>> refreshPluginCatalog() {
    return _catalogRefreshSingleFlight.run(() async {
      try {
        final catalog = await _catalogLoader();
        _pluginCatalogByName = {
          for (final item in catalog) pluginNameKey(item.name): item,
        };
        pluginHTTPList
          ..clear()
          ..addAll(catalog);
        _pluginCatalogRefreshedAt = DateTime.now();
        return List<PluginHTTPItem>.unmodifiable(catalog);
      } catch (error, stackTrace) {
        _errorReporter(
          'Plugin: failed to refresh rule catalog',
          error,
          stackTrace,
        );
        rethrow;
      }
    });
  }

  Future<List<PluginHTTPItem>> ensurePluginCatalog() {
    if (isPluginCatalogFresh) {
      return Future.value(List<PluginHTTPItem>.unmodifiable(pluginHTTPList));
    }
    return refreshPluginCatalog();
  }

  Future<int> checkPluginUpdatesOnStartup({required bool enabled}) async {
    if (!enabled) {
      return 0;
    }
    await refreshPluginCatalog();
    return _updatablePluginNames().length;
  }

  bool _remoteIsNewer(String localVersion, String remoteVersion) {
    try {
      return needUpdate(localVersion, remoteVersion);
    } catch (_) {
      return localVersion != remoteVersion;
    }
  }

  PluginCatalogItemStatus pluginStatus(PluginHTTPItem pluginHTTPItem) {
    var pluginStatus = PluginCatalogItemStatus.install;
    for (Plugin plugin in pluginList) {
      if (pluginNameKey(pluginHTTPItem.name) == pluginNameKey(plugin.name)) {
        if (_remoteIsNewer(plugin.version, pluginHTTPItem.version)) {
          pluginStatus = PluginCatalogItemStatus.update;
        } else {
          pluginStatus = PluginCatalogItemStatus.installed;
        }
        break;
      }
    }
    return pluginStatus;
  }

  PluginUpdateAvailability pluginUpdateStatus(Plugin plugin) {
    if (_pluginCatalogRefreshedAt == null) {
      return PluginUpdateAvailability.unknown;
    }
    final remote = _pluginCatalogByName[pluginNameKey(plugin.name)];
    if (remote == null) {
      return PluginUpdateAvailability.notInCatalog;
    }
    return _remoteIsNewer(plugin.version, remote.version)
        ? PluginUpdateAvailability.updatable
        : PluginUpdateAvailability.latest;
  }

  List<String> _updatablePluginNames() {
    return [
      for (final plugin in pluginList)
        if (pluginUpdateStatus(plugin) == PluginUpdateAvailability.updatable)
          _pluginCatalogByName[pluginNameKey(plugin.name)]!.name,
    ];
  }

  Future<PluginUpdateResult> tryUpdatePluginByName(String name) {
    return _mutations.run(() async {
      final catalogName =
          _pluginCatalogByName[pluginNameKey(name)]?.name ?? name;
      final attempt = await _preparePluginUpdate(catalogName);
      if (attempt.result == PluginUpdateResult.updated) {
        await _mutateAndPersistNow(
          () => _replacePlugin(attempt.plugin!, preserveEnabled: true),
          errorMessage:
              'Plugin: failed to persist downloaded rule $catalogName',
        );
      }
      return attempt.result;
    });
  }

  Future<_PluginUpdateAttempt> _preparePluginUpdate(String name) async {
    late final Plugin remotePlugin;
    try {
      remotePlugin = await _pluginLoader(name);
    } catch (error, stackTrace) {
      _errorReporter(
        'Plugin: failed to download rule $name',
        error,
        stackTrace,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    // Validate at the injected loader boundary so production and test/custom
    // loaders follow the same integrity rule. Preserve the catalog spelling.
    if (remotePlugin.name.isEmpty ||
        pluginNameKey(remotePlugin.name) != pluginNameKey(name)) {
      final error = FormatException(
        'Downloaded rule name ${remotePlugin.name} does not match $name',
      );
      _errorReporter(
        'Plugin: rejected mismatched rule payload',
        error,
        StackTrace.current,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    remotePlugin.name = name;
    try {
      if (remotePlugin.requiresNewerClient) {
        return (result: PluginUpdateResult.requiresNewerClient, plugin: null);
      }
    } catch (error, stackTrace) {
      _errorReporter(
        'Plugin: invalid API level in rule $name',
        error,
        stackTrace,
      );
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    Plugin? local;
    for (final plugin in pluginList) {
      if (pluginNameKey(plugin.name) == pluginNameKey(name)) {
        local = plugin;
        break;
      }
    }
    // 上游目录按名称检索，不能用缺少编号的旧规则覆盖同名 Plus 来源。
    if (local?.ruleId.isNotEmpty == true &&
        local!.ruleId != remotePlugin.ruleId) {
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    try {
      remotePlugin.validateCatalog();
    } catch (_) {
      return (result: PluginUpdateResult.failed, plugin: null);
    }
    // Never downgrade an installed plugin; mirrors may lag behind upstream.
    if (local != null && !_remoteIsNewer(local.version, remotePlugin.version)) {
      return (result: PluginUpdateResult.notNewer, plugin: null);
    }
    return (result: PluginUpdateResult.updated, plugin: remotePlugin);
  }

  Future<PluginBatchUpdateResult> tryUpdateAllPlugin({
    bool ensureCatalog = true,
  }) {
    return _mutations.run(
      () => _tryUpdateAllPlugin(ensureCatalog: ensureCatalog),
    );
  }

  Future<PluginBatchUpdateResult> _tryUpdateAllPlugin({
    required bool ensureCatalog,
  }) async {
    if (ensureCatalog) {
      await ensurePluginCatalog();
    } else if (_pluginCatalogRefreshedAt == null) {
      throw StateError('Plugin catalog has not been loaded');
    }

    final candidates = _updatablePluginNames();
    final attempts = await _preparePluginUpdates(candidates);
    var updated = 0;
    var requiresNewerClient = 0;
    var failed = 0;
    var notNewer = 0;

    final updatedPlugins = <Plugin>[];
    for (final attempt in attempts) {
      switch (attempt.result) {
        case PluginUpdateResult.updated:
          updated++;
          updatedPlugins.add(attempt.plugin!);
        case PluginUpdateResult.requiresNewerClient:
          requiresNewerClient++;
        case PluginUpdateResult.failed:
          failed++;
        case PluginUpdateResult.notNewer:
          notNewer++;
      }
    }

    if (updatedPlugins.isNotEmpty) {
      await _mutateAndPersistNow(() {
        for (final plugin in updatedPlugins) {
          _replacePlugin(plugin, preserveEnabled: true);
        }
      }, errorMessage: 'Plugin: failed to persist batch rule update');
    }
    return PluginBatchUpdateResult(
      candidates: candidates.length,
      updated: updated,
      requiresNewerClient: requiresNewerClient,
      failed: failed,
      notNewer: notNewer,
    );
  }

  Future<List<_PluginUpdateAttempt>> _preparePluginUpdates(
    List<String> names,
  ) async {
    if (names.isEmpty) {
      return const [];
    }
    final results = List<_PluginUpdateAttempt?>.filled(names.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < names.length) {
        final index = nextIndex++;
        results[index] = await _preparePluginUpdate(names[index]);
      }
    }

    final workerCount = names.length < _maxConcurrentRuleDownloads
        ? names.length
        : _maxConcurrentRuleDownloads;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results.cast<_PluginUpdateAttempt>();
  }

  Future<void> removePlugins(Set<String> pluginNames) {
    final names = Set<String>.of(pluginNames);
    return _mutateAndPersist(() {
      for (int i = pluginList.length - 1; i >= 0; --i) {
        var name = pluginList[i].name;
        if (names.contains(name)) {
          pluginList.removeAt(i);
        }
      }
    }, errorMessage: 'Plugin: failed to persist batch rule removal');
  }
}
