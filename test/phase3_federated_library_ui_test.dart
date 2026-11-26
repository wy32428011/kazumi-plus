import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/pages/player/player_failover_banner.dart';
import 'package:kazumi/pages/player/player_presentation_context.dart';
import 'package:kazumi/pages/player/player_quality_sheet.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/failover_controller.dart';
import 'package:kazumi/services/media/federated_catalog_coordinator.dart';
import 'package:kazumi/services/media/media_catalog.dart';
import 'package:kazumi/services/media/source_fanout_service.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';
import 'package:media_kit/media_kit.dart' show VideoTrack;

Plugin _makePlugin(
  String ruleId,
  String name, {
  List<String> mediaTypes = const ['movie', 'tv'],
}) {
  return Plugin.fromJson({
    'api': '1',
    'type': 'anime',
    'name': name,
    'version': '1.0',
    'muliSources': true,
    'useWebview': false,
    'useNativePlayer': true,
    'userAgent': '',
    'baseURL': 'https://$ruleId.example.com',
    'searchURL': 'https://$ruleId.example.com/search?wd=@keyword',
    'searchList': '',
    'searchName': '',
    'searchResult': '',
    'chapterRoads': '',
    'chapterResult': '',
    'ruleId': ruleId,
    'supportedMediaTypes': mediaTypes,
  });
}

class _FakeMediaProvider implements MediaProvider {
  _FakeMediaProvider({
    required this.plugin,
    this.discoverItems = const [],
    this.searchItems = const [],
    this.throwCaptchaOnSearch = false,
  });

  @override
  final Plugin plugin;

  @override
  String get ruleId => plugin.ruleId;

  @override
  List<MediaKind> get supportedKinds => const [MediaKind.movie, MediaKind.tv];

  final List<MediaSummary> discoverItems;
  final List<MediaSummary> searchItems;
  final bool throwCaptchaOnSearch;

  int discoverCalls = 0;
  int searchCalls = 0;

  @override
  Future<List<MediaCategory>> queryCategories(
    MediaKind kind, {
    CancelToken? cancelToken,
  }) async => const [];

  @override
  Future<MediaPage> queryDiscover(
    MediaKind kind, {
    String? categoryId,
    MediaSort? sort,
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    discoverCalls++;
    return MediaPage(items: discoverItems, page: page, hasMore: true);
  }

  @override
  Future<MediaPage> searchMedia(
    MediaKind kind,
    String keyword, {
    int page = 1,
    CancelToken? cancelToken,
  }) async {
    searchCalls++;
    if (throwCaptchaOnSearch) {
      throw CaptchaRequiredException(plugin.name);
    }
    return MediaPage(items: searchItems, page: page, hasMore: false);
  }

  @override
  Future<MediaDetail> queryDetail(
    MediaSummary item, {
    CancelToken? cancelToken,
  }) async => MediaDetail(summary: item);

  @override
  Future<SourcePlaylist> queryPlaylist(
    MediaSummary item, {
    MediaSeason? season,
    CancelToken? cancelToken,
  }) async => const SourcePlaylist(roads: []);
}

class _FakeCatalogService implements MediaCatalogService {
  _FakeCatalogService(this._providers);
  final List<MediaProvider> _providers;

  @override
  List<MediaProvider> providersFor(MediaKind kind) => _providers;

