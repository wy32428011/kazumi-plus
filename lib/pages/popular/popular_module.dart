import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/media/media_home_page.dart';
import 'package:kazumi/pages/popular/popular_controller.dart';

final popularModule = createModule(
  path: '/popular',
  register: (c) {
    c.route(
      '/',
      transition: TransitionType.none,
      child: (context, state) =>
          MediaHomePage(animeController: inject<PopularController>()),
    );
  },
);
