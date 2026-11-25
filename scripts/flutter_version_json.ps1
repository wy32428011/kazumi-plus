# 版本机读输出后可能附带 Flutter 首次运行提示，只解析首个完整的 JSON 对象。
function ConvertTo-FlutterVersionJson([string]$OutputText) {
    $stringReader = [IO.StringReader]::new($OutputText)
    $jsonReader = [Newtonsoft.Json.JsonTextReader]::new($stringReader)
    try {
        # 保留 SDK 返回的日期字符串，避免 JSON 读取器自动转换日期格式。
        $jsonReader.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $versionObject = [Newtonsoft.Json.Linq.JObject]::Load($jsonReader)
        return $versionObject.ToString([Newtonsoft.Json.Formatting]::Indented)
    } finally {
        $jsonReader.Close()
        $stringReader.Dispose()
    }
}
