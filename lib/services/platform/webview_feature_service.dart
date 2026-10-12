import 'dart:io';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/platform_environment_service.dart';

class WebViewFeatureService {
  WebViewFeatureService._();

  static bool? _isDocumentStartScriptSupported;
  static bool _isAvailable = true;

  static bool get isAvailable => _isAvailable;

  /// 只在需要网页解析时检查能力，直链播放不依赖 WebView。
  static void requireAvailable() {
    if (!_isAvailable) throw const WebViewUnavailableException();
  }

  static Future<void> initialize() async {
    if (Platform.isAndroid) {
      _isAvailable = PlatformEnvironmentService.androidWebViewAvailable;
      if (!_isAvailable) {
        _isDocumentStartScriptSupported = false;
        return;
      }
      try {
        _isDocumentStartScriptSupported = await PlatformWebViewFeature.static()
            .isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)
            .timeout(const Duration(seconds: 5));
      } catch (error) {
        // 缺少或禁用系统网页组件的电视仍应允许 API 与直链来源正常工作。
        _isAvailable = false;
        _isDocumentStartScriptSupported = false;
        KazumiLogger().w('系统 WebView 不可用，保留直链播放能力', error: error);
      }
    }
  }

  static bool get isDocumentStartScriptSupported =>
      _isDocumentStartScriptSupported ?? false;
}

class WebViewUnavailableException implements Exception {
  const WebViewUnavailableException();

  @override
  String toString() => '此设备没有可用的 WebView，此来源需要网页解析或验证，请更换直链来源。';
}
