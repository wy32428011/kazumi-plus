import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';
import 'package:kazumi/services/media/rule_media_catalog_service.dart';
import 'package:kazumi/services/media/source_traffic_guard.dart';
import 'package:kazumi/services/media/vod_payload_cache.dart';
import 'package:kazumi/services/media/work_cluster_matcher.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

void main() {
  group('MediaTextNormalizer', () {
    test('decodes multi-encoded HTML entities up to 4 rounds', () {
      expect(
        MediaTextNormalizer.decodeHtmlRecursive(
          '&amp;amp;amp;quot;Dune&amp;amp;amp;quot; &amp;amp; Part Two',
        ),
        '"Dune" & Part Two',
      );
      expect(
        MediaTextNormalizer.decodeHtmlRecursive('A&nbsp;&nbsp;B'),
        'A B',
      );
    });

    test('cleans malformed years and rejects invalid values', () {
      expect(MediaTextNormalizer.cleanYear('2026–'), '2026');
      expect(MediaTextNormalizer.cleanYear('(2025年)'), '2025');
      expect(MediaTextNormalizer.cleanYear('1984'), '1984');
      expect(MediaTextNormalizer.cleanYear('0'), '');
      expect(MediaTextNormalizer.cleanYear('未知'), '');
    });

    test('filters fake MacCMS vod_score and keeps honest douban score', () {
      expect(
        MediaTextNormalizer.parseHonestRating(
          doubanScore: '0.0',
          rawRating: '9.0',
          isMacCmsVodScore: true,
        ),
        '',
      );
      expect(
        MediaTextNormalizer.parseHonestRating(
          doubanScore: '8.3',
          rawRating: '9.0',
          isMacCmsVodScore: true,
        ),
        '8.3',
      );
      expect(
        MediaTextNormalizer.parseHonestRating(
          doubanScore: '11.5',
          rawRating: '9.0',
          isMacCmsVodScore: true,
        ),
        '',
      );
    });

    test('folds traditional Chinese and parses strict episode numbers', () {
      expect(
        MediaTextNormalizer.toSimplifiedChinese('慶餘年 進擊的巨人 粵語版'),
        '庆余年 进击的巨人 粤语版',
      );
      expect(MediaTextNormalizer.parseEpisodeNumber('第01集'), 1);
      expect(MediaTextNormalizer.parseEpisodeNumber('EP08'), 8);
      expect(MediaTextNormalizer.parseEpisodeNumber('e12'), 12);
      expect(MediaTextNormalizer.parseEpisodeNumber('1080P'), isNull);
      expect(MediaTextNormalizer.parseEpisodeNumber('4K'), isNull);
      expect(MediaTextNormalizer.parseEpisodeNumber('S02E03'), isNull);
      expect(MediaTextNormalizer.parseEpisodeNumber('TC抢先版'), isNull);
    });

    test('detects dub variants without false splitting domestic dramas', () {
      expect(
        MediaTextNormalizer.detectDubVariant(
          title: '庆余年',
          statusText: 'HD国语',
          region: '中国大陆',
        ),
        AudioDubVariant.original,
      );
      expect(
        MediaTextNormalizer.detectDubVariant(
          title: '沙丘2',
          statusText: 'HD国语',
          region: '美国',
        ),
        AudioDubVariant.mandarinDub,
      );
      expect(
        MediaTextNormalizer.detectDubVariant(
          title: '沙丘2(粤语)',
          statusText: 'HD',
          region: '美国',
        ),
        AudioDubVariant.cantoneseDub,
      );
    });

    test('extracts explicit season tokens and never infers season 1', () {
      expect(MediaTextNormalizer.extractExplicitSeasonToken('庆余年'), isNull);
      expect(
        MediaTextNormalizer.extractExplicitSeasonToken('庆余年 第二季'),
        2,
      );
      expect(
        MediaTextNormalizer.extractExplicitSeasonToken('Silo Season 2'),
        2,
      );
    });
  });

  group('WorkClusterMatcher', () {
    const matcher = WorkClusterMatcher();

    MediaCandidate makeCandidate({
      required String ruleId,
      required String id,
      required String title,
      MediaKind kind = MediaKind.movie,
      String year = '',
      String region = '',
      String statusText = '',
      String detailSource = '',
      RichMediaMeta richMeta = RichMediaMeta.empty,
      double score = 0.7,
    }) {
      return MediaCandidate(
        summary: MediaSummary(
          ref: MediaRef.source(ruleId: ruleId, kind: kind, id: id),
          title: title,
          detailSource: detailSource.isEmpty ? id : detailSource,
          sourceName: ruleId,
          year: year,
          region: region,
          statusText: statusText,
        ),
        richMeta: richMeta,
        score: score,
      );
    }

    test('clusters Tier-1 doubanId and separates dubbed sibling clusters', () {
      final orig1 = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '101',
        title: '沙丘2',
        year: '2024',
        richMeta: const RichMediaMeta(
          doubanId: '35575567',
          dubVariant: AudioDubVariant.original,
        ),
        score: 0.9,
      );
      final orig2 = makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        id: '202',
        title: '沙丘2',
        year: '2024',
        richMeta: const RichMediaMeta(
          doubanId: '35575567',
          dubVariant: AudioDubVariant.original,
        ),
        score: 0.85,
      );
      final dubCn = makeCandidate(
        ruleId: 'kazumi-plus.hongniu',
        id: '303',
        title: '沙丘2(国语)',
        year: '2024',
        richMeta: const RichMediaMeta(
          doubanId: '35575567',
          dubVariant: AudioDubVariant.mandarinDub,
        ),
        score: 0.88,
      );

      final clusters = matcher.cluster([orig1, orig2, dubCn]);
      expect(clusters.length, 1);
      expect(clusters.single.candidates.length, 2);
      expect(clusters.single.dubVariant, AudioDubVariant.original);
      expect(clusters.single.siblingDubClusters.length, 1);
      expect(
        clusters.single.siblingDubClusters.single.dubVariant,
        AudioDubVariant.mandarinDub,
      );
      expect(
        clusters.single.siblingDubClusters.single.candidates.single.ruleId,
        'kazumi-plus.hongniu',
      );
    });

    test('blocks Tier-1 mislabeled doubanId when year and title diverge', () {
      final a = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '1',
        title: '沙丘2',
        year: '2024',
        richMeta: const RichMediaMeta(doubanId: '1234567'),
      );
      final b = makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        id: '2',
        title: '霸王别姬',
        year: '1993',
        richMeta: const RichMediaMeta(doubanId: '1234567'),
      );
      expect(matcher.cluster([a, b]).length, 2);
    });

    test('prevents remake false merge (Dune 2024 vs Dune 1984)', () {
      final dune2024 = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '1',
        title: '沙丘',
        year: '2024',
        richMeta: const RichMediaMeta(directors: ['丹尼斯·维伦纽瓦']),
      );
      final dune1984 = makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        id: '2',
        title: '沙丘',
        year: '1984',
        richMeta: const RichMediaMeta(directors: ['大卫·林奇']),
      );
      expect(matcher.cluster([dune2024, dune1984]).length, 2);
    });

    test('prevents multi-season and explicit-season false merge', () {
      final sUnmarked = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '10',
        kind: MediaKind.tv,
        title: '庆余年',
        year: '2019',
      );
      final s2 = makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        id: '20',
        kind: MediaKind.tv,
        title: '庆余年 第二季',
        year: '2024',
        richMeta: const RichMediaMeta(seasonToken: 2),
      );
      final multiSeason = makeCandidate(
        ruleId: 'kazumi-plus.hongniu',
        id: '30',
        kind: MediaKind.tv,
        title: '庆余年',
        year: '2019',
        richMeta: const RichMediaMeta(hasExplicitSeasons: true),
      );
      expect(matcher.cluster([sUnmarked, s2, multiSeason]).length, 3);
    });

    test('enforces strict 4K-AV bidirectional CJK + English and exact year', () {
      final mac = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '101',
        title: '沙丘2',
        year: '2024',
        richMeta: const RichMediaMeta(
          aliases: ['Dune: Part Two'],
          directors: ['丹尼斯·维伦纽瓦'],
        ),
      );
      final fourKavMatch = makeCandidate(
        ruleId: 'kazumi-plus.4kav',
        id: 'https://www.4k-av.com/movie/009163-dune-part-two',
        detailSource: 'https://www.4k-av.com/movie/009163-dune-part-two',
        title: '沙丘2',
        year: '2024',
      );
      final fourKavWrongYear = makeCandidate(
        ruleId: 'kazumi-plus.4kav',
        id: 'https://www.4k-av.com/movie/009163-dune-part-two-2023',
        detailSource: 'https://www.4k-av.com/movie/009163-dune-part-two',
        title: '沙丘2',
        year: '2023',
      );

      expect(matcher.cluster([mac, fourKavMatch]).length, 1);
      expect(matcher.cluster([mac, fourKavWrongYear]).length, 2);
    });

    test('splits completed TV shows when episode count diverges > 20%', () {
      final tvA = makeCandidate(
        ruleId: 'kazumi-plus.iqiyi',
        id: '1',
        kind: MediaKind.tv,
        title: '测试剧集名',
        year: '2024',
        richMeta: const RichMediaMeta(
          isCompleted: true,
          reportedEpisodeCount: 40,
        ),
      );
      final tvB = makeCandidate(
        ruleId: 'kazumi-plus.zy360',
        id: '2',
        kind: MediaKind.tv,
        title: '测试剧集名',
        year: '2024',
        richMeta: const RichMediaMeta(
          isCompleted: true,
          reportedEpisodeCount: 24,
        ),
      );
      expect(matcher.cluster([tvA, tvB]).length, 2);
    });
  });

  group('VodPayloadCache 3->1 reuse', () {
    test('reuses MacCMS ac=videolist payload for detail and playlist with 0 extra requests', () async {
      final jsonMap =
          jsonDecode(File('assets/plugins/iqiyi.json').readAsStringSync())
              as Map<String, dynamic>;
      final plugin = Plugin.fromJson(jsonMap);
      final cache = VodPayloadCache();
      final executor = _CountingExecutor([
        jsonEncode({
          'page': 1,
          'pagecount': 2,
          'list': [
            {
              'vod_id': 98765,
              'type_id': 10,
              'vod_name': '测试电影 &amp;amp;amp; 特别版',
              'vod_pic': 'https://img.example.com/poster.jpg',
              'vod_year': '2026–',
              'vod_area': '美国',
              'vod_remarks': 'HD中字',
              'vod_score': '9.0',
              'vod_douban_id': '35575567',
              'vod_douban_score': '0.0',
              'vod_director': '克里斯托弗·诺兰',
              'vod_actor': '演员甲,演员乙',
              'vod_sub': 'Test Movie',
              'vod_class': '科幻,动作',
              'vod_content': '<p>完整简介内容</p>',
              'vod_play_from': 'iqiyi',
              'vod_play_url': r'HD中字$https://cdn.example.com/1/index.m3u8',
            },
          ],
        }),
      ]);
      final provider = RuleMediaProvider(
        plugin,
        engine: RuleEngine(requestExecutor: executor, logFailures: false),
        payloadCache: cache,
      );

      final page = await provider.queryDiscover(MediaKind.movie);
      expect(executor.callCount, 1);
      expect(page.items.length, 1);
      final summary = page.items.single;
      expect(summary.title, '测试电影 & 特别版');
      expect(summary.year, '2026');
      // 伪 vod_score=9.0 已屏蔽，无有效豆瓣分时置空
      expect(summary.ratingText, '');

      // 详情与播放列表均直接命中 VodPayloadCache，零额外网络请求
      final detail = await provider.queryDetail(summary);
      final playlist = await provider.queryPlaylist(summary);
      expect(executor.callCount, 1);
      expect(detail.description, '完整简介内容');
      expect(detail.aliases, ['Test Movie']);
      expect(playlist.roads.length, 1);
      expect(playlist.roads.single.episodes.single.id, 'feature');
      expect(
        playlist.roads.single.episodes.single.url,
        'https://cdn.example.com/1/index.m3u8',
      );
      expect(cache.getRichMeta(summary.ref)?.doubanId, '35575567');
    });

    test('evicts LRU entries and expires entries past TTL', () {
      var clock = DateTime(2026, 1, 1, 12, 0, 0);
      final cache = VodPayloadCache(
        maxEntries: 2,
        ttl: const Duration(minutes: 15),
        now: () => clock,
      );
      CachedVodPayload entry(String id) {
        final ref = MediaRef.source(
          ruleId: 'r1',
          kind: MediaKind.movie,
          id: id,
        );
        return CachedVodPayload(
          ref: ref,
          summary: MediaSummary(ref: ref, title: id, detailSource: id),
          richMeta: RichMediaMeta.empty,
          cachedAt: clock,
        );
      }

      cache.put(entry('1'));
      cache.put(entry('2'));
      // Touch 1 so 2 becomes oldest
      expect(cache.get(entry('1').ref), isNotNull);
      cache.put(entry('3'));
      expect(cache.get(entry('2').ref), isNull);
      expect(cache.get(entry('1').ref), isNotNull);

      clock = clock.add(const Duration(minutes: 16));
      expect(cache.get(entry('1').ref), isNull);
    });
  });

  group('SourceTrafficGuard', () {
    test('enforces global & per-host concurrency and deduplicates in-flight GETs', () async {
      var constrained = false;
      final guard = SourceTrafficGuard(
        hostMinInterval: Duration.zero,
        maxPerHostConcurrency: 2,
        defaultGlobalConcurrency: 4,
        constrainedGlobalConcurrency: 2,
        isConstrainedResolver: () => constrained,
      );

      // 1. Concurrent identical GETs deduplicate
      var execCount = 0;
      final gate = Completer<String>();
      final f1 = guard.run<String>(
        url: 'https://a.example.com/api?t=1&pg=1',
        action: (_) {
          execCount++;
          return gate.future;
        },
      );
      final cancelA = CancelToken();
      final f2 = guard.run<String>(
        url: 'https://a.example.com/api?pg=1&t=1',
        cancelToken: cancelA,
        action: (_) {
          execCount++;
          return gate.future;
        },
      );
      expect(guard.deduplicatedHits, 1);

      // Cancelling f2 must not abort f1
      cancelA.cancel('caller2 cancelled');
      await expectLater(f2, throwsA(anything));
      gate.complete('ok');
      expect(await f1, 'ok');
      expect(execCount, 1);

      // 2. Constrained mode caps global concurrency to 2
      constrained = true;
      expect(guard.currentGlobalLimit, 2);
      var concurrent = 0;
      var maxConcurrent = 0;
      await Future.wait(
        List.generate(5, (i) {
          return guard.run<void>(
            url: 'https://host$i.example.com/vod',
            deduplicate: false,
            action: (_) async {
              concurrent++;
              if (concurrent > maxConcurrent) maxConcurrent = concurrent;
              await Future<void>.delayed(const Duration(milliseconds: 20));
              concurrent--;
            },
          );
        }),
      );
      expect(maxConcurrent, lessThanOrEqualTo(2));
    });
  });
}

class _CountingExecutor implements RuleRequestExecutor {
  _CountingExecutor(this._responses);

  final List<String> _responses;
  int callCount = 0;

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    callCount++;
    return _responses.removeAt(0);
  }
}
