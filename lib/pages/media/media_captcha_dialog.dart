import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/catalog_rule_config.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/captcha_verification_service.dart';

/// 保存失败操作的请求模板和变量；验证只更新同一来源的 Cookie。
class MediaCaptchaRequest {
  const MediaCaptchaRequest({
    required this.plugin,
    required this.operation,
    required this.variables,
    required this.label,
  });
  final Plugin plugin;
  final CatalogOperation operation;
  final Map<String, Object?> variables;
  final String label;
}

Future<bool> verifyMediaCaptcha(
  BuildContext context,
  MediaCaptchaRequest request,
) async {
  final config = request.plugin.antiCrawlerConfig;
  final prepared = const ApiRuleStrategy().prepareRequest(
    request.operation.request,
    request.variables,
  );
  if (prepared.method != 'GET' ||
      config.captchaType != CaptchaType.imageCaptcha ||
      config.captchaImage.isEmpty ||
      config.captchaInput.isEmpty ||
      config.captchaButton.isEmpty) {
    KazumiDialog.showToast(message: '此规则没有可用的人工图片验证配置；请更新规则后重试原操作。');
    return false;
  }
  final url = RequestOptions(
    path: prepared.url,
    queryParameters: prepared.query,
  ).uri.toString();
  return await KazumiDialog.show<bool>(
        context: context,
        clickMaskDismiss: false,
        builder: (_) => _MediaCaptchaDialog(
          plugin: request.plugin,
          label: request.label,
          url: url,
        ),
      ) ??
      false;
}

/// 面向任意插件（含传统 XPath 动漫插件与目录 API 插件）的可见人工图片验证入口。
/// 绝不静默绕过验证码；验证通过仅刷新该站点的持久化 Cookie。
Future<bool> verifyPluginSearchCaptcha(
  BuildContext context, {
  required Plugin plugin,
  required String keyword,
}) async {
  final animeChannel = plugin.catalog?.channels['anime'];
  final catalogOp = animeChannel?.search ?? animeChannel?.discover;
  if (catalogOp != null) {
    return verifyMediaCaptcha(
      context,
      MediaCaptchaRequest(
        plugin: plugin,
        operation: catalogOp,
        variables: {'keyword': keyword, 'page': 1},
        label: '${plugin.name} 人工验证',
      ),
    );
  }
  final config = plugin.antiCrawlerConfig;
  if (config.captchaType != CaptchaType.imageCaptcha ||
      config.captchaImage.isEmpty ||
      config.captchaInput.isEmpty ||
      config.captchaButton.isEmpty) {
    KazumiDialog.showToast(message: '此规则没有可用的人工图片验证配置；请返回来源页完成验证。');
    return false;
  }
  final targetUrl = plugin.searchURL.isNotEmpty
      ? plugin.searchURL.replaceAll('@keyword', Uri.encodeQueryComponent(keyword))
      : plugin.baseUrl;
  return await KazumiDialog.show<bool>(
        context: context,
        clickMaskDismiss: false,
        builder: (_) => _MediaCaptchaDialog(
          plugin: plugin,
          label: '${plugin.name} 人工验证',
          url: targetUrl,
        ),
      ) ??
      false;
}

/// 复用原验证服务的 WebView、Cookie 持久化与提交过程，由用户识别图片。
class _MediaCaptchaDialog extends StatefulWidget {
  const _MediaCaptchaDialog({
    required this.plugin,
    required this.label,
    required this.url,
  });
  final Plugin plugin;
  final String label;
  final String url;

  @override
  State<_MediaCaptchaDialog> createState() => _MediaCaptchaDialogState();
}

class _MediaCaptchaDialogState extends State<_MediaCaptchaDialog> {
  final _service = CaptchaVerificationService();
  final _input = TextEditingController();
  StreamSubscription<String?>? _subscription;
  Timer? _timeout;
  Uint8List? _image;
  String? _error;
  bool _busy = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _subscription = _service.onCaptchaImageUrl.listen((value) {
      if (!mounted || value == null) return;
      try {
        final bytes = base64Decode(value.split(',').last);
        _timeout?.cancel();
        setState(() {
          _image = bytes;
          _error = null;
        });
      } catch (_) {
        setState(() => _error = '验证码图片无法显示，请重新加载。');
      }
    });
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() {
      _image = null;
      _error = null;
    });
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 15), () {
      if (mounted) setState(() => _error = '验证码加载超时，请重试。');
    });
    final config = widget.plugin.antiCrawlerConfig;
    try {
      await _service.loadForCaptcha(
        widget.url,
        config.captchaImage,
        inputXpath: config.captchaInput,
      );
    } catch (_) {
      _timeout?.cancel();
      if (mounted) setState(() => _error = '验证码加载失败，请重试。');
    }
  }

  Future<void> _submit() async {
    if (_busy || _input.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final plugin = widget.plugin;
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 15), () {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '验证尚未通过，请检查输入或刷新图片。';
        });
      }
    });
    try {
      await _service.submitCaptcha(
        captchaCode: _input.text.trim(),
        inputXpath: plugin.antiCrawlerConfig.captchaInput,
        buttonXpath: plugin.antiCrawlerConfig.captchaButton,
        pluginName: plugin.name,
        onFinalizing: () => _timeout?.cancel(),
        onVerified: (_) {
          if (mounted && !_closing) {
            setState(() => _closing = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) Navigator.of(context).pop(true);
            });
          }
        },
      );
    } catch (_) {
      _timeout?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '验证码提交失败，请重试。';
        });
      }
    }
  }

  Future<void> _close() async {
    if (_closing) return;
    setState(() => _closing = true);
    _timeout?.cancel();
    await _service.cancelAndSave(widget.plugin.name);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _subscription?.cancel();
    _input.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _closing,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_close());
    },
    child: AlertDialog(
      scrollable: true,
      title: Text('${widget.plugin.name}  人工验证'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('请输入图片中的字符。验证成功后只重试“${widget.label}”。'),
            const SizedBox(height: 16),
            if (_image != null)
              Image.memory(
                _image!,
                height: 100,
                errorBuilder: (_, error, stack) => const Text('图片无法解码，请刷新。'),
              )
            else if (_error == null)
              const CircularProgressIndicator(),
            if (_error != null) Text(_error!),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '验证码'),
              onSubmitted: (_) => _submit(),
            ),
            TextButton(
              onPressed: _busy ? null : _reload,
              child: const Text('刷新图片'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _close, child: const Text('取消')),
        FilledButton(
          onPressed: _busy || _image == null ? null : _submit,
          child: Text(_busy ? '验证中' : '提交'),
        ),
      ],
    ),
  );
}
