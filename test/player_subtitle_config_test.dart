import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';
import 'package:media_kit/media_kit.dart';

void main() {
  group('buildMediaPlayerConfiguration', () {
    test('enables libass on desktop without Android font override', () {
      final config = buildMediaPlayerConfiguration(
        bufferSize: 32 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
        adBlocker: true,
        isAndroid: false,
      );

      expect(config.libass, isTrue);
      expect(config.libassAndroidFont, isNull);
      expect(config.libassAndroidFontName, isNull);
      expect(config.osc, isFalse);
      expect(config.adBlocker, isTrue);
    });

    test('enables libass with bundled MiSans font on Android gpu renderer', () {
      final config = buildMediaPlayerConfiguration(
        bufferSize: 16 * 1024 * 1024,
        logLevel: MPVLogLevel.info,
        adBlocker: false,
        isAndroid: true,
        videoRenderer: 'gpu-next',
      );

      expect(config.libass, isTrue);
      expect(config.libassAndroidFont, 'assets/fonts/MiSans-Regular.ttf');
      expect(config.libassAndroidFontName, 'MiSans');
    });

    test('falls back to Flutter SubtitleView on Android mediacodec_embed', () {
      final config = buildMediaPlayerConfiguration(
        bufferSize: 16 * 1024 * 1024,
        logLevel: MPVLogLevel.info,
        adBlocker: false,
        isAndroid: true,
        videoRenderer: 'mediacodec_embed',
      );

      expect(config.libass, isFalse);
      expect(config.libassAndroidFont, isNull);
      expect(config.libassAndroidFontName, isNull);
    });
  });
}
