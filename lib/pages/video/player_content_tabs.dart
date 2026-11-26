import 'package:flutter/material.dart';

class PlayerContentTabs extends StatelessWidget {
  const PlayerContentTabs({
    super.key,
    required this.controller,
    required this.onEpisodesSelected,
    this.showComments = true,
    this.tabLabels,
  });

  final TabController controller;
  final VoidCallback onEpisodesSelected;
  final bool showComments;
  final List<String>? tabLabels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final height = (MediaQuery.textScalerOf(context).scale(14) * 1.5 + 16)
        .clamp(48.0, double.infinity);
    final labels = tabLabels ??
        [
          '选集',
          if (showComments) '评论',
        ];

    return Material(
      color: colors.surface,
      child: TabBar(
        controller: controller,
        padding: EdgeInsets.zero,
        dividerHeight: 0,
        splashBorderRadius: BorderRadius.zero,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 3,
        labelColor: colors.primary,
        unselectedLabelColor: colors.onSurfaceVariant,
        labelStyle: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelStyle: theme.textTheme.titleSmall,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        onTap: (index) {
          if (index == 0) onEpisodesSelected();
        },
        tabs: [
          for (final label in labels) Tab(text: label, height: height),
        ],
      ),
    );
  }
}
