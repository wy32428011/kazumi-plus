import 'dart:math' as math;

import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/services/media/media_text_normalizer.dart';

/// 两级保守防误并作品聚簇引擎：
/// - 全局硬互斥：频道不同、显式多季容器、季号标注不一致、音轨/配音版本不同均禁并。
/// - Tier 1：豆瓣 ID 精确聚类（附反错填年差+标题 Jaccard 保护）。
/// - Tier 2：片名/别名交集 + 年份守卫 + 导演交集/4K-AV 双向中英校验 + 完结剧集集数守卫。
class WorkClusterMatcher {
  const WorkClusterMatcher();

  static const String fourKavRuleId = 'kazumi-plus.4kav';

  /// 将多来源候选聚合为去重后的 [WorkCluster] 列表。
  /// 同作品不同配音版本会拆成独立簇，并在存在原声主簇时挂入 [WorkCluster.siblingDubClusters]。
  List<WorkCluster> cluster(List<MediaCandidate> candidates) {
    if (candidates.isEmpty) return const [];

    // 1. 先按 MediaRef.key 去重，避免同一来源同一条目重复加入。
    final deduped = <String, MediaCandidate>{};
    for (final candidate in candidates) {
      final existing = deduped[candidate.refKey];
      if (existing == null || _shouldReplaceCandidate(existing, candidate)) {
        deduped[candidate.refKey] = candidate;
      }
    }

    // 2. 分桶聚簇（同频道 + 同音轨 + 通过硬互斥和两级校验）。
    final groups = <_MutableClusterGroup>[];
    for (final candidate in deduped.values) {
      _MutableClusterGroup? matchedGroup;
      for (final group in groups) {
        if (canMergeIntoSamePool(group.representative, candidate)) {
          matchedGroup = group;
          break;
        }
      }
      if (matchedGroup != null) {
        matchedGroup.add(candidate);
      } else {
        groups.add(_MutableClusterGroup(candidate));
      }
    }

    final builtClusters = groups.map((group) => group.build()).toList();

    // 3. 关联同作品不同配音版本的 siblingDubClusters（严禁合池，仅挂载切换入口）。
    final siblingIndicesByCluster = <int, List<int>>{};
    for (var i = 0; i < builtClusters.length; i++) {
      for (var j = i + 1; j < builtClusters.length; j++) {
        final a = groups[i].representative;
        final b = groups[j].representative;
        if (a.richMeta.dubVariant == b.richMeta.dubVariant) continue;
        if (matchesUnderlyingWork(a, b)) {
          siblingIndicesByCluster.putIfAbsent(i, () => []).add(j);
          siblingIndicesByCluster.putIfAbsent(j, () => []).add(i);
        }
      }
    }

    // 若同一作品同时存在原声主簇与配音副簇，则以原声主簇展示在顶层，配音簇挂在 siblingDubClusters。
    final nestedDubIndices = <int>{};
    for (var i = 0; i < builtClusters.length; i++) {
      final siblings = siblingIndicesByCluster[i];
      if (siblings == null || siblings.isEmpty) continue;
      if (builtClusters[i].dubVariant == AudioDubVariant.original) {
        for (final siblingIndex in siblings) {
          if (builtClusters[siblingIndex].dubVariant != AudioDubVariant.original) {
            nestedDubIndices.add(siblingIndex);
          }
        }
      }
    }

    final result = <WorkCluster>[];
    for (var i = 0; i < builtClusters.length; i++) {
      if (nestedDubIndices.contains(i)) continue;
      final siblings = siblingIndicesByCluster[i] ?? const <int>[];
      if (siblings.isEmpty) {
        result.add(builtClusters[i]);
      } else {
        final siblingClusters = [
          for (final idx in siblings) builtClusters[idx],
        ];
        result.add(
          builtClusters[i].copyWith(siblingDubClusters: siblingClusters),
        );
      }
    }
    return result;
  }

  /// 判定两个候选是否允许合并进同一个自动选源与容灾候选池。
  bool canMergeIntoSamePool(MediaCandidate a, MediaCandidate b) {
    if (a.refKey == b.refKey) return true;
    if (a.richMeta.dubVariant != b.richMeta.dubVariant) return false;
    return matchesUnderlyingWork(a, b);
  }

