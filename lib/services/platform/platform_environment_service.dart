import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/logging/logger.dart';

/// 设备交互形态与影视内容类型互相独立。
enum AppDeviceFormFactor { handheld, desktop, television }

class PlatformEnvironmentService {
  PlatformEnvironmentService._();

  static const _intentChannel = MethodChannel('com.predidit.kazumi/intent');
  static const _televisionBuild =
      bool.fromEnvironment('KAZUMI_TELEVISION') || appFlavor == 'tv';
  static AppDeviceFormFactor _formFactor = _televisionBuild
      ? AppDeviceFormFactor.television
      : AppDeviceFormFactor.handheld;
  static bool _androidWebViewAvailable = true;

  static AppDeviceFormFactor get formFactor => _formFactor;
  static bool get isTelevisionBuild => _televisionBuild;
  static bool get isTelevision => _formFactor == AppDeviceFormFactor.television;
  static bool get androidWebViewAvailable => _androidWebViewAvailable;

  @visibleForTesting
  static void setFormFactorForTesting(AppDeviceFormFactor factor) {
    _formFactor = factor;
  }

  /// 启动前读取系统电视模式；电视构建也兼容未声明电视模式的普通盒子。
  static Future<void> initialize() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      _formFactor = AppDeviceFormFactor.desktop;
      return;
    }
    if (!Platform.isAndroid) return;
    try {
      final capabilities = await _intentChannel
          .invokeMapMethod<String, dynamic>('getDeviceCapabilities')
          .timeout(const Duration(seconds: 3));
      final television =
          _televisionBuild || capabilities?['television'] == true;
      _formFactor = television
          ? AppDeviceFormFactor.television
          : AppDeviceFormFactor.handheld;
      _androidWebViewAvailable = capabilities?['webViewAvailable'] != false;
    } catch (error) {
      // 旧原生工程或探测失败时仍可启动；网页能力由后续探测确认。
      KazumiLogger().w('设备能力探测失败，使用构建默认值', error: error);
    }
  }

  static Future<bool> isRunningOnX11() async {
    if (!Platform.isLinux) {
      return false;
    }
    try {
      return await _intentChannel.invokeMethod('isRunningOnX11');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to check X11 environment: '${e.message}'.");
      return false;
    }
  }

  static Future<int> getAndroidSdkVersion() async {
    if (!Platform.isAndroid) {
      return 0;
    }
    try {
      return await _intentChannel.invokeMethod('getAndroidSdkVersion');
    } on PlatformException catch (e) {
      KazumiLogger().e("Failed to get Android SDK version: '${e.message}'.");
      return 0;
    }
  }
}
