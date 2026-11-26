import 'package:kazumi/modules/media/media_models.dart';

/// 音轨/配音版本枚举，严禁将不同配音版本混入原声候选池或静默切轨。
enum AudioDubVariant {
  original('原声'),
  mandarinDub('国语配音'),
  cantoneseDub('粤语配音'),
  taiwaneseDub('台语配音'),
  englishDub('英语配音'),
  unknown('默认');

  const AudioDubVariant(this.label);
  final String label;

  static AudioDubVariant parse(Object? value) => values.firstWhere(
    (item) => item.name == value,
    orElse: () => AudioDubVariant.original,
  );
}

/// 流规格证据来源：UI 清晰度徽章仅允许消费 [mpvTrackList] 实播解码结果。
enum StreamProfileProvenance {
  mpvTrackList,
  m3u8MasterInf;

  static StreamProfileProvenance parse(Object? value) => values.firstWhere(
    (item) => item.name == value,
    orElse: () => StreamProfileProvenance.m3u8MasterInf,
  );
}

/// 经过实播解码或探针提取的视频流规格画像。
class VerifiedStreamProfile {
  const VerifiedStreamProfile({
    required this.width,
    required this.height,
    required this.provenance,
    required this.verifiedAt,
    this.fps,
    this.videoCodec = '',
    this.hdrType = '',
    this.bitrateKbps,
  });

  final int width;
  final int height;
  final double? fps;
  final String videoCodec;
  final String hdrType;
  final int? bitrateKbps;
  final StreamProfileProvenance provenance;
  final DateTime verifiedAt;

  /// 仅 mpv 实播解码确认过宽高时才允许在 UI 展示“实测画质”徽章。
  bool get isUiVerified =>
      provenance == StreamProfileProvenance.mpvTrackList &&
      width > 0 &&
      height > 0;

  bool get is4K =>
      width >= 3840 || height >= 2000 || (width >= 3600 && height >= 1440);

  bool get is1440P =>
      !is4K && (width >= 2560 || height >= 1400 || (width >= 2400 && height >= 1000));

  bool get is1080P =>
      !is4K &&
      !is1440P &&
      (width >= 1920 || height >= 1000 || (width >= 1800 && height >= 720));

  bool get is720P =>
      !is4K && !is1440P && !is1080P && (width >= 1280 || height >= 680);

  String get resolutionTier {
    if (width <= 0 || height <= 0) return '';
    if (is4K) return '4K';
    if (is1440P) return '1440P';
    if (is1080P) return '1080P';
    if (is720P) return '720P';
    if (height >= 400) return '480P';
    return 'SD';
  }

