import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/pages/router.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/services/media/source_media_library.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';
import 'package:kazumi/television/tv_focus.dart';
import 'package:kazumi/theme/kazumi_theme_tokens.dart';

class ScaffoldMenu extends StatefulWidget {
  const ScaffoldMenu({super.key, required this.location});

  final String location;

  @override
  State<ScaffoldMenu> createState() => _ScaffoldMenu();
}

class _ScaffoldMenu extends State<ScaffoldMenu> with RouteAware {
  final _outletKey = GlobalKey<RouterOutletState>();

  /// 侧栏节点随外壳存活，内容页切换或返回时仍能定位当前入口。
  final _tvMenuFocusNodes = List.generate(
    4,
    (index) => FocusNode(debugLabel: '电视侧栏 $index'),
  );
  final _tvOutletFocusNode = FocusNode(debugLabel: '电视内容边界');
  bool _tvRailDimmed = false;
  late final _tvOutletTraversalPolicy = _TvOutletTraversalPolicy(
    onLeftEdge: _focusTelevisionMenu,
  );
  late int _selectedIndex = menu.indexForPath(widget.location);
  DateTime? _lastExitPromptAt;

  /// The shell sits at the bottom of the root stack and stays mounted while
  /// other pages cover it, so it publishes that state for its subtree.
  bool _isCovered = false;

  @override
  void didUpdateWidget(covariant ScaffoldMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _selectedIndex = menu.indexForPath(widget.location);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    for (final node in _tvMenuFocusNodes) {
      node.dispose();
    }
    _tvOutletFocusNode.dispose();
    super.dispose();
  }

  @override
  void didPushNext() => _setCovered(true);

  @override
  void didPopNext() => _setCovered(false);

  void _setCovered(bool value) {
    if (!mounted || _isCovered == value) {
      return;
    }
    setState(() => _isCovered = value);
  }

  void _selectDestination(int index) {
    _lastExitPromptAt = null;
    if (index == _selectedIndex) {
      return;
    }
    final outlet = _outletKey.currentState;
    if (outlet == null) return;
    outlet.navigate('/tab${menu.getPath(index)}/');
    setState(() => _selectedIndex = index);
  }

