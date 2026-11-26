import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:path_provider/path_provider.dart';

/// 片源故障精细分级（决定惩罚权重与是否退避/熔断/冷却）。
enum SourceFailureKind {
  /// 偶发 TLS EOF / BAD_RECORD_MAC：退避 250ms 重试 1 次后仍失败仅计 0.5 次。
  tlsTransient,

  /// 单片或单集 404/410：仅本次会话屏蔽该集，对站点仅轻罚 0.25，不连坐整站。
  http4xxGone,

  /// 网络超时或连接中断。
  networkTimeout,

  /// 上游 5xx 故障。
  http5xx,

  /// 播放列表为空或无有效分片。
  emptyPlaylist,

  /// 解码失败、非法 AES-128 密钥或非媒体内容。
  decodeError,

  /// 触发站点反爬 / CAPTCHA 挑战：绝不静默绕过，立即冷却 30 分钟移出自动池。
  captchaRequired,

  /// 本机断网止损：不惩罚任何站点或 CDN。
  localOffline,
}

/// 单个片源规则按内容频道键控的实测健康状态。
class SourceRuleHealth {
  const SourceRuleHealth({
    required this.pluginIdentityKey,
    required this.kind,
    this.consecutiveFailures = 0.0,
    this.circuitTripCount = 0,
    this.circuitOpenUntil,
    this.captchaCooldownUntil,
    this.startupSuccessRate = 0.85,
    this.stallRatePer10Min = 0.0,
    this.ewmaTtfbMs,
    this.ewmaThroughputKbps,
    this.recentWidths = const [],
    this.recentHeights = const [],
    this.lastVerifiedProfile,
    this.lastCdnGroup = '',
    this.lastError = '',
    required this.updatedAt,
  });

  final String pluginIdentityKey;
  final MediaKind kind;
  final double consecutiveFailures;
  final int circuitTripCount;
  final DateTime? circuitOpenUntil;
  final DateTime? captchaCooldownUntil;
  final double startupSuccessRate;
  final double stallRatePer10Min;
  final double? ewmaTtfbMs;
  final double? ewmaThroughputKbps;

  /// 仅记录 mpv 实播解码（StreamProfileProvenance.mpvTrackList）样本，最多保留 9 条。
  final List<int> recentWidths;
  final List<int> recentHeights;
  final VerifiedStreamProfile? lastVerifiedProfile;
  final String lastCdnGroup;
  final String lastError;
  final DateTime updatedAt;

  String get storageKey => '$pluginIdentityKey|${kind.name}';

  bool isCaptchaCooldown(DateTime now) =>
      captchaCooldownUntil != null && now.isBefore(captchaCooldownUntil!);

  bool isCircuitOpen(DateTime now) =>
      circuitOpenUntil != null && now.isBefore(circuitOpenUntil!);

  bool isHalfOpen(DateTime now) =>
      circuitOpenUntil != null &&
      !now.isBefore(circuitOpenUntil!) &&
      consecutiveFailures >= 3.0;

  int? get medianWidth => _median(recentWidths);
  int? get medianHeight => _median(recentHeights);

  bool get hasVerifiedResolution =>
      (medianWidth ?? 0) > 0 && (medianHeight ?? 0) > 0;

  static int? _median(List<int> values) {
    final valid = values.where((v) => v > 0).toList()..sort();
    if (valid.isEmpty) return null;
    return valid[valid.length ~/ 2];
  }

