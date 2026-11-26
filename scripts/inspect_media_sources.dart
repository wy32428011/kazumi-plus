import 'dart:convert';
import 'dart:io';

import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/catalog_rule_strategy.dart';

/// 使用应用的资料和选集解析器核验真实接口，证据保存在指定目录。
Future<void> main(List<String> arguments) async {
  final output = Directory(
    arguments.isEmpty ? '.tools/media-sources-live' : arguments.first,
  );
  await output.create(recursive: true);
  final sources = arguments.length > 1
      ? arguments.skip(1)
      : ['haohua', 'xinlang', 'maoyan', 'modu', 'huya', 'jinying', 'ikun', 'guangsu', 'subo'];
  final results = await Future.wait(
    sources.map((source) async {
      try {
        final result = await inspectSource(source, output);
        stdout.writeln(jsonEncode(result));
        return result;
      } catch (error) {
        exitCode = 1;
        final result = <String, Object?>{'source': source, 'error': '$error'};
        stderr.writeln(jsonEncode(result));
        return result;
      }
    }),
  );
  await File('${output.path}/summary.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'verifiedAt': DateTime.now().toUtc().toIso8601String(),
      'scope': '真实API、现有解析器、HLS清单、密钥及首分片；未验证播放器音画',
      'sources': results,
    }),
  );
}

