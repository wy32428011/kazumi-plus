import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/media/source_health_repository.dart';
import 'package:kazumi/services/media/source_scoring_engine.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

/// 片源健康与智能选源诊断中心（`/settings/source-health`）。
///
/// 职责：
/// - 调整全局智能选源策略（均衡 / 画质优先 / 极速流畅优先）与播中卡顿自动容灾开关；
/// - 展示全频道各片源的实测健康态（仅消费 `mpv` 实播解码分辨率、EWMA TTFB、吞吐率、CDN 归属组与熔断/人工验证冷却状态）；
/// - 支持单源一键解除熔断/重置统计或清空全部测速记录，并直达规则管理页。
class SourceHealthPage extends StatefulWidget {
  const SourceHealthPage({super.key});

  @override
  State<SourceHealthPage> createState() => _SourceHealthPageState();
}

class _SourceHealthPageState extends State<SourceHealthPage> {
  final _health = SourceHealthRepository.instance;
  final _scoring = SourceScoringEngine.instance;
  final _pluginsController = inject<PluginsController>();

  MediaKind _selectedKind = MediaKind.movie;
  late SourceRecommendationStrategy _strategy;
  late bool _autoFailover;

  @override
  void initState() {
    super.initState();
    _strategy = SourceRecommendationStrategy.parse(
      GStorage.getSetting(SettingsKeys.sourceRecommendationStrategy),
    );
    _autoFailover =
        GStorage.getSetting(SettingsKeys.autoFailoverEnabled) as bool? ?? true;
  }

  Future<void> _setStrategy(SourceRecommendationStrategy value) async {
    if (_strategy == value) return;
    setState(() => _strategy = value);
    await GStorage.putSetting(
      SettingsKeys.sourceRecommendationStrategy,
      value.name,
    );
  }

  Future<void> _setAutoFailover(bool value) async {
    setState(() => _autoFailover = value);
    await GStorage.putSetting(SettingsKeys.autoFailoverEnabled, value);
  }