  /// 判定两个候选是否指向同一底层作品（允许配音版本不同，用于挂载 siblingDubClusters）。
  bool matchesUnderlyingWork(MediaCandidate a, MediaCandidate b) {
    if (a.refKey == b.refKey) return true;

    // 全局硬互斥守卫 (1) 频道不同禁并
    if (a.summary.ref.kind != b.summary.ref.kind) return false;

    // 全局硬互斥守卫 (2) 含显式 seasonsPath 的多季容器不并入扁平单季簇
    if (a.richMeta.hasExplicitSeasons || b.richMeta.hasExplicitSeasons) {
      return false;
    }

    // 全局硬互斥守卫 (3) seasonToken 不一致或单方标有季号禁并（绝不推断第 1 季）
    if (a.richMeta.seasonToken != b.richMeta.seasonToken) {
      return false;
    }

    final doubanA = a.richMeta.doubanId;
    final doubanB = b.richMeta.doubanId;
    final yearA = MediaTextNormalizer.parseYearInt(a.summary.year);
    final yearB = MediaTextNormalizer.parseYearInt(b.summary.year);

    // Tier 1：豆瓣 ID 精确聚类（含反错填保护）
    if (doubanA.isNotEmpty && doubanB.isNotEmpty) {
      if (doubanA != doubanB) return false;
      if (yearA != null && yearB != null && (yearA - yearB).abs() > 2) {
        final jaccard = _titleTokenJaccard(a, b);
        if (jaccard < 0.2) return false;
      }
      return true;
    }

    // Tier 2：保守复合匹配
    final titlesA = _normalizedTitles(a);
    final titlesB = _normalizedTitles(b);
    final commonTitles = titlesA.intersection(titlesB);
    if (commonTitles.isEmpty) return false;

    // 双方有年份时 |yearA - yearB| <= 1，彻底阻断《沙丘 2024》与《沙丘 1984》误并
    if (yearA != null && yearB != null && (yearA - yearB).abs() > 1) {
      return false;
    }

    // 4K-AV（无导演 XPath 源）专项严苛守卫：要求 yearDiff == 0 且中英文双向同时命中
    final involves4kav =
        a.ruleId == fourKavRuleId || b.ruleId == fourKavRuleId;
    if (involves4kav) {
      if (yearA == null || yearB == null || yearA != yearB) {
        return false;
      }
      final cjkA = _normalizedCjkTitles(a);
      final cjkB = _normalizedCjkTitles(b);
      final latinA = _normalizedLatinTitles(a);
      final latinB = _normalizedLatinTitles(b);
      if (cjkA.intersection(cjkB).isEmpty) return false;
      if (latinA.isNotEmpty || latinB.isNotEmpty) {
        if (latinA.intersection(latinB).isEmpty) return false;
      } else {
        final longestCjk = cjkA
            .intersection(cjkB)
            .fold<int>(0, (prev, value) => math.max(prev, value.length));
        if (longestCjk < 4) return false;
      }
    } else {
      // 短片名（≤2 字）或任意一方缺失年份，强制要求导演交集
      final longestCommon = commonTitles.fold<int>(
        0,
        (prev, value) => math.max(prev, value.length),
      );
      final missingYear = yearA == null || yearB == null;
      if (missingYear || longestCommon <= 2) {
        final directorsA = _normalizedDirectors(a);
        final directorsB = _normalizedDirectors(b);
        if (directorsA.intersection(directorsB).isEmpty) {
          return false;
        }
      }
    }

    // 剧集均标完结且声明总集数差 > 20% 时拆簇
    if (a.summary.ref.kind == MediaKind.tv &&
        a.richMeta.isCompleted &&
        b.richMeta.isCompleted) {
      final countA = a.richMeta.reportedEpisodeCount;
      final countB = b.richMeta.reportedEpisodeCount;
      if (countA != null && countB != null && countA > 0 && countB > 0) {
        final diffRatio = (countA - countB).abs() / math.max(countA, countB);
        if (diffRatio > 0.20) return false;
      }
    }

    return true;
  }

