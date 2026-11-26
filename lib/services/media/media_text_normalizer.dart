import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/media/work_cluster_models.dart';

/// 影视元数据清洗与标准化工具：
/// - 递归 HTML 解码（最多 4 轮至收敛，根治 &amp;amp;amp;）
/// - 年份清洗（修剪 2026– / (2025) 等异常格式）
/// - 诚实评分过滤（屏蔽 MacCMS 伪 vod_score，无真实豆瓣分返回空串）
/// - 繁简折叠与版本/季号/集号识别
class MediaTextNormalizer {
  const MediaTextNormalizer._();

  static final RegExp _yearRegex = RegExp(r'(19\d{2}|20[0-3]\d)');
  static final RegExp _doubanIdRegex = RegExp(r'^\d+$');
  static final RegExp _whitespaceRegex = RegExp(r'\s+');
  static final RegExp _episodeRegex = RegExp(
    r'^(?:第\s*)?(\d{1,4})\s*(?:集|话|話|期)?$',
  );
  static final RegExp _epPrefixRegex = RegExp(
    r'^(?:EP|E)\s*0*(\d{1,4})$',
    caseSensitive: false,
  );
  static final RegExp _camTsRegex = RegExp(
    r'(?:^|[\s\[\(\-_./])(?:TC|TS|CAM|HC|HDCAM|HDTC|HDTS)(?:$|[\s\]\)\-_./])|枪版|槍版|抢先版|搶先版|尝鲜版|嘗鮮版',
    caseSensitive: false,
  );
  static final RegExp _explicitArabicSeasonRegex = RegExp(
    r'(?:第\s*0*([1-9]\d?)\s*季)|(?:(?:\b|[\s\-_])(?:Season|S)\s*0*([1-9]\d?)(?!\s*E\d)(?:\b|$))',
    caseSensitive: false,
  );
  static final RegExp _explicitChineseSeasonRegex = RegExp(
    r'第\s*([一二三四五六七八九十两兩]{1,3})\s*季',
  );
  static final RegExp _completedStatusRegex = RegExp(
    r'完结|完結|全\s*\d+\s*集|全集|大结局|大結局',
  );
  static final RegExp _episodeCountRegex = RegExp(
    r'(?:全|共|更新至第?|已更新至?第?)\s*(\d{1,4})\s*(?:集|话|話|期)',
  );
  static final RegExp _noiseBracketRegex = RegExp(
    r'[\(\[【（]\s*(?:国语|國語|粤语|粵語|台语|臺語|国配|中配|粤配|台配|英配|原声|原聲|中字|双语|雙語|双字|雙字|未删减|未刪減|完整版|加长版|加長版|导演剪辑版|導演剪輯版|修复版|修復版|重制版|重製版|蓝光|藍光|高清|超清|正片|电影版|電影版|4K|1080P|720P|HD|BD|HDR|60FPS|TS|TC|CAM|抢先版|枪版|清晰版|中英双字|中英雙字)[^\)\]】）]*[\)\]】）]',
    caseSensitive: false,
  );
  static final RegExp _noiseSuffixRegex = RegExp(
    r'(?:[\s\-_/]+|\b)(?:国语版|國語版|粤语版|粵語版|台语版|臺語版|国语配音|國語配音|粤语配音|粵語配音|国配|中配|粤配|台配|中字|双语|雙語|未删减版?|未刪減版?|加长版|加長版|导演剪辑版|導演剪輯版|蓝光版?|藍光版?|高清版?|超清版?|4K\s*HDR|4K|2160P|1080P|720P|60FPS|HDR|HD中字|HD国语|HD粤语|BD中字|BD国语|BD粤语|TC中字|TS中字|TC|TS|HD|BD|抢先版|枪版)$',
    caseSensitive: false,
  );
  static final RegExp _stripPunctuationRegex = RegExp(
    r'''[\s·•・.\-_:,;!?/\\|()\[\]{}（）【】《》「」『』“”"'`~～@#\$%\^&\*\+=<>，。！？：；、—–]+''',
  );

  /// 递归执行 HTML 实体解码，最多 [maxRounds] 轮，直到文本收敛。
  static String decodeHtmlRecursive(Object? value, {int maxRounds = 4}) {
    var current = value?.toString().trim() ?? '';
    if (current.isEmpty) return '';
    for (var round = 0; round < maxRounds; round++) {
      final decoded = html.parseFragment(current).text?.trim() ?? '';
      if (decoded == current) break;
      current = decoded;
    }
    return current.replaceAll(' ', ' ').replaceAll(_whitespaceRegex, ' ').trim();
  }

  /// 提取合法四位年份（1900-2039），自动修剪 `2026–`、`(2025)`、`2024年` 等脏文本。
  static String cleanYear(Object? value) {
    final text = decodeHtmlRecursive(value);
    if (text.isEmpty) return '';
    final match = _yearRegex.firstMatch(text);
    return match?.group(1) ?? '';
  }

  /// 提取合法年份整数，非法返回 null。
  static int? parseYearInt(Object? value) {
    final cleaned = cleanYear(value);
    return cleaned.isEmpty ? null : int.tryParse(cleaned);
  }

