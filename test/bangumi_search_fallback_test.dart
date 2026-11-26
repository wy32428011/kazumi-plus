import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/core/bangumi_transport.dart';
import 'package:kazumi/utils/bangumi_mirror_credentials.dart';

class _TestRequestHandler extends RequestInterceptorHandler {
  RequestOptions? resolvedOptions;

  @override
  void next(RequestOptions requestOptions) {
    resolvedOptions = requestOptions;
  }
}

class _TestErrorHandler extends ErrorInterceptorHandler {
  _TestErrorHandler(this.onNext);

  final void Function(DioException) onNext;

  @override
  void next(DioException err) {
    onNext(err);
  }
}

void main() {
  group('Bangumi Mirror Search & Fallback Tests', () {
    test('hasBangumiMirrorCredentials returns boolean without throwing', () {
      expect(hasBangumiMirrorCredentials, isA<bool>());
    });

    test('isProtectedBangumiMirrorPath correctly detects search and comments', () {
      final searchUri = Uri.parse('https://api.bgm.tv/v0/search/subjects?limit=20&offset=0');
      final commentsUri = Uri.parse('https://next.bgm.tv/p1/subjects/123/comments');
      final otherUri = Uri.parse('https://api.bgm.tv/v0/subjects/123');

      expect(isProtectedBangumiMirrorPath(searchUri, 'POST'), isTrue);
      expect(isProtectedBangumiMirrorPath(searchUri, 'GET'), isFalse);
      expect(isProtectedBangumiMirrorPath(commentsUri, 'GET'), isTrue);
      expect(isProtectedBangumiMirrorPath(otherUri, 'GET'), isFalse);
    });

    test('BangumiAccelerationInterceptor redirects protected path to ECH when credentials missing', () {
      final interceptor = BangumiAccelerationInterceptor();
      final options = RequestOptions(
        path: 'https://api.bgm.tv/v0/search/subjects?limit=20&offset=0',
        method: 'POST',
      );
      final handler = _TestRequestHandler();

      interceptor.onRequest(options, handler);

      expect(handler.resolvedOptions, isNotNull);
      if (!hasBangumiMirrorCredentials) {
        expect(handler.resolvedOptions!.extra['bangumiEch'], isTrue);
        expect(handler.resolvedOptions!.extra['_bangumiRetryTier'], equals(1));
        expect(handler.resolvedOptions!.path, contains('api.bgm.tv/v0/search/subjects'));
        expect(handler.resolvedOptions!.path, isNot(contains('api.kazumi.fyi')));
      }
    });

    test('BangumiAccelerationInterceptor passes through cancelled errors without retry', () async {
      final interceptor = BangumiAccelerationInterceptor();
      final options = RequestOptions(
        path: 'https://api.bgm.tv/v0/search/subjects?limit=20&offset=0',
        method: 'POST',
      );
      final cancelErr = DioException.requestCancelled(
        requestOptions: options,
        reason: 'User cancelled',
      );

      var errorHandled = false;

      // We can invoke onError and verify it forwards cancel without retrying
      await interceptor.onError(
        cancelErr,
        _TestErrorHandler((forwarded) {
          errorHandled = true;
          expect(forwarded.type, DioExceptionType.cancel);
        }),
      );

      expect(errorHandled, isTrue);
    });

    test('BangumiAccelerationInterceptor retains originalUri for multi-tier fallback', () {
      final interceptor = BangumiAccelerationInterceptor();
      final options = RequestOptions(
        path: 'https://api.bgm.tv/v0/subjects/123',
        method: 'GET',
      );
      final handler = _TestRequestHandler();

      interceptor.onRequest(options, handler);

      expect(handler.resolvedOptions, isNotNull);
      expect(handler.resolvedOptions!.extra['_bangumiOriginalUri'], isNotNull);
    });
  });
}