  static bool _shouldReplaceCandidate(
    MediaCandidate existing,
    MediaCandidate incoming,
  ) {
    if (incoming.score != existing.score) {
      return incoming.score > existing.score;
    }
    if (incoming.playlist != null && existing.playlist == null) return true;
    if (incoming.detail != null && existing.detail == null) return true;
    return incoming.richMeta.hasValidDoubanId &&
        !existing.richMeta.hasValidDoubanId;
  }

  static Set<String> _normalizedTitles(MediaCandidate candidate) {
    final set = <String>{};
    void addRaw(String raw) {
      final norm = MediaTextNormalizer.normalizeTitleForMatching(raw);
      if (norm.isNotEmpty) set.add(norm);
    }

    addRaw(candidate.summary.title);
    for (final alias in candidate.richMeta.aliases) {
      addRaw(alias);
    }
    if (candidate.detail != null) {
      addRaw(candidate.detail!.summary.title);
      for (final alias in candidate.detail!.aliases) {
        addRaw(alias);
      }
    }
    final slugLatin = _extractLatinSlugFrom4kavUrl(candidate);
    if (slugLatin.isNotEmpty) addRaw(slugLatin);
    return set;
  }

  static Set<String> _normalizedCjkTitles(MediaCandidate candidate) {
    final result = <String>{};
    for (final title in _allRawTitles(candidate)) {
      if (MediaTextNormalizer.containsCjk(title)) {
        final norm = MediaTextNormalizer.normalizeTitleForMatching(title);
        if (norm.isNotEmpty) result.add(norm);
      }
    }
    return result;
  }

  static Set<String> _normalizedLatinTitles(MediaCandidate candidate) {
    final result = <String>{};
    for (final title in _allRawTitles(candidate)) {
      if (MediaTextNormalizer.containsLatinLetters(title) &&
          !MediaTextNormalizer.containsCjk(title)) {
        final norm = MediaTextNormalizer.normalizeTitleForMatching(title);
        if (norm.length >= 2) result.add(norm);
      }
    }
    final slugLatin = _extractLatinSlugFrom4kavUrl(candidate);
    if (slugLatin.isNotEmpty) {
      final norm = MediaTextNormalizer.normalizeTitleForMatching(slugLatin);
      if (norm.length >= 2) result.add(norm);
    }
    return result;
  }

  static Iterable<String> _allRawTitles(MediaCandidate candidate) sync* {
    yield candidate.summary.title;
    yield* candidate.richMeta.aliases;
    if (candidate.detail != null) {
      yield candidate.detail!.summary.title;
      yield* candidate.detail!.aliases;
    }
  }

  static String _extractLatinSlugFrom4kavUrl(MediaCandidate candidate) {
    if (candidate.ruleId != fourKavRuleId) return '';
    final uri = Uri.tryParse(candidate.summary.detailSource);
    if (uri == null || uri.pathSegments.isEmpty) return '';
    final slug = uri.pathSegments.lastWhere(
      (segment) => segment.isNotEmpty,
      orElse: () => '',
    );
    // e.g. 009163-dune-part-two -> dune part two
    final cleaned = slug.replaceFirst(RegExp(r'^\d+-'), '').replaceAll('-', ' ');
    return MediaTextNormalizer.containsLatinLetters(cleaned) ? cleaned : '';
  }

  static Set<String> _normalizedDirectors(MediaCandidate candidate) {
    return candidate.richMeta.directors
        .map(MediaTextNormalizer.normalizePersonName)
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  static double _titleTokenJaccard(MediaCandidate a, MediaCandidate b) {
    final tokensA = _charBigrams(_normalizedTitles(a));
    final tokensB = _charBigrams(_normalizedTitles(b));
    if (tokensA.isEmpty || tokensB.isEmpty) return 0.0;
    final intersection = tokensA.intersection(tokensB).length;
    final union = tokensA.union(tokensB).length;
    return union == 0 ? 0.0 : intersection / union;
  }

  static Set<String> _charBigrams(Set<String> strings) {
    final bigrams = <String>{};
    for (final str in strings) {
      if (str.length <= 1) {
        if (str.isNotEmpty) bigrams.add(str);
        continue;
      }
      for (var i = 0; i < str.length - 1; i++) {
        bigrams.add(str.substring(i, i + 2));
      }
    }
    return bigrams;
  }
}

class _MutableClusterGroup {
  _MutableClusterGroup(MediaCandidate first)
    : _candidates = [first],
      representative = first;

