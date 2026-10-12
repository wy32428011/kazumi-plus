import 'package:dio/dio.dart';
import 'package:kazumi/modules/media/media_models.dart';
import 'package:kazumi/plugins/plugins.dart';

/// 界面通过能力接口访问来源，避免绑定某个站点的字段。
abstract interface class MediaProvider {
  Plugin get plugin;
  String get ruleId;
  List<MediaKind> get supportedKinds;

  Future<List<MediaCategory>> queryCategories(
    MediaKind kind, {
    CancelToken? cancelToken,
  });
  Future<MediaPage> queryDiscover(
    MediaKind kind, {
    String? categoryId,
    int page = 1,
    CancelToken? cancelToken,
  });
  Future<MediaPage> searchMedia(
    MediaKind kind,
    String keyword, {
    int page = 1,
    CancelToken? cancelToken,
  });
  Future<MediaDetail> queryDetail(
    MediaSummary item, {
    CancelToken? cancelToken,
  });
  Future<SourcePlaylist> queryPlaylist(
    MediaSummary item, {
    MediaSeason? season,
    CancelToken? cancelToken,
  });
}

abstract interface class MediaCatalogService {
  List<MediaProvider> providersFor(MediaKind kind);
  MediaProvider? providerById(String ruleId);
}
