import 'package:kazumi/plugins/api_rule_config.dart';

/// 资料字段的提取位置；API 使用 JSONPath，网页使用 XPath 与可选属性。
class CatalogField {
  const CatalogField({required this.path, this.attribute = ''});

  final String path;
  final String attribute;

  factory CatalogField.fromJson(Object? value) {
    if (value is String) return CatalogField(path: value);
    final json = _map(value);
    return CatalogField(
      path: json['path'] as String? ?? '',
      attribute: json['attribute'] as String? ?? '',
    );
  }

  Object toJson() =>
      attribute.isEmpty ? path : {'path': path, 'attribute': attribute};
}

/// 分类、目录、搜索与详情共享声明式请求，不允许规则执行任意代码。
class CatalogOperation {
  CatalogOperation({
    required this.mode,
    required this.request,
    required this.listPath,
    required this.fields,
    this.totalPagesPath = '',
    this.hasMorePath = '',
    this.nextPagePath = '',
    this.seasonsPath = '',
    this.seasonFields = const {},
  });

  final String mode;
  final ApiRequestConfig request;
  final String listPath;
  final Map<String, CatalogField> fields;
  final String totalPagesPath;
  final String hasMorePath;
  final String nextPagePath;
  final String seasonsPath;
  final Map<String, CatalogField> seasonFields;

  factory CatalogOperation.fromJson(Object? value) {
    final json = _map(value);
    return CatalogOperation(
      mode: json['mode'] as String? ?? RuleMode.xpath,
      request: ApiRequestConfig.fromJson(_map(json['request'])),
      listPath: json['listPath'] as String? ?? '',
      fields: _fields(json['fields']),
      totalPagesPath: json['totalPagesPath'] as String? ?? '',
      hasMorePath: json['hasMorePath'] as String? ?? '',
      nextPagePath: json['nextPagePath'] as String? ?? '',
      seasonsPath: json['seasonsPath'] as String? ?? '',
      seasonFields: _fields(json['seasonFields']),
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode,
    'request': request.toJson(),
    'listPath': listPath,
    'fields': fields.map((key, value) => MapEntry(key, value.toJson())),
    if (totalPagesPath.isNotEmpty) 'totalPagesPath': totalPagesPath,
    if (hasMorePath.isNotEmpty) 'hasMorePath': hasMorePath,
    if (nextPagePath.isNotEmpty) 'nextPagePath': nextPagePath,
    if (seasonsPath.isNotEmpty) 'seasonsPath': seasonsPath,
    if (seasonFields.isNotEmpty)
      'seasonFields': seasonFields.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
  };
}

/// 原站分类编号按频道显式划分，避免按名称猜测内容类型。
class CatalogChannel {
  CatalogChannel({
    required this.categoryIds,
    required this.defaultCategoryId,
    required this.categories,
    required this.discover,
    required this.search,
    required this.detail,
  });

  final List<String> categoryIds;
  final String defaultCategoryId;
  final CatalogOperation categories;
  final CatalogOperation discover;
  final CatalogOperation search;
  final CatalogOperation detail;

  factory CatalogChannel.fromJson(Object? value) {
    final json = _map(value);
    return CatalogChannel(
      categoryIds: (json['categoryIds'] as List? ?? [])
          .map((value) => value.toString())
          .toList(),
      defaultCategoryId: json['defaultCategoryId']?.toString() ?? '',
      categories: CatalogOperation.fromJson(json['categories']),
      discover: CatalogOperation.fromJson(json['discover']),
      search: CatalogOperation.fromJson(json['search']),
      detail: CatalogOperation.fromJson(json['detail']),
    );
  }

  Map<String, dynamic> toJson() => {
    'categoryIds': categoryIds,
    'defaultCategoryId': defaultCategoryId,
    'categories': categories.toJson(),
    'discover': discover.toJson(),
    'search': search.toJson(),
    'detail': detail.toJson(),
  };
}

/// Plus 资料协议与原有动漫搜索、章节协议分开版本管理。
class CatalogRuleConfig {
  const CatalogRuleConfig({required this.channels});

  final Map<String, CatalogChannel> channels;

  factory CatalogRuleConfig.fromJson(Map<String, dynamic> json) =>
      CatalogRuleConfig(
        channels: _map(
          json['channels'],
        ).map((key, value) => MapEntry(key, CatalogChannel.fromJson(value))),
      );

  Map<String, dynamic> toJson() => {
    'channels': channels.map((key, value) => MapEntry(key, value.toJson())),
  };
}

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((key, item) => MapEntry(key.toString(), item))
    : <String, dynamic>{};

Map<String, CatalogField> _fields(Object? value) =>
    _map(value).map((key, item) => MapEntry(key, CatalogField.fromJson(item)));
