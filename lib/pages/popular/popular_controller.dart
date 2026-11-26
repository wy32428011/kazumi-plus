import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/utils/search_parser.dart';
import 'package:mobx/mobx.dart';

part 'popular_controller.g.dart';

class PopularController = _PopularController with _$PopularController;

abstract class _PopularController with Store {
  static const int _trendPageSize = 24;

  int _trendOffset = 0;
  int _filteredOffset = 0;

  @observable
  String currentTag = '';

  final Observable<String> _currentYear = Observable('');
  String get currentYear => _currentYear.value;
  set currentYear(String val) => runInAction(() => _currentYear.value = val);

  final Observable<String> _currentSort = Observable('heat');
  String get currentSort => _currentSort.value;
  set currentSort(String val) => runInAction(() => _currentSort.value = val);

  bool get isFiltered =>
      currentTag.isNotEmpty || currentYear.isNotEmpty || currentSort != 'heat';

  @observable
  ObservableList<BangumiItem> bangumiList = ObservableList.of([]);

  @observable
  ObservableList<BangumiItem> trendList = ObservableList.of([]);

  double scrollOffset = 0.0;

  @observable
  bool isLoadingMore = false;

  @observable
  bool isTimeOut = false;

  bool get _bangumiMirrorEnabled {
    try {
      return BangumiAcceleration.current == BangumiAcceleration.mirror;
    } catch (_) {
      return false;
    }
  }

  void setCurrentTag(String s) {
    currentTag = s;
  }

  void setCurrentYear(String y) {
    currentYear = y;
  }

  void setCurrentSort(String s) {
    currentSort = s;
  }

  void resetFilters({bool autoQuery = true}) {
    runInAction(() {
      currentTag = '';
      _currentYear.value = '';
      _currentSort.value = 'heat';
    });
    clearBangumiList();
    _filteredOffset = 0;
    if (autoQuery && trendList.isEmpty) {
      queryBangumiByTrend(type: 'init');
    }
  }

  void clearBangumiList() {
    bangumiList.clear();
  }

  @action
  Future<void> queryAnime({String type = 'add'}) async {
    if (!isFiltered) {
      await queryBangumiByTrend(type: type);
    } else {
      await queryFilteredBangumi(type: type);
    }
  }

  @action
  Future<void> queryFilteredBangumi({String type = 'add'}) async {
    if (type == 'init') {
      bangumiList.clear();
      _filteredOffset = 0;
    }
    isLoadingMore = true;

    if (_bangumiMirrorEnabled &&
        currentYear.isEmpty &&
        currentSort == 'heat' &&
        currentTag.isNotEmpty) {
      final result = await BangumiApi.getBangumiMirrorPopularSubjects(
        tag: currentTag,
        offset: bangumiList.length,
      );
      final existingIds = bangumiList.map((item) => item.id).toSet();
      bangumiList.addAll(result.where((item) => existingIds.add(item.id)));
      isLoadingMore = false;
      isTimeOut = bangumiList.isEmpty;
      return;
    }

    SearchDateRange? dateRange;
    if (currentYear.isNotEmpty) {
      if (currentYear.contains('年代')) {
        final startYear =
            int.tryParse(currentYear.replaceAll(RegExp(r'\D'), '')) ?? 2010;
        dateRange = SearchDateRange(
          start: '$startYear-01-01',
          end: '${startYear + 10}-01-01',
        );
      } else if (currentYear == '更早') {
        dateRange = const SearchDateRange(
          start: '1960-01-01',
          end: '2000-01-01',
        );
      } else {
        final y = int.tryParse(currentYear);
        if (y != null) {
          dateRange = SearchDateRange(
            start: '$y-01-01',
            end: '${y + 1}-01-01',
          );
        }
      }
    }

    final page = await BangumiApi.bangumiSearch(
      '',
      tags: currentTag.isNotEmpty ? [currentTag] : const [],
      sort: currentSort,
      dateRange: dateRange,
      offset: _filteredOffset,
      limit: _trendPageSize,
    );

    if (page != null && page.items.isNotEmpty) {
      _filteredOffset += page.rawCount > 0 ? page.rawCount : page.items.length;
      final existingIds = bangumiList.map((item) => item.id).toSet();
      bangumiList.addAll(page.items.where((item) => existingIds.add(item.id)));
    }
    isLoadingMore = false;
    isTimeOut = bangumiList.isEmpty && (page == null);
  }

  // Async actions commit each segment between awaits as one transaction,
  // batching the completion writes into a single notification.
  @action
  Future<void> queryBangumiByTrend({String type = 'add'}) async {
    if (type == 'init') {
      trendList.clear();
      _trendOffset = 0;
    }
    isLoadingMore = true;
    final result = _bangumiMirrorEnabled
        ? await BangumiApi.getBangumiMirrorPopularSubjects(
            limit: _trendPageSize,
            offset: _trendOffset,
          )
        : await BangumiApi.getBangumiTrendsList(
            limit: _trendPageSize,
            offset: _trendOffset,
          );
    if (result.isNotEmpty) {
      _trendOffset += _trendPageSize;
    }
    final existingIds = trendList.map((item) => item.id).toSet();
    trendList.addAll(result.where((item) => existingIds.add(item.id)));
    isLoadingMore = false;
    isTimeOut = trendList.isEmpty;
  }

  @action
  Future<void> queryBangumiByTag({String type = 'add'}) async {
    await queryAnime(type: type);
  }
}