  /// 只承接当前可见内容页的左边界，不从弹层或文本编辑中夺取焦点。
  bool _focusTelevisionMenu(FocusNode currentNode) {
    if (!PlatformEnvironmentService.isTelevision ||
        !mounted ||
        _isCovered ||
        ModalRoute.of(context)?.isCurrent != true ||
        !currentNode.hasPrimaryFocus ||
        !currentNode.ancestors.contains(_tvOutletFocusNode)) {
      return false;
    }
    final focusedContext = currentNode.context;
    if (focusedContext == null || !focusedContext.mounted) {
      return false;
    }
    final focusedRoute = ModalRoute.of(focusedContext);
    if (focusedRoute is! PageRoute ||
        !focusedRoute.isCurrent ||
        focusedContext.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    final menuNode = _tvMenuFocusNodes[_selectedIndex];
    if (!menuNode.canRequestFocus || menuNode.context == null) {
      return false;
    }
    menuNode.requestFocus();
    return true;
  }

  void _handleSystemBack(BuildContext context) {
    if (_outletKey.currentState?.maybePop() ?? false) {
      _lastExitPromptAt = null;
      return;
    }

    if (_selectedIndex != 0) {
      _selectDestination(0);
      return;
    }

    final now = DateTime.now();
    final lastPromptAt = _lastExitPromptAt;
    if (lastPromptAt == null ||
        now.difference(lastPromptAt) > const Duration(seconds: 2)) {
      _lastExitPromptAt = now;
      KazumiDialog.showToast(message: '再按一次退出应用', context: context);
      return;
    }

    _lastExitPromptAt = null;
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return RouteVisibility(
      isCovered: _isCovered,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleSystemBack(context);
          }
        },
        child: OrientationBuilder(
          builder: (context, orientation) {
            if (PlatformEnvironmentService.isTelevision) {
              return _televisionMenu(context);
            }
            return orientation == Orientation.portrait
                ? _bottomMenu(context, _selectedIndex)
                : _sideMenu(context, _selectedIndex);
          },
        ),
      ),
    );
  }

  /// 电视使用固定暗房侧栏（184dp），初始落在推荐入口，右键进入内容区。
  Widget _televisionMenu(BuildContext context) {
    final tokens = KazumiThemeTokens.of(context);
    const entries = [
      (Icons.local_movies_outlined, '放映室'),
      (Icons.calendar_month_outlined, '时间表'),
      (Icons.bookmarks_outlined, '片单'),
      (Icons.tune_outlined, '我的'),
    ];
    return Scaffold(
      backgroundColor: tokens.canvas,
      body: SafeArea(
        child: Row(
          children: [
            AnimatedOpacity(
              opacity: _tvRailDimmed ? 0.72 : 1.0,
              duration: const Duration(milliseconds: 140),
              child: Container(
                width: 184,
                decoration: BoxDecoration(
                  color: tokens.surface1,
                  border: Border(
                    right: BorderSide(color: tokens.hairline, width: 1),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 27, 14, 27),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: tokens.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Kazumi Plus',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: tokens.textPrimary,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '银盐放映室 · TV',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: tokens.textMuted,
                        ),
                      ),
                      const SizedBox(height: 24),
                      for (var index = 0; index < entries.length; index++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: TvAction(
                            key: ValueKey('tv-menu-$index'),
                            focusNode: _tvMenuFocusNodes[index],
                            autofocus: index == _selectedIndex,
                            label: entries[index].$2,
                            selected: index == _selectedIndex,
                            onPressed: () => _selectDestination(index),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    entries[index].$1,
                                    size: 21,
                                    color: index == _selectedIndex
                                        ? tokens.accent
                                        : tokens.textSecondary,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      entries[index].$2,
                                      style: TextStyle(
                                        color: index == _selectedIndex
                                            ? tokens.textPrimary
                                            : tokens.textSecondary,
                                        fontWeight: index == _selectedIndex
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      Text(
                        '方向键导航\n确认选择 · 返回上一级',
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.textMuted,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: Focus(
                focusNode: _tvOutletFocusNode,
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (hasFocus) {
                  if (_tvRailDimmed != hasFocus && mounted) {
                    setState(() => _tvRailDimmed = hasFocus);
                  }
                },
                child: FocusTraversalGroup(
                  policy: _tvOutletTraversalPolicy,
                  child: _outlet(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _outlet(BuildContext context, {BorderRadius? borderRadius}) {
    final tokens = KazumiThemeTokens.of(context);
    Widget child = NotificationListener<NavigationNotification>(
      // A non-poppable outlet must not override the shell's PopScope state.
      onNotification: (notification) => !notification.canHandlePop,
      child: RouterOutlet(key: _outletKey),
    );
    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }
    return ColoredBox(color: tokens.canvas, child: child);
  }

  Widget _bottomMenu(BuildContext context, int selectedIndex) {
    final tokens = KazumiThemeTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.canvas,
      body: _outlet(context),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: tokens.surface1,
          border: Border(top: BorderSide(color: tokens.hairline, width: 1)),
        ),
        child: NavigationBar(
          destinations: const <Widget>[
            NavigationDestination(
              selectedIcon: Icon(Icons.local_movies_rounded),
              icon: Icon(Icons.local_movies_outlined),
              label: '放映室',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.calendar_month_rounded),
              icon: Icon(Icons.calendar_month_outlined),
              label: '时间表',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.bookmarks_rounded),
              icon: Icon(Icons.bookmarks_outlined),
              label: '片单',
            ),
            NavigationDestination(
              selectedIcon: Icon(Icons.tune_rounded),
              icon: Icon(Icons.tune_outlined),
              label: '我的',
            ),
          ],
          selectedIndex: selectedIndex,
          onDestinationSelected: _selectDestination,
        ),
      ),
    );
  }

  void _openUnifiedSearch(BuildContext context) {
    final library = SourceMediaLibrary.instance;
    final kind = MediaKind.parse(library.preference('home.kind'));
    if (kind == MediaKind.anime) {
      context.pushNamed('/search/');
    } else {
      context.pushNamed(
        '/media/search',
        arguments: MediaSearchArgs(kind: kind),
      );
    }
  }

  Widget _sideMenu(BuildContext context, int selectedIndex) {
    final tokens = KazumiThemeTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.surface1,
      body: Row(
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.surface1,
              border: Border(
                right: BorderSide(color: tokens.hairline, width: 1),
              ),
            ),
            child: EmbeddedNativeControlArea(
              child: NavigationRail(
                backgroundColor: Colors.transparent,
                groupAlignment: -0.88,
                minWidth: 72,
                leading: Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Tooltip(
                    message: '全局检索片名、演员或导演',
                    child: Material(
                      color: tokens.surface2,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: tokens.hairline),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _openUnifiedSearch(context),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.search_rounded,
                            color: tokens.accent,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                labelType: NavigationRailLabelType.all,
                destinations: const <NavigationRailDestination>[
                  NavigationRailDestination(
                    selectedIcon: Icon(Icons.local_movies_rounded),
                    icon: Icon(Icons.local_movies_outlined),
                    label: Text('放映室'),
                  ),
                  NavigationRailDestination(
                    selectedIcon: Icon(Icons.calendar_month_rounded),
                    icon: Icon(Icons.calendar_month_outlined),
                    label: Text('时间表'),
                  ),
                  NavigationRailDestination(
                    selectedIcon: Icon(Icons.bookmarks_rounded),
                    icon: Icon(Icons.bookmarks_outlined),
                    label: Text('片单'),
                  ),
                  NavigationRailDestination(
                    selectedIcon: Icon(Icons.tune_rounded),
                    icon: Icon(Icons.tune_outlined),
                    label: Text('我的'),
                  ),
                ],
                selectedIndex: selectedIndex,
                onDestinationSelected: _selectDestination,
              ),
            ),
          ),
          Expanded(child: _outlet(context)),
        ],
      ),
    );
  }
}

/// RouterOutlet 的路由焦点范围默认在边缘停止；电视只补齐回侧栏路径。
class _TvOutletTraversalPolicy extends ReadingOrderTraversalPolicy {
  _TvOutletTraversalPolicy({required this.onLeftEdge});

  final bool Function(FocusNode currentNode) onLeftEdge;

  @override
  bool inDirection(FocusNode currentNode, TraversalDirection direction) {
    if (super.inDirection(currentNode, direction)) {
      return true;
    }
    if (direction != TraversalDirection.left || !onLeftEdge(currentNode)) {
      return false;
    }
    // 离开内容范围后清除方向回溯，重新进入时以当前页面焦点为准。
    final scope = currentNode.nearestScope;
    if (scope != null) {
      invalidateScopeData(scope);
    }
    return true;
  }
}
