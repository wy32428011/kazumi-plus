import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/utils/async_rate_limiter.dart';

/// 全局统一片源流量守卫：
/// - 按规范化 host 隔离的最小请求间隔（默认 400ms）
/// - 单 host 最大并发 2
/// - 全局并发上限联动受限网络/低内存模式（桌面/Wi-Fi 4，移动计量/低内存 2）
/// - 基于 (host, method, normalizedUrl, queryHash) 的并发请求单飞去重（带独立取消隔离）
class SourceTrafficGuard {
  SourceTrafficGuard({
    this.hostMinInterval = const Duration(milliseconds: 400),
    this.maxPerHostConcurrency = 2,
    this.defaultGlobalConcurrency = 4,
    this.constrainedGlobalConcurrency = 2,
    bool Function()? isConstrainedResolver,
  }) : _isConstrainedResolver =
           isConstrainedResolver ?? _defaultConstrainedResolver;

  static final SourceTrafficGuard instance = SourceTrafficGuard();

  final Duration hostMinInterval;
  final int maxPerHostConcurrency;
  final int defaultGlobalConcurrency;
  final int constrainedGlobalConcurrency;
  final bool Function() _isConstrainedResolver;

  final Map<String, AsyncRateLimiter> _hostLimiters = {};
  final Map<String, _DynamicSemaphore> _hostSemaphores = {};
  final _DynamicSemaphore _globalSemaphore = _DynamicSemaphore();
  final Map<String, _SharedFlight<dynamic>> _inFlight = {};

  int _deduplicatedHits = 0;
  int get deduplicatedHits => _deduplicatedHits;

  int get activeGlobalRequests => _globalSemaphore.activeCount;

  int get currentGlobalLimit => _isConstrainedResolver()
      ? constrainedGlobalConcurrency
      : defaultGlobalConcurrency;

  static bool _defaultConstrainedResolver() {
    try {
      return LowMemoryMode.current.isEnabled(
        isMetered: MeteredNetworkService.isMetered,
        isLocalPlayback: false,
      );
    } catch (_) {
      // 无 Hive 初始化的单测环境下安全回退非受限模式。
      return false;
    }
  }

  /// 提取规范化 host（小写，剥离端口）。
  static String canonicalHost(String url) {
    final uri = Uri.tryParse(url.trim());
    final host = uri?.host.toLowerCase() ?? '';
    return host.isEmpty ? 'unknown' : host;
  }

  /// 构建稳定的单飞去重键。
  static String buildRequestKey({
    required String url,
    String method = 'GET',
    Map<String, Object?> query = const {},
  }) {
    final uri = Uri.tryParse(url.trim());
    final host = canonicalHost(url);
    final normalizedPath = uri == null
        ? url.trim()
        : '${uri.scheme.toLowerCase()}://$host'
              '${uri.hasPort ? ':${uri.port}' : ''}${uri.path}';
    final mergedQuery = <String, String>{};
    if (uri != null) {
      uri.queryParameters.forEach((key, value) {
        mergedQuery[key] = value;
      });
    }
    query.forEach((key, value) {
      if (value != null) {
        mergedQuery[key] = value.toString();
      }
    });
    final sortedKeys = mergedQuery.keys.toList()..sort();
    final canonicalQuery = sortedKeys
        .map((k) => '$k=${mergedQuery[k]}')
        .join('&');
    final queryHash = sha256
        .convert(utf8.encode(canonicalQuery))
        .toString()
        .substring(0, 16);
    return '$host|${method.toUpperCase()}|$normalizedPath|$queryHash';
  }

  /// 在统一流量治理保护下执行请求；支持按 [deduplicate] 合并并发相同请求。
  Future<T> run<T>({
    required String url,
    required Future<T> Function(CancelToken innerCancelToken) action,
    String method = 'GET',
    Map<String, Object?> query = const {},
    CancelToken? cancelToken,
    bool deduplicate = true,
    bool bypassRateLimit = false,
  }) {
    if (cancelToken?.isCancelled == true) {
      return Future<T>.error(
        cancelToken!.cancelError ??
            DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: '请求已取消',
            ),
      );
    }

    if (!deduplicate) {
      final innerToken = CancelToken();
      cancelToken?.whenCancel.then((error) {
        if (!innerToken.isCancelled) {
          innerToken.cancel(error);
        }
      });
      return _executeGuarded(
        url: url,
        action: () => action(innerToken),
        cancelToken: cancelToken,
        bypassRateLimit: bypassRateLimit,
      );
    }

    final key = buildRequestKey(url: url, method: method, query: query);
    final existing = _inFlight[key];
    if (existing != null && existing is _SharedFlight<T>) {
      _deduplicatedHits++;
      return existing.attachWaiter(url: url, cancelToken: cancelToken);
    }

    late final _SharedFlight<T> flight;
    flight = _SharedFlight<T>(
      onCleanup: () {
        if (identical(_inFlight[key], flight)) {
          _inFlight.remove(key);
        }
      },
    );
    _inFlight[key] = flight;
    final waiterFuture = flight.attachWaiter(
      url: url,
      cancelToken: cancelToken,
    );

