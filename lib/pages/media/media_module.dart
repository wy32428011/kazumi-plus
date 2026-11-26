import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/modules/media/work_cluster_models.dart';
import 'package:kazumi/pages/media/source_browse_page.dart';
import 'package:kazumi/pages/media/source_search_page.dart';
import 'package:kazumi/pages/media/source_detail_page.dart';
import 'package:kazumi/pages/media/source_player_page.dart';
import 'package:kazumi/pages/route_error_page.dart';

final mediaModule = createModule(
  path: '/media',
  register: (c) {
    c
      ..route(
        '/search',
        child: (context, state) {
          final args = state.arguments;
          if (args is! MediaSearchArgs || args.kind == MediaKind.anime) {
            return const RouteErrorPage(message: '影视搜索参数无效，请返回频道重新搜索。');
          }
          return SourceSearchPage(args: args);
        },
      )
      ..route(
        '/detail',
        child: (context, state) {
          final arg = state.arguments;
          if (arg is WorkCluster && arg.kind != MediaKind.anime) {
            return SourceDetailPage(
              media: arg.toPrimarySummary(),
              initialCluster: arg,
            );
          }
          if (arg is MediaSummary && !arg.ref.isAnime) {
            return SourceDetailPage(media: arg);
          }
          return const RouteErrorPage(message: '影视详情参数无效，请重新打开作品。');
        },
      )
      ..route(
        '/play',
        child: (context, state) {
          final args = state.arguments;
          if (args is! PlaybackContext || args.media.ref.isAnime) {
            return const RouteErrorPage(message: '影视播放参数无效，请从详情页重新选集。');
          }
          return SourcePlayerPage(playbackContext: args);
        },
      );
  },
);
