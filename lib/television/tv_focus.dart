import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

/// 电视输入形态独立于内容频道；手机直接复用原有树与主题。
class TvApplicationScope extends StatefulWidget {
  const TvApplicationScope({super.key, required this.child});
  final Widget child;

  @override
  State<TvApplicationScope> createState() => _TvApplicationScopeState();
}

class _TvApplicationScopeState extends State<TvApplicationScope> {
  FocusNode? _lastFocus;
  FocusHighlightStrategy? _previousStrategy;

  @override
  void initState() {
    super.initState();
    if (PlatformEnvironmentService.isTelevision) {
      _previousStrategy = FocusManager.instance.highlightStrategy;
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      FocusManager.instance.addListener(_followFocus);
    }
  }

  void _followFocus() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || identical(focus, _lastFocus)) return;
    _lastFocus = focus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final focusedContext = focus.context;
      if (!mounted ||
          !focus.hasPrimaryFocus ||
          focusedContext == null ||
          !focusedContext.mounted) {
        return;
      }
      unawaited(
        Scrollable.ensureVisible(
          focusedContext,
          alignment: .5,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_followFocus);
    if (_previousStrategy != null) {
      FocusManager.instance.highlightStrategy = _previousStrategy!;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformEnvironmentService.isTelevision) return widget.child;
    final original = Theme.of(context);
    final colors = original.brightness == Brightness.dark
        ? original.colorScheme
        : ColorScheme.fromSeed(
            seedColor: original.colorScheme.primary,
            brightness: Brightness.dark,
          );
    final focusSide = WidgetStateProperty.resolveWith<BorderSide?>(
      (states) => states.contains(WidgetState.focused)
          ? BorderSide(color: colors.primary, width: 3)
          : null,
    );
    final focusOverlay = WidgetStateProperty.resolveWith<Color?>(
      (states) => states.contains(WidgetState.focused)
          ? colors.primary.withValues(alpha: .22)
          : null,
    );
    final buttonStyle = ButtonStyle(
      side: focusSide,
      overlayColor: focusOverlay,
      minimumSize: const WidgetStatePropertyAll(Size(52, 48)),
    );
    return Theme(
      data: original.copyWith(
        brightness: Brightness.dark,
        colorScheme: colors,
        scaffoldBackgroundColor: colors.surface,
        canvasColor: colors.surface,
        cardColor: colors.surfaceContainerLow,
        cardTheme: original.cardTheme.copyWith(
          color: colors.surfaceContainerLow,
        ),
        appBarTheme: original.appBarTheme.copyWith(
          backgroundColor: colors.surface,
          foregroundColor: colors.onSurface,
        ),
        dialogTheme: original.dialogTheme.copyWith(
          backgroundColor: colors.surfaceContainerHigh,
        ),
        popupMenuTheme: original.popupMenuTheme.copyWith(
          color: colors.surfaceContainerHigh,
          textStyle: TextStyle(color: colors.onSurface),
        ),
        focusColor: colors.primary.withValues(alpha: .26),
        textTheme: original.textTheme.apply(
          bodyColor: colors.onSurface,
          displayColor: colors.onSurface,
          fontSizeFactor: 1.08,
        ),
        filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
        outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
        textButtonTheme: TextButtonThemeData(style: buttonStyle),
        iconButtonTheme: IconButtonThemeData(style: buttonStyle),
        listTileTheme: ListTileThemeData(
          textColor: colors.onSurface,
          iconColor: colors.onSurfaceVariant,
          selectedTileColor: colors.primaryContainer,
        ),
      ),
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
          ),
          SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
            TraversalDirection.left,
          ),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              DirectionalFocusIntent(TraversalDirection.right),
        },
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: widget.child,
        ),
      ),
    );
  }
}

/// 给已有 Material 控件增加可见焦点框，不额外创建一个可停留的焦点。
class TvFocusFrame extends StatefulWidget {
  const TvFocusFrame({super.key, required this.child, this.radius = 14});
  final Widget child;
  final double radius;

  @override
  State<TvFocusFrame> createState() => _TvFocusFrameState();
}

class _TvFocusFrameState extends State<TvFocusFrame> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    if (!PlatformEnvironmentService.isTelevision) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) => setState(() => _focused = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: _focused
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: widget.child,
      ),
    );
  }
}

