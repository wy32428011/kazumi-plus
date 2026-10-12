import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/media/media_models.dart';
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

/// 影视资料独立存储，原动漫同步服务仍只读取原有数据库。
class SourceMediaLibrary extends ChangeNotifier {
  SourceMediaLibrary._();
  static final SourceMediaLibrary instance = SourceMediaLibrary._();

  late Box<String> _collections;
  late Box<String> _histories;
  late Box<String> _progress;
  late Box<String> _preferences;
  bool _initialized = false;
  final _writes = AsyncSerialQueue();

  Future<void> init() async {
    if (_initialized) return;
    // 打开失败直接交由应用错误页处理，保留原文件供恢复。
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
    _initialized = true;
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

  SourceHistory? historyFor(MediaRef ref) {
    final raw = _histories.get(_storageKey(ref.key));
    return raw == null
        ? null
        : SourceHistory.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
    await Future.wait([_histories.flush(), _progress.flush()]);
    notifyListeners();
  });

  String? preference(String key) => _preferences.get(key);

  Future<void> setPreference(String key, String value) async {
    await _preferences.put(key, value);
    await _preferences.flush();
  }
}