  SourceRuleHealth copyWith({
    double? consecutiveFailures,
    int? circuitTripCount,
    DateTime? circuitOpenUntil,
    bool clearCircuitOpen = false,
    DateTime? captchaCooldownUntil,
    bool clearCaptchaCooldown = false,
    double? startupSuccessRate,
    double? stallRatePer10Min,
    double? ewmaTtfbMs,
    double? ewmaThroughputKbps,
    List<int>? recentWidths,
    List<int>? recentHeights,
    VerifiedStreamProfile? lastVerifiedProfile,
    String? lastCdnGroup,
    String? lastError,
    DateTime? updatedAt,
  }) {
    return SourceRuleHealth(
      pluginIdentityKey: pluginIdentityKey,
      kind: kind,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      circuitTripCount: circuitTripCount ?? this.circuitTripCount,
      circuitOpenUntil: clearCircuitOpen
          ? null
          : (circuitOpenUntil ?? this.circuitOpenUntil),
      captchaCooldownUntil: clearCaptchaCooldown
          ? null
          : (captchaCooldownUntil ?? this.captchaCooldownUntil),
      startupSuccessRate: startupSuccessRate ?? this.startupSuccessRate,
      stallRatePer10Min: stallRatePer10Min ?? this.stallRatePer10Min,
      ewmaTtfbMs: ewmaTtfbMs ?? this.ewmaTtfbMs,
      ewmaThroughputKbps: ewmaThroughputKbps ?? this.ewmaThroughputKbps,
      recentWidths: recentWidths ?? this.recentWidths,
      recentHeights: recentHeights ?? this.recentHeights,
      lastVerifiedProfile: lastVerifiedProfile ?? this.lastVerifiedProfile,
      lastCdnGroup: lastCdnGroup ?? this.lastCdnGroup,
      lastError: lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'pluginIdentityKey': pluginIdentityKey,
    'kind': kind.name,
    'consecutiveFailures': consecutiveFailures,
    'circuitTripCount': circuitTripCount,
    'circuitOpenUntil': circuitOpenUntil?.toIso8601String(),
    'captchaCooldownUntil': captchaCooldownUntil?.toIso8601String(),
    'startupSuccessRate': startupSuccessRate,
    'stallRatePer10Min': stallRatePer10Min,
    'ewmaTtfbMs': ewmaTtfbMs,
    'ewmaThroughputKbps': ewmaThroughputKbps,
    'recentWidths': recentWidths,
    'recentHeights': recentHeights,
    'lastVerifiedProfile': lastVerifiedProfile?.toJson(),
    'lastCdnGroup': lastCdnGroup,
    'lastError': lastError,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory SourceRuleHealth.fromJson(Map<String, dynamic> json) {
    final profileRaw = json['lastVerifiedProfile'];
    return SourceRuleHealth(
      pluginIdentityKey: json['pluginIdentityKey'] as String? ?? '',
      kind: MediaKind.parse(json['kind']),
      consecutiveFailures:
          (json['consecutiveFailures'] as num?)?.toDouble() ?? 0.0,
      circuitTripCount: (json['circuitTripCount'] as num?)?.toInt() ?? 0,
      circuitOpenUntil: DateTime.tryParse(
        json['circuitOpenUntil'] as String? ?? '',
      ),
      captchaCooldownUntil: DateTime.tryParse(
        json['captchaCooldownUntil'] as String? ?? '',
      ),
      startupSuccessRate:
          (json['startupSuccessRate'] as num?)?.toDouble() ?? 0.85,
      stallRatePer10Min:
          (json['stallRatePer10Min'] as num?)?.toDouble() ?? 0.0,
      ewmaTtfbMs: (json['ewmaTtfbMs'] as num?)?.toDouble(),
      ewmaThroughputKbps: (json['ewmaThroughputKbps'] as num?)?.toDouble(),
      recentWidths: [
        for (final item in (json['recentWidths'] as List? ?? const []))
          if (item is num && item > 0) item.toInt(),
      ],
      recentHeights: [
        for (final item in (json['recentHeights'] as List? ?? const []))
          if (item is num && item > 0) item.toInt(),
      ],
      lastVerifiedProfile: profileRaw is Map
          ? VerifiedStreamProfile.fromJson(
              Map<String, dynamic>.from(profileRaw),
            )
          : null,
      lastCdnGroup: json['lastCdnGroup'] as String? ?? '',
      lastError: json['lastError'] as String? ?? '',
      updatedAt:
          DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 按动态识别的 TS 分片 CDN 归属组追踪的共享上游健康状态。
class CdnGroupHealth {
  const CdnGroupHealth({
    required this.cdnGroup,
    this.consecutiveFailures = 0.0,
    this.degradedUntil,
    this.lastFailureAt,
    this.lastSuccessAt,
    required this.updatedAt,
  });

  final String cdnGroup;
  final double consecutiveFailures;
  final DateTime? degradedUntil;
  final DateTime? lastFailureAt;
  final DateTime? lastSuccessAt;
  final DateTime updatedAt;

  bool isDegraded(DateTime now) =>
      degradedUntil != null && now.isBefore(degradedUntil!);

  CdnGroupHealth copyWith({
    double? consecutiveFailures,
    DateTime? degradedUntil,
    bool clearDegraded = false,
    DateTime? lastFailureAt,
    DateTime? lastSuccessAt,
    DateTime? updatedAt,
  }) {
    return CdnGroupHealth(
      cdnGroup: cdnGroup,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      degradedUntil: clearDegraded
          ? null
          : (degradedUntil ?? this.degradedUntil),
      lastFailureAt: lastFailureAt ?? this.lastFailureAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'cdnGroup': cdnGroup,
    'consecutiveFailures': consecutiveFailures,
    'degradedUntil': degradedUntil?.toIso8601String(),
    'lastFailureAt': lastFailureAt?.toIso8601String(),
    'lastSuccessAt': lastSuccessAt?.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CdnGroupHealth.fromJson(Map<String, dynamic> json) => CdnGroupHealth(
    cdnGroup: json['cdnGroup'] as String? ?? '',
    consecutiveFailures:
        (json['consecutiveFailures'] as num?)?.toDouble() ?? 0.0,
    degradedUntil: DateTime.tryParse(json['degradedUntil'] as String? ?? ''),
    lastFailureAt: DateTime.tryParse(json['lastFailureAt'] as String? ?? ''),
    lastSuccessAt: DateTime.tryParse(json['lastSuccessAt'] as String? ?? ''),
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// 本机可恢复片源与 CDN 实测健康库（`plus_source_health_v1`）。
///
/// 设计守卫：
/// - 仅保存在本机辅助盒，损坏时自动清空重建，绝不阻塞应用启动或污染影视核心四表；
/// - 跨电影、电视剧与动漫共享同一套实测健康与 CDN 遥测；
/// - 经 [AsyncSerialQueue] 与防抖合并写盘，避免播放过程中频繁磁盘刷写。
class SourceHealthRepository extends ChangeNotifier {
  SourceHealthRepository({
    DateTime Function()? clock,
    Duration flushDebounce = const Duration(milliseconds: 800),
  }) : _clock = clock ?? DateTime.now,
       _flushDebounce = flushDebounce;

  static final SourceHealthRepository instance = SourceHealthRepository();

  static const String boxName = 'plus_source_health_v1';
  static const String _rulePrefix = 'rule:';
  static const String _cdnPrefix = 'cdn:';
  static const int _maxResolutionSamples = 9;
  static const Duration captchaCooldownDuration = Duration(minutes: 30);
  static const Duration cdnDegradeDuration = Duration(minutes: 10);

  static const List<Duration> _circuitBackoffs = [
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 60),
  ];

  final DateTime Function() _clock;
  final Duration _flushDebounce;
  final AsyncSerialQueue _writes = AsyncSerialQueue();

  Box<String>? _box;
  bool _initialized = false;
  final Map<String, SourceRuleHealth> _ruleHealth = {};
  final Map<String, CdnGroupHealth> _cdnHealth = {};
  final Set<String> _dirtyKeys = {};
  final Set<String> _deletedKeys = {};
  Timer? _flushTimer;

  bool get isInitialized => _initialized;

  /// 插件统一身份键：优先使用稳定 ruleId，兼容无 ruleId 的传统动漫插件。
  static String pluginIdentityKey(Plugin plugin) =>
      plugin.ruleId.isNotEmpty ? plugin.ruleId : plugin.name;

  static String _ruleMapKey(String pluginIdentityKey, MediaKind kind) =>
      '$pluginIdentityKey|${kind.name}';

  /// 从首个有效分片的最终跳转 URL 动态归一化生成 `cdnGroup`：
  /// - 公有云对象存储 / 多租户 CDN 保留桶前缀（host + 首段路径），防不同业务互相误伤；
  /// - 私有采集分发域提取 eTLD+1（及非日期/哈希的静态首段特征），使同上游多镜像域名自动归入同组。
  static String normalizeCdnGroup(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.host.isEmpty) return '';
    final host = uri.host.toLowerCase();

    if (_isIpLiteral(host)) {
      return host;
    }

    final firstSegment = _extractMeaningfulFirstSegment(uri.pathSegments);
    if (_isPublicCloudHost(host)) {
      return firstSegment.isEmpty ? host : '$host/$firstSegment';
    }

    final etldPlusOne = _extractEtldPlusOne(host);
    if (firstSegment.isNotEmpty) {
      return '$etldPlusOne/$firstSegment';
    }
    return etldPlusOne;
  }

  static bool _isIpLiteral(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every((p) {
      final n = int.tryParse(p);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static const List<String> _publicCloudSuffixes = [
    '.aliyuncs.com',
    '.myqcloud.com',
    '.qiniucdn.com',
    '.clouddn.com',
    '.cloudfront.net',
    '.akamaized.net',
    '.akamaihd.net',
    '.fastly.net',
    '.b-cdn.net',
    '.cloudflare.com',
    '.r2.dev',
    '.amazonaws.com',
    '.volces.com',
    '.bcebos.com',
    '.hwcdn.net',
    '.cdnhwc1.com',
    '.cdnhwc2.com',
    '.ksyuncdn.com',
    '.bytecdn.cn',
    '.bilivideo.com',
  ];

  static bool _isPublicCloudHost(String host) {
    for (final suffix in _publicCloudSuffixes) {
      if (host.endsWith(suffix) || host == suffix.substring(1)) {
        return true;
      }
    }
    return false;
  }

  static const Set<String> _twoPartTlds = {
    'com.cn',
    'net.cn',
    'org.cn',
    'gov.cn',
    'edu.cn',
    'co.uk',
    'org.uk',
    'co.jp',
    'ne.jp',
    'com.hk',
    'com.tw',
    'com.au',
    'com.sg',
  };

  static String _extractEtldPlusOne(String host) {
    final labels = host.split('.').where((e) => e.isNotEmpty).toList();
    if (labels.length <= 2) return host;
    final lastTwo = '${labels[labels.length - 2]}.${labels.last}';
    if (_twoPartTlds.contains(lastTwo) && labels.length >= 3) {
      return '${labels[labels.length - 3]}.$lastTwo';
    }
    return lastTwo;
  }

  static final RegExp _ephemeralSegmentPattern = RegExp(
    r'^(?:\d{4,14}|[0-9a-f]{8,}|v\d+|hls|m3u8|video|vod|media|play|live|index|playlist|stream|seg\d*)$',
    caseSensitive: false,
  );

  static String _extractMeaningfulFirstSegment(List<String> segments) {
    if (segments.isEmpty) return '';
    final first = segments.first.trim().toLowerCase();
    if (first.isEmpty || first.contains('.')) return '';
    if (first.length > 24) return '';
    if (_ephemeralSegmentPattern.hasMatch(first)) return '';
    return first;
  }

  /// 初始化可恢复辅助盒；若损坏则静默重建为空盒，绝不抛出阻塞主启动流程。
  Future<void> init({Box<String>? overrideBox}) async {
    if (_initialized && overrideBox == null) return;
    _ruleHealth.clear();
    _cdnHealth.clear();

    if (overrideBox != null) {
      _box = overrideBox;
    } else {
      _box = await _openRecoverableBox();
    }

    final box = _box;
    if (box != null) {
      var hadCorruptEntry = false;
      for (final entry in box.toMap().entries) {
        final key = entry.key.toString();
        try {
          final decoded = jsonDecode(entry.value);
          if (decoded is! Map) {
            hadCorruptEntry = true;
            continue;
          }
          final map = Map<String, dynamic>.from(decoded);
          if (key.startsWith(_rulePrefix)) {
            final health = SourceRuleHealth.fromJson(map);
            if (health.pluginIdentityKey.isNotEmpty) {
              _ruleHealth[_ruleMapKey(health.pluginIdentityKey, health.kind)] =
                  health;
            }
          } else if (key.startsWith(_cdnPrefix)) {
            final health = CdnGroupHealth.fromJson(map);
            if (health.cdnGroup.isNotEmpty) {
              _cdnHealth[health.cdnGroup] = health;
            }
          }
        } catch (_) {
          hadCorruptEntry = true;
        }
      }
      if (hadCorruptEntry) {
        KazumiLogger().w(
          'SourceHealthRepository: ignored corrupted entries in $boxName',
        );
      }
    }
    _initialized = true;
  }

  Future<Box<String>?> _openRecoverableBox() async {
    try {
      return await Hive.openBox<String>(boxName);
    } catch (error) {
      KazumiLogger().w(
        'SourceHealthRepository: box $boxName corrupted, resetting',
        error: error,
      );
      try {
        final hivePath = '${(await getApplicationSupportDirectory()).path}/hive';
        for (final ext in const ['.hive', '.lock']) {
          final file = File('$hivePath/$boxName$ext');
          if (await file.exists()) {
            await file.delete();
          }
        }
        return await Hive.openBox<String>(boxName);
      } catch (e2) {
        KazumiLogger().w(
          'SourceHealthRepository: fallback to in-memory health tracking',
          error: e2,
        );
        return null;
      }
    }
  }

  SourceRuleHealth? healthFor(String pluginIdentityKey, MediaKind kind) =>
      _ruleHealth[_ruleMapKey(pluginIdentityKey, kind)];

  /// 若指定频道暂无记录，允许读取该规则跨频道最近记录的 CDN 组与稳定度作弱参考。
  SourceRuleHealth? bestAvailableHealthFor(
    String pluginIdentityKey,
    MediaKind kind,
  ) {
    final exact = healthFor(pluginIdentityKey, kind);
    if (exact != null) return exact;
    SourceRuleHealth? latest;
    for (final entry in _ruleHealth.values) {
      if (entry.pluginIdentityKey != pluginIdentityKey) continue;
      if (latest == null || entry.updatedAt.isAfter(latest.updatedAt)) {
        latest = entry;
      }
    }
    return latest;
  }

  CdnGroupHealth? cdnHealthFor(String cdnGroup) =>
      cdnGroup.isEmpty ? null : _cdnHealth[cdnGroup];

  List<SourceRuleHealth> allRuleHealth() =>
      _ruleHealth.values.toList(growable: false);

  List<CdnGroupHealth> allCdnHealth() =>
      _cdnHealth.values.toList(growable: false);

  bool isSourceInCaptchaCooldown(
    String pluginIdentityKey,
    MediaKind kind, {
    DateTime? now,
  }) {
    final current = now ?? _clock();
    final direct = healthFor(pluginIdentityKey, kind);
    if (direct != null && direct.isCaptchaCooldown(current)) return true;
    // CAPTCHA 冷却作用于同一站点全频道，避免在电影触发反爬后立刻又去轰炸电视剧接口。
    for (final item in _ruleHealth.values) {
      if (item.pluginIdentityKey == pluginIdentityKey &&
          item.isCaptchaCooldown(current)) {
        return true;
      }
    }
    return false;
  }

  /// 记录一次探针或实播成功，平滑更新 EWMA 与 CDN 健康状态。
  void recordSuccess({
    required String pluginIdentityKey,
    required MediaKind kind,
    int? ttfbMs,
    int? throughputKbps,
    String cdnGroup = '',
    VerifiedStreamProfile? verifiedProfile,
    DateTime? now,
  }) {
    if (pluginIdentityKey.isEmpty) return;
    final ts = now ?? _clock();
    final key = _ruleMapKey(pluginIdentityKey, kind);
    final prev =
        _ruleHealth[key] ??
        SourceRuleHealth(
          pluginIdentityKey: pluginIdentityKey,
          kind: kind,
          updatedAt: ts,
        );

    final nextSuccessRate = _ewma(prev.startupSuccessRate, 1.0, alpha: 0.25);
    final nextStallRate = _ewma(prev.stallRatePer10Min, 0.0, alpha: 0.20);
    final nextTtfb = ttfbMs != null && ttfbMs > 0
        ? (prev.ewmaTtfbMs == null
              ? ttfbMs.toDouble()
              : _ewma(prev.ewmaTtfbMs!, ttfbMs.toDouble(), alpha: 0.35))
        : prev.ewmaTtfbMs;
    final nextThroughput = throughputKbps != null && throughputKbps > 0
        ? (prev.ewmaThroughputKbps == null
              ? throughputKbps.toDouble()
              : _ewma(
                  prev.ewmaThroughputKbps!,
                  throughputKbps.toDouble(),
                  alpha: 0.35,
                ))
        : prev.ewmaThroughputKbps;

    var widths = prev.recentWidths;
    var heights = prev.recentHeights;
    var lastProfile = prev.lastVerifiedProfile;
    if (verifiedProfile != null && verifiedProfile.isUiVerified) {
      widths = [...widths, verifiedProfile.width];
      heights = [...heights, verifiedProfile.height];
      if (widths.length > _maxResolutionSamples) {
        widths = widths.sublist(widths.length - _maxResolutionSamples);
      }
      if (heights.length > _maxResolutionSamples) {
        heights = heights.sublist(heights.length - _maxResolutionSamples);
      }
      lastProfile = verifiedProfile;
    }

    final updated = prev.copyWith(
      consecutiveFailures: 0.0,
      circuitTripCount: 0,
      clearCircuitOpen: true,
      startupSuccessRate: nextSuccessRate.clamp(0.0, 1.0),
      stallRatePer10Min: nextStallRate.clamp(0.0, 10.0),
      ewmaTtfbMs: nextTtfb,
      ewmaThroughputKbps: nextThroughput,
      recentWidths: widths,
      recentHeights: heights,
      lastVerifiedProfile: lastProfile,
      lastCdnGroup: cdnGroup.isNotEmpty ? cdnGroup : prev.lastCdnGroup,
      lastError: '',
      updatedAt: ts,
    );

    _ruleHealth[key] = updated;
    _markDirty('$_rulePrefix$key');

    if (cdnGroup.isNotEmpty) {
      final prevCdn =
          _cdnHealth[cdnGroup] ??
          CdnGroupHealth(cdnGroup: cdnGroup, updatedAt: ts);
      _cdnHealth[cdnGroup] = prevCdn.copyWith(
        consecutiveFailures: 0.0,
        clearDegraded: true,
        lastSuccessAt: ts,
        updatedAt: ts,
      );
      _markDirty('$_cdnPrefix$cdnGroup');
    }

    notifyListeners();
  }

  /// 记录播中卡顿，提升该源卡顿率并临时标记同 CDN 组降级。
  void recordStall({
    required String pluginIdentityKey,
    required MediaKind kind,
    String cdnGroup = '',
    String reason = '',
    DateTime? now,
  }) {
    if (pluginIdentityKey.isEmpty) return;
    final ts = now ?? _clock();
    final key = _ruleMapKey(pluginIdentityKey, kind);
    final prev =
        _ruleHealth[key] ??
        SourceRuleHealth(
          pluginIdentityKey: pluginIdentityKey,
          kind: kind,
          updatedAt: ts,
        );

    final nextStallRate = (prev.stallRatePer10Min * 0.6 + 1.5).clamp(0.0, 10.0);
    final effectiveCdn = cdnGroup.isNotEmpty ? cdnGroup : prev.lastCdnGroup;
    _ruleHealth[key] = prev.copyWith(
      stallRatePer10Min: nextStallRate,
      lastCdnGroup: effectiveCdn,
      lastError: reason.isNotEmpty ? reason : prev.lastError,
      updatedAt: ts,
    );
    _markDirty('$_rulePrefix$key');

    if (effectiveCdn.isNotEmpty) {
      _markCdnDegraded(effectiveCdn, increment: 1.0, now: ts);
    }

    notifyListeners();
  }

  /// 记录一次分类故障：按精细分级执行惩罚、退避熔断或 30 分钟 CAPTCHA 冷却。
  void recordFailure({
    required String pluginIdentityKey,
    required MediaKind kind,
    required SourceFailureKind failureKind,
    String cdnGroup = '',
    String message = '',
    DateTime? now,
  }) {
    if (pluginIdentityKey.isEmpty ||
        failureKind == SourceFailureKind.localOffline) {
      return;
    }
    final ts = now ?? _clock();
    final key = _ruleMapKey(pluginIdentityKey, kind);
    final prev =
        _ruleHealth[key] ??
        SourceRuleHealth(
          pluginIdentityKey: pluginIdentityKey,
          kind: kind,
          updatedAt: ts,
        );
    final effectiveCdn = cdnGroup.isNotEmpty ? cdnGroup : prev.lastCdnGroup;

    if (failureKind == SourceFailureKind.captchaRequired) {
      final until = ts.add(captchaCooldownDuration);
      _ruleHealth[key] = prev.copyWith(
        captchaCooldownUntil: until,
        lastError: message.isNotEmpty ? message : '站点需要人工验证，已暂停自动推荐 30 分钟',
        updatedAt: ts,
      );
      _markDirty('$_rulePrefix$key');
      notifyListeners();
      return;
    }

    final weight = switch (failureKind) {
      SourceFailureKind.tlsTransient => 0.5,
      SourceFailureKind.http4xxGone => 0.25,
      SourceFailureKind.networkTimeout ||
      SourceFailureKind.http5xx ||
      SourceFailureKind.emptyPlaylist ||
      SourceFailureKind.decodeError => 1.0,
      SourceFailureKind.captchaRequired || SourceFailureKind.localOffline => 0.0,
    };

    final nextFailures = prev.consecutiveFailures + weight;
    var tripCount = prev.circuitTripCount;
    DateTime? openUntil = prev.circuitOpenUntil;

    if (nextFailures >= 3.0) {
      final backoffIndex = tripCount.clamp(0, _circuitBackoffs.length - 1);
      openUntil = ts.add(_circuitBackoffs[backoffIndex]);
      tripCount += 1;
    }

    final successSample = failureKind == SourceFailureKind.http4xxGone
        ? prev.startupSuccessRate
        : _ewma(
            prev.startupSuccessRate,
            0.0,
            alpha: failureKind == SourceFailureKind.tlsTransient ? 0.12 : 0.25,
          );

    _ruleHealth[key] = prev.copyWith(
      consecutiveFailures: nextFailures,
      circuitTripCount: tripCount,
      circuitOpenUntil: openUntil,
      startupSuccessRate: successSample.clamp(0.05, 1.0),
      lastCdnGroup: effectiveCdn,
      lastError: message.isNotEmpty ? message : failureKind.name,
      updatedAt: ts,
    );
    _markDirty('$_rulePrefix$key');

    if (effectiveCdn.isNotEmpty &&
        failureKind != SourceFailureKind.http4xxGone &&
        failureKind != SourceFailureKind.tlsTransient) {
      _markCdnDegraded(effectiveCdn, increment: 1.0, now: ts);
    }

    notifyListeners();
  }

  /// 用户在可见界面手动通过 CAPTCHA 验证后立即恢复自动候选资格。
  void clearCaptchaCooldown(String pluginIdentityKey, {MediaKind? kind}) {
    var changed = false;
    final ts = _clock();
    for (final entry in _ruleHealth.entries.toList()) {
      final health = entry.value;
      if (health.pluginIdentityKey != pluginIdentityKey) continue;
      if (kind != null && health.kind != kind) continue;
      if (health.captchaCooldownUntil != null) {
        _ruleHealth[entry.key] = health.copyWith(
          clearCaptchaCooldown: true,
          lastError: '',
          updatedAt: ts,
        );
        _markDirty('$_rulePrefix${entry.key}');
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// 手动重置某个片源的健康与熔断状态（供片源健康中心排障使用）。
  void resetSourceHealth(String pluginIdentityKey, {MediaKind? kind}) {
    var changed = false;
    for (final key in _ruleHealth.keys.toList()) {
      final health = _ruleHealth[key]!;
      if (health.pluginIdentityKey != pluginIdentityKey) continue;
      if (kind != null && health.kind != kind) continue;
      _ruleHealth.remove(key);
      _deletedKeys.add('$_rulePrefix$key');
      _dirtyKeys.remove('$_rulePrefix$key');
      changed = true;
    }
    if (changed) {
      _scheduleFlush();
      notifyListeners();
    }
  }

  /// 清空全部内存与磁盘遥测（用于测试或用户一键重置测速记录）。
  Future<void> clearAll() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _ruleHealth.clear();
    _cdnHealth.clear();
    _dirtyKeys.clear();
    _deletedKeys.clear();
    final box = _box;
    if (box != null && box.isOpen) {
      await _writes.run(() async {
        await box.clear();
        await box.flush();
      });
    }
    notifyListeners();
  }

  /// 立即刷盘（测试与退出时调用）。
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _persistDirty();
  }

  void _markCdnDegraded(
    String cdnGroup, {
    required double increment,
    required DateTime now,
  }) {
    final prev =
        _cdnHealth[cdnGroup] ??
        CdnGroupHealth(cdnGroup: cdnGroup, updatedAt: now);
    _cdnHealth[cdnGroup] = prev.copyWith(
      consecutiveFailures: prev.consecutiveFailures + increment,
      degradedUntil: now.add(cdnDegradeDuration),
      lastFailureAt: now,
      updatedAt: now,
    );
    _markDirty('$_cdnPrefix$cdnGroup');
  }

  void _markDirty(String boxKey) {
    _deletedKeys.remove(boxKey);
    _dirtyKeys.add(boxKey);
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_box == null) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () {
      unawaited(_persistDirty());
    });
  }

  Future<void> _persistDirty() async {
    final box = _box;
    if (box == null || !box.isOpen) return;
    if (_dirtyKeys.isEmpty && _deletedKeys.isEmpty) return;

    final toWrite = <String, String>{};
    for (final boxKey in _dirtyKeys) {
      if (boxKey.startsWith(_rulePrefix)) {
        final k = boxKey.substring(_rulePrefix.length);
        final value = _ruleHealth[k];
        if (value != null) toWrite[boxKey] = jsonEncode(value.toJson());
      } else if (boxKey.startsWith(_cdnPrefix)) {
        final k = boxKey.substring(_cdnPrefix.length);
        final value = _cdnHealth[k];
        if (value != null) toWrite[boxKey] = jsonEncode(value.toJson());
      }
    }
    final toDelete = _deletedKeys.toList();
    _dirtyKeys.clear();
    _deletedKeys.clear();

    await _writes.run(() async {
      if (!box.isOpen) return;
      if (toWrite.isNotEmpty) {
        await box.putAll(toWrite);
      }
      if (toDelete.isNotEmpty) {
        await box.deleteAll(toDelete);
      }
      await box.flush();
    });
  }

  static double _ewma(double current, double sample, {required double alpha}) =>
      current * (1.0 - alpha) + sample * alpha;
}