  @override
  MediaProvider? providerById(String ruleId) =>
      _providers.where((p) => p.ruleId == ruleId).firstOrNull;
}

class _FakeSourceSwitchingFeatures extends ChangeNotifier
    implements PlayerSourceSwitchingFeatures {
  _FakeSourceSwitchingFeatures({
    required List<PlayerSourceOption> options,
    FailoverBannerState? banner,
  }) : _options = options,
       _failoverBanner = banner;

  final List<PlayerSourceOption> _options;
  FailoverBannerState? _failoverBanner;
  bool _autoFailover = true;
  SourceRecommendationStrategy _strategy =
      SourceRecommendationStrategy.balanced;
  String? lastSwitchedOptionId;
  String? lastPinnedOptionId;
  String? lastCaptchaOptionId;
  bool undoCalled = false;

  @override
  Listenable get sourceChanges => this;

  @override
  String get currentSourceLabel => '爱奇艺资源';

  @override
  String get currentCdnGroup => 'cdn-a';

  @override
  bool get autoFailoverEnabled => _autoFailover;

  @override
  SourceRecommendationStrategy get recommendationStrategy => _strategy;

  @override
  AudioDubVariant get selectedDubVariant => AudioDubVariant.original;

  @override
  List<AudioDubVariant> get availableDubVariants => const [
    AudioDubVariant.original,
  ];

  @override
  List<PlayerSourceOption> get sourceOptions => _options;

  @override
  bool get isSwitchingSource => false;

  @override
  bool get isDiscoveringSources => false;

  @override
  FailoverBannerState? get failoverBanner => _failoverBanner;

  @override
  Future<void> setAutoFailoverEnabled(bool enabled) async {
    _autoFailover = enabled;
    notifyListeners();
  }

  @override
  Future<void> setRecommendationStrategy(
    SourceRecommendationStrategy strategy,
  ) async {
    _strategy = strategy;
    notifyListeners();
  }

  @override
  void selectDubVariant(AudioDubVariant variant) {}

  @override
  Future<void> switchToSource(String optionId) async {
    lastSwitchedOptionId = optionId;
    notifyListeners();
  }

  @override
  Future<void> togglePinSource(String optionId) async {
    lastPinnedOptionId = optionId;
    notifyListeners();
  }

  @override
  Future<void> openCaptchaVerification(
    BuildContext context,
    String optionId,
  ) async {
    lastCaptchaOptionId = optionId;
  }

  @override
  Future<void> refreshSources() async {}

  @override
  void dismissFailoverBanner() {
    _failoverBanner = null;
    notifyListeners();
  }

  @override
  Future<void> undoLastFailover() async {
    undoCalled = true;
    _failoverBanner = null;
    notifyListeners();
  }
}

void main() {
  group('FederatedCatalogCoordinator K=3 锚点与 4K-AV 独立轨', () {
    test('严格仅选 K=3 跨 CDN 健康锚点，跳过熔断、CAPTCHA 冷却与 4K-AV 独立轨', () async {
      final now = DateTime(2026, 11, 26, 14, 0);
      final health = SourceHealthRepository(clock: () => now);
      final scoring = SourceScoringEngine(healthRepository: health);
      final cache = VodPayloadCache();

      final p1 = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.iqiyi', '爱奇艺资源'),
        discoverItems: [
          MediaSummary(
            ref: MediaRef.source(
              kind: MediaKind.movie,
              ruleId: 'kazumi-plus.iqiyi',
              id: 'm1',
            ),
            title: '沙丘2',
            year: '2024',
            detailSource: 'https://iqiyi/m1',
            sourceName: '爱奇艺资源',
          ),
        ],
      );
      final p2 = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.zy360', '360资源'),
        discoverItems: [
          MediaSummary(
            ref: MediaRef.source(
              kind: MediaKind.movie,
              ruleId: 'kazumi-plus.zy360',
              id: 'm2',
            ),
            title: '沙丘2',
            year: '2024',
            detailSource: 'https://zy360/m2',
            sourceName: '360资源',
          ),
        ],
      );
      final p3 = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.hongniu', '红牛资源'),
        discoverItems: [
          MediaSummary(
            ref: MediaRef.source(
              kind: MediaKind.movie,
              ruleId: 'kazumi-plus.hongniu',
              id: 'm3',
            ),
            title: '奥本海默',
            year: '2023',
            detailSource: 'https://hongniu/m3',
            sourceName: '红牛资源',
          ),
        ],
      );
      final p4SameCdn = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.mirror', '同源镜像'),
      );
      final p5Captcha = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.captchagated', '验证站点'),
      );
      final p4kav = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.4kav', '4K-AV'),
        discoverItems: [
          MediaSummary(
            ref: MediaRef.source(
              kind: MediaKind.movie,
              ruleId: 'kazumi-plus.4kav',
              id: 'k1',
            ),
            title: '星际穿越',
            year: '2014',
            detailSource: 'https://4kav/k1',
            sourceName: '4K-AV',
          ),
        ],
      );

      // 给 p1 和 p4SameCdn 标记相同 CDN，且 p5 进入 CAPTCHA 30 分钟冷却。
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.iqiyi',
        kind: MediaKind.movie,
        cdnGroup: 'cdn-alpha',
        ttfbMs: 110,
        now: now,
      );
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.mirror',
        kind: MediaKind.movie,
        cdnGroup: 'cdn-alpha',
        ttfbMs: 120,
        now: now,
      );
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.zy360',
        kind: MediaKind.movie,
        cdnGroup: 'cdn-beta',
        ttfbMs: 140,
        now: now,
      );
      health.recordSuccess(
        pluginIdentityKey: 'kazumi-plus.hongniu',
        kind: MediaKind.movie,
        cdnGroup: 'cdn-gamma',
        ttfbMs: 160,
        now: now,
      );
      health.recordFailure(
        pluginIdentityKey: 'kazumi-plus.captchagated',
        kind: MediaKind.movie,
        failureKind: SourceFailureKind.captchaRequired,
        now: now,
      );

      final coordinator = FederatedCatalogCoordinator(
        catalog: _FakeCatalogService([
          p1,
          p4SameCdn,
          p2,
          p3,
          p5Captcha,
          p4kav,
        ]),
        healthRepository: health,
        scoringEngine: scoring,
        payloadCache: cache,
      );

      final anchors = coordinator.selectAnchors(MediaKind.movie, now: now);
      expect(anchors.length, 3);
      expect(
        anchors.map((a) => a.ruleId),
        containsAll([
          'kazumi-plus.iqiyi',
          'kazumi-plus.zy360',
          'kazumi-plus.hongniu',
        ]),
      );
      expect(anchors.map((a) => a.ruleId), isNot(contains('kazumi-plus.4kav')));
      expect(
        anchors.map((a) => a.ruleId),
        isNot(contains('kazumi-plus.captchagated')),
      );

      final page = await coordinator.loadFederatedPage(
        kind: MediaKind.movie,
        category: SemanticMediaCategory.all,
        page: 1,
      );
      expect(p1.discoverCalls, 1);
      expect(p2.discoverCalls, 1);
      expect(p3.discoverCalls, 1);
      expect(p4SameCdn.discoverCalls, 0);
      expect(p5Captcha.discoverCalls, 0);
      expect(p4kav.discoverCalls, 0);
      expect(page.succeededAnchors, 3);
      expect(page.clusters.length, 2); // 沙丘2 + 奥本海默

      // 独立异步 4K-AV 轨按需加载，不阻塞锚点主墙
      final fourKavRail = await coordinator.loadFourKavRail(
        kind: MediaKind.movie,
      );
      expect(p4kav.discoverCalls, 1);
      expect(fourKavRail.length, 1);
      expect(fourKavRail.single.primaryTitle, '星际穿越');
    });
  });

  group('SourceFanOutService 合规门控与遥测汇报', () {
    test('跳过 30 分钟 CAPTCHA 冷却与熔断源，聚合健康源结果并汇报透明统计', () async {
      final now = DateTime(2026, 11, 26, 15, 0);
      final health = SourceHealthRepository(clock: () => now);
      final scoring = SourceScoringEngine(healthRepository: health);

      final healthyProvider = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.iqiyi', '爱奇艺资源'),
        searchItems: [
          MediaSummary(
            ref: MediaRef.source(
              kind: MediaKind.movie,
              ruleId: 'kazumi-plus.iqiyi',
              id: 's1',
            ),
            title: '流浪地球2',
            year: '2023',
            detailSource: 'https://iqiyi/s1',
            sourceName: '爱奇艺资源',
          ),
        ],
      );
      final captchaProvider = _FakeMediaProvider(
        plugin: _makePlugin('kazumi-plus.needverify', '需验证源'),
        throwCaptchaOnSearch: true,
      );
      health.recordFailure(
        pluginIdentityKey: 'kazumi-plus.needverify',
        kind: MediaKind.movie,
        failureKind: SourceFailureKind.captchaRequired,
        now: now,
      );

      final fanOut = SourceFanOutService(
        catalog: _FakeCatalogService([healthyProvider, captchaProvider]),
        healthRepository: health,
        scoringEngine: scoring,
        payloadCache: VodPayloadCache(),
      );

      final summary = await fanOut.searchClustered(
        kind: MediaKind.movie,
        keyword: '流浪地球2',
      );
      expect(healthyProvider.searchCalls, 1);
      expect(captchaProvider.searchCalls, 0); // 冷却期内严禁轰炸/绕过
      expect(summary.succeededSources, 1);
      expect(summary.captchaPlugins.map((p) => p.name), ['需验证源']);
      expect(summary.clusters.length, 1);
      expect(summary.clusters.single.primaryTitle, '流浪地球2');
    });
  });

  group('SourceMediaLibrary 存量四表 100% 兼容与无损折叠', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('kazumi_plus_lib_test_');
      Hive.init(tempDir.path);
      await SourceMediaLibrary.instance.resetForTesting();
    });

    tearDown(() async {
      await SourceMediaLibrary.instance.resetForTesting();
      await Hive.close();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('完整读取存量 SHA256 主键四表夹具，执行无损折叠、跨源查进度与级联清理', () async {
      final refA = MediaRef.source(
        kind: MediaKind.tv,
        ruleId: 'kazumi-plus.iqiyi',
        id: 'tv-100',
      );
      final refB = MediaRef.source(
        kind: MediaKind.tv,
        ruleId: 'kazumi-plus.zy360',
        id: 'tv-200',
      );
      final summaryA = MediaSummary(
        ref: refA,
        title: '繁花',
        year: '2023',
        detailSource: 'https://iqiyi/tv-100',
        sourceName: '爱奇艺资源',
      );
      final summaryB = MediaSummary(
        ref: refB,
        title: '繁花',
        year: '2023',
        detailSource: 'https://zy360/tv-200',
        sourceName: '360资源',
      );

      // 预写入老版本四表格式数据（严格使用 SHA256(MediaRef.key) 主键）
      final colBox = await Hive.openBox<String>('plus_source_collections_v1');
      final histBox = await Hive.openBox<String>('plus_source_histories_v1');
      final keyA = sha256.convert(utf8.encode(refA.key)).toString();
      final keyB = sha256.convert(utf8.encode(refB.key)).toString();

      await colBox.put(
        keyA,
        jsonEncode({
          'media': summaryA.toJson(),
          'status': 1,
          'updatedAt': DateTime(2026, 11, 20, 10, 0).toIso8601String(),
        }),
      );
      await colBox.put(
        keyB,
        jsonEncode({
          'media': summaryB.toJson(),
          'status': 1,
          'updatedAt': DateTime(2026, 11, 21, 10, 0).toIso8601String(),
        }),
      );
      await histBox.put(
        keyA,
        jsonEncode(
          SourceHistory(
            media: summaryA,
            roadId: 'r1',
            episodeId: 'ep4',
            episodeTitle: '第 4 集',
            positionMs: 420000,
            durationMs: 2700000,
            updatedAt: DateTime(2026, 11, 20, 11, 0),
          ).toJson(),
        ),
      );
      await histBox.put(
        keyB,
        jsonEncode(
          SourceHistory(
            media: summaryB,
            roadId: 'r1',
            episodeId: 'ep5',
            episodeTitle: '第 5 集',
            positionMs: 600000,
            durationMs: 2700000,
            updatedAt: DateTime(2026, 11, 22, 11, 0),
          ).toJson(),
        ),
      );
      await colBox.close();
      await histBox.close();

      // 启动库应无缝读取存量四表
      final lib = SourceMediaLibrary.instance;
      await lib.init();
      expect(lib.collections.length, 2);
      expect(lib.histories.length, 2);

      // 建立可恢复弱关联索引后，展示层折叠为 1 条且保留两份底层 SHA256 主键记录
      final cluster = WorkCluster(
        clusterKey: 'douban:34874432',
        kind: MediaKind.tv,
        primaryTitle: '繁花',
        year: '2023',
        dubVariant: AudioDubVariant.original,
        candidates: [
          MediaCandidate(summary: summaryA, richMeta: const RichMediaMeta()),
          MediaCandidate(summary: summaryB, richMeta: const RichMediaMeta()),
        ],
      );
      await lib.linkWorkCluster(
        cluster,
        activeRefKey: refB.key,
        pinnedRuleId: 'kazumi-plus.zy360',
        updatePinned: true,
      );

      final foldedCols = lib.foldedCollections(kind: MediaKind.tv);
      expect(foldedCols.length, 1);
      expect(foldedCols.single.sourceCount, 2);
      expect(foldedCols.single.primary.media.ref, refB); // 最新更新时间胜出
      expect(lib.collections.length, 2); // 无损保留底层四表

      final foldedHists = lib.foldedHistories(kind: MediaKind.tv);
      expect(foldedHists.length, 1);
      expect(foldedHists.single.primary.episodeTitle, '第 5 集');
      expect(lib.latestHistoryForCluster(cluster)?.episodeTitle, '第 5 集');
      expect(lib.pinnedRuleIdForGroup('douban:34874432'), 'kazumi-plus.zy360');

      // 级联清理作品簇历史后无“影子残留”
      await lib.removeHistoryCluster(foldedHists.single.linkedRefs);
      expect(lib.histories, isEmpty);
      expect(lib.foldedHistories(), isEmpty);
    });
  });

  group('银盐放映室视觉系统与零 BackdropFilter 播放器抽屉验收', () {
    test('三套主题令牌色阶与强调色符合银盐放映室规范', () {
      final darkTheme = buildSilverSaltTheme(brightness: Brightness.dark);
      final oledTheme = buildSilverSaltTheme(
        brightness: Brightness.dark,
        oledEnhance: true,
      );
      final lightTheme = buildSilverSaltTheme(brightness: Brightness.light);

      expect(
        darkTheme.extension<KazumiThemeTokens>()!.canvas,
        const Color(0xFF0B0C0E),
      );
      expect(
        oledTheme.extension<KazumiThemeTokens>()!.canvas,
        const Color(0xFF000000),
      );
      expect(
        lightTheme.extension<KazumiThemeTokens>()!.canvas,
        const Color(0xFFF6F5F2),
      );
      expect(
        darkTheme.extension<KazumiThemeTokens>()!.accent,
        KazumiThemeTokens.tungstenGold,
      );
      expect(
        lightTheme.extension<KazumiThemeTokens>()!.accent,
        KazumiThemeTokens.warmBronze,
      );
    });

    testWidgets(
      'PlayerSourceQualityPanel 与 PlayerFailoverBanner 零 BackdropFilter 且响应切源与撤销',
      (tester) async {
        final qualityController = PlaybackQualityController(
          canInteract: () => true,
        );
        addTearDown(qualityController.dispose);
        qualityController.tracks = [
          const VideoTrack('1', null, null, w: 1920, h: 1080, bitrate: 6000000),
        ];
        qualityController.width = 1920;
        qualityController.height = 1080;
        qualityController.selectedId = '1';

        final features = _FakeSourceSwitchingFeatures(
          options: [
            PlayerSourceOption(
              id: 'opt-current',
              ruleId: 'kazumi-plus.iqiyi',
              sourceName: '爱奇艺资源',
              isCurrent: true,
              isPinned: false,
              probeStatus: CandidateProbeStatus.ready,
              ttfbMs: 85,
              cdnGroup: 'cdn-a',
              isSameCdnAsCurrent: true,
              verifiedProfile: VerifiedStreamProfile(
                width: 1920,
                height: 1080,
                provenance: StreamProfileProvenance.mpvTrackList,
                verifiedAt: DateTime(2026, 11, 26),
              ),
              score: 92,
              dubVariant: AudioDubVariant.original,
            ),
            const PlayerSourceOption(
              id: 'opt-alt',
              ruleId: 'kazumi-plus.zy360',
              sourceName: '360资源',
              isCurrent: false,
              isPinned: false,
              probeStatus: CandidateProbeStatus.ready,
              ttfbMs: 112,
              cdnGroup: 'cdn-b',
              isSameCdnAsCurrent: false,
              score: 88,
              dubVariant: AudioDubVariant.original,
            ),
            const PlayerSourceOption(
              id: 'opt-captcha',
              ruleId: 'kazumi-plus.4kav',
              sourceName: '4K-AV',
              isCurrent: false,
              isPinned: false,
              probeStatus: CandidateProbeStatus.captchaRequired,
              cdnGroup: 'cdn-c',
              isSameCdnAsCurrent: false,
              score: 0,
              dubVariant: AudioDubVariant.original,
              canOpenManualCaptcha: true,
            ),
          ],
          banner: FailoverBannerState(
            fromSourceName: '旧源',
            toSourceName: '爱奇艺资源',
            reasonText: '播放卡顿',
            tier: 2,
            canUndo: true,
            createdAt: DateTime(2026, 11, 26),
          ),
        );
        addTearDown(features.dispose);

        await tester.binding.setSurfaceSize(const Size(420, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          MaterialApp(
            theme: buildSilverSaltTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: Stack(
                children: [
                  PlayerSourceQualityPanel(
                    controller: qualityController,
                    sourceFeatures: features,
                  ),
                  Positioned.fill(
                    child: PlayerFailoverBanner(
                      features: features,
                      disableAnimations: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        // 严禁在视频叠加层使用 BackdropFilter
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.text('片源与清晰度'), findsOneWidget);
        expect(find.text('实测 1080P'), findsOneWidget);
        expect(find.text('独立节点'), findsOneWidget);
        expect(find.text('切回原源'), findsOneWidget);

        // 点击撤销容灾按钮
        await tester.tap(find.text('切回原源'));
        await tester.pump();
        expect(features.undoCalled, isTrue);

        // 点击备选源触发切换
        await tester.tap(find.text('360资源'));
        await tester.pump();
        expect(features.lastSwitchedOptionId, 'opt-alt');
        expect(tester.takeException(), isNull);
      },
    );
  });
}
