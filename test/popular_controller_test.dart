import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';

void main() {
  group('PopularController filtering tests', () {
    test('initial state is not filtered', () {
      final controller = PopularController();
      expect(controller.currentTag, '');
      expect(controller.currentYear, '');
      expect(controller.currentSort, 'heat');
      expect(controller.isFiltered, false);
    });

    test('setting tag marks as filtered', () {
      final controller = PopularController();
      controller.setCurrentTag('日常');
      expect(controller.currentTag, '日常');
      expect(controller.isFiltered, true);
    });

    test('setting year marks as filtered', () {
      final controller = PopularController();
      controller.setCurrentYear('2024');
      expect(controller.currentYear, '2024');
      expect(controller.isFiltered, true);
    });

    test('setting sort to non-heat marks as filtered', () {
      final controller = PopularController();
      controller.setCurrentSort('score');
      expect(controller.currentSort, 'score');
      expect(controller.isFiltered, true);
    });

    test('resetFilters clears all filters back to default', () {
      final controller = PopularController();
      controller.setCurrentTag('奇幻');
      controller.setCurrentYear('2023');
      controller.setCurrentSort('rank');
      expect(controller.isFiltered, true);

      controller.resetFilters(autoQuery: false);
      expect(controller.currentTag, '');
      expect(controller.currentYear, '');
      expect(controller.currentSort, 'heat');
      expect(controller.isFiltered, false);
    });
  });
}
