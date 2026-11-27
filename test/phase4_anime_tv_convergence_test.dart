import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_change_module.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/source_traffic_guard.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/television/tv_playback_controls.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

class _StubCollectCrudRepository implements ICollectCrudRepository {
  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  List<CollectedBangumi> getAllCollectibles() => const [];

  @override
  CollectedBangumi? getCollectible(int id) => null;

  @override
  int getCollectType(int id) => 0;

  @override
  Future<void> addCollectible(BangumiItem bangumiItem, int type) async {}

  @override
  Future<void> updateCollectible(BangumiItem bangumiItem) async {}

  @override
  Future<void> deleteCollectible(int id) async {}

  @override
  Future<void> addCollectChange(CollectedBangumiChange change) async {}

  @override
  List<BangumiItem> getFavorites() => const [];

  @override
  Future<void> clearFavorites() async {}
}

class _StubAnimePlugin extends Plugin {
  _StubAnimePlugin({
    required super.name,
    required super.ruleId,
    required super.baseUrl,
    super.supportedMediaTypes = const ['anime'],
    this.onQuery,
  }) : super(
         api: '1',
         type: 'anime',
         version: '1.0',
         muliSources: true,
         useWebview: false,
         useNativePlayer: true,
         usePost: false,
         useLegacyParser: false,
         adBlocker: false,
         userAgent: '',
         referer: '',
         searchURL: '$baseUrl/search?wd=@keyword',
         searchList: '',
         searchName: '',
         searchResult: '',
         chapterRoads: '',
         chapterResult: '',
       );

  final Future<PluginSearchResponse> Function(String keyword)? onQuery;
  int queryCount = 0;

  @override
  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async {
    queryCount++;
    if (onQuery != null) {
      return onQuery!(keyword);
    }
    return PluginSearchResponse(
      pluginName: name,
      data: [SearchItem(name: keyword, src: '$baseUrl/detail/1')],
    );
  }
}

class _GuardedRuleExecutor implements RuleRequestExecutor {
  _GuardedRuleExecutor({
    required this.guard,
    required this.responder,
  });

  final SourceTrafficGuard guard;
  final Future<String> Function(
    PreparedRuleRequest request,
    RuleExecutionConfig config,
    CancelToken cancelToken,
  ) responder;

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) {
    return guard.run<String>(
      url: request.url,
      method: request.method,
      query: request.query,
      cancelToken: cancelToken,
      deduplicate: request.method == 'GET',
      action: (innerToken) => responder(request, config, innerToken),
    );
  }
}

class _RuleEngineBackedAnimePlugin extends Plugin {
  _RuleEngineBackedAnimePlugin({
    required super.name,
    required super.ruleId,
    required super.baseUrl,
    required RuleEngine engine,
  }) : _engine = engine,
       super(
         api: '8',
         type: 'movie',
         version: '1.1.0',
         supportedMediaTypes: const ['anime', 'tv', 'movie'],
         muliSources: true,
         useWebview: false,
         useNativePlayer: true,
         usePost: false,
         useLegacyParser: false,
         adBlocker: false,
         userAgent: '',
         referer: '',
         searchURL: '',
         searchList: '',
         searchName: '',
         searchResult: '',
         chapterRoads: '',
         chapterResult: '',
         searchMode: RuleMode.api,
         searchApiConfig: ApiSearchConfig(
           request: ApiRequestConfig(
             method: 'GET',
             url: '$baseUrl/api.php/provide/vod/',
             query: const {'ac': 'videolist', 'wd': '@keyword', 'pg': 1},
           ),
           listPath: r'$.list[*]',
           namePath: r'$.vod_name',
           sourcePath: r'$.vod_id',
         ),
       );

  final RuleEngine _engine;

  @override
  Future<RuleSearchTrace> traceSearch(
    String keyword, {
    RuleCancelToken? cancelToken,
  }) {
    return _engine.search(executionConfig, keyword, cancelToken: cancelToken);
  }
}

