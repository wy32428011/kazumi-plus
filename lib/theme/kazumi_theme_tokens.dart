import 'package:flutter/material.dart';
import 'package:kazumi/utils/constants.dart';

/// 「银盐放映室」（Silver-Salt Screening Room）全站设计令牌。
///
/// 采用中性 D65 电影级暗房石墨色阶与克制钨丝金主强调色，提供暗房、OLED 纯黑、
/// 暖雪花石浅色三套语义令牌，全站统一复用。
@immutable
class KazumiThemeTokens extends ThemeExtension<KazumiThemeTokens> {
  const KazumiThemeTokens({
    required this.canvas,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.hairline,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.healthy,
    required this.warning,
    required this.danger,
  });

  final Color canvas;
  final Color surface1;
  final Color surface2;
  final Color surface3;
  final Color hairline;
  final Color accent;
  final Color accentSoft;
  final Color onAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color healthy;
  final Color warning;
  final Color danger;

  /// 默认主强调色：钨丝金（暗房高可读、零荧光感）。
  static const Color tungstenGold = Color(0xFFD8A85B);

  /// 浅色模式主强调色：深古铜金（白底对比度 > 4.6:1）。
  static const Color warmBronze = Color(0xFF96651A);

  static const KazumiThemeTokens dark = KazumiThemeTokens(
    canvas: Color(0xFF0B0C0E),
    surface1: Color(0xFF121316),
    surface2: Color(0xFF191C22),
    surface3: Color(0xFF21252D),
    hairline: Color(0xFF2B303A),
    accent: tungstenGold,
    accentSoft: Color(0x26D8A85B),
    onAccent: Color(0xFF110E08),
    textPrimary: Color(0xFFF3F4F6),
    textSecondary: Color(0xFFA1A7B3),
    textMuted: Color(0xFF6B7280),
    healthy: Color(0xFF4ADE80),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
  );

  static const KazumiThemeTokens oled = KazumiThemeTokens(
    canvas: Color(0xFF000000),
    surface1: Color(0xFF0B0C0E),
    surface2: Color(0xFF14161B),
    surface3: Color(0xFF1C2027),
    hairline: Color(0xFF262B34),
    accent: tungstenGold,
    accentSoft: Color(0x26D8A85B),
    onAccent: Color(0xFF110E08),
    textPrimary: Color(0xFFF3F4F6),
    textSecondary: Color(0xFFA1A7B3),
    textMuted: Color(0xFF6B7280),
    healthy: Color(0xFF4ADE80),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
  );

  static const KazumiThemeTokens light = KazumiThemeTokens(
    canvas: Color(0xFFF6F5F2),
    surface1: Color(0xFFFFFFFF),
    surface2: Color(0xFFEFEDE8),
    surface3: Color(0xFFE6E2DA),
    hairline: Color(0xFFDDD8CE),
    accent: warmBronze,
    accentSoft: Color(0x1F96651A),
    onAccent: Color(0xFFFFFFFF),
    textPrimary: Color(0xFF14161A),
    textSecondary: Color(0xFF525866),
    textMuted: Color(0xFF7D8492),
    healthy: Color(0xFF15803D),
    warning: Color(0xFFB45309),
    danger: Color(0xFFB91C1C),
  );