  Future<void> _resetAll() async {
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置全部片源健康记录？'),
        content: const Text(
          '将清空所有片源的实测分辨率、延迟、吞吐统计以及熔断/验证冷却状态，不影响已安装的规则和片单。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _health.clearAll();
    if (mounted) {
      KazumiDialog.showToast(message: '已重置全部片源健康与测速记录');
    }
  }

  List<Plugin> _pluginsFor(MediaKind kind) {
    final list = _pluginsController.pluginList.where((p) {
      if (!p.enabled) return false;
      if (kind == MediaKind.anime) {
        return p.supportedMediaTypes.contains(MediaKind.anime.name) ||
            p.catalog == null;
      }
      return p.supportedMediaTypes.contains(kind.name) &&
          p.catalog?.channels.containsKey(kind.name) == true;
    }).toList();
    list.sort((a, b) {
      final sa = _scoring.scorePlugin(a, kind);
      final sb = _scoring.scorePlugin(b, kind);
      return sb.compareTo(sa);
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    return SettingsDetailScaffold(
      title: const Text('片源健康与智能选源'),
      actions: [
        IconButton(
          tooltip: '打开规则管理',
          onPressed: () => context.pushNamed('/settings/plugin/'),
          icon: const Icon(Icons.extension_outlined),
        ),
        IconButton(
          tooltip: '重置全部健康记录',
          onPressed: _resetAll,
          icon: const Icon(Icons.restart_alt_rounded),
        ),
      ],
      body: AnimatedBuilder(
        animation: _health,
        builder: (context, _) {
          final plugins = _pluginsFor(_selectedKind);
          final now = DateTime.now();

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              // 1. 智能选源策略与播中容灾配置卡
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tokens.surface1,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: tokens.hairline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '智能选源策略',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '根据实播解码分辨率、首帧响应、吞吐率与跨 CDN 稳定性自动排序，绝不轻信站点虚标标签。',
                      style: TextStyle(
                        color: tokens.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in SourceRecommendationStrategy.values)
                          TvFocusFrame(
                            radius: 8,
                            child: ChoiceChip(
                              label: Text(s.label),
                              selected: _strategy == s,
                              showCheckmark: false,
                              onSelected: (_) => unawaited(_setStrategy(s)),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Divider(color: tokens.hairline, height: 1),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '播中卡顿自动容灾切源',
                        style: TextStyle(
                          color: tokens.textPrimary,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        '遭遇断流、404 或持续缓冲时，自动预探独立 CDN 备源并保进度热切（提供 6 秒撤销）',
                        style: TextStyle(
                          color: tokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      value: _autoFailover,
                      onChanged: (v) => unawaited(_setAutoFailover(v)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // 2. 频道切换与实时监控表头
              Row(
                children: [
                  for (final kind in const [
                    MediaKind.movie,
                    MediaKind.tv,
                    MediaKind.anime,
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TvFocusFrame(
                        radius: 8,
                        child: ChoiceChip(
                          label: Text(kind.label),
                          selected: _selectedKind == kind,
                          showCheckmark: false,
                          onSelected: (_) =>
                              setState(() => _selectedKind = kind),
                        ),
                      ),
                    ),
                  const Spacer(),
                  Text(
                    '${plugins.length} 个已启用规则',
                    style: TextStyle(color: tokens.textMuted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (plugins.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: tokens.surface1,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: tokens.hairline),
                  ),
                  child: Column(
                    children: [
                      Text(
                        '当前频道暂无已启用片源规则',
                        style: TextStyle(color: tokens.textSecondary),
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () =>
                            context.pushNamed('/settings/plugin/'),
                        child: const Text('前往规则管理'),
                      ),
                    ],
                  ),
                )
              else
                for (final plugin in plugins)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _buildRuleHealthTile(context, tokens, plugin, now),
                  ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRuleHealthTile(
    BuildContext context,
    KazumiThemeTokens tokens,
    Plugin plugin,
    DateTime now,
  ) {
    final identityKey = SourceHealthRepository.pluginIdentityKey(plugin);
    final health = _health.healthFor(identityKey, _selectedKind);
    final inCaptcha = _health.isSourceInCaptchaCooldown(
      identityKey,
      _selectedKind,
      now: now,
    );
    final isCircuitOpen = health != null && health.isCircuitOpen(now);
    final isHalfOpen = health != null && health.isHalfOpen(now);

    final (statusLabel, statusColor) = inCaptcha
        ? ('需人工验证', tokens.warning)
        : isCircuitOpen
        ? ('熔断冷却中', tokens.danger)
        : isHalfOpen
        ? ('半开试探', tokens.warning)
        : health == null
        ? ('待实测', tokens.textMuted)
        : ('健康', tokens.healthy);

    final score = _scoring.scorePlugin(plugin, _selectedKind, now: now);
    final verifiedBadge = health?.lastVerifiedProfile?.uiBadgeText ?? '';
    final metrics = <String>[
      '综合分 ${(score * 100).round()}',
      if (verifiedBadge.isNotEmpty) '实测 $verifiedBadge',
      if (health?.ewmaTtfbMs != null) '首包 ${health!.ewmaTtfbMs!.round()}ms',
      if (health?.ewmaThroughputKbps != null)
        '速率 ${(health!.ewmaThroughputKbps! / 1000).toStringAsFixed(1)}Mbps',
      if (health != null) '起播 ${(health.startupSuccessRate * 100).round()}%',
      if (health != null && health.lastCdnGroup.isNotEmpty)
        'CDN ${health.lastCdnGroup}',
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.surface1,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plugin.name,
                  style: TextStyle(
                    color: tokens.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.45),
                  ),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            metrics.join('  '),
            style: TextStyle(
              color: tokens.textSecondary,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (health != null && health.lastError.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '最近记录：${health.lastError}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.warning, fontSize: 11.5),
            ),
          ],
          if (health != null || inCaptcha) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (inCaptcha)
                  TextButton(
                    onPressed: () {
                      _health.clearCaptchaCooldown(
                        identityKey,
                        kind: _selectedKind,
                      );
                      KazumiDialog.showToast(
                        message: '已解除 ${plugin.name} 冷却，下次请求将重新校验',
                      );
                    },
                    child: const Text('解除验证冷却'),
                  ),
                TextButton(
                  onPressed: () {
                    _health.resetSourceHealth(
                      identityKey,
                      kind: _selectedKind,
                    );
                    KazumiDialog.showToast(message: '已重置 ${plugin.name} 健康统计');
                  },
                  child: const Text('重置此源'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
