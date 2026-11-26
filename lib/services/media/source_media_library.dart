import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/utils/async_serial_queue.dart';

class SourceCollection {
  const SourceCollection({
    required this.media,
    required this.status,
    required this.updatedAt,
  });
  final MediaSummary media;
  final int status;
  final DateTime updatedAt;
}

class SourceHistory {
  const SourceHistory({
    required this.media,
    required this.roadId,
    required this.episodeId,
    required this.episodeTitle,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    this.seasonId,
    this.seasonName,
  });
  final MediaSummary media;
  final String roadId;
  final String episodeId;
  final String episodeTitle;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final String? seasonId;
  final String? seasonName;

  Map<String, dynamic> toJson() => {
    'media': media.toJson(),
    'roadId': roadId,
    'episodeId': episodeId,
    'episodeTitle': episodeTitle,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAt': updatedAt.toIso8601String(),
    'seasonId': seasonId,
    'seasonName': seasonName,
  };

  factory SourceHistory.fromJson(Map<String, dynamic> json) => SourceHistory(
    media: MediaSummary.fromJson(
      Map<String, dynamic>.from(json['media'] as Map),
    ),
    roadId: json['roadId'] as String,
    episodeId: json['episodeId'] as String,
    episodeTitle: json['episodeTitle'] as String,
    positionMs: (json['positionMs'] as num).toInt(),
    durationMs: (json['durationMs'] as num).toInt(),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    seasonId: json['seasonId'] as String?,
    seasonName: json['seasonName'] as String?,
  );
}

/// 本机可恢复作品弱关联索引记录（`plus_work_links_v1`）。
///
/// 仅用于展示层片单/历史折叠去重、跨源续播查最新进度与用户固定优先源记忆；
/// 真实片单/进度数据始终以 `SHA256(MediaRef.key)` 主键保留在原四张核心表中。
class WorkLinkRecord {
  const WorkLinkRecord({
    required this.workGroupKey,
    required this.memberRefKeys,
    required this.lastActiveRefKey,
    required this.updatedAt,
    this.pinnedRuleId,
  });

