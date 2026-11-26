// Bangumi mirror API credentials for the search signature flow.
// Release/PR CI injects them via --dart-define=KAZUMI_APPID / KAZUMI_KEY.
const Map<String, String> bangumiMirrorCredentials = {
  'id': String.fromEnvironment('KAZUMI_APPID'),
  'value': String.fromEnvironment('KAZUMI_KEY'),
};

/// 检查是否配置了有效的镜像受保护端点凭据。
/// 本地或缺少注入凭据时，镜像站会拒绝受保护请求（如搜索），需智能回退至 ECH 或直连。
bool get hasBangumiMirrorCredentials {
  final id = bangumiMirrorCredentials['id']?.trim() ?? '';
  final value = bangumiMirrorCredentials['value']?.trim() ?? '';
  return id.isNotEmpty && value.isNotEmpty;
}