  /// 仅在 [isUiVerified] 为真时返回可用于 UI 徽章的文案，否则返回空串。
  String get uiBadgeText {
    if (!isUiVerified) return '';
    final tier = resolutionTier;
    if (tier.isEmpty) return '';
    if (hdrType.isNotEmpty) return '$tier $hdrType';
    return tier;
  }

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'videoCodec': videoCodec,
    'hdrType': hdrType,
    'bitrateKbps': bitrateKbps,
    'provenance': provenance.name,
    'verifiedAt': verifiedAt.toIso8601String(),
  };

  factory VerifiedStreamProfile.fromJson(Map<String, dynamic> json) =>
      VerifiedStreamProfile(
        width: (json['width'] as num?)?.toInt() ?? 0,
        height: (json['height'] as num?)?.toInt() ?? 0,
        fps: (json['fps'] as num?)?.toDouble(),
        videoCodec: json['videoCodec'] as String? ?? '',
        hdrType: json['hdrType'] as String? ?? '',
        bitrateKbps: (json['bitrateKbps'] as num?)?.toInt(),
        provenance: StreamProfileProvenance.parse(json['provenance']),
        verifiedAt:
            DateTime.tryParse(json['verifiedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// 非破坏式补读的影视富元数据（用于防误并聚簇、缓存复用与策略打分）。
class RichMediaMeta {
  const RichMediaMeta({
    this.doubanId = '',
    this.doubanScore,
    this.directors = const [],
    this.aliases = const [],
    this.actors = const [],
    this.genres = const [],
    this.description = '',
    this.updatedAtText = '',
    this.language = '',
    this.playFrom = '',
    this.playUrl = '',
    this.hasExplicitSeasons = false,
    this.dubVariant = AudioDubVariant.original,
    this.seasonToken,
    this.isCompleted = false,
    this.reportedEpisodeCount,
    this.isCamOrTs = false,
  });

  static const empty = RichMediaMeta();

  final String doubanId;
  final double? doubanScore;
  final List<String> directors;
  final List<String> aliases;
  final List<String> actors;
  final List<String> genres;
  final String description;
  final String updatedAtText;
  final String language;
  final String playFrom;
  final String playUrl;
  final bool hasExplicitSeasons;
  final AudioDubVariant dubVariant;

  /// 仅当片名明确标注季号时提取，用于互斥防误并，严禁推断“第 1 季”。
  final int? seasonToken;
  final bool isCompleted;
  final int? reportedEpisodeCount;
  final bool isCamOrTs;

  bool get hasValidDoubanId => doubanId.isNotEmpty;

  RichMediaMeta copyWith({
    String? doubanId,
    double? doubanScore,
    List<String>? directors,
    List<String>? aliases,
    List<String>? actors,
    List<String>? genres,
    String? description,
    String? updatedAtText,
    String? language,
    String? playFrom,
    String? playUrl,
    bool? hasExplicitSeasons,
    AudioDubVariant? dubVariant,
    int? seasonToken,
    bool? isCompleted,
    int? reportedEpisodeCount,
    bool? isCamOrTs,
  }) {
    return RichMediaMeta(
      doubanId: doubanId ?? this.doubanId,
      doubanScore: doubanScore ?? this.doubanScore,
      directors: directors ?? this.directors,
      aliases: aliases ?? this.aliases,
      actors: actors ?? this.actors,
      genres: genres ?? this.genres,
      description: description ?? this.description,
      updatedAtText: updatedAtText ?? this.updatedAtText,
      language: language ?? this.language,
      playFrom: playFrom ?? this.playFrom,
      playUrl: playUrl ?? this.playUrl,
      hasExplicitSeasons: hasExplicitSeasons ?? this.hasExplicitSeasons,
      dubVariant: dubVariant ?? this.dubVariant,
      seasonToken: seasonToken ?? this.seasonToken,
      isCompleted: isCompleted ?? this.isCompleted,
      reportedEpisodeCount: reportedEpisodeCount ?? this.reportedEpisodeCount,
      isCamOrTs: isCamOrTs ?? this.isCamOrTs,
    );
  }
}

/// 自动选源策略偏好。
enum SourceRecommendationStrategy {
  balanced('均衡优选'),
  qualityFirst('画质优先'),
  speedFirst('流畅优先');

  const SourceRecommendationStrategy(this.label);
  final String label;

  static SourceRecommendationStrategy parse(Object? value) => values.firstWhere(
    (item) => item.name == value,
    orElse: () => SourceRecommendationStrategy.balanced,
  );
}

/// 单个片源候选的实时探活/可用性状态。
enum CandidateProbeStatus {
  idle,
  probing,
  ready,
  degraded,
  failed,
  captchaRequired,
  circuitOpen,
  disabled,
}

/// 聚合作品下的单个来源候选。
class MediaCandidate {
  const MediaCandidate({
    required this.summary,
    this.richMeta = RichMediaMeta.empty,
    this.detail,
    this.playlist,
    this.score = 0.0,
    this.scoreBreakdown = const {},
    this.probeStatus = CandidateProbeStatus.idle,
    this.ttfbMs,
    this.throughputKbps,
    this.cdnGroup = '',
    this.streamProfile,
    this.lastError = '',
    this.isPinned = false,
    this.isLazyWebview = false,
    this.hasAntiCrawler = false,
    this.isSameCdnAsActive = false,
  });

  final MediaSummary summary;
  final RichMediaMeta richMeta;
  final MediaDetail? detail;
  final SourcePlaylist? playlist;
  final double score;
  final Map<String, double> scoreBreakdown;
  final CandidateProbeStatus probeStatus;
  final int? ttfbMs;
  final int? throughputKbps;
  final String cdnGroup;
  final VerifiedStreamProfile? streamProfile;
  final String lastError;
  final bool isPinned;
  final bool isLazyWebview;
  final bool hasAntiCrawler;
  final bool isSameCdnAsActive;

  String get ruleId => summary.ref.ruleId;
  String get sourceName => summary.sourceName;
  String get refKey => summary.ref.key;

  bool get isAutoEligible =>
      probeStatus != CandidateProbeStatus.failed &&
      probeStatus != CandidateProbeStatus.captchaRequired &&
      probeStatus != CandidateProbeStatus.circuitOpen &&
      probeStatus != CandidateProbeStatus.disabled;

  MediaCandidate copyWith({
    MediaSummary? summary,
    RichMediaMeta? richMeta,
    MediaDetail? detail,
    SourcePlaylist? playlist,
    double? score,
    Map<String, double>? scoreBreakdown,
    CandidateProbeStatus? probeStatus,
    int? ttfbMs,
    int? throughputKbps,
    String? cdnGroup,
    VerifiedStreamProfile? streamProfile,
    String? lastError,
    bool? isPinned,
    bool? isLazyWebview,
    bool? hasAntiCrawler,
    bool? isSameCdnAsActive,
  }) {
    return MediaCandidate(
      summary: summary ?? this.summary,
      richMeta: richMeta ?? this.richMeta,
      detail: detail ?? this.detail,
      playlist: playlist ?? this.playlist,
      score: score ?? this.score,
      scoreBreakdown: scoreBreakdown ?? this.scoreBreakdown,
      probeStatus: probeStatus ?? this.probeStatus,
      ttfbMs: ttfbMs ?? this.ttfbMs,
      throughputKbps: throughputKbps ?? this.throughputKbps,
      cdnGroup: cdnGroup ?? this.cdnGroup,
      streamProfile: streamProfile ?? this.streamProfile,
      lastError: lastError ?? this.lastError,
      isPinned: isPinned ?? this.isPinned,
      isLazyWebview: isLazyWebview ?? this.isLazyWebview,
      hasAntiCrawler: hasAntiCrawler ?? this.hasAntiCrawler,
      isSameCdnAsActive: isSameCdnAsActive ?? this.isSameCdnAsActive,
    );
  }
}

/// 纯内存瞬态聚合作品簇：对用户呈现“一部作品”，底层保留全部来源独立 MediaRef。
class WorkCluster {
  const WorkCluster({
    required this.clusterKey,
    required this.kind,
    required this.dubVariant,
    required this.primaryTitle,
    required this.candidates,
    this.year = '',
    this.region = '',
    this.posterUrl = '',
    this.ratingText = '',
    this.statusText = '',
    this.description = '',
    this.directors = const [],
    this.aliases = const [],
    this.genres = const [],
    this.castText = '',
    this.doubanId = '',
    this.siblingDubClusters = const [],
  });

  final String clusterKey;
  final MediaKind kind;
  final AudioDubVariant dubVariant;
  final String primaryTitle;
  final String year;
  final String region;
  final String posterUrl;
  final String ratingText;
  final String statusText;
  final String description;
  final List<String> directors;
  final List<String> aliases;
  final List<String> genres;
  final String castText;
  final String doubanId;
  final List<MediaCandidate> candidates;
  final List<WorkCluster> siblingDubClusters;

  int get sourceCount => candidates.length;

  Set<String> get memberRefKeys =>
      candidates.map((candidate) => candidate.refKey).toSet();

  MediaCandidate get recommendedCandidate {
    if (candidates.isEmpty) {
      throw StateError('WorkCluster($clusterKey) has no candidates');
    }
    MediaCandidate? bestEligible;
    for (final candidate in candidates) {
      if (!candidate.isAutoEligible) continue;
      if (bestEligible == null || candidate.score > bestEligible.score) {
        bestEligible = candidate;
      }
    }
    return bestEligible ?? candidates.first;
  }

  MediaSummary toPrimarySummary() {
    final best = recommendedCandidate;
    return MediaSummary(
      ref: best.summary.ref,
      title: primaryTitle.isNotEmpty ? primaryTitle : best.summary.title,
      detailSource: best.summary.detailSource,
      sourceName: best.summary.sourceName,
      posterUrl: posterUrl.isNotEmpty ? posterUrl : best.summary.posterUrl,
      year: year.isNotEmpty ? year : best.summary.year,
      region: region.isNotEmpty ? region : best.summary.region,
      statusText: statusText.isNotEmpty ? statusText : best.summary.statusText,
      ratingText: ratingText,
    );
  }

  WorkCluster copyWith({
    String? clusterKey,
    MediaKind? kind,
    AudioDubVariant? dubVariant,
    String? primaryTitle,
    String? year,
    String? region,
    String? posterUrl,
    String? ratingText,
    String? statusText,
    String? description,
    List<String>? directors,
    List<String>? aliases,
    List<String>? genres,
    String? castText,
    String? doubanId,
    List<MediaCandidate>? candidates,
    List<WorkCluster>? siblingDubClusters,
  }) {
    return WorkCluster(
      clusterKey: clusterKey ?? this.clusterKey,
      kind: kind ?? this.kind,
      dubVariant: dubVariant ?? this.dubVariant,
      primaryTitle: primaryTitle ?? this.primaryTitle,
      year: year ?? this.year,
      region: region ?? this.region,
      posterUrl: posterUrl ?? this.posterUrl,
      ratingText: ratingText ?? this.ratingText,
      statusText: statusText ?? this.statusText,
      description: description ?? this.description,
      directors: directors ?? this.directors,
      aliases: aliases ?? this.aliases,
      genres: genres ?? this.genres,
      castText: castText ?? this.castText,
      doubanId: doubanId ?? this.doubanId,
      candidates: candidates ?? this.candidates,
      siblingDubClusters: siblingDubClusters ?? this.siblingDubClusters,
    );
  }
}
