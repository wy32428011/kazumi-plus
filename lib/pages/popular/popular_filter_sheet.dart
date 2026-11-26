import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/utils/constants.dart';

class AnimeFilterResult {
  const AnimeFilterResult({
    required this.tag,
    required this.year,
    required this.sort,
  });

  final String tag;
  final String year;
  final String sort;
}

const List<String> animeYearOptions = [
  '2026',
  '2025',
  '2024',
  '2023',
  '2022',
  '2021',
  '2020',
  '2019',
  '2018',
  '2017',
  '2016',
  '2015',
  '2010年代',
  '2000年代',
  '更早',
];

const Map<String, String> animeSortOptions = {
  'heat': '热门推荐',
  'score': '评分最高',
  'rank': '排名优选',
  'date': '上映时间',
};

class AnimeFilterSheet extends StatefulWidget {
  const AnimeFilterSheet({
    super.key,
    required this.initialTag,
    required this.initialYear,
    required this.initialSort,
  });

  final String initialTag;
  final String initialYear;
  final String initialSort;

  @override
  State<AnimeFilterSheet> createState() => _AnimeFilterSheetState();
}

class _AnimeFilterSheetState extends State<AnimeFilterSheet> {
  late String _draftTag = widget.initialTag;
  late String _draftYear = widget.initialYear;
  late String _draftSort = widget.initialSort;

  void _reset() {
    setState(() {
      _draftTag = '';
      _draftYear = '';
      _draftSort = 'heat';
    });
  }

  void _apply() {
    Navigator.pop(
      context,
      AnimeFilterResult(
        tag: _draftTag,
        year: _draftYear,
        sort: _draftSort,
      ),
    );
  }

  Widget _buildSectionTitle(String title, {String? subtitle}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MaterialBottomSheetHeader(
            title: '筛选动漫',
            onClose: () => Navigator.pop(context),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              children: [
                _buildSectionTitle(
                  '排序方式',
                  subtitle: animeSortOptions[_draftSort],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final entry in animeSortOptions.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: _draftSort == entry.key,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() => _draftSort = entry.key);
                          }
                        },
                      ),
                  ],
                ),
                _buildSectionTitle(
                  '年份时间',
                  subtitle: _draftYear.isEmpty ? '全部年份' : _draftYear,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('全部年份'),
                      selected: _draftYear.isEmpty,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _draftYear = '');
                        }
                      },
                    ),
                    for (final year in animeYearOptions)
                      ChoiceChip(
                        label: Text(year),
                        selected: _draftYear == year,
                        onSelected: (selected) {
                          setState(() => _draftYear = selected ? year : '');
                        },
                      ),
                  ],
                ),
                _buildSectionTitle(
                  '题材标签',
                  subtitle: _draftTag.isEmpty ? '全部题材' : _draftTag,
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: const Text('全部题材'),
                      selected: _draftTag.isEmpty,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() => _draftTag = '');
                        }
                      },
                    ),
                    for (final tag in defaultAnimeTags)
                      ChoiceChip(
                        label: Text(tag),
                        selected: _draftTag == tag,
                        onSelected: (selected) {
                          setState(() => _draftTag = selected ? tag : '');
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _reset,
                      child: const Text('重置'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _apply,
                      child: const Text('完成筛选'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
