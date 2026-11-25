import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/auto_updater.dart';
import 'package:kazumi/services/update/update_download_source.dart';
import 'package:kazumi/services/update/update_downloader.dart';
import 'package:kazumi/utils/version.dart';

void main() {
  group('needUpdate', () {
    test('handles leading v prefix and build metadata', () {
      expect(needUpdate('0.1.0', 'v0.2.0'), isTrue);
      expect(needUpdate('v0.1.0+1', 'v0.1.0+2'), isFalse);
      expect(needUpdate('0.1.0+1', '0.1.1+2'), isTrue);
      expect(needUpdate('v0.2.0', '0.1.9'), isFalse);
      expect(needUpdate('V1.0.0', 'v1.0.0'), isFalse);
    });

    test('handles prerelease versions according to semver precedence', () {
      expect(needUpdate('0.2.0-beta.1', '0.2.0'), isTrue);
      expect(needUpdate('0.2.0', '0.2.0-beta.1'), isFalse);
      expect(needUpdate('0.2.0-beta.1', '0.2.0-beta.2'), isTrue);
      expect(needUpdate('0.2.0-beta.2', '0.2.0-beta.10'), isTrue);
      expect(needUpdate('0.2.0-alpha.1', '0.2.0-beta.1'), isTrue);
    });

    test('returns false instead of throwing on invalid version strings', () {
      expect(needUpdate('0.1.0', 'invalid-tag'), isFalse);
      expect(needUpdate('', 'v0.2.0'), isFalse);
      expect(needUpdate('0.1.0', 'v0.2.'), isFalse);
    });
  });

  group('installation type detection and asset matching', () {
    final releaseAssets = <Map<String, dynamic>>[
      {
        'name': 'Kazumi-Plus-v0.2.0-windows-x64-setup.exe',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-windows-x64-setup.exe',
        'digest': 'sha256:1111',
      },
      {
        'name': 'Kazumi-Plus-v0.2.0-windows-x64.zip',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-windows-x64.zip',
      },
      {
        'name': 'Kazumi-Plus-v0.2.0-android-mobile-arm64.apk',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-android-mobile-arm64.apk',
      },
      {
        'name': 'Kazumi-Plus-v0.2.0-android-tv.apk',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-android-tv.apk',
      },
      {
        'name': 'Kazumi-Plus-v0.2.0-macos.dmg',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-macos.dmg',
      },
      {
        'name': 'Kazumi-Plus-v0.2.0-ios.ipa',
        'browser_download_url':
            'https://github.com/example/kazumi-plus/releases/download/v0.2.0/Kazumi-Plus-v0.2.0-ios.ipa',
      },
    ];

    test('Windows prefers EXE installer and keeps ZIP as fallback', () {
      final types = detectAvailableInstallationTypes(
        isWindows: true,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
        isAndroid: false,
        isTelevisionBuild: false,
      );
      expect(
        types,
        equals([
          InstallationType.windowsExe,
          InstallationType.windowsPortable,
        ]),
      );

      final exeAsset =
          getUpdateAssetForType(releaseAssets, InstallationType.windowsExe);
      expect(exeAsset?['name'], 'Kazumi-Plus-v0.2.0-windows-x64-setup.exe');
      expect(getUpdateFileHashFromAsset(exeAsset!), '1111');

      final zipAsset = getUpdateAssetForType(
          releaseAssets, InstallationType.windowsPortable);
      expect(zipAsset?['name'], 'Kazumi-Plus-v0.2.0-windows-x64.zip');
    });

    test('Android distinguishes mobile and TV packages', () {
      final mobileTypes = detectAvailableInstallationTypes(
        isWindows: false,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
        isAndroid: true,
        isTelevisionBuild: false,
      );
      final tvTypes = detectAvailableInstallationTypes(
        isWindows: false,
        isLinux: false,
        isMacOS: false,
        isIOS: false,
        isAndroid: true,
        isTelevisionBuild: true,
      );

      expect(mobileTypes, equals([InstallationType.androidMobileApk]));
      expect(tvTypes, equals([InstallationType.androidTvApk]));

      expect(
        getUpdateAssetForType(releaseAssets, InstallationType.androidMobileApk)
            ?['name'],
        'Kazumi-Plus-v0.2.0-android-mobile-arm64.apk',
      );
      expect(
        getUpdateAssetForType(releaseAssets, InstallationType.androidTvApk)
            ?['name'],
        'Kazumi-Plus-v0.2.0-android-tv.apk',
      );
    });

    test('iOS does not match in-app asset and falls back to release page', () {
      expect(InstallationType.ios.downloadsInApp, isFalse);
      expect(
        getUpdateAssetForType(releaseAssets, InstallationType.ios),
        isNull,
      );
    });

    test('resolveAvailableInstallationTypes filters to assets present in release',
        () {
      final zipOnlyAssets = [releaseAssets[1]];
      final resolved = resolveAvailableInstallationTypes(
        const [InstallationType.windowsExe, InstallationType.windowsPortable],
        zipOnlyAssets,
      );
      expect(resolved, equals([InstallationType.windowsPortable]));
    });
  });

  group('getAvailableUpdateDownloadSources', () {
    test('defaults to GitHub when mirror_download_url is absent', () {
      final githubOnlyAsset = <String, dynamic>{
        'name': 'Kazumi-Plus-v0.2.0-windows-x64-setup.exe',
        'browser_download_url': 'https://github.com/example/file.exe',
      };
      expect(
        getAvailableUpdateDownloadSources(githubOnlyAsset),
        equals([UpdateDownloadSource.github]),
      );
    });

    test('lists mirror and GitHub when both URLs exist', () {
      final dualAsset = <String, dynamic>{
        'name': 'Kazumi-Plus-v0.2.0-windows-x64-setup.exe',
        'mirror_download_url': 'https://mirror.example.com/file.exe',
        'browser_download_url': 'https://github.com/example/file.exe',
      };
      expect(
        getAvailableUpdateDownloadSources(dualAsset),
        equals([UpdateDownloadSource.mirror, UpdateDownloadSource.github]),
      );
    });
  });
}
