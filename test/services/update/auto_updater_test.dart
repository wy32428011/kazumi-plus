import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
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

  group('ApiEndpoints update channel configuration', () {
    test('defaults to independent Kazumi Plus release API', () {
      expect(ApiEndpoints.isUpdateConfigured, isTrue);
      expect(
        ApiEndpoints.effectiveLatestApp,
        equals(ApiEndpoints.defaultPlusUpdateUrl),
      );
      expect(
        ApiEndpoints.isUpstreamKazumiUpdateUrl(ApiEndpoints.effectiveLatestApp),
        isFalse,
      );
      expect(
        ApiEndpoints.releasePageUrl,
        equals('https://github.com/wy32428011/kazumi-plus/releases'),
      );
    });

    test('resolveUpdateUrl validates scheme and blocks upstream Predidit/Kazumi', () {
      expect(ApiEndpoints.resolveUpdateUrl(''), isEmpty);
      expect(ApiEndpoints.resolveUpdateUrl('   '), isEmpty);
      expect(ApiEndpoints.resolveUpdateUrl('ftp://example.com/latest'), isEmpty);
      expect(
        ApiEndpoints.resolveUpdateUrl(
          'https://api.github.com/repos/Predidit/Kazumi/releases/latest',
        ),
        isEmpty,
      );
      expect(
        ApiEndpoints.resolveUpdateUrl(
          'https://api.github.com/repos/predidit/kazumi/releases/latest',
        ),
        isEmpty,
      );
      expect(
        ApiEndpoints.resolveUpdateUrl('https://github.com/Predidit/Kazumi/releases'),
        isEmpty,
      );
      expect(
        ApiEndpoints.resolveUpdateUrl(
          '  https://api.github.com/repos/custom-owner/kazumi-plus/releases/latest  ',
        ),
        equals(
          'https://api.github.com/repos/custom-owner/kazumi-plus/releases/latest',
        ),
      );
    });

    test('deriveReleasePageUrl converts GitHub API endpoint to web releases URL', () {
      expect(
        ApiEndpoints.deriveReleasePageUrl(
          'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest',
        ),
        equals('https://github.com/wy32428011/kazumi-plus/releases'),
      );
      expect(
        ApiEndpoints.deriveReleasePageUrl('https://updates.example.com/latest.json'),
        equals('https://updates.example.com/latest.json'),
      );
      expect(
        ApiEndpoints.deriveReleasePageUrl(
          'https://api.github.com/repos/Predidit/Kazumi/releases/latest',
        ),
        isEmpty,
      );
    });
  });

  group('SHA256SUMS parsing and fallback', () {
    const validSha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const secondSha =
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

    test('parseSha256Sums parses standard and binary checksum formats', () {
      const sumsContent = '''
# Kazumi Plus checksums
$validSha  Kazumi-Plus-v0.3.0-windows-x64-setup.exe
$secondSha *./Kazumi-Plus-v0.3.0-android-mobile-arm64.apk
short-hash  invalid.zip
''';

      expect(
        findSha256InSums(
          sumsContent,
          'Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
        ),
        equals(validSha),
      );
      expect(
        findSha256InSums(
          sumsContent,
          'kazumi-plus-v0.3.0-android-mobile-arm64.apk',
        ),
        equals(secondSha),
      );
      expect(findSha256InSums(sumsContent, 'invalid.zip'), isEmpty);
    });

    test('resolveExpectedHash falls back to SHA256SUMS.txt when digest is absent', () async {
      final fetchedUrls = <String>[];
      final updater = AutoUpdater.forTesting(
        textFetcher: (url, {headers = const {}}) async {
          fetchedUrls.add(url);
          return '$validSha  Kazumi-Plus-v0.3.0-windows-x64-setup.exe\n';
        },
      );
      final targetAsset = <String, dynamic>{
        'name': 'Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
        'browser_download_url':
            'https://github.com/wy32428011/kazumi-plus/releases/download/v0.3.0/Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
      };
      final assets = [
        targetAsset,
        <String, dynamic>{
          'name': 'SHA256SUMS.txt',
          'browser_download_url':
              'https://github.com/wy32428011/kazumi-plus/releases/download/v0.3.0/SHA256SUMS.txt',
        },
      ];

      final resolved = await updater.resolveExpectedHash(
        assets,
        targetAsset,
        UpdateDownloadSource.github,
      );
      expect(resolved, equals(validSha));
      expect(
        fetchedUrls,
        equals([
          'https://github.com/wy32428011/kazumi-plus/releases/download/v0.3.0/SHA256SUMS.txt',
        ]),
      );
    });

    test('resolveExpectedHash uses asset digest directly without extra fetch', () async {
      var fetched = false;
      final updater = AutoUpdater.forTesting(
        textFetcher: (url, {headers = const {}}) async {
          fetched = true;
          return '';
        },
      );
      final targetAsset = <String, dynamic>{
        'name': 'Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
        'digest': 'sha256:$validSha',
      };

      final resolved = await updater.resolveExpectedHash(
        [targetAsset],
        targetAsset,
        UpdateDownloadSource.github,
      );
      expect(resolved, equals(validSha));
      expect(fetched, isFalse);
    });

    test('getUpdateDownloadErrorMessage exposes missing SHA256 argument error', () {
      expect(
        getUpdateDownloadErrorMessage(ArgumentError('更新缺少有效的 SHA256 校验值')),
        equals('更新缺少有效的 SHA256 校验值'),
      );
    });
  });

  group('AutoUpdater.checkForUpdates', () {
    test('detects newer GitHub release and sends GitHub API headers', () async {
      String? requestedUrl;
      Map<String, dynamic>? requestedHeaders;
      final updater = AutoUpdater.forTesting(
        updateUrl:
            'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest',
        currentVersion: '0.2.0',
        installationTypesDetector: () => const [
          InstallationType.windowsExe,
          InstallationType.windowsPortable,
        ],
        textFetcher: (url, {headers = const {}}) async {
          requestedUrl = url;
          requestedHeaders = headers;
          return json.encode({
            'tag_name': 'v0.3.0',
            'body': '新版本说明',
            'html_url':
                'https://github.com/wy32428011/kazumi-plus/releases/tag/v0.3.0',
            'published_at': '2026-11-28T00:00:00Z',
            'assets': [
              {
                'name': 'Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
                'browser_download_url':
                    'https://github.com/wy32428011/kazumi-plus/releases/download/v0.3.0/Kazumi-Plus-v0.3.0-windows-x64-setup.exe',
                'digest':
                    'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
              },
            ],
          });
        },
      );

      final info = await updater.checkForUpdates();
      expect(
        requestedUrl,
        equals(
          'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest',
        ),
      );
      expect(
        requestedHeaders?['Accept'],
        contains('application/vnd.github+json'),
      );
      expect(info, isNotNull);
      expect(info!.version, equals('v0.3.0'));
      expect(info.description, equals('新版本说明'));
      expect(
        info.recommendedInstallationType,
        equals(InstallationType.windowsExe),
      );
      expect(
        info.availableInstallationTypes,
        equals([InstallationType.windowsExe]),
      );
    });

    test('returns null when already on latest version', () async {
      final updater = AutoUpdater.forTesting(
        updateUrl:
            'https://api.github.com/repos/wy32428011/kazumi-plus/releases/latest',
        currentVersion: '0.2.0',
        textFetcher: (url, {headers = const {}}) async => json.encode({
          'tag_name': 'v0.2.0',
          'assets': const [],
        }),
      );

      expect(await updater.checkForUpdates(), isNull);
    });

    test('skips request when updateUrl is empty or points to upstream Kazumi', () async {
      var calls = 0;
      for (final blockedUrl in [
        '',
        'https://api.github.com/repos/Predidit/Kazumi/releases/latest',
      ]) {
        final updater = AutoUpdater.forTesting(
          updateUrl: blockedUrl,
          currentVersion: '0.1.0',
          textFetcher: (url, {headers = const {}}) async {
            calls++;
            return '{}';
          },
        );
        expect(await updater.checkForUpdates(), isNull);
      }
      expect(calls, equals(0));
    });
  });
}