  final List<MediaCandidate> _candidates;
  MediaCandidate representative;

  void add(MediaCandidate candidate) {
    final existingIdx = _candidates.indexWhere(
      (item) => item.refKey == candidate.refKey,
    );
    if (existingIdx >= 0) {
      _candidates[existingIdx] = candidate;
    } else {
      _candidates.add(candidate);
    }
    if (candidate.richMeta.hasValidDoubanId &&
        !representative.richMeta.hasValidDoubanId) {
      representative = candidate;
    }
  }

  WorkCluster build() {
    final sorted = List<MediaCandidate>.of(_candidates)
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        if (a.isAutoEligible != b.isAutoEligible) {
          return a.isAutoEligible ? -1 : 1;
        }
        final scoreDiff = b.score.compareTo(a.score);
        if (scoreDiff != 0) return scoreDiff;
        return a.ruleId.compareTo(b.ruleId);
      });

    final primary = sorted.first;
    final doubanId = sorted
        .map((c) => c.richMeta.doubanId)
        .firstWhere((id) => id.isNotEmpty, orElse: () => '');

    final primaryTitle = sorted
        .map((c) => c.summary.title.trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => primary.summary.title);
    final year = sorted
        .map((c) => MediaTextNormalizer.cleanYear(c.summary.year))
        .firstWhere((y) => y.isNotEmpty, orElse: () => '');
    final region = sorted
        .map((c) => c.summary.region.trim())
        .firstWhere((r) => r.isNotEmpty, orElse: () => '');
    final posterUrl = sorted
        .map((c) => c.summary.posterUrl.trim())
        .firstWhere((p) => p.isNotEmpty, orElse: () => '');
    final ratingText = sorted
        .map((c) => c.summary.ratingText.trim())
        .firstWhere((r) => r.isNotEmpty, orElse: () => '');
    final statusText = sorted
        .map((c) => c.summary.statusText.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');

    var description = '';
    var castText = '';
    final directors = <String>{};
    final aliases = <String>{};
    final genres = <String>{};

    for (final candidate in sorted) {
      final desc = candidate.detail?.description.isNotEmpty == true
          ? candidate.detail!.description
          : candidate.richMeta.description;
      if (desc.length > description.length) {
        description = desc;
      }
      final cast = candidate.detail?.castText.isNotEmpty == true
          ? candidate.detail!.castText
          : candidate.richMeta.actors.join(' / ');
      if (cast.length > castText.length) {
        castText = cast;
      }
      directors.addAll(candidate.richMeta.directors);
      aliases.addAll(candidate.richMeta.aliases);
      if (candidate.detail != null) {
        aliases.addAll(candidate.detail!.aliases);
        genres.addAll(candidate.detail!.genres);
      }
      genres.addAll(candidate.richMeta.genres);
    }

    final normTitle = MediaTextNormalizer.normalizeTitleForMatching(
      primaryTitle,
    );
    final kind = primary.summary.ref.kind;
    final dub = primary.richMeta.dubVariant;
    final clusterKey = doubanId.isNotEmpty
        ? 'douban:${kind.name}:$doubanId:${dub.name}'
        : 'fp:${kind.name}:${normTitle.isNotEmpty ? normTitle : primary.refKey}:${year.isEmpty ? 'na' : year}:${dub.name}';

    return WorkCluster(
      clusterKey: clusterKey,
      kind: kind,
      dubVariant: dub,
      primaryTitle: primaryTitle,
      year: year,
      region: region,
      posterUrl: posterUrl,
      ratingText: ratingText,
      statusText: statusText,
      description: description,
      directors: directors.toList(),
      aliases: aliases.toList(),
      genres: genres.toList(),
      castText: castText,
      doubanId: doubanId,
      candidates: sorted,
    );
  }
}