  static KazumiThemeTokens of(BuildContext context) {
    final ext = Theme.of(context).extension<KazumiThemeTokens>();
    if (ext != null) return ext;
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  @override
  KazumiThemeTokens copyWith({
    Color? canvas,
    Color? surface1,
    Color? surface2,
    Color? surface3,
    Color? hairline,
    Color? accent,
    Color? accentSoft,
    Color? onAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? healthy,
    Color? warning,
    Color? danger,
  }) {
    return KazumiThemeTokens(
      canvas: canvas ?? this.canvas,
      surface1: surface1 ?? this.surface1,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      hairline: hairline ?? this.hairline,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      healthy: healthy ?? this.healthy,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  KazumiThemeTokens lerp(ThemeExtension<KazumiThemeTokens>? other, double t) {
    if (other is! KazumiThemeTokens) return this;
    return KazumiThemeTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface1: Color.lerp(surface1, other.surface1, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      healthy: Color.lerp(healthy, other.healthy, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }
}

/// 构建「银盐放映室」全局 [ThemeData]。
///
/// - 当 [customAccent] 为空且 [dynamicScheme] 为空时，采用完整银盐放映室中性色阶 + 钨丝金；
/// - 当用户主动选择自定义色或开启动态取色时，仅替换强调色，维持中性暗房基底避免背景染泥色。
ThemeData buildSilverSaltTheme({
  required Brightness brightness,
  String? fontFamily,
  Color? customAccent,
  ColorScheme? dynamicScheme,
  bool oledEnhance = false,
}) {
  final isDark = brightness == Brightness.dark;
  final baseTokens = isDark
      ? (oledEnhance ? KazumiThemeTokens.oled : KazumiThemeTokens.dark)
      : KazumiThemeTokens.light;

  final effectiveAccent =
      dynamicScheme?.primary ??
      customAccent ??
      baseTokens.accent;
  final effectiveOnAccent =
      ThemeData.estimateBrightnessForColor(effectiveAccent) == Brightness.dark
      ? Colors.white
      : const Color(0xFF110E08);

  final tokens = baseTokens.copyWith(
    accent: effectiveAccent,
    accentSoft: effectiveAccent.withValues(alpha: isDark ? 0.16 : 0.13),
    onAccent: effectiveOnAccent,
  );

  final scheme =
      (dynamicScheme ??
              ColorScheme.fromSeed(
                seedColor: effectiveAccent,
                brightness: brightness,
              ))
          .copyWith(
            primary: tokens.accent,
            onPrimary: tokens.onAccent,
            primaryContainer: tokens.surface2,
            onPrimaryContainer: tokens.textPrimary,
            secondary: tokens.accent,
            onSecondary: tokens.onAccent,
            secondaryContainer: tokens.surface2,
            onSecondaryContainer: tokens.textPrimary,
            surface: tokens.canvas,
            onSurface: tokens.textPrimary,
            onSurfaceVariant: tokens.textSecondary,
            surfaceContainerLowest: tokens.canvas,
            surfaceContainerLow: tokens.surface1,
            surfaceContainer: tokens.surface1,
            surfaceContainerHigh: tokens.surface2,
            surfaceContainerHighest: tokens.surface3,
            outline: tokens.hairline,
            outlineVariant: tokens.hairline,
            error: tokens.danger,
          );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: fontFamily,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.canvas,
    canvasColor: tokens.canvas,
    dividerColor: tokens.hairline,
    extensions: [tokens],
    progressIndicatorTheme: progressIndicatorTheme2024,
    sliderTheme: sliderTheme2024,
    pageTransitionsTheme: pageTransitionsTheme2024,
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.canvas,
      foregroundColor: tokens.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: tokens.surface1,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.hairline, width: 1),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.surface1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: tokens.hairline, width: 1),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.surface1,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(color: tokens.hairline, width: 1),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      backgroundColor: tokens.surface1,
      surfaceTintColor: Colors.transparent,
      indicatorColor: tokens.accentSoft,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 22,
          color: selected ? tokens.accent : tokens.textSecondary,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? tokens.accent : tokens.textSecondary,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: tokens.surface1,
      indicatorColor: tokens.accentSoft,
      selectedIconTheme: IconThemeData(color: tokens.accent, size: 22),
      unselectedIconTheme: IconThemeData(color: tokens.textSecondary, size: 22),
      selectedLabelTextStyle: TextStyle(
        color: tokens.accent,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: tokens.textSecondary,
        fontSize: 11,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: tokens.surface1,
      selectedColor: tokens.accentSoft,
      disabledColor: tokens.surface1,
      side: BorderSide(color: tokens.hairline),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(color: tokens.textPrimary, fontSize: 12),
      secondaryLabelStyle: TextStyle(color: tokens.accent, fontSize: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return tokens.accentSoft;
          return tokens.surface1;
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return tokens.accent;
          return tokens.textSecondary;
        }),
        side: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BorderSide(color: tokens.accent.withValues(alpha: 0.65));
          }
          return BorderSide(color: tokens.hairline);
        }),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.accent,
        foregroundColor: tokens.onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: tokens.textPrimary,
        side: BorderSide(color: tokens.hairline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.surface1,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: tokens.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: tokens.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: tokens.accent, width: 1.4),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: tokens.hairline,
      thickness: 1,
      space: 1,
    ),
  );
}

/// 观影暗房锁定（Cinema Dark Lock）：
/// 无论全局处于画廊浅色还是暗房深色模式，进入播放路由后局部强制锁定暗房主题
/// （若已处于深色则原样保留当前主题与用户自定义强调色/OLED 设置）。
ThemeData buildCinemaDarkTheme(
  BuildContext context, {
  bool oledEnhance = false,
}) {
  final current = Theme.of(context);
  if (current.brightness == Brightness.dark) {
    return current;
  }
  final currentTokens = current.extension<KazumiThemeTokens>();
  final currentAccent = currentTokens?.accent;
  final preserveCustomAccent =
      currentAccent != null &&
      currentAccent != KazumiThemeTokens.warmBronze &&
      currentAccent != KazumiThemeTokens.tungstenGold;
  return buildSilverSaltTheme(
    brightness: Brightness.dark,
    fontFamily: current.textTheme.bodyMedium?.fontFamily,
    customAccent: preserveCustomAccent ? currentAccent : null,
    oledEnhance: oledEnhance,
  );
}

