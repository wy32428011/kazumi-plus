import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/request/apis/bilibili_danmaku_api.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/storage/settings_keys.dart';

void main() {
  group('DanmakuApi.normalizeSearchKeyword & buildSearchCandidates', () {
    test('strips trailing Chinese and EP episode suffixes', () {
      expect(DanmakuApi.normalizeSearchKeyword('葬送的芙莉莲 第01集'), '葬送的芙莉莲');
      expect(DanmakuApi.normalizeSearchKeyword('鬼灭之刃 EP12'), '鬼灭之刃');
      expect(DanmakuApi.normalizeSearchKeyword('  进击的巨人  '), '进击的巨人');
    });

    test('cleans quality/dubbing/year tags and deduplicates candidates', () {
      expect(
        DanmakuApi.buildSearchCandidates([
          '流浪地球2 (2023) 4K',
          '流浪地球2 HD',
          '狂飙 第1部 (2023) 国语',
        ]),
        [
          '流浪地球2',
          '狂飙 第1部',
          '狂飙',
        ],
      );
    });
  });

  group('DanmakuApi.normalizeCustomBaseUrl', () {
    test('normalizes valid http/https URLs and strips trailing /api/v2', () {
      expect(
        DanmakuApi.normalizeCustomBaseUrl(' https://dm.example.com/ '),
        'https://dm.example.com',
      );
      expect(
        DanmakuApi.normalizeCustomBaseUrl('https://dm.example.com/token/api/v2/'),
        'https://dm.example.com/token',
      );
      expect(
        DanmakuApi.normalizeCustomBaseUrl('http://127.0.0.1:9321/api/v2'),
        'http://127.0.0.1:9321',
      );
    });

    test('rejects invalid or non-http schemes', () {
      expect(DanmakuApi.normalizeCustomBaseUrl(''), '');
      expect(DanmakuApi.normalizeCustomBaseUrl('ftp://example.com'), '');
      expect(DanmakuApi.normalizeCustomBaseUrl('not-a-url'), '');
    });
  });

  group('Danmaku response catalog & inline episodes', () {
    test('propagates catalog and parses inline episodes', () {
      final search = DanmakuSearchResponse.fromJson(
        {
          'hasMore': false,
          'animes': [
            {
              'animeId': 42,
              'animeTitle': '测试作品',
              'typeDescription': '电视剧',
              'episodes': [
                {'episodeId': 4201, 'episodeTitle': '第1集'},
              ],
            },
          ],
        },
        catalog: DanmakuCatalog.custom,
      );
      expect(search.animes, hasLength(1));
      expect(search.animes.first.catalog, DanmakuCatalog.custom);
      expect(search.animes.first.inlineEpisodes, hasLength(1));
      expect(search.animes.first.inlineEpisodes.first.catalog, DanmakuCatalog.custom);
      expect(search.animes.first.inlineEpisodes.first.episodeId, 4201);

      final epResp = DanmakuEpisodeResponse.fromJson(
        {
          'bangumi': {
            'animeId': 42,
            'episodes': [
              {'episodeId': 4202, 'episodeTitle': '第2集'},
            ],
          },
          'errorCode': 0,
          'success': true,
          'errorMessage': '',
        },
        catalog: DanmakuCatalog.custom,
      );
      expect(epResp.bangumiId, 42);
      expect(epResp.episodes.single.catalog, DanmakuCatalog.custom);
    });
  });

  group('BilibiliDanmakuApi.parseXml', () {
    test('parses scroll, top, bottom danmakus and decodes entities', () {
      const xml = '''
<i>
  <d p="2.5,1,25,16777215,1700000000,0,abc,1,10">hello &amp; world</d>
  <d p="5.0,5,25,16711680,1700000000,0,abc,2,10">&lt;顶部&gt;</d>
  <d p="8.2,4,25,65280,1700000000,0,abc,3,10">底部弹幕</d>
  <d p="9.0,1,25,16777215">   </d>
  <d p="bad">ignored</d>
</i>
''';
      final entries = BilibiliDanmakuApi.parseXml(xml);
      expect(entries, hasLength(3));
      expect(entries[0].time, 2.5);
      expect(entries[0].type, 1);
      expect(entries[0].message, 'hello & world');
      expect(entries[0].source, 'BiliBili');
      expect(entries[1].type, 5);
      expect(entries[1].message, '<顶部>');
      expect(entries[2].type, 4);
      expect(entries[2].message, '底部弹幕');
    });
  });

  group('BilibiliDanmakuApi.selectBestAnime', () {
    test('prefers exact non-variant bangumi over dubbed variants', () {
      const candidates = [
        DanmakuSearchAnime(
          animeId: 1,
          animeTitle: '葬送的芙莉莲（中配）',
          typeDescription: '番剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuSearchAnime(
          animeId: 2,
          animeTitle: '葬送的芙莉莲',
          typeDescription: '番剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuSearchAnime(
          animeId: 3,
          animeTitle: '完全无关的作品',
          typeDescription: '番剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      final picked = BilibiliDanmakuApi.selectBestAnime(candidates, '葬送的芙莉莲');
      expect(picked?.animeId, 2);
    });

    test('prefers media kind affinity and rejects derivative noise titles', () {
      const tvCandidates = [
        DanmakuSearchAnime(
          animeId: 101,
          animeTitle: '【一口气看完】《甄嬛传规则怪谈》',
          typeDescription: '电视剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      expect(
        BilibiliDanmakuApi.selectBestAnime(
          tvCandidates,
          '甄嬛传',
          preferredKind: MediaKind.tv,
        ),
        isNull,
      );

      const movieCandidates = [
        DanmakuSearchAnime(
          animeId: 201,
          animeTitle: '流浪地球',
          typeDescription: '番剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuSearchAnime(
          animeId: 202,
          animeTitle: '流浪地球',
          typeDescription: '电影',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      final pickedMovie = BilibiliDanmakuApi.selectBestAnime(
        movieCandidates,
        '流浪地球',
        preferredKind: MediaKind.movie,
      );
      expect(pickedMovie?.animeId, 202);
    });

    test('returns null when no candidate matches keyword', () {
      const candidates = [
        DanmakuSearchAnime(
          animeId: 10,
          animeTitle: '其他作品',
          typeDescription: '番剧',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      expect(BilibiliDanmakuApi.selectBestAnime(candidates, '葬送的芙莉莲'), isNull);
    });
  });

  group('BilibiliDanmakuApi.matchEpisode', () {
    test('matches explicit episode number even when PV precedes episode 1', () {
      final episodes = [
        DanmakuEpisode(
          episodeId: 100,
          episodeTitle: 'PV1 正式预告',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuEpisode(
          episodeId: 101,
          episodeTitle: '第1集 冒险的终点',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuEpisode(
          episodeId: 102,
          episodeTitle: '第2集 不必是魔法也无所谓',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      expect(BilibiliDanmakuApi.matchEpisode(episodes, 1)?.episodeId, 101);
      expect(BilibiliDanmakuApi.matchEpisode(episodes, 2)?.episodeId, 102);
    });

    test('movie matching skips trailers and prefers feature film', () {
      final movieEpisodes = [
        DanmakuEpisode(
          episodeId: 301,
          episodeTitle: '终极预告 (预告)',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuEpisode(
          episodeId: 302,
          episodeTitle: '正片',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      expect(
        BilibiliDanmakuApi.matchEpisode(movieEpisodes, 1, isMovie: true)
            ?.episodeId,
        302,
      );
    });

    test('falls back to 1-based index when titles have no episode number', () {
      final episodes = [
        DanmakuEpisode(
          episodeId: 201,
          episodeTitle: '正片上',
          catalog: BilibiliDanmakuApi.catalog,
        ),
        DanmakuEpisode(
          episodeId: 202,
          episodeTitle: '正片下',
          catalog: BilibiliDanmakuApi.catalog,
        ),
      ];
      expect(BilibiliDanmakuApi.matchEpisode(episodes, 2)?.episodeId, 202);
      expect(BilibiliDanmakuApi.matchEpisode(episodes, 3), isNull);
    });
  });

  group('Default settings & controller safety', () {
    test('danmakuEnabledByDefault defaults to true', () {
      expect(SettingsKeys.danmakuEnabledByDefault.defaultValue, isTrue);
    });

    test('PlayerDanmakuController canvas helpers are safe before attach', () {
      final controller = PlayerDanmakuController(isLocalPlayback: () => false);
      expect(controller.hasCanvasController, isFalse);
      expect(controller.isCanvasRunning, isFalse);
      controller.clearAndInvalidateScheduledDanmakus();
      controller.clearCanvas();
      controller.pauseCanvas();
      controller.resumeCanvas();
      controller.updateDanmakuSpeed(1.5);
    });
  });
}
