import 'dart:collection';

import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';

/// MacCMS `ac=videolist` 完整载荷缓存条目，将 3 次相同详情请求压缩为 1 次。
class CachedVodPayload {
  const CachedVodPayload({
    required this.ref,
    required this.summary,
    required this.richMeta,
    required this.cachedAt,
    this.detail,
    this.playlist,
  });

  final MediaRef ref;
  final MediaSummary summary;
  final RichMediaMeta richMeta;
  final MediaDetail? detail;
  final SourcePlaylist? playlist;
  final DateTime cachedAt;

  CachedVodPayload mergeWith(CachedVodPayload incoming) {
    return CachedVodPayload(
      ref: incoming.ref,
      summary: incoming.summary,
      richMeta: incoming.richMeta,
      cachedAt: incoming.cachedAt,
      detail: incoming.detail ?? detail,
      playlist: incoming.playlist ?? playlist,
    );
  }
}

/// 纯内存 LRU 载荷复用缓存（上限 400 条，TTL 15 分钟），按 `MediaRef.key` 索引。
/// 仅复用不带显式分季的 MacCMS 完整载荷；含 `season != null` 时由调用方绕过缓存独立拉取。
class VodPayloadCache {
  VodPayloadCache({
    this.maxEntries = 400,
    this.ttl = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final VodPayloadCache instance = VodPayloadCache();

  final int maxEntries;
  final Duration ttl;
  final DateTime Function() _now;
  final LinkedHashMap<String, CachedVodPayload> _entries = LinkedHashMap();

  int get length => _entries.length;

  void put(CachedVodPayload payload) {
    final key = payload.ref.key;
    final existing = _entries.remove(key);
    final merged = existing == null ? payload : existing.mergeWith(payload);
    _entries[key] = merged;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  CachedVodPayload? get(MediaRef ref) {
    final key = ref.key;
    final entry = _entries.remove(key);
    if (entry == null) return null;
    if (_now().difference(entry.cachedAt) > ttl) {
      return null;
    }
    // 命中后移到末尾维持 LRU 顺序。
    _entries[key] = entry;
    return entry;
  }

  RichMediaMeta? getRichMeta(MediaRef ref) => get(ref)?.richMeta;

  void invalidate(MediaRef ref) {
    _entries.remove(ref.key);
  }

  void invalidateRule(String ruleId) {
    _entries.removeWhere((_, value) => value.ref.ruleId == ruleId);
  }

  void clear() {
    _entries.clear();
  }
}