  /// 清洗豆瓣 ID：仅接受纯数字且 `>= 1000000`。
  static String cleanDoubanId(Object? value) {
    final text = decodeHtmlRecursive(value);
    if (text.isEmpty || !_doubanIdRegex.hasMatch(text)) return '';
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 1000000) return '';
    return text;
  }

  /// 诚实评分解析：
  /// - 优先解析 `doubanScore`，严格要求 `0.0 < s <= 10.0`；
  /// - 当 [isMacCmsVodScore] 为真时直接忽略伪占位 `vod_score`；
  /// - 无有效评分时返回空串，绝不补造。
  static String parseHonestRating({
    Object? doubanScore,
    Object? rawRating,
    bool isMacCmsVodScore = false,
  }) {
    final parsedDouban = parseHonestScoreValue(doubanScore);
    if (parsedDouban != null) {
      return parsedDouban.toStringAsFixed(1);
    }
    if (isMacCmsVodScore) return '';
    final parsedFallback = parseHonestScoreValue(rawRating);
    if (parsedFallback != null) {
      return parsedFallback.toStringAsFixed(1);
    }
    return '';
  }

  static double? parseHonestScoreValue(Object? value) {
    final text = decodeHtmlRecursive(value);
    if (text.isEmpty) return null;
    final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(text);
    if (match == null) return null;
    final score = double.tryParse(match.group(0)!);
    if (score == null || score <= 0.0 || score > 10.0) return null;
    return score;
  }

  /// 严格锚定集号解析：支持 `第1集`、`01`、`EP01`、`E01`，拒绝 `1080P`、`4K`、`S02E03`。
  static int? parseEpisodeNumber(String title) {
    final trimmed = decodeHtmlRecursive(title);
    if (trimmed.isEmpty) return null;
    final primary = _episodeRegex.firstMatch(trimmed);
    if (primary != null) {
      final value = int.tryParse(primary.group(1)!);
      if (value != null && value > 0) return value;
    }
    final epMatch = _epPrefixRegex.firstMatch(trimmed);
    if (epMatch != null) {
      final value = int.tryParse(epMatch.group(1)!);
      if (value != null && value > 0) return value;
    }
    return null;
  }

  /// 识别是否枪版/抢先版/TC/TS。
  static bool detectCamOrTs(String title, {String statusText = ''}) {
    final combined = '${decodeHtmlRecursive(title)} ${decodeHtmlRecursive(statusText)}';
    return _camTsRegex.hasMatch(combined);
  }

  /// 仅当片名明确标注季号时返回季数；缺失季标返回 null，绝不自动推断“第 1 季”。
  static int? extractExplicitSeasonToken(String title) {
    final simplified = toSimplifiedChinese(decodeHtmlRecursive(title));
    if (simplified.isEmpty) return null;
    final arabic = _explicitArabicSeasonRegex.firstMatch(simplified);
    if (arabic != null) {
      final numStr = arabic.group(1) ?? arabic.group(2);
      final parsed = int.tryParse(numStr ?? '');
      if (parsed != null && parsed >= 1 && parsed <= 50) return parsed;
    }
    final chinese = _explicitChineseSeasonRegex.firstMatch(simplified);
    if (chinese != null) {
      final parsed = _parseChineseSmallNumber(chinese.group(1)!);
      if (parsed != null && parsed >= 1 && parsed <= 50) return parsed;
    }
    return null;
  }

  /// 识别显式配音版本。
  /// 对国产/内地/台湾地区作品仅通过片名显式标配（如“粤语版”“国配”）拆分，
  /// 避免把国产剧常规 `HD国语` 误判为“配音版”而与无标注源错误分裂。
  static AudioDubVariant detectDubVariant({
    required String title,
    String statusText = '',
    String region = '',
    String playFrom = '',
  }) {
    final normTitle = toSimplifiedChinese(decodeHtmlRecursive(title)).toLowerCase();
    final normStatus = toSimplifiedChinese(decodeHtmlRecursive(statusText)).toLowerCase();
    final normRegion = toSimplifiedChinese(decodeHtmlRecursive(region));
    final normPlayFrom = toSimplifiedChinese(decodeHtmlRecursive(playFrom)).toLowerCase();

    final isMandarinNativeRegion =
        normRegion.contains('中国') ||
        normRegion.contains('大陆') ||
        normRegion.contains('内地') ||
        normRegion.contains('台湾');
    final isCantoneseNativeRegion = normRegion.contains('香港');

    // 片名显式标配始终拆簇
    if (RegExp(r'粤语|粤配|cantonese').hasMatch(normTitle)) {
      return isCantoneseNativeRegion && !normTitle.contains('配音') && !normTitle.contains('粤配')
          ? AudioDubVariant.original
          : AudioDubVariant.cantoneseDub;
    }
    if (RegExp(r'国语|国配|中配|普通话|mandarin').hasMatch(normTitle)) {
      return isMandarinNativeRegion && !normTitle.contains('配音') && !normTitle.contains('国配')
          ? AudioDubVariant.original
          : AudioDubVariant.mandarinDub;
    }
    if (RegExp(r'台语|台配|闽南语').hasMatch(normTitle)) {
      return AudioDubVariant.taiwaneseDub;
    }
    if (RegExp(r'英语配音|英配|英语版').hasMatch(normTitle)) {
      return AudioDubVariant.englishDub;
    }

    // 状态/线路显式标配（排除原生语言）
    final combinedHint = '$normStatus $normPlayFrom';
    if (RegExp(r'粤语|粤配').hasMatch(combinedHint) && !isCantoneseNativeRegion) {
      return AudioDubVariant.cantoneseDub;
    }
    if (RegExp(r'国配|中配').hasMatch(combinedHint) ||
        (RegExp(r'国语').hasMatch(combinedHint) &&
            !isMandarinNativeRegion &&
            normRegion.isNotEmpty)) {
      return AudioDubVariant.mandarinDub;
    }
    if (RegExp(r'台配|台语|闽南语').hasMatch(combinedHint)) {
      return AudioDubVariant.taiwaneseDub;
    }
    if (RegExp(r'英配|英语配音').hasMatch(combinedHint)) {
      return AudioDubVariant.englishDub;
    }
    return AudioDubVariant.original;
  }

  /// 提取剧集完结状态与声明集数，用于防误并校验。
  static ({bool isCompleted, int? episodeCount}) parseCompletionAndCount(
    String statusText,
  ) {
    final simplified = toSimplifiedChinese(decodeHtmlRecursive(statusText));
    if (simplified.isEmpty) {
      return (isCompleted: false, episodeCount: null);
    }
    final isCompleted = _completedStatusRegex.hasMatch(simplified);
    final match = _episodeCountRegex.firstMatch(simplified);
    final count = match == null ? null : int.tryParse(match.group(1)!);
    return (isCompleted: isCompleted, episodeCount: count);
  }

  /// 保留可读字符用于搜索词（HTML 解码 + 去画质/配音括注后缀）。
  static String cleanQueryTitle(String raw) {
    var text = decodeHtmlRecursive(raw);
    if (text.isEmpty) return '';
    for (var i = 0; i < 3; i++) {
      final stripped = text
          .replaceAll(_noiseBracketRegex, ' ')
          .replaceAll(_noiseSuffixRegex, '')
          .replaceAll(_whitespaceRegex, ' ')
          .trim();
      if (stripped == text) break;
      text = stripped;
    }
    return text.trim();
  }

  /// 标准化片名/别名用于聚簇指纹比对（繁简折叠 + 半角 + 去画质/配音噪声 + 去标点）。
  static String normalizeTitleForMatching(String raw) {
    var text = _toHalfWidth(toSimplifiedChinese(decodeHtmlRecursive(raw)));
    if (text.isEmpty) return '';
    // 迭代去除尾部/括号噪声标签
    for (var i = 0; i < 3; i++) {
      final stripped = text
          .replaceAll(_noiseBracketRegex, ' ')
          .replaceAll(_noiseSuffixRegex, '')
          .trim();
      if (stripped == text) break;
      text = stripped;
    }
    text = text.toLowerCase().replaceAll(_stripPunctuationRegex, '');
    return text;
  }

  /// 标准化人名（导演/主演）用于交集比对。
  static String normalizePersonName(String raw) {
    final text = _toHalfWidth(toSimplifiedChinese(decodeHtmlRecursive(raw)));
    return text.toLowerCase().replaceAll(_stripPunctuationRegex, '');
  }

  /// 拆分多值字段（别名、导演、主演、类型）。
  static List<String> splitMultiValue(Object? value) {
    if (value is List) {
      return value
          .map(decodeHtmlRecursive)
          .where((item) => item.isNotEmpty)
          .toList();
    }
    final text = decodeHtmlRecursive(value);
    if (text.isEmpty) return const [];
    return text
        .split(RegExp(r'[,，、/|]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  /// 是否包含 ASCII 拉丁字母词（用于区分中英文片名/别名）。
  static bool containsLatinLetters(String text) =>
      RegExp(r'[A-Za-z]{2,}').hasMatch(text);

  /// 是否包含中文汉字。
  static bool containsCjk(String text) =>
      RegExp(r'[一-鿿]').hasMatch(text);

  /// 繁简转换（覆盖影视/动漫高频繁体字约 1200+ 字）。
  static String toSimplifiedChinese(String input) {
    if (input.isEmpty) return '';
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      buffer.write(_tradToSimpMap[ch] ?? ch);
    }
    return buffer.toString();
  }

  static String _toHalfWidth(String input) {
    final buffer = StringBuffer();
    for (final codeUnit in input.codeUnits) {
      if (codeUnit == 0x3000) {
        buffer.writeCharCode(0x20);
      } else if (codeUnit >= 0xFF01 && codeUnit <= 0xFF5E) {
        buffer.writeCharCode(codeUnit - 0xFEE0);
      } else {
        buffer.writeCharCode(codeUnit);
      }
    }
    return buffer.toString();
  }

  static int? _parseChineseSmallNumber(String raw) {
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '兩': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (raw == '十') return 10;
    if (raw.length == 1) return digits[raw];
    if (raw.startsWith('十') && raw.length == 2) {
      final ones = digits[raw[1]];
      return ones == null ? null : 10 + ones;
    }
    if (raw.endsWith('十') && raw.length == 2) {
      final tens = digits[raw[0]];
      return tens == null ? null : tens * 10;
    }
    if (raw.length == 3 && raw[1] == '十') {
      final tens = digits[raw[0]];
      final ones = digits[raw[2]];
      if (tens != null && ones != null) return tens * 10 + ones;
    }
    return null;
  }

  // 高频影视/动漫片名繁简对照表（显式键值对，杜绝拼接错位）。
  static const Map<String, String> _tradToSimpMap = {
    '萬': '万', '與': '与', '專': '专', '業': '业', '叢': '丛', '東': '东', '絲': '丝', '丟': '丢',
    '兩': '两', '嚴': '严', '喪': '丧', '個': '个', '臨': '临', '為': '为', '麗': '丽', '舉': '举',
    '麼': '么', '義': '义', '烏': '乌', '樂': '乐', '喬': '乔', '習': '习', '鄉': '乡', '書': '书',
    '買': '买', '亂': '乱', '爭': '争', '於': '于', '虧': '亏', '雲': '云', '亞': '亚', '產': '产',
    '親': '亲', '億': '亿', '僅': '仅', '僕': '仆', '從': '从', '倉': '仓', '儀': '仪', '們': '们',
    '價': '价', '眾': '众', '優': '优', '夥': '伙', '會': '会', '傘': '伞', '偉': '伟', '傳': '传',
    '傷': '伤', '倫': '伦', '偽': '伪', '體': '体', '餘': '余', '俠': '侠', '侶': '侣', '偵': '侦',
    '側': '侧', '僑': '侨', '盡': '尽', '傑': '杰', '備': '备', '債': '债', '傾': '倾', '儲': '储',
    '兒': '儿', '兇': '凶', '兌': '兑', '黨': '党', '蘭': '兰', '關': '关', '興': '兴', '養': '养',
    '獸': '兽', '岡': '冈', '冊': '册', '寫': '写', '軍': '军', '農': '农', '衝': '冲', '決': '决',
    '況': '况', '凍': '冻', '淨': '净', '準': '准', '涼': '凉', '減': '减', '湊': '凑', '凜': '凛',
    '幾': '几', '鳳': '凤', '憑': '凭', '凱': '凯', '擊': '击', '鑿': '凿', '劃': '划', '劉': '刘',
    '則': '则', '剛': '刚', '創': '创', '刪': '删', '別': '别', '劑': '剂', '劇': '剧', '劍': '剑',
    '勁': '劲', '勞': '劳', '勢': '势', '勳': '勋', '動': '动', '務': '务', '勝': '胜', '勸': '劝',
    '匯': '汇', '區': '区', '醫': '医', '華': '华', '協': '协', '單': '单', '盧': '卢', '衛': '卫',
    '卻': '却', '廳': '厅', '歷': '历', '厲': '厉', '壓': '压', '厭': '厌', '廁': '厕', '廂': '厢',
    '廈': '厦', '廚': '厨', '參': '参', '雙': '双', '發': '发', '變': '变', '敘': '叙', '疊': '叠',
    '葉': '叶', '號': '号', '嘆': '叹', '嗎': '吗', '聽': '听', '啟': '启', '吳': '吴', '員': '员',
    '嗚': '呜', '響': '响', '囉': '啰', '囑': '嘱', '團': '团', '園': '园', '圍': '围', '國': '国',
    '圖': '图', '圓': '圆', '聖': '圣', '場': '场', '塊': '块', '堅': '坚', '壇': '坛', '壩': '坝',
    '墳': '坟', '墜': '坠', '壘': '垒', '壞': '坏', '壟': '垄', '聲': '声', '殼': '壳', '壺': '壶',
    '壽': '寿', '處': '处', '複': '复', '夠': '够', '夢': '梦', '頭': '头', '誇': '夸', '夾': '夹',
    '奪': '夺', '奮': '奋', '獎': '奖', '奧': '奥', '妝': '妆', '婦': '妇', '媽': '妈', '娛': '娱',
    '嬰': '婴', '嬸': '婶', '孫': '孙', '學': '学', '實': '实', '寵': '宠', '審': '审', '宮': '宫',
    '寬': '宽', '賓': '宾', '寧': '宁', '寶': '宝', '尋': '寻', '導': '导', '將': '将', '對': '对',
    '爾': '尔', '塵': '尘', '嘗': '尝', '堯': '尧', '屍': '尸', '層': '层', '屆': '届', '屬': '属',
    '歲': '岁', '崗': '岗', '島': '岛', '峽': '峡', '嶺': '岭', '嶽': '岳', '巔': '巅', '巖': '岩',
    '幣': '币', '帥': '帅', '師': '师', '帳': '帐', '簾': '帘', '帶': '带', '幀': '帧', '幫': '帮',
    '幹': '干', '廣': '广', '庫': '库', '廢': '废', '廬': '庐', '開': '开', '異': '异', '棄': '弃',
    '張': '张', '強': '强', '彈': '弹', '彎': '弯', '彙': '汇', '彥': '彦', '徑': '径', '後': '后',
    '復': '复', '徵': '征', '徹': '彻', '憶': '忆', '懺': '忏', '應': '应', '憂': '忧', '懷': '怀',
    '態': '态', '憐': '怜', '總': '总', '戀': '恋', '恆': '恒', '恥': '耻', '懇': '恳', '惡': '恶',
    '惱': '恼', '愛': '爱', '憤': '愤', '願': '愿', '懾': '慑', '慘': '惨', '慚': '惭', '慣': '惯',
    '慶': '庆', '憲': '宪', '懲': '惩', '懶': '懒', '懸': '悬', '懼': '惧', '戲': '戏', '戰': '战',
    '載': '载', '戶': '户', '擁': '拥', '掃': '扫', '揚': '扬', '擾': '扰', '護': '护', '報': '报',
    '擔': '担', '擬': '拟', '攏': '拢', '揀': '拣', '攔': '拦', '擰': '拧', '撥': '拨', '擇': '择',
    '摯': '挚', '掙': '挣', '掛': '挂', '採': '采', '揮': '挥', '損': '损', '搖': '摇', '攝': '摄',
    '擺': '摆', '攤': '摊', '摟': '搂', '撈': '捞', '撓': '挠', '撫': '抚', '撲': '扑', '撿': '捡',
    '據': '据', '擠': '挤', '擱': '搁', '擲': '掷', '擴': '扩', '攜': '携', '攬': '揽', '敗': '败',
    '斂': '敛', '敵': '敌', '數': '数', '齋': '斋', '鬥': '斗', '斬': '斩', '斷': '断', '無': '无',
    '舊': '旧', '時': '时', '昇': '升', '晉': '晋', '曬': '晒', '曉': '晓', '晝': '昼', '暫': '暂',
    '暈': '晕', '暢': '畅', '曠': '旷', '術': '术', '機': '机', '殺': '杀', '雜': '杂', '權': '权',
    '條': '条', '來': '来', '楊': '杨', '極': '极', '構': '构', '棗': '枣', '槍': '枪', '楓': '枫',
    '櫃': '柜', '柵': '栅', '標': '标', '棧': '栈', '欄': '栏', '樹': '树', '棲': '栖', '檔': '档',
    '橋': '桥', '樺': '桦', '檢': '检', '棟': '栋', '樓': '楼', '樞': '枢', '樣': '样', '樸': '朴',
    '橫': '横', '櫥': '橱', '鬱': '郁', '歐': '欧', '欽': '钦', '歡': '欢', '歸': '归', '殲': '歼',
    '殘': '残', '殭': '僵', '毀': '毁', '毆': '殴', '畢': '毕', '斃': '毙', '氣': '气', '氫': '氢',
    '漢': '汉', '湯': '汤', '溝': '沟', '沒': '没', '瀝': '沥', '淪': '沦', '滄': '沧', '滬': '沪',
    '淚': '泪', '瀉': '泻', '潑': '泼', '澤': '泽', '潔': '洁', '灑': '洒', '洩': '泄', '淺': '浅',
    '漿': '浆', '澆': '浇', '濁': '浊', '測': '测', '濟': '济', '瀏': '浏', '渾': '浑', '濃': '浓',
    '濤': '涛', '澇': '涝', '漣': '涟', '濰': '维', '渦': '涡', '渙': '涣', '滌': '涤', '潤': '润',
    '澗': '涧', '漲': '涨', '澀': '涩', '澱': '淀', '淵': '渊', '漬': '渍', '漸': '渐', '漁': '渔',
    '滲': '渗', '溫': '温', '湧': '涌', '濕': '湿', '滅': '灭', '滾': '滚', '滯': '滞', '滿': '满',
    '潛': '潜', '潰': '溃', '濫': '滥', '濱': '滨', '濺': '溅', '濾': '滤', '瀕': '濒', '瀟': '潇',
    '瀾': '澜', '灘': '滩', '灣': '湾', '燈': '灯', '靈': '灵', '災': '灾', '燦': '灿', '爐': '炉',
    '燉': '炖', '點': '点', '煉': '炼', '熾': '炽', '爍': '烁', '爛': '烂', '燭': '烛', '煙': '烟',
    '煩': '烦', '燒': '烧', '燙': '烫', '燼': '烬', '熱': '热', '煥': '焕', '熒': '荧', '營': '营',
    '燬': '毁', '燻': '熏', '爺': '爷', '牆': '墙', '牘': '牍', '牽': '牵', '犧': '牺', '犢': '犊',
    '狀': '状', '猶': '犹', '獨': '独', '狹': '狭', '獅': '狮', '猙': '狰', '獄': '狱', '獵': '猎',
    '貓': '猫', '獻': '献', '獰': '狞', '獲': '获', '獺': '獭', '瑪': '玛', '環': '环', '現': '现',
    '覺': '觉', '珮': '佩', '瓊': '琼', '瑣': '琐', '瑤': '瑶', '瑩': '莹', '璽': '玺', '瓏': '珑',
    '甦': '苏', '電': '电', '畫': '画', '畝': '亩', '當': '当', '疇': '畴', '療': '疗',
    '瘋': '疯', '癢': '痒', '癡': '痴', '癥': '症', '癬': '癣', '癮': '瘾', '癱': '瘫', '癲': '癫',
    '皺': '皱', '盜': '盗', '盤': '盘', '監': '监', '盪': '荡', '著': '着', '睜': '睁',
    '瞞': '瞒', '瞭': '了', '瞼': '睑', '矇': '蒙', '矚': '瞩', '矯': '矫', '磚': '砖', '硯': '砚',
    '砲': '炮', '礪': '砺', '硃': '朱', '碩': '硕', '確': '确', '碼': '码', '礎': '础', '礙': '碍',
    '礦': '矿', '禮': '礼', '禱': '祷', '禍': '祸', '禦': '御', '禪': '禅', '離': '离', '種': '种',
    '稅': '税', '稱': '称', '穀': '谷', '積': '积', '穎': '颖', '穩': '稳', '穫': '获', '窮': '穷',
    '窯': '窑', '窺': '窥', '竄': '窜', '竅': '窍', '竊': '窃', '競': '竞', '筍': '笋', '筆': '笔',
    '箏': '筝', '節': '节', '範': '范', '築': '筑', '篩': '筛', '簡': '简', '簫': '箫', '簽': '签',
    '籃': '篮', '籌': '筹', '籐': '藤', '籟': '籁', '籠': '笼', '籤': '签', '籬': '篱',
    '籲': '吁', '類': '类', '粵': '粤', '糞': '粪', '糧': '粮', '糾': '纠', '紀': '纪', '約': '约',
    '紅': '红', '紋': '纹', '納': '纳', '紐': '纽', '純': '纯', '紗': '纱', '紙': '纸', '級': '级',
    '紛': '纷', '紡': '纺', '緊': '紧', '紮': '扎', '細': '细', '紳': '绅', '紹': '绍', '終': '终',
    '絃': '弦', '組': '组', '結': '结', '絕': '绝', '絞': '绞', '絡': '络', '絢': '绚', '給': '给',
    '絨': '绒', '統': '统', '絳': '绛', '絹': '绢', '綁': '绑', '綏': '绥', '經': '经', '綜': '综',
    '綠': '绿', '綢': '绸', '線': '线', '維': '维', '綱': '纲', '網': '网', '綴': '缀', '綵': '彩',
    '綸': '纶', '綽': '绰', '綾': '绫', '綿': '绵', '緋': '绯', '緒': '绪', '緝': '缉', '緞': '缎',
    '締': '缔', '緣': '缘', '編': '编', '緩': '缓', '緬': '缅', '緯': '纬', '練': '练', '緻': '致',
    '縈': '萦', '縊': '缢', '縛': '缚', '縣': '县', '縫': '缝', '縮': '缩', '縱': '纵', '纖': '纤',
    '縷': '缕', '績': '绩', '繆': '缪', '織': '织', '繚': '缭', '繞': '绕', '繡': '绣',
    '繩': '绳', '繪': '绘', '繫': '系', '繭': '茧', '繳': '缴', '繹': '译', '繼': '继', '繽': '缤',
    '續': '续', '纏': '缠', '纓': '缨', '纜': '缆', '羅': '罗', '罰': '罚', '罵': '骂', '罷': '罢',
    '羈': '羁', '羨': '羡', '翹': '翘', '聯': '联', '聰': '聪', '聳': '耸', '職': '职', '聾': '聋',
    '肅': '肃', '腸': '肠', '膚': '肤', '餚': '肴', '腎': '肾', '腫': '肿', '脹': '胀', '脅': '胁',
    '膽': '胆', '膠': '胶', '脈': '脉', '脊': '脊', '臟': '脏', '臍': '脐', '腦': '脑',
    '膿': '脓', '腳': '脚', '脫': '脱', '臉': '脸', '騰': '腾', '膩': '腻', '臘': '腊', '臺': '台',
    '艦': '舰', '艙': '舱', '艱': '艰', '艷': '艳', '豔': '艳', '蕪': '芜', '蘆': '芦', '蘋': '苹',
    '荊': '荆', '薦': '荐', '蕩': '荡', '榮': '荣', '葷': '荤', '藥': '药', '莊': '庄', '莖': '茎',
    '萊': '莱', '蓮': '莲', '鶯': '莺', '蘿': '萝', '螢': '萤', '蕭': '萧',
    '薩': '萨', '蔥': '葱', '蔣': '蒋', '藍': '蓝', '藝': '艺', '藹': '蔼', '藺': '蔺', '蘇': '苏',
    '蘊': '蕴', '虜': '虏', '慮': '虑', '虛': '虚', '蟲': '虫', '蠶': '蚕', '蠻': '蛮', '蟄': '蛰',
    '蛻': '蜕', '蝸': '蜗', '蠟': '蜡', '蟬': '蝉', '蝕': '蚀', '蝦': '虾', '螞': '蚂', '蟻': '蚁',
    '蠅': '蝇', '蠍': '蝎', '蠱': '蛊', '襯': '衬', '襪': '袜', '襲': '袭', '裝': '装',
    '裡': '里', '補': '补', '褲': '裤', '製': '制', '襖': '袄', '襠': '裆', '見': '见', '規': '规',
    '覓': '觅', '視': '视', '覽': '览', '觀': '观', '觸': '触', '訂': '订', '計': '计', '訊': '讯',
    '討': '讨', '訓': '训', '託': '托', '記': '记', '訛': '讹', '訝': '讶', '訟': '讼', '訣': '诀',
    '訪': '访', '設': '设', '許': '许', '訴': '诉', '診': '诊', '註': '注', '證': '证', '評': '评',
    '詛': '诅', '識': '识', '詐': '诈', '詆': '诋', '詞': '词', '詔': '诏', '詠': '咏', '詢': '询',
    '詣': '诣', '試': '试', '詩': '诗', '詫': '诧', '詭': '诡', '詮': '诠', '詰': '诘', '話': '话',
    '該': '该', '詳': '详', '詼': '诙', '誅': '诛', '誌': '志', '認': '认', '誕': '诞',
    '誘': '诱', '語': '语', '誠': '诚', '誡': '诫', '誣': '诬', '誤': '误', '誦': '诵', '誨': '诲',
    '說': '说', '誰': '谁', '課': '课', '誹': '诽', '誼': '谊', '調': '调', '諄': '谆', '談': '谈',
    '請': '请', '諒': '谅', '論': '论', '諜': '谍', '諡': '谥', '諦': '谛', '諧': '谐', '諫': '谏',
    '諭': '谕', '諮': '咨', '諱': '讳', '諷': '讽', '諸': '诸', '諺': '谚', '諾': '诺', '謀': '谋',
    '謁': '谒', '謂': '谓', '謊': '谎', '謎': '谜', '謔': '谑', '謗': '谤', '謙': '谦', '講': '讲',
    '謝': '谢', '謠': '谣', '謨': '谟', '謬': '谬', '謹': '谨', '譁': '哗', '譏': '讥', '譚': '谭',
    '譜': '谱', '譯': '译', '議': '议', '譴': '谴', '譽': '誉', '讀': '读', '讒': '谗', '讓': '让',
    '讚': '赞', '豈': '岂', '豎': '竖', '豐': '丰', '豬': '猪', '貝': '贝', '貞': '贞', '負': '负',
    '財': '财', '貢': '贡', '貧': '贫', '貨': '货', '販': '贩', '貪': '贪', '貫': '贯', '責': '责',
    '貴': '贵', '貶': '贬', '貸': '贷', '費': '费', '貼': '贴', '貿': '贸', '賀': '贺',
    '賃': '赁', '賄': '贿', '資': '资', '賈': '贾', '賊': '贼', '賑': '赈', '賜': '赐', '賞': '赏',
    '賠': '赔', '賢': '贤', '賣': '卖', '賤': '贱', '賦': '赋', '質': '质', '賬': '账', '賭': '赌',
    '賴': '赖', '賺': '赚', '購': '购', '賽': '赛', '贊': '赞', '贈': '赠', '贏': '赢', '贓': '赃',
    '贖': '赎', '贛': '赣', '趙': '赵', '趕': '赶', '趨': '趋', '跡': '迹', '踐': '践', '蹤': '踪',
    '躍': '跃', '軀': '躯', '車': '车', '軋': '轧', '軌': '轨', '軒': '轩', '軟': '软', '軸': '轴',
    '輕': '轻', '較': '较', '輔': '辅', '輛': '辆', '輝': '辉', '輩': '辈', '輪': '轮', '輯': '辑',
    '輸': '输', '輻': '辐', '輾': '辗', '輿': '舆', '轄': '辖', '轅': '辕', '轉': '转', '轍': '辙',
    '轎': '轿', '轟': '轰', '辭': '辞', '辦': '办', '辯': '辩', '邊': '边', '遼': '辽', '達': '达',
    '遷': '迁', '過': '过', '邁': '迈', '運': '运', '還': '还', '這': '这', '進': '进', '遠': '远',
    '違': '违', '連': '连', '遲': '迟', '迴': '回', '適': '适', '選': '选', '遜': '逊', '遞': '递',
    '週': '周', '遊': '游', '遙': '遥', '遺': '遗', '邏': '逻', '郵': '邮', '鄭': '郑', '鄰': '邻',
    '鄧': '邓', '醞': '酝', '醜': '丑', '醬': '酱', '釀': '酿', '釁': '衅', '釋': '释', '釐': '厘',
    '針': '针', '釘': '钉', '釣': '钓', '鈍': '钝', '鈔': '钞', '鈕': '钮', '鈞': '钧', '鈣': '钙',
    '鈴': '铃', '鈾': '铀', '鉀': '钾', '鉑': '铂', '鉗': '钳', '鉚': '铆', '鉛': '铅', '鉤': '钩',
    '鐵': '铁', '銀': '银', '銅': '铜', '銘': '铭', '銜': '衔', '鋁': '铝', '銳': '锐', '銷': '销',
    '銹': '锈', '鋅': '锌', '鋒': '锋', '鋤': '锄', '鋪': '铺', '鋰': '锂', '鋸': '锯', '鋼': '钢',
    '錄': '录', '錐': '锥', '錘': '锤', '錚': '铮', '錠': '锭', '錢': '钱', '錦': '锦', '錨': '锚',
    '錫': '锡', '錯': '错', '錳': '锰', '錶': '表', '鍊': '炼', '鍋': '锅', '鍍': '镀', '鍛': '锻',
    '鍬': '锹', '鍵': '键', '鍾': '钟', '鎂': '镁', '鎊': '镑', '鎔': '熔', '鎖': '锁', '鎗': '枪',
    '鎚': '锤', '鎢': '钨', '鎧': '铠', '鎮': '镇', '鎳': '镍', '鎬': '镐', '鏈': '链', '鏗': '铿',
    '鏘': '锵', '鏡': '镜', '鏢': '镖', '鏤': '镂', '鏽': '锈', '鐘': '钟', '鐮': '镰', '鑄': '铸',
    '鑑': '鉴', '鑒': '鉴', '鑛': '矿', '鑰': '钥', '鑲': '镶', '鑷': '镊', '鑼': '锣', '鑽': '钻',
    '長': '长', '門': '门', '閃': '闪', '閉': '闭', '閏': '闰', '閑': '闲', '間': '间',
    '閔': '闵', '閘': '闸', '閣': '阁', '閥': '阀', '閨': '闺', '閩': '闽', '閱': '阅', '閻': '阎',
    '闊': '阔', '闌': '阑', '闡': '阐', '闢': '辟', '隊': '队', '陝': '陕', '陞': '升', '陣': '阵',
    '陰': '阴', '陳': '陈', '陸': '陆', '陽': '阳', '階': '阶', '隕': '陨', '際': '际',
    '隱': '隐', '隴': '陇', '隸': '隶', '隻': '只', '雖': '虽', '雛': '雏', '雞': '鸡', '難': '难',
    '霧': '雾', '靄': '霭', '霽': '霁', '靂': '雳', '靜': '静', '鞏': '巩', '韋': '韦',
    '韌': '韧', '韓': '韩', '韻': '韵', '頁': '页', '頂': '顶', '頃': '顷', '項': '项', '順': '顺',
    '須': '须', '頌': '颂', '預': '预', '頑': '顽', '頒': '颁', '頓': '顿', '頗': '颇', '領': '领',
    '頜': '颌', '頤': '颐', '頰': '颊', '頸': '颈', '頹': '颓', '頻': '频', '顆': '颗', '題': '题',
    '額': '额', '顏': '颜', '顛': '颠', '顧': '顾', '顫': '颤', '顯': '显', '顱': '颅', '顴': '颧',
    '風': '风', '颺': '扬', '颯': '飒', '颱': '台', '颳': '刮', '颶': '飓', '飄': '飘', '飆': '飙',
    '飛': '飞', '飢': '饥', '飯': '饭', '飲': '饮', '飼': '饲', '飽': '饱', '飾': '饰', '餃': '饺',
    '餅': '饼', '餉': '饷', '餌': '饵', '餒': '馁', '餓': '饿', '餛': '馄', '餞': '饯', '餡': '馅',
    '館': '馆', '餵': '喂', '餾': '馏', '饅': '馒', '饒': '饶', '饑': '饥', '饌': '馔', '饋': '馈',
    '饗': '飨', '馬': '马', '馭': '驭', '馮': '冯', '馱': '驼', '馳': '驰', '馴': '驯', '駁': '驳',
    '駐': '驻', '駒': '驹', '駕': '驾', '駛': '驶', '駝': '驼', '駭': '骇', '駱': '骆', '駿': '骏',
    '騁': '骋', '騎': '骑', '騙': '骗', '騷': '骚', '驅': '驱', '騾': '骡', '驀': '蓦', '驁': '骜',
    '驍': '骁', '驕': '骄', '驗': '验', '驚': '惊', '驛': '驿', '驟': '骤', '驢': '驴', '驤': '骧',
    '驥': '骥', '髒': '脏', '髮': '发', '鬍': '胡', '鬚': '须', '鬢': '鬓', '鬧': '闹', '魚': '鱼',
    '魯': '鲁', '鮑': '鲍', '鮭': '鲑', '鮮': '鲜', '鯉': '鲤', '鯊': '鲨', '鯛': '鲷', '鯤': '鲲',
    '鯨': '鲸', '鯽': '鲫', '鰓': '鳃', '鱷': '鳄', '鰭': '鳍', '鰻': '鳗', '鱈': '鳕', '鱉': '鳖',
    '鱒': '鳟', '鱗': '鳞', '鱘': '鲟', '鳥': '鸟', '鳩': '鸠', '鳴': '鸣', '鴉': '鸦', '鴕': '鸵',
    '鴛': '鸳', '鴦': '鸯', '鴨': '鸭', '鴻': '鸿', '鴿': '鸽', '鵑': '鹃', '鵝': '鹅', '鵠': '鹄',
    '鵡': '鹉', '鵬': '鹏', '鵲': '鹊', '鶉': '鹑', '鶴': '鹤', '鷗': '鸥', '鷺': '鹭',
    '鷹': '鹰', '鹹': '咸', '鹼': '碱', '鹽': '盐', '麥': '麦', '麩': '麸', '麵': '面', '黃': '黄',
    '黴': '霉', '齊': '齐', '齒': '齿', '齡': '龄', '龍': '龙', '龐': '庞', '龔': '龚', '龜': '龟',
  };
}
