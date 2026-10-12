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

  /// 电视使用固定侧栏，初始落在推荐入口，右键进入内容区。
  Widget _televisionMenu(BuildContext context) {
    const entries = [
      (Icons.home_outlined, '推荐'),
      (Icons.calendar_month_outlined, '动漫时间表'),
      (Icons.favorite_outline, '片单'),
      (Icons.settings_outlined, '我的'),
    ];
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 170,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 12, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Kazumi Plus',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text('电视版', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 28),
                    for (var index = 0; index < entries.length; index++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
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
                              vertical: 15,
                            ),
                            child: Row(
                              children: [
                                Icon(entries[index].$1, size: 22),
                                const SizedBox(width: 10),
                                Expanded(child: Text(entries[index].$2)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    const Text(
                      '方向键导航\n确认选择 · 返回上一级',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Focus(
                focusNode: _tvOutletFocusNode,
                canRequestFocus: false,
                skipTraversal: true,
                child: FocusTraversalGroup(
                  policy: _tvOutletTraversalPolicy,
                  child: _outlet(
                    context,
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _outlet(BuildContext context, {BorderRadius? borderRadius}) {
    Widget child = NotificationListener<NavigationNotification>(
      // A non-poppable outlet must not override the shell's PopScope state.
      onNotification: (notification) => !notification.canHandlePop,
      child: RouterOutlet(key: _outletKey),
    );
    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }

  Widget _bottomMenu(BuildContext context, int selectedIndex) {
    return Scaffold(
      body: _outlet(context),
      bottomNavigationBar: NavigationBar(
        destinations: const <Widget>[
          NavigationDestination(
            selectedIcon: Icon(Icons.home),
            icon: Icon(Icons.home_outlined),
            label: '推荐',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.timeline),
            icon: Icon(Icons.timeline_outlined),
            label: '动漫时间表',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.favorite),
            icon: Icon(Icons.favorite_outlined),
            label: '片单',
          ),
          NavigationDestination(
            selectedIcon: Icon(Icons.settings),
            icon: Icon(Icons.settings),
            label: '我的',
          ),
        ],
        selectedIndex: selectedIndex,
        onDestinationSelected: _selectDestination,
      ),
    );
  }

  Widget _sideMenu(BuildContext context, int selectedIndex) {
    const borderRadius = BorderRadius.only(
      topLeft: Radius.circular(16),
      bottomLeft: Radius.circular(16),
    );
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      body: Row(
        children: [
          EmbeddedNativeControlArea(
            child: NavigationRail(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
              groupAlignment: 1,
              leading: FloatingActionButton(
                elevation: 0,
                heroTag: null,
                onPressed: () {
                  final library = SourceMediaLibrary.instance;
                  final kind = MediaKind.parse(library.preference('home.kind'));
                  if (kind == MediaKind.anime) {
                    context.pushNamed('/search/');
                  } else {
                    context.pushNamed(
                      '/media/search',
                      arguments: MediaSearchArgs(
                        kind: kind,
                        ruleId: library.preference('${kind.name}.source'),
                      ),
                    );
                  }
                },
                child: const Icon(Icons.search),
              ),
              labelType: NavigationRailLabelType.selected,
              destinations: const <NavigationRailDestination>[
                NavigationRailDestination(
                  selectedIcon: Icon(Icons.home),
                  icon: Icon(Icons.home_outlined),
                  label: Text('推荐'),
                ),
                NavigationRailDestination(
                  selectedIcon: Icon(Icons.timeline),
                  icon: Icon(Icons.timeline_outlined),
                  label: Text('动漫时间表'),
                ),
                NavigationRailDestination(
                  selectedIcon: Icon(Icons.favorite),
                  icon: Icon(Icons.favorite_border),
                  label: Text('片单'),
                ),
                NavigationRailDestination(
                  selectedIcon: Icon(Icons.settings),
                  icon: Icon(Icons.settings_outlined),
                  label: Text('我的'),
                ),
              ],
              selectedIndex: selectedIndex,
              onDestinationSelected: _selectDestination,
            ),
          ),
          Expanded(child: _outlet(context, borderRadius: borderRadius)),
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
