import 'package:kazumi/services/storage/storage.dart';

enum BangumiAcceleration {
  direct,
  ech,
  mirror;

  static BangumiAcceleration get current {
    try {
      return switch (GStorage.getSetting(SettingsKeys.bangumiAcceleration)) {
        'direct' => direct,
        'ech' => ech,
        'mirror' => mirror,
        _ =>
          GStorage.getSetting(SettingsKeys.enableBangumiProxy) ? mirror : direct,
      };
    } catch (_) {
      return mirror;
    }
  }

  String get label => switch (this) {
    direct => '直连',
    ech => 'ECH',
    mirror => '镜像',
  };
}
