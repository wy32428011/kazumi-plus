import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/media/rule_media_catalog_service.dart';
import 'package:kazumi/services/plugin/api_rule_engine.dart';
import 'package:kazumi/services/plugin/catalog_rule_strategy.dart';
import 'package:kazumi/services/plugin/xpath_rule_strategy.dart';

void main() {
  Plugin load4kavPlugin() {
    final jsonMap =
        jsonDecode(File('assets/plugins/4kav.json').readAsStringSync())
            as Map<String, dynamic>;
    return Plugin.fromJson(jsonMap);
  }

  test('4K-AV bundled rule validates and restricts to movie channel only', () {
    final plugin = load4kavPlugin();
    expect(plugin.ruleId, 'kazumi-plus.4kav');
    expect(plugin.supportedMediaTypes, ['movie']);
    expect(plugin.catalog?.channels.keys, ['movie']);
    expect(plugin.executionConfig.userAgent, contains('Safari/'));
    const CatalogRuleStrategy().validate(plugin.catalog!);
  });

  test('4K-AV XPath search filters out /tv/ and /av/ entries', () async {
    final plugin = load4kavPlugin();
    const mixedSearchHtml = '''
<html><body>
<ul id="cate_list">
  <li><a href="/tv/">电视剧</a></li>
  <li><a href="/movie/">电影</a></li>
  <li><a href="/av/">AV</a></li>
</ul>
<div id="MainContent_newestlist">
  <div class="virow search">
    <div class="NTMitem Main">
      <div class="title"><a href="/movie/009163-test-movie/" title="测试电影"><h2>测试电影</h2></a></div>
      <div class="posinfo">
        <div class="info">
          <div class="resyear"><label title="分辨率">4K HDR 60FPS</label><label title="年份">2025</label></div>
        </div>
        <div class="poster"><a href="/movie/009163-test-movie/"><img src="https://www.4k-av.com/movie/009163-test-movie/poster_nail.jpg"></a></div>
      </div>
    </div>
    <div class="NTMitem">
      <div class="title"><a href="/tv/207208-test-tv-ep01/" title="测试剧集"><h2>测试剧集</h2></a></div>
    </div>
    <div class="NTMitem">
      <div class="title"><a href="/av/999999-adult/" title="非影视"><h2>非影视</h2></a></div>
    </div>
  </div>
</div>
</body></html>
''';
    final executor = _QueueExecutor([mixedSearchHtml]);
    final provider = RuleMediaProvider(
      plugin,
      engine: RuleEngine(requestExecutor: executor, logFailures: false),
    );

    final page = await provider.searchMedia(MediaKind.movie, '测试');
    expect(page.items.length, 1);
    expect(page.items.single.title, '测试电影');
    expect(
      page.items.single.detailSource,
      'https://www.4k-av.com/movie/009163-test-movie',
    );
  });

  test('4K-AV detail normalizes apex/www canonical link and rejects mismatched path', () async {
    final plugin = load4kavPlugin();
    const detailHtml = '''
<html>
<head>
  <link rel="alternate" hreflang="zh-Hans" href="https://4k-av.com/movie/009163-test-movie/" />
</head>
<body>
  <ul id="cate_list"><li><a href="/movie/">电影</a></li></ul>
  <video id="video1"><source src="https://www.4k-av.com/movie/009163-test-movie/4K/stream.m3u8" type="application/x-mpegURL"></video>
  <div id="MainContent_titleh12"><div class="MainTitle">测试电影</div><h2>Test Movie</h2></div>
  <div id="MainContent_poster"><img src="https://www.4k-av.com/movie/009163-test-movie/poster_nail.jpg"></div>
  <div id="MainContent_videodetail"><span>分辨率: 4K HDR 60FPS</span><span><a href="/2025/">2025</a></span></div>
  <div id="MainContent_tags"><a href="/tag/剧情/">剧情</a></div>
  <div id="MainContent_videodesc"><p>简介内容</p></div>
</body>
</html>
''';
    const wrongDetailHtml = '''
<html>
<head>
  <link rel="alternate" hreflang="zh-Hans" href="https://4k-av.com/movie/000001-other-movie/" />
</head>
<body>
  <ul id="cate_list"><li><a href="/movie/">电影</a></li></ul>
  <div id="MainContent_titleh12"><div class="MainTitle">另一部电影</div></div>
</body>
</html>
''';
    final executor = _QueueExecutor([detailHtml, wrongDetailHtml]);
    final provider = RuleMediaProvider(
      plugin,
      engine: RuleEngine(requestExecutor: executor, logFailures: false),
    );
    const summary = MediaSummary(
      ref: MediaRef.source(
        ruleId: 'kazumi-plus.4kav',
        kind: MediaKind.movie,
        id: 'https://www.4k-av.com/movie/009163-test-movie',
      ),
      title: '测试电影',
      detailSource: 'https://www.4k-av.com/movie/009163-test-movie',
      sourceName: '4K-AV',
    );

    final detail = await provider.queryDetail(summary);
    expect(detail.summary.ref, summary.ref);
    expect(detail.summary.detailSource, summary.detailSource);
    expect(detail.description, '简介内容');

    // Verify XPath chapter parsing extracts <source src="...m3u8"> directly.
    final parsedChapters = const XPathRuleStrategy().parseChapters(
      detailHtml,
      plugin.executionConfig,
    );
    expect(parsedChapters.roads.length, 1);
    expect(
      parsedChapters.roads.single.data,
      ['https://www.4k-av.com/movie/009163-test-movie/4K/stream.m3u8'],
    );

    await expectLater(
      provider.queryDetail(summary),
      throwsA(isA<CatalogErrorException>()),
    );
  });
}

class _QueueExecutor implements RuleRequestExecutor {
  _QueueExecutor(this._responses);

  final List<String> _responses;

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    return _responses.removeAt(0);
  }
}
