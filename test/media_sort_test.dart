import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/media/media_models.dart';

void main() {
  group('MediaSort tests', () {
    test('MediaSort.parse fallback and valid values', () {
      expect(MediaSort.parse('latest'), MediaSort.latest);
      expect(MediaSort.parse('rating'), MediaSort.rating);
      expect(MediaSort.parse('yearDesc'), MediaSort.yearDesc);
      expect(MediaSort.parse('yearAsc'), MediaSort.yearAsc);
      expect(MediaSort.parse('title'), MediaSort.title);
      expect(MediaSort.parse('unknown'), MediaSort.latest);
      expect(MediaSort.parse(null), MediaSort.latest);
    });

    final item1 = const MediaSummary(
      ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.tv, id: '1'),
      title: '流浪地球',
      detailSource: '1',
      ratingText: '8.5',
      year: '2019',
    );
    final item2 = const MediaSummary(
      ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.tv, id: '2'),
      title: '庆余年',
      detailSource: '2',
      ratingText: '9.2',
      year: '2024',
    );
    final item3 = const MediaSummary(
      ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.tv, id: '3'),
      title: '大话西游',
      detailSource: '3',
      ratingText: '9.0',
      year: '1995',
    );
    final item4 = const MediaSummary(
      ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.tv, id: '4'),
      title: '暂无年份与评分',
      detailSource: '4',
      ratingText: '',
      year: '',
    );
    final items = [item1, item2, item3, item4];

    test('sortedBy latest keeps original order', () {
      final sorted = items.sortedBy(MediaSort.latest);
      expect(sorted.map((e) => e.title).toList(), [
        '流浪地球',
        '庆余年',
        '大话西游',
        '暂无年份与评分',
      ]);
    });

    test('sortedBy rating puts highest rating first and empty last', () {
      final sorted = items.sortedBy(MediaSort.rating);
      expect(sorted.map((e) => e.title).toList(), [
        '庆余年', // 9.2
        '大话西游', // 9.0
        '流浪地球', // 8.5
        '暂无年份与评分', // empty
      ]);
    });

    test('sortedBy yearDesc puts newest year first and empty last', () {
      final sorted = items.sortedBy(MediaSort.yearDesc);
      expect(sorted.map((e) => e.title).toList(), [
        '庆余年', // 2024
        '流浪地球', // 2019
        '大话西游', // 1995
        '暂无年份与评分', // empty
      ]);
    });

    test('sortedBy yearAsc puts oldest year first and empty last', () {
      final sorted = items.sortedBy(MediaSort.yearAsc);
      expect(sorted.map((e) => e.title).toList(), [
        '大话西游', // 1995
        '流浪地球', // 2019
        '庆余年', // 2024
        '暂无年份与评分', // empty
      ]);
    });

    test('sortedBy title sorts alphabetically case-insensitively', () {
      final a = const MediaSummary(
        ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.movie, id: 'a'),
        title: 'Apple',
        detailSource: 'a',
      );
      final b = const MediaSummary(
        ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.movie, id: 'b'),
        title: 'banana',
        detailSource: 'b',
      );
      final c = const MediaSummary(
        ref: MediaRef.source(ruleId: 'r1', kind: MediaKind.movie, id: 'c'),
        title: 'Cat',
        detailSource: 'c',
      );
      final list = [b, c, a];
      final sorted = list.sortedBy(MediaSort.title);
      expect(sorted.map((e) => e.title).toList(), ['Apple', 'banana', 'Cat']);
    });
  });
}
