import 'package:html/parser.dart' as html;
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

/// 同一结果模型供网页规则与 JSON 接口规则使用。
class CatalogParseResult {
  const CatalogParseResult({
    required this.rows,
    required this.hasMore,
    this.seasons = const [],
  });
  final List<Map<String, Object?>> rows;
  final bool hasMore;
  final List<Map<String, Object?>> seasons;
}

class CatalogRuleStrategy {
  const CatalogRuleStrategy();

  /// 导入与编辑时校验声明，避免缺少类型边界的来源混入其它频道。
  void validate(CatalogRuleConfig config) {
    if (config.channels.isEmpty) {
      throw const FormatException('资料规则至少需要一个频道');
    }
    for (final entry in config.channels.entries) {
      if (!const ['anime', 'tv', 'movie'].contains(entry.key)) {
        throw FormatException('不支持的资料频道：${entry.key}');
      }
      final channel = entry.value;
      if (channel.categoryIds.isEmpty ||
          !channel.categoryIds.contains(channel.defaultCategoryId)) {
        throw FormatException('${entry.key} 需要分类白名单和其中的默认分类');
      }
      for (final operation in [
        channel.categories,
        channel.discover,
        channel.search,
        channel.detail,
      ]) {
        _validateOperation(operation);
      }
      _requireFields(channel.categories, ['id', 'name']);
      for (final operation in [
        channel.discover,
        channel.search,
        channel.detail,
      ]) {
        _requireFields(operation, ['title', 'source', 'categoryId']);
      }
    }
  }

  void _requireFields(CatalogOperation operation, List<String> names) {
    for (final name in names) {
      if (operation.fields[name]?.path.isNotEmpty != true) {
        throw FormatException('资料操作缺少字段：$name');
      }
    }
  }

  void _validateOperation(CatalogOperation operation) {
    if (!const [RuleMode.api, RuleMode.xpath].contains(operation.mode)) {
      throw const FormatException('资料模式必须是 api 或 xpath');
    }
    if (operation.seasonsPath.isNotEmpty &&
        ['id', 'name', 'source'].any(
          (field) => operation.seasonFields[field]?.path.isNotEmpty != true,
        )) {
      throw const FormatException(
        '启用 seasonsPath 时必须配置 seasonFields.id、seasonFields.name 和 seasonFields.source',
      );
    }
    const ApiRuleStrategy().prepareRequest(operation.request, const {
      'keyword': 'example',
      'source': '1',
      'categoryId': '1',
      'page': 1,
      'seasonId': '',
      'mediaType': 'movie',
    });
    final paginationFields = [
      operation.totalPagesPath,
      operation.hasMorePath,
      operation.nextPagePath,
    ].where((value) => value.isNotEmpty);
    if (paginationFields.length > 1) {
      throw const FormatException('分页只能选择总页数、是否更多或下一页节点之一');
    }
    final paths = [
      operation.listPath,
      operation.seasonsPath,
      ...paginationFields,
      ...operation.fields.values.map((field) => field.path),
      ...operation.seasonFields.values.map((field) => field.path),
    ].where((path) => path.isNotEmpty);
    if (operation.mode == RuleMode.api) {
      if (operation.nextPagePath.isNotEmpty) {
        throw const FormatException('API 分页请使用 totalPagesPath 或 hasMorePath');
      }
      for (final path in paths) {
        RestrictedJsonPath.validate(path);
      }
    } else {
      final root = html.parse('<html><body></body></html>').documentElement!;
      for (final path in paths) {
        root.queryXPath(path).nodes;
      }
    }
  }

  CatalogParseResult parse(String raw, CatalogOperation operation, int page) {
    return operation.mode == RuleMode.api
        ? _parseApi(raw, operation, page)
        : _parseXPath(raw, operation, page);
  }

  CatalogParseResult _parseApi(
    String raw,
    CatalogOperation operation,
    int page,
  ) {
    final document = const ApiRuleStrategy().decodeResponse(raw);
    final nodes = operation.listPath.isEmpty
        ? [document]
        : RestrictedJsonPath.read(document, operation.listPath);
    final rows = nodes
        .map((node) => _apiFields(node, operation.fields))
        .toList();
    final seasons = <Map<String, Object?>>[];
    if (operation.seasonsPath.isNotEmpty && nodes.isNotEmpty) {
      for (final season in RestrictedJsonPath.read(
        nodes.first,
        operation.seasonsPath,
      )) {
        seasons.add(_apiFields(season, operation.seasonFields));
      }
    }
    Object? read(String path) =>
        path.isEmpty ? null : RestrictedJsonPath.readFirst(document, path);
    return CatalogParseResult(
      rows: rows,
      seasons: seasons,
      hasMore: operation.totalPagesPath.isNotEmpty
          ? page < (int.tryParse('${read(operation.totalPagesPath)}') ?? page)
          : _truthy(read(operation.hasMorePath)),
    );
  }

  Map<String, Object?> _apiFields(
    Object? node,
    Map<String, CatalogField> fields,
  ) => fields.map(
    (name, field) => MapEntry(
      name,
      field.path.isEmpty
          ? null
          : RestrictedJsonPath.readFirst(node, field.path),
    ),
  );

  CatalogParseResult _parseXPath(
    String raw,
    CatalogOperation operation,
    int page,
  ) {
    final root = html.parse(raw).documentElement!;
    final nodes = root
        .queryXPath(operation.listPath.isEmpty ? '.' : operation.listPath)
        .nodes;
    final rows = <Map<String, Object?>>[];
    final seasons = <Map<String, Object?>>[];
    for (final node in nodes) {
      final row = <String, Object?>{};
      for (final entry in operation.fields.entries) {
        final field = entry.value;
        final selected = field.path.isEmpty
            ? null
            : node.queryXPath(field.path).node;
        row[entry.key] = field.attribute.isEmpty
            ? selected?.text
            : selected?.attributes[field.attribute];
      }
      rows.add(row);
    }
    if (operation.seasonsPath.isNotEmpty && nodes.isNotEmpty) {
      for (final node in nodes.first.queryXPath(operation.seasonsPath).nodes) {
        final row = <String, Object?>{};
        for (final entry in operation.seasonFields.entries) {
          final field = entry.value;
          final selected = field.path.isEmpty
              ? null
              : node.queryXPath(field.path).node;
          row[entry.key] = field.attribute.isEmpty
              ? selected?.text
              : selected?.attributes[field.attribute];
        }
        seasons.add(row);
      }
    }
    String? read(String path) =>
        path.isEmpty ? null : root.queryXPath(path).node?.text;
    final hasMore = operation.nextPagePath.isNotEmpty
        ? root.queryXPath(operation.nextPagePath).nodes.isNotEmpty
        : operation.totalPagesPath.isNotEmpty
        ? page < (int.tryParse(read(operation.totalPagesPath) ?? '') ?? page)
        : _truthy(read(operation.hasMorePath));
    return CatalogParseResult(rows: rows, seasons: seasons, hasMore: hasMore);
  }

  bool _truthy(Object? value) =>
      value == true ||
      value == 1 ||
      value?.toString().toLowerCase() == 'true' ||
      value == '1';
}