Future<Map<String, Object?>> inspectSource(
  String source,
  Directory output,
) async {
  final rule =
      jsonDecode(await File('assets/plugins/$source.json').readAsString())
          as Map<String, dynamic>;
  final config = CatalogRuleConfig.fromJson(rule['catalog']);
  const catalog = CatalogRuleStrategy();
  const api = ApiRuleStrategy();
  catalog.validate(config);
  final chapters = ApiChapterConfig.fromJson(rule['chapterApiConfig']);
  api.validateChapterConfig(chapters);
  api.validateSearchConfig(ApiSearchConfig.fromJson(rule['searchApiConfig']));
  final directory = Directory('${output.path}/$source');
  await directory.create(recursive: true);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final channels = <String, Object?>{};
  try {
    for (final kind in ['tv', 'movie', 'anime']) {
      final channel = config.channels[kind]!;
      final variables = <String, Object?>{
        'page': 1,
        'categoryId': channel.defaultCategoryId,
        'mediaType': kind,
      };
      Future<String> fetchOperation(
        String name,
        CatalogOperation operation,
        Map<String, Object?> values,
      ) async {
        // 每个来源顺序请求并保留间隔，避免批量核验密集访问采集接口。
        await Future<void>.delayed(const Duration(seconds: 1));
        final prepared = api.prepareRequest(operation.request, values);
        final uri = Uri.parse(prepared.url).replace(
          queryParameters: {
            ...Uri.parse(prepared.url).queryParameters,
            ...prepared.query.map((key, value) => MapEntry(key, '$value')),
          },
        );
        final raw = utf8.decode(
          await fetchBytes(
            client,
            uri,
            headers: {
              'User-Agent': 'Mozilla/5.0',
              'Referer': '${rule['baseURL']}/',
              ...prepared.headers.map((key, value) => MapEntry(key, '$value')),
            },
          ),
        );
        await File('${directory.path}/$kind-$name.json').writeAsString(raw);
        return raw;
      }

      final classes = catalog.parse(
        await fetchOperation('categories', channel.categories, variables),
        channel.categories,
        1,
      );
      final classIds = classes.rows.map((row) => '${row['id']}').toSet();
      if (!classIds.containsAll(channel.categoryIds)) {
        throw StateError('$kind 分类白名单含有源站未返回的编号');
      }
      final first = catalog.parse(
        await fetchOperation('discover', channel.discover, variables),
        channel.discover,
        1,
      );
      final rows = first.rows
          .where((row) => channel.categoryIds.contains('${row['categoryId']}'))
          .toList();
      if (rows.isEmpty) throw StateError('$kind 没有频道内资料');
      if (first.hasMore) {
        final second = catalog.parse(
          await fetchOperation('page2', channel.discover, {
            ...variables,
            'page': 2,
          }),
          channel.discover,
          2,
        );
        if (second.rows.isEmpty ||
            second.rows.map((row) => '${row['source']}').join(',') ==
                first.rows.map((row) => '${row['source']}').join(',')) {
          throw StateError('$kind 第二页为空或重复第一页');
        }
      }
      final item = rows.first;
      final id = '${item['source']}';
      final search = catalog.parse(
        await fetchOperation('search', channel.search, {
          ...variables,
          'keyword': '${item['title']}',
        }),
        channel.search,
        1,
      );
      if (!search.rows.any((row) => '${row['source']}' == id)) {
        throw StateError('$kind 精确标题搜索未返回当前作品');
      }
      final detailRaw = await fetchOperation('detail', channel.detail, {
        ...variables,
        'source': id,
      });
      final detail = catalog.parse(detailRaw, channel.detail, 1);
      if (detail.rows.isEmpty ||
          '${detail.rows.first['source']}' != id ||
          !channel.categoryIds.contains('${detail.rows.first['categoryId']}')) {
        throw StateError('$kind 详情身份或分类不一致');
      }
      final roads = api.parseChapters(
        detailRaw,
        chapters,
        source: id,
        baseUrl: rule['baseURL'],
      );
      if (roads.roads.isEmpty || roads.diagnostics.isNotEmpty) {
        throw StateError('$kind 选集解析失败：${roads.diagnostics}');
      }
      final media = await inspectMedia(
        client,
        Uri.parse(roads.roads.first.data.first),
        rule['baseURL'],
        directory,
        kind,
      );
      channels[kind] = {
        'categoryCount': channel.categoryIds.length,
        'defaultCategoryId': channel.defaultCategoryId,
        'title': item['title'],
        'id': id,
        'itemsOnPage': rows.length,
        'hasMore': first.hasMore,
        'roads': roads.roads.length,
        'episodes': roads.roads.first.data.length,
        'media': media,
      };
    }
    return {'source': source, 'ruleId': rule['ruleId'], 'channels': channels};
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, Object?>> inspectMedia(
  HttpClient client,
  Uri uri,
  String referer,
  Directory output,
  String kind,
) async {
  final headers = {'User-Agent': 'Mozilla/5.0', 'Referer': referer};
  final entry = uri;
  for (var depth = 0; depth < 4; depth++) {
    final raw = utf8.decode(await fetchBytes(client, uri, headers: headers));
    if (!raw.trimLeft().startsWith('#EXTM3U')) {
      throw StateError('播放地址没有返回 HLS 清单：$uri');
    }
    await File('${output.path}/$kind-hls-$depth.m3u8').writeAsString(raw);
    final lines = const LineSplitter().convert(raw);
    final next = lines.firstWhere(
      (line) => line.trim().isNotEmpty && !line.startsWith('#'),
    );
    if (raw.contains('#EXT-X-STREAM-INF:')) {
      uri = uri.resolve(next);
      continue;
    }
    // 加密 HLS 同时核对密钥，不把仅清单成功视作媒体链成功。
    final key = RegExp(r'#EXT-X-KEY:.*URI="([^"]+)"').firstMatch(raw);
    int? keyBytes;
    if (key != null) {
      keyBytes = (await fetchBytes(
        client,
        uri.resolve(key.group(1)!),
        headers: headers,
      )).length;
      if (raw.contains('METHOD=AES-128') && keyBytes != 16) {
        throw StateError('AES-128 密钥长度错误：$keyBytes');
      }
    }
    final segment = uri.resolve(next);
    final bytes = await fetchBytes(
      client,
      segment,
      headers: {...headers, 'Range': 'bytes=0-1023'},
      limit: 1024,
    );
    if (bytes.length < 188) throw StateError('媒体分片样本过短');
    final sample = utf8
        .decode(bytes.take(80).toList(), allowMalformed: true)
        .trimLeft();
    if (sample.toLowerCase().startsWith('<!doctype html') ||
        sample.toLowerCase().startsWith('<html') ||
        sample.startsWith('{"')) {
      throw StateError('媒体分片返回网页或 JSON 错误');
    }
    return {
      'entry': '$entry',
      'playlist': '$uri',
      'segment': '$segment',
      'segmentBytes': bytes.length,
      'keyBytes': keyBytes,
    };
  }
  throw StateError('HLS 主清单嵌套超过核验上限');
}

Future<List<int>> fetchBytes(
  HttpClient client,
  Uri uri, {
  Map<String, String> headers = const {},
  int? limit,
}) async {
  final request = await client.getUrl(uri).timeout(const Duration(seconds: 20));
  headers.forEach(request.headers.set);
  final response = await request.close().timeout(const Duration(seconds: 20));
  if (response.statusCode != 200 && response.statusCode != 206) {
    throw HttpException('HTTP ${response.statusCode}', uri: uri);
  }
  final bytes = <int>[];
  await for (final chunk in response.timeout(const Duration(seconds: 20))) {
    bytes.addAll(limit == null ? chunk : chunk.take(limit - bytes.length));
    if (limit != null && bytes.length >= limit) break;
  }
  return bytes;
}