  final String workGroupKey;
  final List<String> memberRefKeys;
  final String lastActiveRefKey;
  final String? pinnedRuleId;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'workGroupKey': workGroupKey,
    'memberRefKeys': memberRefKeys,
    'lastActiveRefKey': lastActiveRefKey,
    'pinnedRuleId': pinnedRuleId,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory WorkLinkRecord.fromJson(Map<String, dynamic> json) => WorkLinkRecord(
    workGroupKey: json['workGroupKey'] as String? ?? '',
    memberRefKeys: [
      for (final item in (json['memberRefKeys'] as List? ?? const []))
        if (item is String && item.isNotEmpty) item,
    ],
    lastActiveRefKey: json['lastActiveRefKey'] as String? ?? '',
    pinnedRuleId: json['pinnedRuleId'] as String?,
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// 展示层折叠后的片单条目。
class FoldedSourceCollection {
  const FoldedSourceCollection({
    required this.primary,
    required this.linkedRefs,
    this.workGroupKey,
  });

  final SourceCollection primary;
  final List<MediaRef> linkedRefs;
  final String? workGroupKey;

  int get sourceCount => linkedRefs.length;
}

/// 展示层折叠后的历史条目。
class FoldedSourceHistory {
  const FoldedSourceHistory({
    required this.primary,
    required this.linkedRefs,
    this.workGroupKey,
  });

  final SourceHistory primary;
  final List<MediaRef> linkedRefs;
  final String? workGroupKey;

  int get sourceCount => linkedRefs.length;
}

/// 影视资料独立存储，原动漫同步服务仍只读取原有数据库。
class SourceMediaLibrary extends ChangeNotifier {
  SourceMediaLibrary._();
  static final SourceMediaLibrary instance = SourceMediaLibrary._();

  static const String workLinksBoxName = 'plus_work_links_v1';

  late Box<String> _collections;
  late Box<String> _histories;
  late Box<String> _progress;
  late Box<String> _preferences;
  Box<String>? _workLinks;
  final Map<String, WorkLinkRecord> _workLinksCache = {};
  final Map<String, String> _refKeyToWorkGroup = {};
  bool _initialized = false;
  final _writes = AsyncSerialQueue();

  Future<void> init() async {
    if (_initialized) return;
    // 核心四表打开失败直接交由应用错误页处理，保留原文件供恢复。
    _collections = await Hive.openBox<String>('plus_source_collections_v1');
    _histories = await Hive.openBox<String>('plus_source_histories_v1');
    _progress = await Hive.openBox<String>('plus_source_progress_v1');
    _preferences = await Hive.openBox<String>('plus_media_preferences_v1');
    // 校验内容后再开放页面，错误记录不会被静默覆盖或清空。
    for (final raw in _collections.values) {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      MediaSummary.fromJson(Map<String, dynamic>.from(json['media'] as Map));
      if (json['status'] is! num) throw const FormatException('影视片单状态无效');
      DateTime.parse(json['updatedAt'] as String);
    }
    for (final raw in [..._histories.values, ..._progress.values]) {
      SourceHistory.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    await _initRecoverableWorkLinks();
    _initialized = true;
  }

  /// `plus_work_links_v1` 属于可恢复辅助索引盒：若损坏则自动清空重建，绝不阻塞主库启动。
  Future<void> _initRecoverableWorkLinks() async {
    _workLinksCache.clear();
    _refKeyToWorkGroup.clear();
    try {
      final box = await Hive.openBox<String>(workLinksBoxName);
      for (final raw in box.values) {
        final record = WorkLinkRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map),
        );
        if (record.workGroupKey.isEmpty) continue;
        _workLinksCache[record.workGroupKey] = record;
        for (final refKey in record.memberRefKeys) {
          _refKeyToWorkGroup[refKey] = record.workGroupKey;
        }
      }
      _workLinks = box;
    } catch (_) {
      try {
        if (Hive.isBoxOpen(workLinksBoxName)) {
          await Hive.box<String>(workLinksBoxName).close();
        }
        await Hive.deleteBoxFromDisk(workLinksBoxName);
        _workLinks = await Hive.openBox<String>(workLinksBoxName);
      } catch (_) {
        _workLinks = null;
      }
    }
  }

  List<SourceCollection> get collections => _collections.values.map((raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return SourceCollection(
      media: MediaSummary.fromJson(
        Map<String, dynamic>.from(json['media'] as Map),
      ),
      status: (json['status'] as num).toInt(),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  List<SourceHistory> get histories =>
      _histories.values
          .map(
            (raw) =>
                SourceHistory.fromJson(jsonDecode(raw) as Map<String, dynamic>),
          )
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  // Hive 字符串主键有长度限制；对完整结构身份编码，不对标题取哈希。
  String _storageKey(String identity) =>
      sha256.convert(utf8.encode(identity)).toString();

  bool isCollected(MediaRef ref) =>
      _collections.containsKey(_storageKey(ref.key));

  /// 检查作品簇内任一关联来源是否已加入片单（用于跨源切源后收藏状态一致）。
  SourceCollection? collectionForCluster(WorkCluster cluster) {
    final keys = <String>{
      ...cluster.memberRefKeys,
      if (_workLinksCache[cluster.clusterKey] case final rec?)
        ...rec.memberRefKeys,
    };
    SourceCollection? best;
    for (final refKey in keys) {
      final raw = _collections.get(_storageKey(refKey));
      if (raw == null) continue;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final item = SourceCollection(
        media: MediaSummary.fromJson(
          Map<String, dynamic>.from(json['media'] as Map),
        ),
        status: (json['status'] as num).toInt(),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
      if (best == null || item.updatedAt.isAfter(best.updatedAt)) {
        best = item;
      }
    }
    return best;
  }

  Future<void> setCollection(MediaSummary media, {int status = 1}) =>
      _writes.run(() async {
        if (media.ref.isAnime) throw ArgumentError('影视库不接收 Bangumi 记录');
        if (status < 1 || status > 5) throw ArgumentError('片单状态无效');
        await _collections.put(
          _storageKey(media.ref.key),
          jsonEncode({
            'media': media.toJson(),
            'status': status,
            'updatedAt': DateTime.now().toIso8601String(),
          }),
        );
        await _collections.flush();
        notifyListeners();
      });

  Future<void> removeCollection(MediaRef ref) => _writes.run(() async {
    await _collections.delete(_storageKey(ref.key));
    await _collections.flush();
    notifyListeners();
  });

  /// 移除作品簇内所有关联来源的片单记录，避免折叠视图下出现“删不掉的影子条目”。
  Future<void> removeCollectionCluster(Iterable<MediaRef> refs) =>
      _writes.run(() async {
        for (final ref in refs) {
          await _collections.delete(_storageKey(ref.key));
        }
        await _collections.flush();
        notifyListeners();
      });

  SourceHistory? historyFor(MediaRef ref) {
    final raw = _histories.get(_storageKey(ref.key));
    return raw == null
        ? null
        : SourceHistory.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// 查询作品簇内跨来源最新观看历史（供零选源详情页和跨源续播使用）。
  SourceHistory? latestHistoryForCluster(WorkCluster cluster) {
    final keys = <String>{
      ...cluster.memberRefKeys,
      if (_workLinksCache[cluster.clusterKey] case final rec?)
        ...rec.memberRefKeys,
    };
    SourceHistory? best;
    for (final refKey in keys) {
      final raw = _histories.get(_storageKey(refKey));
      if (raw == null) continue;
      final item = SourceHistory.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (best == null || item.updatedAt.isAfter(best.updatedAt)) {
        best = item;
      }
    }
    return best;
  }

  String _progressKey(MediaRef ref, String roadId, PlayableEpisode episode) =>
      _storageKey(jsonEncode([ref.key, roadId, episode.key]));

  SourceHistory? progressFor(
    MediaRef ref,
    String roadId,
    PlayableEpisode episode,
  ) {
    final raw = _progress.get(_progressKey(ref, roadId, episode));
    return raw == null
        ? null
        : SourceHistory.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> recordProgress({
    required MediaSummary media,
    required PlaybackRoad road,
    required PlayableEpisode episode,
    required int positionMs,
    required int durationMs,
    MediaSeason? season,
  }) => _writes.run(() async {
    if (media.ref.isAnime) throw ArgumentError('影视库不接收 Bangumi 记录');
    final history = SourceHistory(
      media: media,
      roadId: road.id,
      episodeId: episode.id,
      episodeTitle: episode.title,
      positionMs: positionMs.clamp(0, durationMs > 0 ? durationMs : positionMs),
      durationMs: durationMs,
      updatedAt: DateTime.now(),
      seasonId: season?.id ?? episode.seasonId,
      seasonName: season?.name,
    );
    final raw = jsonEncode(history.toJson());
    await _progress.put(_progressKey(media.ref, road.id, episode), raw);
    await _histories.put(_storageKey(media.ref.key), raw);
    // 定期与离开播放页时由播放器调用，避免每一帧触发磁盘写入。
    await Future.wait([_progress.flush(), _histories.flush()]);
    notifyListeners();
  });

  Future<void> removeHistory(MediaRef ref) => _writes.run(() async {
    await _deleteHistoryRefLocked(ref);
    await Future.wait([_histories.flush(), _progress.flush()]);
    notifyListeners();
  });

  /// 级联删除作品关联簇下所有来源的历史与进度，防止“删除一条又冒出同片另一源”。
  Future<void> removeHistoryCluster(Iterable<MediaRef> refs) =>
      _writes.run(() async {
        final refList = refs.toList(growable: false);
        for (final ref in refList) {
          await _deleteHistoryRefLocked(ref);
        }
        await Future.wait([_histories.flush(), _progress.flush()]);
        notifyListeners();
      });

  Future<void> _deleteHistoryRefLocked(MediaRef ref) async {
    await _histories.delete(_storageKey(ref.key));
    final keys = _progress
        .toMap()
        .entries
        .where((entry) {
          final history = SourceHistory.fromJson(
            jsonDecode(entry.value) as Map<String, dynamic>,
          );
          return history.media.ref == ref;
        })
        .map((entry) => entry.key)
        .toList();
    await _progress.deleteAll(keys);
  }

  /// 将作品聚簇的成员关联关系写入本机可恢复索引 `plus_work_links_v1`。
  Future<void> linkWorkCluster(
    WorkCluster cluster, {
    String? activeRefKey,
    String? pinnedRuleId,
    bool updatePinned = false,
  }) => _writes.run(() async {
    final groupKey = cluster.clusterKey;
    if (groupKey.isEmpty) return;
    final existing = _workLinksCache[groupKey];
    final members = <String>{
      ...?existing?.memberRefKeys,
      ...cluster.memberRefKeys,
    };
    final record = WorkLinkRecord(
      workGroupKey: groupKey,
      memberRefKeys: members.toList(growable: false),
      lastActiveRefKey:
          activeRefKey ??
          existing?.lastActiveRefKey ??
          (cluster.candidates.isNotEmpty ? cluster.candidates.first.refKey : ''),
      pinnedRuleId: updatePinned ? pinnedRuleId : existing?.pinnedRuleId,
      updatedAt: DateTime.now(),
    );
    _workLinksCache[groupKey] = record;
    for (final key in members) {
      _refKeyToWorkGroup[key] = groupKey;
    }
    final box = _workLinks;
    if (box != null && box.isOpen) {
      await box.put(_storageKey(groupKey), jsonEncode(record.toJson()));
      await box.flush();
    }
    notifyListeners();
  });

  String? workGroupKeyForRef(MediaRef ref) => _refKeyToWorkGroup[ref.key];

  String? pinnedRuleIdForGroup(String workGroupKey) =>
      _workLinksCache[workGroupKey]?.pinnedRuleId;

  /// 按 `plus_work_links_v1` 对影视片单做无损展示折叠（不改动底层四表数据）。
  List<FoldedSourceCollection> foldedCollections({MediaKind? kind}) {
    final all = collections.where(
      (item) => kind == null || item.media.ref.kind == kind,
    );
    final grouped = <String, List<SourceCollection>>{};
    for (final item in all) {
      final groupKey =
          _refKeyToWorkGroup[item.media.ref.key] ?? item.media.ref.key;
      grouped.putIfAbsent(groupKey, () => []).add(item);
    }
    final folded = <FoldedSourceCollection>[];
    for (final entry in grouped.entries) {
      final items = entry.value
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      folded.add(
        FoldedSourceCollection(
          primary: items.first,
          linkedRefs: [for (final i in items) i.media.ref],
          workGroupKey: _workLinksCache.containsKey(entry.key)
              ? entry.key
              : null,
        ),
      );
    }
    folded.sort((a, b) => b.primary.updatedAt.compareTo(a.primary.updatedAt));
    return folded;
  }

  /// 按 `plus_work_links_v1` 对影视观看历史做无损展示折叠。
  List<FoldedSourceHistory> foldedHistories({MediaKind? kind}) {
    final all = histories.where(
      (item) => kind == null || item.media.ref.kind == kind,
    );
    final grouped = <String, List<SourceHistory>>{};
    for (final item in all) {
      final groupKey =
          _refKeyToWorkGroup[item.media.ref.key] ?? item.media.ref.key;
      grouped.putIfAbsent(groupKey, () => []).add(item);
    }
    final folded = <FoldedSourceHistory>[];
    for (final entry in grouped.entries) {
      final items = entry.value
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      folded.add(
        FoldedSourceHistory(
          primary: items.first,
          linkedRefs: [for (final i in items) i.media.ref],
          workGroupKey: _workLinksCache.containsKey(entry.key)
              ? entry.key
              : null,
        ),
      );
    }
    folded.sort((a, b) => b.primary.updatedAt.compareTo(a.primary.updatedAt));
    return folded;
  }

  String? preference(String key) => _preferences.get(key);

  Future<void> setPreference(String key, String value) async {
    await _preferences.put(key, value);
    await _preferences.flush();
  }

  /// 仅用于单元测试重置单例状态。
  @visibleForTesting
  Future<void> resetForTesting() async {
    if (_initialized) {
      for (final box in [
        _collections,
        _histories,
        _progress,
        _preferences,
        ?_workLinks,
      ]) {
        if (box.isOpen) await box.close();
      }
    }
    _workLinks = null;
    _workLinksCache.clear();
    _refKeyToWorkGroup.clear();
    _initialized = false;
  }
}
