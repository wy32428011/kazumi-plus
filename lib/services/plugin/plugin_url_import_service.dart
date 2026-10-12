import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/plugin/plugin_import_parser.dart';

/// 网址只负责下载文本，规则语法和身份校验继续交给现有导入器。
class PluginUrlImportService {
  static const _maximumBytes = 2 * 1024 * 1024;

  static Future<PluginImportParseResult> load(
    String value, {
    required CancelToken cancelToken,
  }) async {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 HTTP 或 HTTPS 规则网址。');
    }
    try {
      final response = await DioFactory.pluginDio.get<List<int>>(
        uri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 20),
          headers: const {'accept': 'application/json, text/plain, */*'},
        ),
        onReceiveProgress: (received, total) {
          if (received > _maximumBytes || total > _maximumBytes) {
            cancelToken.cancel('规则文件超过 2 MiB，请使用较小的文件。');
          }
        },
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.length > _maximumBytes) {
        throw const FormatException('规则文件超过 2 MiB，请使用较小的文件。');
      }
      // 允许 UTF-8 BOM；不把 HTML 错误页或损坏编码作为规则写入。
      final text = utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
      return PluginImportParser.parse(text);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        throw FormatException(error.error?.toString() ?? '下载已取消。');
      }
      final status = error.response?.statusCode;
      throw FormatException(
        status == null ? '规则下载失败，请检查网络或网址后重试。' : '规则网址返回 HTTP $status，请检查链接。',
      );
    }
  }
}
