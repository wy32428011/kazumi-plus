import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
    SourceHealthRepository? healthRepository,
    SourceScoringEngine? scoringEngine,
  }) : _health = healthRepository ?? SourceHealthRepository.instance,
       _scoring = scoringEngine ?? SourceScoringEngine.instance;

  final InfoController infoController;
  final PluginsController pluginsController;
  final SourceHealthRepository _health;
  final SourceScoringEngine _scoring;

  /// Per-plugin sessions and cancel tokens so a replacement query
  /// (alias/manual search) cancels and invalidates the previous attempt.
  final Map<String, AsyncSessionOwner> _querySessions = {};
  final Map<String, RuleCancelToken> _pluginCancelTokens = {};
  bool _isCancelled = false;

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName && _supportsAnime(plugin)) {
        infoController.pluginSearchResponseList.removeWhere(
          (response) => response.pluginName == pluginName,
        );
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.pending;
        // 用户手动重试/别名检索显式绕过自动池冷却门控，底层 RuleEngine 仍受 SourceTrafficGuard 保护。
        await _queryPlugin(
          plugin,
          keyword,
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
          respectCaptchaCooldown: true,
        ),
      ),
    );
  }

  Future<void> _queryPlugin(
    Plugin plugin,
    String keyword, {
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
    final previousToken = _pluginCancelTokens[plugin.name];
    if (previousToken != null && !previousToken.isCancelled) {
      previousToken.cancel('replaced by newer search');
    }
    final cancelToken = RuleCancelToken();
    _pluginCancelTokens[plugin.name] = cancelToken;

    final stopwatch = Stopwatch()..start();
    try {
      // 底层 RuleEngine 执行器已通过 SourceTrafficGuard.instance 实施统一并发与站点限频治理，
      // 此处直接调用 queryBangumi，避免重复套壳导致信号量重入死锁。
      final result = await plugin.queryBangumi(
        keyword,
        shouldRethrow: true,
        cancelToken: cancelToken,
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
      if ((error is DioException && CancelToken.isCancel(error)) ||
          (error is NetworkException &&
              error.type == NetworkExceptionType.cancel)) {
        return;
      }
      _handleSearchError(plugin, error);
    } finally {
      if (identical(_pluginCancelTokens[plugin.name], cancelToken)) {
        _pluginCancelTokens.remove(plugin.name);
      }
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
    for (final token in _pluginCancelTokens.values) {
      if (!token.isCancelled) {
        token.cancel('search cancelled');
      }
    }
    _pluginCancelTokens.clear();
  }
}

