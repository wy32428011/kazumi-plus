import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/source_traffic_guard.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
    SourceTrafficGuard? trafficGuard,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
  }) : _trafficGuard = trafficGuard ?? SourceTrafficGuard.instance,
       _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance;

  final InfoController infoController;
  final PluginsController pluginsController;
  final SourceTrafficGuard _trafficGuard;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;
  final RuleCancelToken _cancelToken = RuleCancelToken();
  final CancelToken _guardCancelToken = CancelToken();

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};
  bool _isCancelled = false;

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName && _supportsAnime(plugin)) {
        infoController.pluginSearchResponseList.removeWhere(
          (response) => response.pluginName == pluginName,
        );
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.pending;
        // 用户手动重试/别名检索显式绕过单飞缓存与自动池冷却门控，仍受站点限频与并发守卫保护。
        await _queryPlugin(
          plugin,
          keyword,
          deduplicate: false,
          respectCaptchaCooldown: false,
        );
        return;
      }
    }
  }

  /// Publishes the result page harvested by the captcha webview, skipping
  /// one network round trip. Returns false when the HTML does not parse
  /// into results; callers should fall back to [querySource].
  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName || !_supportsAnime(plugin)) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
      _health.clearCaptchaCooldown(identityKey, kind: MediaKind.anime);
      if (result.data.isNotEmpty) {
        _health.recordSuccess(
          pluginIdentityKey: identityKey,
          kind: MediaKind.anime,
        );
      }
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(String keyword) async {
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();

    final plugins = pluginsController.pluginList.where(_supportsAnime).toList();
    // 按跨频道共享的实测健康评分降序调度，优先让健康高速的规则抢占并发槽。
    plugins.sort((a, b) {
      final scoreB = _scoring.scorePlugin(b, MediaKind.anime);
      final scoreA = _scoring.scorePlugin(a, MediaKind.anime);
      return scoreB.compareTo(scoreA);
    });

    for (final plugin in plugins) {
      final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
      if (_health.isSourceInCaptchaCooldown(identityKey, MediaKind.anime)) {
        infoController.pluginSearchStatus[plugin.name] =
            PluginSearchStatus.captcha;
      } else {
        infoController.pluginSearchStatus[plugin.name] =
            PluginSearchStatus.pending;
      }
    }

    await Future.wait(
      plugins.map(
        (plugin) => _queryPlugin(
          plugin,
          keyword,
          deduplicate: true,
          respectCaptchaCooldown: true,
        ),
      ),
    );
  }

  Future<void> _queryPlugin(
    Plugin plugin,
    String keyword, {
    bool deduplicate = true,
    bool respectCaptchaCooldown = true,
  }) async {
    if (_isCancelled) return;
    final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
    if (respectCaptchaCooldown &&
        _health.isSourceInCaptchaCooldown(identityKey, MediaKind.anime)) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.captcha;
      return;
    }

    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    final stopwatch = Stopwatch()..start();
    final targetUrl = plugin.usesApiSearch
        ? plugin.baseUrl
        : (plugin.searchURL.isNotEmpty ? plugin.searchURL : plugin.baseUrl);
    try {
      final result = await _trafficGuard.run<PluginSearchResponse>(
        url: targetUrl,
        query: {'keyword': keyword, 'plugin': identityKey},
        cancelToken: _guardCancelToken,
        deduplicate: deduplicate,
        action: (_) => plugin.queryBangumi(
          keyword,
          shouldRethrow: true,
          cancelToken: _cancelToken,
        ),
      );
      stopwatch.stop();
      if (_isCancelled || session.isStale) return;
      _health.clearCaptchaCooldown(identityKey, kind: MediaKind.anime);
      if (result.data.isNotEmpty) {
        _health.recordSuccess(
          pluginIdentityKey: identityKey,
          kind: MediaKind.anime,
          ttfbMs: stopwatch.elapsedMilliseconds,
        );
        pluginsController.validityTracker.markSearchValid(plugin.name);
      }
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      infoController.pluginSearchResponseList.add(result);
    } catch (error) {
      stopwatch.stop();
      if (_isCancelled || session.isStale) return;
      if (error is DioException && error.type == DioExceptionType.cancel) {
        return;
      }
      _handleSearchError(plugin, error);
    }
  }

  // 影视规则不会进入原动漫搜索及其验证码重试路径。
  bool _supportsAnime(Plugin plugin) =>
      plugin.enabled && plugin.supportedMediaTypes.contains('anime');

  void _handleSearchError(Plugin plugin, Object error) {
    final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
    if (error is CaptchaRequiredException) {
      KazumiLogger().i(
        'PluginSearchService: captcha required for ${error.pluginName}',
      );
      _health.recordFailure(
        pluginIdentityKey: identityKey,
        kind: MediaKind.anime,
        failureKind: SourceFailureKind.captchaRequired,
        message: '动漫检索触发站点验证',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.captcha;
      return;
    }
    if (error is NoResultException) {
      KazumiLogger().i(
        'PluginSearchService: no results for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.noResult;
      return;
    }
    final name = error is SearchErrorException ? error.pluginName : plugin.name;
    final msg = error.toString();
    final lower = msg.toLowerCase();
    final failureKind =
        (lower.contains('handshake') ||
            lower.contains('bad_record_mac') ||
            lower.contains('tls') ||
            lower.contains('eof'))
        ? SourceFailureKind.tlsTransient
        : SourceFailureKind.networkTimeout;
    _health.recordFailure(
      pluginIdentityKey: identityKey,
      kind: MediaKind.anime,
      failureKind: failureKind,
      message: msg,
    );
    KazumiLogger().w('PluginSearchService: search error for $name');
    infoController.pluginSearchStatus[name] = PluginSearchStatus.error;
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
    if (!_guardCancelToken.isCancelled) {
      _guardCancelToken.cancel('search cancelled');
    }
  }
}