    unawaited(
      _executeGuarded<T>(
        url: url,
        action: () => action(flight.innerCancelToken),
        cancelToken: flight.innerCancelToken,
        bypassRateLimit: bypassRateLimit,
      ).then(
        flight.complete,
        onError: flight.completeError,
      ),
    );

    return waiterFuture;
  }

  Future<T> _executeGuarded<T>({
    required String url,
    required Future<T> Function() action,
    CancelToken? cancelToken,
    bool bypassRateLimit = false,
  }) async {
    final host = canonicalHost(url);
    final hostSemaphore = _hostSemaphores.putIfAbsent(
      host,
      _DynamicSemaphore.new,
    );
    final limiter = _hostLimiters.putIfAbsent(
      host,
      () => AsyncRateLimiter(hostMinInterval),
    );

    await _globalSemaphore.acquire(
      limitProvider: () => currentGlobalLimit,
      cancelToken: cancelToken,
      url: url,
    );
    try {
      await hostSemaphore.acquire(
        limitProvider: () => maxPerHostConcurrency,
        cancelToken: cancelToken,
        url: url,
      );
      try {
        if (!bypassRateLimit && hostMinInterval > Duration.zero) {
          await limiter.acquire();
        }
        if (cancelToken?.isCancelled == true) {
          throw cancelToken!.cancelError ??
              DioException.requestCancelled(
                requestOptions: RequestOptions(path: url),
                reason: '请求已取消',
              );
        }
        return await action();
      } finally {
        hostSemaphore.release(limitProvider: () => maxPerHostConcurrency);
      }
    } finally {
      _globalSemaphore.release(limitProvider: () => currentGlobalLimit);
    }
  }

  void resetMetrics() {
    _deduplicatedHits = 0;
  }
}

class _SharedFlight<T> {
  _SharedFlight({required this.onCleanup});

  final void Function() onCleanup;
  final CancelToken innerCancelToken = CancelToken();
  final List<_FlightWaiter<T>> _waiters = [];
  bool _finished = false;

  bool get isFinished => _finished;

  Future<T> attachWaiter({
    required String url,
    CancelToken? cancelToken,
  }) {
    final completer = Completer<T>();
    final waiter = _FlightWaiter<T>(completer);
    _waiters.add(waiter);

    cancelToken?.whenCancel.then((error) {
      if (_finished || waiter.cancelled) return;
      waiter.cancelled = true;
      if (!completer.isCompleted) {
        completer.completeError(
          error,
        );
      }
      _waiters.remove(waiter);
      if (_waiters.isEmpty && !innerCancelToken.isCancelled) {
        innerCancelToken.cancel(error);
      }
    });

    return completer.future;
  }

  void complete(T value) {
    if (_finished) return;
    _finished = true;
    final snapshot = List<_FlightWaiter<T>>.of(_waiters);
    _waiters.clear();
    onCleanup();
    for (final waiter in snapshot) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.complete(value);
      }
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (_finished) return;
    _finished = true;
    final snapshot = List<_FlightWaiter<T>>.of(_waiters);
    _waiters.clear();
    onCleanup();
    for (final waiter in snapshot) {
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error, stackTrace);
      }
    }
  }
}

class _FlightWaiter<T> {
  _FlightWaiter(this.completer);

  final Completer<T> completer;
  bool cancelled = false;
}

class _DynamicSemaphore {
  int _active = 0;
  final Queue<_SemaphoreWaiter> _queue = Queue();

  int get activeCount => _active;

  Future<void> acquire({
    required int Function() limitProvider,
    required String url,
    CancelToken? cancelToken,
  }) {
    if (cancelToken?.isCancelled == true) {
      return Future<void>.error(
        cancelToken!.cancelError ??
            DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: '请求已取消',
            ),
      );
    }

    final limit = limitProvider().clamp(1, 64);
    if (_active < limit && _queue.isEmpty) {
      _active++;
      return Future<void>.value();
    }

    final waiter = _SemaphoreWaiter(Completer<void>());
    _queue.addLast(waiter);

    cancelToken?.whenCancel.then((error) {
      if (waiter.granted || waiter.cancelled) return;
      waiter.cancelled = true;
      _queue.remove(waiter);
      if (!waiter.completer.isCompleted) {
        waiter.completer.completeError(error);
      }
    });

    return waiter.completer.future;
  }

  void release({required int Function() limitProvider}) {
    if (_active > 0) _active--;
    final limit = limitProvider().clamp(1, 64);
    while (_active < limit && _queue.isNotEmpty) {
      final next = _queue.removeFirst();
      if (next.cancelled || next.completer.isCompleted) continue;
      next.granted = true;
      _active++;
      next.completer.complete();
    }
  }
}

class _SemaphoreWaiter {
  _SemaphoreWaiter(this.completer);

  final Completer<void> completer;
  bool granted = false;
  bool cancelled = false;
}
