import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

/// 每个来源各自维护分页，重复页与连续空页不会无限触发自动请求。
class MediaResultState {
  final List<MediaSummary> items = [];
  int page = 0;
  bool hasMore = true;
  bool loading = false;
  int consecutiveEmptyPages = 0;
  int automaticRequests = 0;
  bool automaticPaused = false;
  String? notice;
  MediaRequestFailure? failure;

  bool get canLoadAutomatically =>
      hasMore && !loading && failure == null && !automaticPaused;

  void reset() {
    items.clear();
    page = 0;
    hasMore = true;
    loading = false;
    consecutiveEmptyPages = 0;
    automaticRequests = 0;
    automaticPaused = false;
    notice = null;
    failure = null;
  }

  void applyPage(MediaPage response, {required bool automatic}) {
    final seen = items.map((item) => item.ref.key).toSet();
    final added = response.items
        .where((item) => seen.add(item.ref.key))
        .toList();
    final previousPage = page;
    page = response.page;
    items.addAll(added);
    hasMore = response.hasMore;
    failure = null;
    if (automatic) automaticRequests++;
    if ((response.items.isNotEmpty && added.isEmpty) ||
        response.page <= previousPage) {
      hasMore = false;
      automaticPaused = true;
      notice = '来源重复返回已有内容或未推进页码，已停止分页。可刷新后重试。';
      return;
    }
    consecutiveEmptyPages = response.items.isEmpty
        ? consecutiveEmptyPages + 1
        : 0;
    if (!hasMore) {
      notice = null;
      return;
    }
    if (hasMore && (consecutiveEmptyPages >= 3 || automaticRequests >= 12)) {
      automaticPaused = true;
      notice = consecutiveEmptyPages >= 3
          ? '连续 3 页没有当前频道的内容，已暂停自动加载；可手动逐页继续。'
          : '本次自动加载已达 12 页，已暂停；可手动逐页继续。';
    } else if (!automaticPaused) {
      notice = response.items.isEmpty && hasMore
          ? '本页没有当前频道的内容，来源仍有下一页。'
          : null;
    }
  }
}

class MediaRequestFailure {
  const MediaRequestFailure(this.message, {this.captcha = false});
  final String message;
  final bool captcha;
}

Object? _rootCause(Object? error) {
  for (var depth = 0; depth < 6; depth++) {
    final Object? next = switch (error) {
      CatalogErrorException(:final cause) => cause,
      ChapterErrorException(:final cause) => cause,
      SearchErrorException(:final cause) => cause,
      _ => null,
    };
    if (next == null || identical(next, error)) break;
    error = next;
  }
  return error;
}

bool mediaRequestCancelled(Object error) {
  final cause = _rootCause(error);
  return (cause is DioException && CancelToken.isCancel(cause)) ||
      (cause is NetworkException && cause.type == NetworkExceptionType.cancel);
}

MediaRequestFailure describeMediaFailure(Object error) {
  final operation = error is CatalogErrorException ? error.operation : '请求';
  final cause = _rootCause(error);
  if (cause is CaptchaRequiredException) {
    return MediaRequestFailure('$operation需要人工验证码，完成验证后会重试原操作。', captcha: true);
  }
  if (cause is NetworkException) {
    if (const [
      NetworkExceptionType.connectionTimeout,
      NetworkExceptionType.receiveTimeout,
      NetworkExceptionType.sendTimeout,
    ].contains(cause.type)) {
      return MediaRequestFailure('$operation超时，请检查网络后重试。');
    }
    if (cause.type == NetworkExceptionType.badResponse) {
      return MediaRequestFailure(
        '$operation返回 HTTP ${cause.statusCode ?? '错误'}，来源可能失效或拒绝访问。',
      );
    }
    if (cause.type == NetworkExceptionType.parseError) {
      return MediaRequestFailure('$operation解析失败，来源返回格式与规则不符。');
    }
    if (cause.type == NetworkExceptionType.badCertificate) {
      return MediaRequestFailure('$operation的证书校验失败，请检查来源地址。');
    }
    return MediaRequestFailure('$operation连接失败，请检查网络或切换来源。');
  }
  if (cause is DioException) {
    if (const [
      DioExceptionType.connectionTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout,
    ].contains(cause.type)) {
      return MediaRequestFailure('$operation超时，请稍后重试。');
    }
    if (cause.type == DioExceptionType.badResponse) {
      return MediaRequestFailure(
        '$operation返回 HTTP ${cause.response?.statusCode ?? '错误'}，来源可能失效或拒绝访问。',
      );
    }
    return MediaRequestFailure('$operation网络连接失败，请稍后重试。');
  }
  if (cause is FormatException ||
      cause is ApiRuleFormatException ||
      operation.contains('解析')) {
    return MediaRequestFailure('$operation失败，来源格式或规则字段不匹配，请更新规则。');
  }
  return MediaRequestFailure('$operation失败，请重试或检查当前来源规则。');
}

class MediaFailureNotice extends StatelessWidget {
  const MediaFailureNotice({
    super.key,
    required this.failure,
    required this.onRetry,
    this.onVerify,
  });
  final MediaRequestFailure failure;
  final VoidCallback onRetry;
  final VoidCallback? onVerify;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(failure.message, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            if (failure.captcha && onVerify != null)
              FilledButton.tonal(
                onPressed: onVerify,
                child: const Text('人工验证并重试'),
              ),
            TextButton(onPressed: onRetry, child: const Text('重试原操作')),
          ],
        ),
      ],
    ),
  );
}