void main() {
  group('Phase 4 动漫跨频道健康共享与 SourceTrafficGuard 集成', () {
    test(
      'PluginSearchService 按跨频道共享健康分调度、过滤非动漫源、尊重 30 分钟 CAPTCHA 冷却且支持手动重试',
      () async {
        final now = DateTime(2026, 11, 26, 16, 0);
        final health = SourceHealthRepository(clock: () => now);
        final scoring = SourceScoringEngine(healthRepository: health);

        final callOrder = <String>[];
        final slowPlugin = _StubAnimePlugin(
          name: '低清慢源',
          ruleId: 'kazumi-plus.slow-anime',
          baseUrl: 'https://slow.example.com',
          onQuery: (kw) async {
            callOrder.add('低清慢源');
            return PluginSearchResponse(
              pluginName: '低清慢源',
              data: [SearchItem(name: kw, src: 'https://slow/1')],
            );
          },
        );
        final fastPlugin = _StubAnimePlugin(
          name: '高速1080P源',
          ruleId: 'kazumi-plus.fast-anime',
          baseUrl: 'https://fast.example.com',
          onQuery: (kw) async {
            callOrder.add('高速1080P源');
            return PluginSearchResponse(
              pluginName: '高速1080P源',
              data: [SearchItem(name: kw, src: 'https://fast/1')],
            );
          },
        );
        final captchaPlugin = _StubAnimePlugin(
          name: '冷却验证源',
          ruleId: 'kazumi-plus.captcha-anime',
          baseUrl: 'https://captcha.example.com',
          onQuery: (kw) async {
            callOrder.add('冷却验证源');
            return PluginSearchResponse(
              pluginName: '冷却验证源',
              data: [SearchItem(name: kw, src: 'https://captcha/1')],
            );
          },
        );
        final movieOnlyPlugin = _StubAnimePlugin(
          name: '纯影视源',
          ruleId: 'kazumi-plus.movie-only',
          baseUrl: 'https://movieonly.example.com',
          supportedMediaTypes: const ['movie', 'tv'],
        );

        // 模拟影视侧已积累的实测健康数据反哺动漫排序（高速 1080P 胜出低清 448P）
        health.recordSuccess(
          pluginIdentityKey: 'kazumi-plus.fast-anime',
          kind: MediaKind.movie,
          ttfbMs: 80,
          verifiedProfile: VerifiedStreamProfile(
            width: 1920,
            height: 1080,
            provenance: StreamProfileProvenance.mpvTrackList,
            verifiedAt: now,
          ),
          now: now,
        );
        health.recordSuccess(
          pluginIdentityKey: 'kazumi-plus.slow-anime',
          kind: MediaKind.movie,
          ttfbMs: 1400,
          verifiedProfile: VerifiedStreamProfile(
            width: 800,
            height: 448,
            provenance: StreamProfileProvenance.mpvTrackList,
            verifiedAt: now,
          ),
          now: now,
        );
        // 冷却验证源处于 30 分钟 CAPTCHA 冷却期
        health.recordFailure(
          pluginIdentityKey: 'kazumi-plus.captcha-anime',
          kind: MediaKind.anime,
          failureKind: SourceFailureKind.captchaRequired,
          now: now,
        );

        final pluginsController = PluginsController();
        pluginsController.pluginList.addAll([
          slowPlugin,
          fastPlugin,
          captchaPlugin,
          movieOnlyPlugin,
        ]);
        final infoController = InfoController(
          CollectController(_StubCollectCrudRepository()),
        );
        final service = PluginSearchService(
          infoController: infoController,
          pluginsController: pluginsController,
          healthRepository: health,
          scoringEngine: scoring,
        );

        await service.queryAllSource('葬送的芙莉莲');

        expect(movieOnlyPlugin.queryCount, 0);
        expect(captchaPlugin.queryCount, 0);
        expect(
          infoController.pluginSearchStatus['冷却验证源'],
          PluginSearchStatus.captcha,
        );
        expect(fastPlugin.queryCount, 1);
        expect(slowPlugin.queryCount, 1);
        // 跨频道共享健康分让高速 1080P 源优先调度
        expect(callOrder.first, '高速1080P源');

        // 用户手动点击重试显式绕过自动池冷却门控，且成功后自动清除冷却
        await service.querySource('葬送的芙莉莲', '冷却验证源');
        expect(captchaPlugin.queryCount, 1);
        expect(
          infoController.pluginSearchStatus['冷却验证源'],
          PluginSearchStatus.success,
        );
        expect(
          health.isSourceInCaptchaCooldown(
            'kazumi-plus.captcha-anime',
            MediaKind.anime,
          ),
          isFalse,
        );
      },
    );

    test(
      'PluginSearchService 并发检索超过全局并发上限的多个真实 RuleEngine 动漫源不会发生信号量死锁，且取消排队不污染健康记录',
      () async {
        final guard = SourceTrafficGuard(
          hostMinInterval: Duration.zero,
          maxPerHostConcurrency: 2,
          defaultGlobalConcurrency: 2,
          constrainedGlobalConcurrency: 2,
          isConstrainedResolver: () => false,
        );
        var active = 0;
        var maxActive = 0;
        final engine = RuleEngine(
          logFailures: false,
          requestExecutor: _GuardedRuleExecutor(
            guard: guard,
            responder: (request, config, _) async {
              active++;
              if (active > maxActive) maxActive = active;
              await Future<void>.delayed(const Duration(milliseconds: 15));
              active--;
              final kw = request.query['wd'] ?? '';
              return '{"list":[{"vod_id":"101","vod_name":"$kw (${config.pluginName})"}]}';
            },
          ),
        );

        final health = SourceHealthRepository();
        final scoring = SourceScoringEngine(healthRepository: health);
        final pluginsController = PluginsController();
        for (var i = 0; i < 6; i++) {
          pluginsController.pluginList.add(
            _RuleEngineBackedAnimePlugin(
              name: '动漫源$i',
              ruleId: 'kazumi-plus.anime-$i',
              baseUrl: 'https://anime$i.example.com',
              engine: engine,
            ),
          );
        }

        final infoController = InfoController(
          CollectController(_StubCollectCrudRepository()),
        );
        final service = PluginSearchService(
          infoController: infoController,
          pluginsController: pluginsController,
          healthRepository: health,
          scoringEngine: scoring,
        );

        await service
            .queryAllSource('葬送的芙莉莲')
            .timeout(const Duration(seconds: 3));

        expect(infoController.pluginSearchResponseList.length, 6);
        for (var i = 0; i < 6; i++) {
          expect(
            infoController.pluginSearchStatus['动漫源$i'],
            PluginSearchStatus.success,
          );
        }
        expect(maxActive, lessThanOrEqualTo(2));
        expect(guard.activeGlobalRequests, 0);

        // 取消排队中的检索不应被包装为 SearchErrorException 或写入故障健康记录
        final blockGate = Completer<void>();
        final cancelEngine = RuleEngine(
          logFailures: false,
          requestExecutor: _GuardedRuleExecutor(
            guard: guard,
            responder: (request, config, cancelToken) async {
              final completer = Completer<String>();
              cancelToken.whenCancel.then((err) {
                if (!completer.isCompleted) completer.completeError(err);
              });
              blockGate.future.then((_) {
                if (!completer.isCompleted) {
                  completer.complete('{"list":[]}');
                }
              });
              return completer.future;
            },
          ),
        );
        final cancelPlugins = PluginsController();
        for (var i = 0; i < 4; i++) {
          cancelPlugins.pluginList.add(
            _RuleEngineBackedAnimePlugin(
              name: '取消源$i',
              ruleId: 'kazumi-plus.cancel-$i',
              baseUrl: 'https://cancel$i.example.com',
              engine: cancelEngine,
            ),
          );
        }
        final cancelHealth = SourceHealthRepository();
        final cancelInfo = InfoController(
          CollectController(_StubCollectCrudRepository()),
        );
        final cancelService = PluginSearchService(
          infoController: cancelInfo,
          pluginsController: cancelPlugins,
          healthRepository: cancelHealth,
          scoringEngine: SourceScoringEngine(healthRepository: cancelHealth),
        );

        final searchFuture = cancelService.queryAllSource('鬼灭之刃');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        cancelService.cancel();
        await searchFuture.timeout(const Duration(seconds: 2));
        // 等待取消信号沿底层请求回调传播并执行 finally 释放信号量槽位
        await Future<void>.delayed(const Duration(milliseconds: 20));

        for (var i = 0; i < 4; i++) {
          expect(
            cancelHealth.healthFor('kazumi-plus.cancel-$i', MediaKind.anime),
            isNull,
          );
          expect(
            cancelInfo.pluginSearchStatus['取消源$i'],
            isNot(PluginSearchStatus.error),
          );
        }
        expect(guard.activeGlobalRequests, 0);
      },
    );

    test('OnlineVideoPlaybackArgs 保留 BangumiItem 主身份并携带可切换动漫备选源', () {
      final item = BangumiItem(
        id: 400602,
        type: 2,
        name: '葬送のフリーレン',
        nameCn: '葬送的芙莉莲',
        summary: '',
        airDate: '2023-09-29',
        airWeekday: 5,
        rank: 1,
        images: const {},
        tags: const [],
        alias: const [],
        ratingScore: 9.0,
        votes: 1000,
        votesCount: const [],
        info: '',
      );
      final primary = _StubAnimePlugin(
        name: '主源',
        ruleId: 'anime.primary',
        baseUrl: 'https://primary.example.com',
      );
      final backup = _StubAnimePlugin(
        name: '备源',
        ruleId: 'anime.backup',
        baseUrl: 'https://backup.example.com',
      );
      final alt = AnimeSourceCandidate(
        plugin: backup,
        title: '葬送的芙莉莲',
        src: 'https://backup.example.com/1',
      );
      final args = OnlineVideoPlaybackArgs(
        bangumiItem: item,
        plugin: primary,
        title: '葬送的芙莉莲',
        src: 'https://primary.example.com/1',
        roads: [
          Road(
            name: '线路 1',
            data: ['https://primary.example.com/ep1'],
            identifier: ['第1集'],
          ),
        ],
        alternateSources: [alt],
      );

      expect(args.bangumiItem.id, 400602);
      expect(args.alternateSources.single.pluginIdentityKey, 'anime.backup');
      expect(
        args.alternateSources.single.id,
        'anime.backup|https://backup.example.com/1',
      );
    });
  });

  group('Phase 4 Android TV 10-Foot 播放控制与焦点回归', () {
    late AppDeviceFormFactor originalFactor;

    setUp(() {
      originalFactor = PlatformEnvironmentService.formFactor;
      PlatformEnvironmentService.setFormFactorForTesting(
        AppDeviceFormFactor.television,
      );
    });

    tearDown(() {
      PlatformEnvironmentService.setFormFactorForTesting(originalFactor);
    });

    testWidgets(
      '超 1 小时影片显示 HH:MM:SS、5 秒无操作自动隐藏 HUD、暂停时不隐藏、零 BackdropFilter',
      (tester) async {
        final overlay = TvPlaybackOverlayController();
        addTearDown(overlay.dispose);

        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            theme: buildSilverSaltTheme(brightness: Brightness.dark),
            home: TvApplicationScope(
              child: Scaffold(
                body: TvPlaybackControls(
                  controller: overlay,
                  title: '沙丘2',
                  position: const Duration(hours: 1, minutes: 5, seconds: 9),
                  duration: const Duration(hours: 2, minutes: 46, seconds: 0),
                  playing: true,
                  rate: 1.0,
                  autoHideDuration: const Duration(seconds: 5),
                  onToggle: () async {},
                  onPlay: () async {},
                  onPause: () async {},
                  onSeek: (_) async {},
                  onRate: (_) async {},
                  onExit: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );

        // 严禁在视频叠加层使用 BackdropFilter
        expect(find.byType(BackdropFilter), findsNothing);
        // 超 1 小时时间码精确格式化为 HH:MM:SS（修复旧版 65:09 / 166:00 缺陷）
        expect(find.text('01:05:09 / 02:46:00'), findsOneWidget);
        expect(overlay.visible, isTrue);

        // 播放中 5 秒无操作自动隐藏 HUD
        await tester.pump(const Duration(seconds: 5));
        await tester.pump();
        expect(overlay.visible, isFalse);

        // 暂停状态下显示 HUD 不应自动隐藏
        await tester.pumpWidget(
          MaterialApp(
            theme: buildSilverSaltTheme(brightness: Brightness.dark),
            home: TvApplicationScope(
              child: Scaffold(
                body: TvPlaybackControls(
                  controller: overlay,
                  title: '沙丘2',
                  position: const Duration(hours: 1, minutes: 5, seconds: 9),
                  duration: const Duration(hours: 2, minutes: 46, seconds: 0),
                  playing: false,
                  rate: 1.0,
                  autoHideDuration: const Duration(seconds: 5),
                  onToggle: () async {},
                  onPlay: () async {},
                  onPause: () async {},
                  onSeek: (_) async {},
                  onRate: (_) async {},
                  onExit: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        overlay.show();
        await tester.pump();
        await tester.pump(const Duration(seconds: 6));
        expect(overlay.visible, isTrue);
      },
    );

    testWidgets(
      'HUD 隐藏时支持 D-pad 左右免唤起直达寻址（±10s）与上键 1 步拉起片源抽屉',
      (tester) async {
        final overlay = TvPlaybackOverlayController()..hideIfVisible();
        addTearDown(overlay.dispose);

        Duration? soughtTo;
        var quickDrawerOpened = false;

        await tester.binding.setSurfaceSize(const Size(1280, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            theme: buildSilverSaltTheme(brightness: Brightness.dark),
            home: TvApplicationScope(
              child: Scaffold(
                body: TvPlaybackControls(
                  controller: overlay,
                  title: '奥本海默',
                  position: const Duration(minutes: 10),
                  duration: const Duration(hours: 3),
                  playing: true,
                  rate: 1.0,
                  onToggle: () async {},
                  onPlay: () async {},
                  onPause: () async {},
                  onSeek: (target) async => soughtTo = target,
                  onRate: (_) async {},
                  onExit: () {},
                  onQuickOpenDrawer: () async {
                    quickDrawerOpened = true;
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(overlay.visible, isFalse);

        // 右键免唤起直达快进 +10s（不弹出完整 HUD）
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(overlay.visible, isFalse);
        expect(find.text('+10s'), findsOneWidget);
        expect(find.text('10:10 / 03:00:00'), findsOneWidget);

        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(soughtTo, const Duration(minutes: 10, seconds: 10));

        // 等待直达寻址轻提示自然消失
        await tester.pump(const Duration(milliseconds: 750));
        expect(find.text('+10s'), findsNothing);

        // 上键 1 步拉起右侧片源与清晰度抽屉
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();
        expect(quickDrawerOpened, isTrue);

        // 两段返回栈验证：先收 HUD，再退出
        overlay.show();
        await tester.pump();
        expect(overlay.hideIfVisible(), isTrue);
        expect(overlay.hideIfVisible(), isFalse);
      },
    );
  });
}