/// 海报与导航采用单一焦点目标，返回上一页后恢复原条目的焦点。
class TvAction extends StatefulWidget {
  const TvAction({
    super.key,
    required this.child,
    required this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.selected = false,
    this.label,
    this.radius = 14,
  });
  final Widget child;
  final FutureOr<void> Function()? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool selected;
  final String? label;
  final double radius;

  @override
  State<TvAction> createState() => _TvActionState();
}

class _TvActionState extends State<TvAction> {
  late final FocusNode _ownedFocus = FocusNode(
    debugLabel: widget.label ?? '电视操作',
  );
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;
  bool _focused = false;

  Future<void> _activate() async {
    if (widget.onPressed == null) return;
    _focus.requestFocus();
    await widget.onPressed!();
    if (mounted &&
        _focus.canRequestFocus &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      _focus.requestFocus();
    }
  }

  @override
  void dispose() {
    _ownedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformEnvironmentService.isTelevision) return widget.child;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      selected: widget.selected,
      child: FocusableActionDetector(
        focusNode: _focus,
        autofocus: widget.autofocus,
        enabled: widget.onPressed != null,
        onFocusChange: (value) => setState(() => _focused = value),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              unawaited(_activate());
              return null;
            },
          ),
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          decoration: BoxDecoration(
            color: _focused
                ? colors.primaryContainer
                : widget.selected
                ? colors.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: _focused ? colors.primary : Colors.transparent,
              width: 3,
            ),
          ),
          child: ExcludeFocus(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed == null ? null : _activate,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 电视用对话列表代替小型下拉菜单；每个选项都有明确方向焦点。
class TvSelect<T> extends StatelessWidget {
  const TvSelect({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.autofocus = false,
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final bool autofocus;

  String get _selectedLabel {
    for (final option in options) {
      if (option.$1 == value) return option.$2;
    }
    return '请选择';
  }

  @override
  Widget build(BuildContext context) => TvFocusFrame(
    child: OutlinedButton.icon(
      autofocus: autofocus,
      icon: const Icon(Icons.expand_more),
      onPressed: onChanged == null
          ? null
          : () async {
              final selected = await showDialog<T>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text(label),
                  content: SizedBox(
                    width: 520,
                    height: options.length > 7 ? 380 : options.length * 54.0,
                    child: ListView.builder(
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: TvAction(
                            autofocus:
                                option.$1 == value ||
                                (index == 0 &&
                                    !options.any((item) => item.$1 == value)),
                            selected: option.$1 == value,
                            label: option.$2,
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(option.$1),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Row(
                                children: [
                                  Expanded(child: Text(option.$2)),
                                  if (option.$1 == value)
                                    const Icon(Icons.check),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              );
              if (context.mounted && selected != null) {
                onChanged?.call(selected);
              }
            },
      label: Text(
        '$label：$_selectedLabel',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// 电视先聚焦搜索按钮，确认后再打开系统键盘，避免方向移动误唤起输入法。
class TvSearchBox extends StatefulWidget {
  const TvSearchBox({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.enabled = true,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final bool enabled;
  final bool autofocus;

  @override
  State<TvSearchBox> createState() => _TvSearchBoxState();
}

class _TvSearchBoxState extends State<TvSearchBox> {
  final _focus = FocusNode(debugLabel: '电视搜索入口');
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TvFocusFrame(
    child: OutlinedButton.icon(
      focusNode: _focus,
      autofocus: widget.autofocus,
      icon: const Icon(Icons.search),
      onPressed: !widget.enabled
          ? null
          : () async {
              final value = await showDialog<String>(
                context: context,
                builder: (_) => _TvInputDialog(
                  initialValue: widget.controller.text,
                  hint: widget.hint,
                ),
              );
              if (!mounted || value == null || value.trim().isEmpty) return;
              widget.controller.text = value.trim();
              widget.onSubmitted(widget.controller.text);
              _focus.requestFocus();
            },
      label: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          widget.controller.text.isEmpty ? widget.hint : widget.controller.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  );
}

class _TvInputDialog extends StatefulWidget {
  const _TvInputDialog({required this.initialValue, required this.hint});
  final String initialValue;
  final String hint;
  @override
  State<_TvInputDialog> createState() => _TvInputDialogState();
}

class _TvInputDialogState extends State<_TvInputDialog> {
  late final _input = TextEditingController(text: widget.initialValue);
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.hint),
    content: SizedBox(
      width: 560,
      child: TextField(
        controller: _input,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(_input.text),
        child: const Text('搜索'),
      ),
    ],
  );
}
